-- 0115 — Ajustes de cuota (Sprint 2 del audit 2026-06-11) + reversión de
-- descuentos al anular pago (fix M3).
--
-- FEATURE (aprobada por Rubén 2026-06-11): el admin/admin_cobranza puede
-- aplicar un AJUSTE (descuento con motivo) a una cuota — p.ej. el cliente
-- pasó sin servicio N días. Principio rector: todo ajuste/promo es una fila
-- en `cargos_extra` (NUNCA se muta `cuotas.monto`): el saldo, los mirrors,
-- el changelog y las invariantes ya digieren cargos_extra.
--
-- FIX M3 (audit): los descuentos automáticos (pronto pago) que un cobro
-- insertaba NO se revertían al anular el pago — la cuota quedaba con el
-- total rebajado para siempre. Ahora cada cargo nacido de un cobro lleva
-- `pago_id`, y anular el pago BORRA sus descuentos (trigger server +
-- mirror local en PagosRepo.anularPago).
--
-- Cadena de integridad (Receta R4): correr esta migración → schema.dart
-- (3 columnas nuevas) → bump _schemaVersion 26→27 → redeploy sync rules
-- ("Active"; los SELECT * las incluyen solos) → app desde cero.

BEGIN;

-- =========================================================================
-- 1. Columnas nuevas de cargos_extra.
--    `origen`: de qué flujo nació el cargo (gobierna guards y UI).
--    `grupo_promo`: agrupa los N cargos de una promoción (Sprint 3) para
--    mostrarlos/revertirlos juntos.
--    `pago_id`: el pago que insertó este cargo automático (M3). SIN FK a
--    propósito: PowerSync sube la CRUD queue en orden de escritura y los
--    cargos del cobro se insertan ANTES que su pago — una FK rebotaría el
--    cargo con 23503 y el connector lo descartaría. La coherencia la
--    garantizan el flujo de cobro (transacción local) y este archivo.
-- =========================================================================
alter table public.cargos_extra
  add column origen text not null default 'cobro'
    check (origen in ('cobro', 'ajuste', 'promo', 'liquidacion')),
  add column grupo_promo uuid,
  add column pago_id uuid;

create index cargos_extra_pago_idx
  on public.cargos_extra (pago_id)
  where pago_id is not null;

comment on column public.cargos_extra.origen is
  'Flujo que creó el cargo: cobro (campo/auto), ajuste (admin con motivo), '
  'promo (Sprint 3), liquidacion (cancelar contrato).';

-- =========================================================================
-- 2. Helper setting_bool (espejo de setting_number, 0011).
-- =========================================================================
create or replace function public.setting_bool(
  p_tenant_id uuid, p_clave text, p_default boolean)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select (valor)::boolean
       from public.settings
      where tenant_id = p_tenant_id and clave = p_clave),
    p_default
  )
$$;

-- =========================================================================
-- 3. Settings del feature (patrón 0085/0086: super-only, enforced por la
--    policy settings_write_admin que excluye editable_por='super_admin').
-- =========================================================================
create or replace function public.seed_settings_ajustes(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'cobranza.ajustes_habilitados', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite al admin aplicar ajustes (descuentos con motivo) a cuotas',
     'super_admin'),
    (p_tenant_id, 'cobranza.ajuste_max_porcentaje', '50'::jsonb, 'number',
     'cobranza', 'Tope porcentual de un ajuste de cuota (0=sin tope)',
     'super_admin'),
    (p_tenant_id, 'cobranza.ajuste_max_monto', '0'::jsonb, 'number',
     'cobranza', 'Tope en C$ de un ajuste de cuota (0=sin tope)',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_ajustes(v_t.id);
  end loop;
end $$;

-- Tenant nuevo: encadenar el seed. OJO (audit Fase 4): se parte del cuerpo
-- VIGENTE (0113 — incluye recibo_layout, el default 5 de dias_cuotas_visibles
-- y la promoción super-only de las 4 claves sensibles), NO del de 0085.
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  -- Default nuevo: 5 días de cuotas próximas (el seed aún inserta 30; se
  -- normaliza acá para no recrear la función completa). [0113]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  -- Reglas/permisos sensibles → super_admin-only. [0113]
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial', 'cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros',
                    'cobranza.cobrador_edita_cobros');
  -- Ajustes de cuota (0115).
  perform public.seed_settings_ajustes(new.id);
  return new;
end;
$$;

-- =========================================================================
-- 4. Guard server-side de ajustes (el control REAL, no solo UI — lección
--    del finding 0046/M7: un setting que gatea dinero se enforcea acá).
--    Sin bypass para super_admin a propósito (previene errores; el súper
--    puede cambiar los topes si lo necesita).
-- =========================================================================
create or replace function public.cargos_ajuste_guard_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_max_pct numeric;
  v_max_monto numeric;
begin
  -- Cascadas y re-upserts NO se re-validan (audit Fase 4): un UPDATE que no
  -- toca los campos gobernados (p.ej. la reasignación de cobrador de 0068,
  -- o el re-upsert idéntico de un retry de batch de PowerSync) pasa de
  -- largo — sin esto, deshabilitar el feature o bajar topes REBOTABA
  -- cascadas sobre ajustes históricos legítimos.
  if tg_op = 'UPDATE'
     and new.tipo = old.tipo
     and new.monto = old.monto
     and coalesce(new.porcentaje, -1) = coalesce(old.porcentaje, -1)
     and coalesce(new.descripcion, '') = coalesce(old.descripcion, '')
     and new.origen = old.origen then
    return new;
  end if;
  if not public.setting_bool(
      new.tenant_id, 'cobranza.ajustes_habilitados', false) then
    raise exception
      'Los ajustes de cuota no están habilitados para esta empresa';
  end if;
  if public.current_user_rol() = 'cobrador' then
    raise exception 'Solo un admin puede aplicar ajustes de cuota';
  end if;
  if new.tipo not in ('descuento_monto', 'descuento_porcentaje') then
    raise exception
      'Un ajuste solo puede ser un descuento (monto o porcentaje)';
  end if;
  if new.descripcion is null or btrim(new.descripcion) = '' then
    raise exception 'El ajuste requiere un motivo';
  end if;

  v_max_pct := public.setting_number(
      new.tenant_id, 'cobranza.ajuste_max_porcentaje', 0);
  v_max_monto := public.setting_number(
      new.tenant_id, 'cobranza.ajuste_max_monto', 0);
  if v_max_pct > 0
     and new.tipo = 'descuento_porcentaje'
     and coalesce(new.porcentaje, 0) > v_max_pct then
    raise exception
      'El ajuste excede el tope configurado de % por ciento', v_max_pct;
  end if;
  if v_max_monto > 0 and new.monto > v_max_monto + 0.01 then
    raise exception 'El ajuste excede el tope de C$% configurado', v_max_monto;
  end if;
  -- Limitación documentada (audit Fase 4, BAJA): el guard NO valida
  -- monto ≤ saldo (carrera offline cobro+ajuste puede sobrepagar; el repo
  -- lo valida con su snapshot local e INV4 lo detecta a posteriori) —
  -- misma clase aceptada que el cobro concurrente multi-dispositivo.
  return new;
end $$;

create trigger trg_cargos_ajuste_guard
  before insert or update on public.cargos_extra
  for each row
  when (new.origen = 'ajuste')
  execute function public.cargos_ajuste_guard_trg();

-- =========================================================================
-- 5. M3: anular un pago borra LOS DESCUENTOS que ese cobro insertó (los
--    identifica pago_id). La reconexión se preserva a propósito (se sigue
--    debiendo). El DELETE dispara en cascada trg_cargos_extra_actualizar_neto
--    (0023, recalcula cargos_neto) y trg_cargos_extra_recalcular_cuota
--    (0018, recalcula estado) — depth 1 al encolar, así que el changelog
--    del cargo borrado SÍ se registra (guard depth<2).
--    Orden con trg_pagos_update_recalcular: alfabético → 'revertir' corre
--    ANTES que 'update_recalcular'; ambos recálculos son SUMs idempotentes.
-- =========================================================================
create or replace function public.pagos_revertir_descuentos_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.cargos_extra
   where pago_id = new.id
     and tipo in ('descuento_monto', 'descuento_porcentaje');
  return new;
end $$;

create trigger trg_pagos_revertir_descuentos
  after update of anulado on public.pagos
  for each row
  when (new.anulado = true and old.anulado = false)
  execute function public.pagos_revertir_descuentos_trg();

-- =========================================================================
-- 6. Quitar ajuste también para admin_cobranza (QA Fase 4, finding ALTO):
--    la policy de DELETE de 0013 exigía is_admin(), pero la UI de ajustes
--    es para admin Y admin_cobranza — su DELETE moría FILTRADO por RLS en
--    silencio (0 filas, sin error) y el cargo "resucitaba" al sync con la
--    cuota ya espejada en 0 → divergencia muda de dinero. UPDATE ya era
--    is_admin_or_cobranza (cargos_write_admins); el DELETE se alinea.
-- =========================================================================
drop policy "cargos_delete_admin" on public.cargos_extra;
create policy "cargos_delete_admin" on public.cargos_extra
  for delete using (
    tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza()
  );

COMMIT;

-- Verificación post-deploy (correr a mano):
--   select column_name from information_schema.columns
--    where table_name = 'cargos_extra'
--      and column_name in ('origen','grupo_promo','pago_id');   -- 3 filas
--   select tgname from pg_trigger
--    where tgrelid = 'public.cargos_extra'::regclass
--      and tgname = 'trg_cargos_ajuste_guard';                  -- 1 fila
--   select tgname from pg_trigger
--    where tgrelid = 'public.pagos'::regclass
--      and tgname = 'trg_pagos_revertir_descuentos';            -- 1 fila
--   select count(*) from public.settings
--    where clave like 'cobranza.ajuste%';        -- 3 × cantidad de tenants
