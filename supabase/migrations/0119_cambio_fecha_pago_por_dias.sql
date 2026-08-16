-- 0119 — Feature C: Cambio de fecha de pago por días (offline-first).
--
-- VISIÓN (decisiones de Rubén, 2026-06-14):
--   El cliente quiere mover su día de pago (ej. del 15 al 30, o al 10). Si está
--   AL DÍA, paga los "días puente" entre su fecha vieja y la nueva (prorrateados
--   = precio_mensual / días reales del mes), con RECIBO en el momento. A partir
--   de ahí su calendario corre en el día nuevo. El personal habilitado lo hace
--   desde un botón al lado de "Pagar" (lista de cobros + mapa), en CAMPO, OFFLINE.
--
-- GATING de 2 niveles:
--   (1) Por TENANT: el super_admin activa la feature (setting super-only
--       'cobranza.cambio_fecha_habilitado'). Es excepcional.
--   (2) Por USUARIO: el admin habilita a cobradores/admin_cobranza específicos
--       (columna cobradores.puede_cambiar_fecha). El rol 'admin' siempre puede
--       (con la feature ON). Sin flujo de aprobación extra: el personal habilitado
--       = capacitado.
--
-- MODELO (Diseño A, decisión de Rubén 2026-06-14; re-anclaje orquestado por el
--   CLIENTE como cambios de filas que sincronizan; el server NO necesita un RPC):
--   - Cargo PUENTE = un cargos_extra (origen='puente', tipo='otro' → SUMA) sobre
--     la ÚLTIMA cuota pagada del contrato (host: cargos_extra.cuota_id es NOT NULL
--     y una cuota anulada no puede alojar el pago). Se cobra al instante → genera
--     pago + recibo con la línea "Puente de pago". Entra a RECAUDADO; NO infla el
--     total fijo (precio × meses) — es ingreso extra, como una reconexión
--     (invariantes #9/#10 intactos).
--   - La/s cuota/s pendiente/s que caen DENTRO de la ventana del puente quedan
--     ABSORBIDAS (anuladas, sin pago = sin deuda); el primer pago completo pasa al
--     día nuevo. Salto corto que no cruza de mes → 0 absorbidas (solo se corre el
--     vencimiento); salto que cruza de mes → se absorbe la cuota de ese mes.
--   - Las cuotas futuras pendientes se mueven al día nuevo: lo hace AUTOMÁTICO el
--     trigger contratos_actualizar_cuotas_futuras_trg (0018) al UPDATE de dia_pago
--     (fecha_vencimiento = calcular_fecha_pago(periodo, dia_pago_nuevo)). El cliente
--     lo espeja local (port Dart de calcular_fecha_pago) para verlo offline al instante.
--   - Contratos de plazo fijo: el cliente agrega 1 cuota de cierre al final (período
--     libre, día nuevo) por cada absorbida → conserva el conteo ACTIVO en
--     duracion_meses (total fijo intacto) → el servicio termina unos días después.
--     Indefinidos: solo se re-ancla el cushion. INV11 (invariantes_dinero.sql) cuenta
--     solo cuotas NO anuladas para no marcar la absorbida + cierre como sobre-generación.
--
-- OFFLINE: como el cobrador opera sin internet, NO se puede usar un RPC server.
--   Los writes ocurren LOCAL (PowerSync) y suben vía RLS. Por eso esta migración
--   EXTIENDE la RLS de contratos/cuotas para permitir esos writes SOLO al personal
--   habilitado y SOLO sobre SUS PROPIOS contratos/cuotas, y RELAJA el guard
--   cuotas_check_cobrador_update (0111/0022) para que el personal habilitado pueda
--   re-fechar (fecha_vencimiento) y absorber (anular) — ver bloques 5 y 6. ⚠ Cambio
--   de acceso sensible — revisar en el audit de seguridad (Fase 4).
--
-- cargos_extra.origen tenía CHECK cerrado (0115) → este archivo lo EXTIENDE con
--   'puente' (bloque 5). El label legible y la línea del recibo se mapean en el cliente.
--
-- POST-DEPLOY: bump schema.dart (cobradores.puede_cambiar_fecha) + _schemaVersion
--   27→28 + redeploy sync rules (la columna se agregó a los SELECT de cobradores).

-- =========================================================================
-- 1. Permiso por usuario (lo habilita el admin a cobradores/admin_cobranza)
-- =========================================================================
alter table public.cobradores
  add column if not exists puede_cambiar_fecha boolean not null default false;

-- =========================================================================
-- 2. Setting super-only por tenant: feature habilitada (patrón 0085/0086).
--    Se agrega la clave nueva a seed_settings_super_only y se re-siembra.
-- =========================================================================
create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.cambio_fecha_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite el cambio de fecha de pago por días (personal habilitado por el admin)',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;

-- =========================================================================
-- 3. Helper: ¿el usuario actual puede cambiar fecha de pago?
--    feature ON (tenant) AND (rol admin OR permiso por usuario).
-- =========================================================================
create or replace function public.puede_cambiar_fecha_pago()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce((
      -- settings.valor es TEXT (0011 lo migró de jsonb a text serializado para
      -- el cliente SQLite); el cliente lo escribe con jsonEncode(bool) → 'true'
      -- /'false'. Comparar como texto (no como jsonb).
      select s.valor = 'true'
        from public.settings s
       where s.tenant_id = public.current_tenant_id()
         and s.clave = 'cobranza.cambio_fecha_habilitado'
    ), false)
    and coalesce((
      select (c.rol = 'admin' or c.puede_cambiar_fecha)
        from public.cobradores c
       where c.id = auth.uid()
    ), false);
$$;

-- =========================================================================
-- 4. RLS: permitir al personal habilitado los writes del cambio de fecha,
--    SOLO sobre SUS PROPIOS contratos/cuotas (cobrador_id = auth.uid()).
--    Los admins/admin_cobranza ya están cubiertos por *_write_admins (0013).
--    Estas policies SUMAN acceso (permissive OR), gateado por la feature+permiso.
-- =========================================================================

-- contratos: UPDATE (dia_pago / fecha_fin) del re-anclaje.
drop policy if exists "contratos_cambiar_fecha" on public.contratos;
create policy "contratos_cambiar_fecha" on public.contratos
  for update
  using (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  )
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  );

-- cuotas: INSERT (cuota de cierre en fijos). Exige que el contrato sea del
-- propio cobrador (patrón endurecido de 0022: el cobrador setea cobrador_id en
-- su propia fila, así que sin el EXISTS podría insertar contra contratos ajenos).
drop policy if exists "cuotas_cambiar_fecha_insert" on public.cuotas;
create policy "cuotas_cambiar_fecha_insert" on public.cuotas
  for insert
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
    and exists (
      select 1 from public.contratos c
       where c.id = cuotas.contrato_id
         and c.cobrador_id = auth.uid()
         and c.tenant_id = public.current_tenant_id()
    )
  );

-- cuotas: UPDATE (anular la cuota absorbida; el día de las futuras lo mueve el
-- trigger 0018 como SECURITY DEFINER). NO se habilita DELETE.
drop policy if exists "cuotas_cambiar_fecha_update" on public.cuotas;
create policy "cuotas_cambiar_fecha_update" on public.cuotas
  for update
  using (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  )
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.puede_cambiar_fecha_pago()
  );

-- NOTA: pagos/recibos ya permiten al cobrador insertar los suyos (0013), así que
-- el cobro del puente + su recibo no requieren policy nueva.

-- =========================================================================
-- 5. Extender el CHECK de cargos_extra.origen para admitir 'puente' (Diseño A).
--    El cargo puente es un cargos_extra origen='puente' tipo='otro' (SUMA) sobre
--    la última cuota pagada. El CHECK de 0115 es inline (nombre autogenerado) →
--    lo ubicamos por pg_constraint y lo reemplazamos por uno con nombre estable.
-- =========================================================================
do $$
declare
  v_con text;
begin
  select c.conname into v_con
    from pg_constraint c
   where c.conrelid = 'public.cargos_extra'::regclass
     and c.contype = 'c'
     and pg_get_constraintdef(c.oid) ilike '%origen%'
     and pg_get_constraintdef(c.oid) ilike '%cobro%'
   limit 1;
  if v_con is not null then
    execute format('alter table public.cargos_extra drop constraint %I', v_con);
  end if;
end $$;

alter table public.cargos_extra
  add constraint cargos_extra_origen_check
  check (origen in ('cobro', 'ajuste', 'promo', 'liquidacion', 'puente'));

-- =========================================================================
-- 6. Relajar el guard cuotas_check_cobrador_update (0111/0022) para el personal
--    habilitado: necesita RE-FECHAR (fecha_vencimiento) las futuras y ABSORBER
--    (anular con metadata) la/s cuota/s del puente, OFFLINE, sobre SUS cuotas.
--    Sigue PROHIBIDO para el cobrador: des-anular (reactivar) y los cambios
--    estructurales (monto/contrato/cliente/cobrador/periodo/tenant).
--    ⚠ Cambio de acceso sensible (Fase 4 seguridad): un cobrador habilitado
--    puede anular/re-fechar SUS cuotas sin aprobación extra (modelo "habilitado
--    = capacitado"). El gating feature+permiso (puede_cambiar_fecha_pago()) y el
--    scope cobrador_id=auth.uid() de las policies 0119 lo acotan.
-- =========================================================================
create or replace function public.cuotas_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text;
begin
  v_rol := public.current_user_rol();
  if v_rol = 'cobrador' then
    if public.puede_cambiar_fecha_pago() then
      -- Personal habilitado (feature C): puede re-fechar (fecha_vencimiento) y
      -- ABSORBER (anular) SOLO SUS PROPIAS cuotas, y la anulación SOLO con el
      -- marcador del flujo legítimo. Necesario porque la policy permissive
      -- cuotas_update_cobrador_propio (0025) NO scopea por dueño (confía en este
      -- guard) y las permissive se unen con OR → sin esto un cobrador habilitado
      -- podría anular por API cuotas pendientes de otros clientes del tenant.
      if new.cobrador_id is distinct from auth.uid()
         or old.cobrador_id is distinct from auth.uid()
      then
        raise exception 'cobrador solo puede cambiar la fecha de SUS propias cuotas';
      end if;
      -- Sigue bloqueado: cambios estructurales y des-anular.
      if new.monto         is distinct from old.monto         or
         new.contrato_id   is distinct from old.contrato_id   or
         new.cliente_id    is distinct from old.cliente_id    or
         new.cobrador_id   is distinct from old.cobrador_id   or
         new.periodo       is distinct from old.periodo       or
         new.tenant_id     is distinct from old.tenant_id     or
         (new.estado <> old.estado and old.estado = 'anulada')
      then
        raise exception 'cobrador no puede cambiar monto/contrato/periodo ni reactivar cuotas anuladas';
      end if;
      -- Anular SOLO por el flujo de cambio de fecha (marcador del motivo): una
      -- anulación arbitraria por el cobrador (borrar deuda) sigue prohibida.
      if new.estado <> old.estado and new.estado = 'anulada'
         and coalesce(new.motivo_anulacion, '') <> 'Absorbida por cambio de fecha de pago'
      then
        raise exception 'cobrador solo puede anular cuotas por cambio de fecha de pago';
      end if;
    else
      -- Guard original (sin la feature de cambio de fecha habilitada).
      if new.monto         is distinct from old.monto         or
         new.contrato_id   is distinct from old.contrato_id   or
         new.cliente_id    is distinct from old.cliente_id    or
         new.cobrador_id   is distinct from old.cobrador_id   or
         new.periodo       is distinct from old.periodo       or
         new.fecha_vencimiento is distinct from old.fecha_vencimiento or
         new.tenant_id     is distinct from old.tenant_id     or
         new.anulada_en    is distinct from old.anulada_en    or
         new.anulada_por   is distinct from old.anulada_por   or
         new.motivo_anulacion is distinct from old.motivo_anulacion or
         -- No puede anular...
         (new.estado <> old.estado and new.estado = 'anulada') or
         -- ...ni des-anular (reactivar) una cuota ya anulada.
         (new.estado <> old.estado and old.estado = 'anulada')
      then
        raise exception 'cobrador no puede anular ni reactivar cuotas; sólo monto_pagado y transiciones de cobro';
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- =========================================================================
-- 7. Guard BEFORE UPDATE en contratos: el rol cobrador (que ahora tiene UPDATE
--    vía contratos_cambiar_fecha, bloque 4) SOLO puede tocar dia_pago y fecha_fin
--    del re-anclaje; todo lo demás, congelado. Sin esto la policy daría UPDATE de
--    TODAS las columnas: un PATCH directo de fecha_fin hacia ATRÁS dispara
--    limpiar_cuotas_excedentes (0023, SECURITY DEFINER) que BORRA cuotas
--    pendientes (deuda); cambiar plan_id/duracion_meses rompería el total fijo
--    (#5); estado='cancelado' cancelaría el contrato. admins/admin_cobranza no
--    pasan por este if (su rol no es 'cobrador'). ⚠ Acceso sensible — Fase 4.
-- =========================================================================
create or replace function public.contratos_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.current_user_rol() = 'cobrador' then
    if new.cliente_id     is distinct from old.cliente_id     or
       new.cobrador_id    is distinct from old.cobrador_id    or
       new.tenant_id      is distinct from old.tenant_id      or
       new.plan_id        is distinct from old.plan_id        or
       new.duracion_meses is distinct from old.duracion_meses or
       new.fecha_inicio   is distinct from old.fecha_inicio   or
       new.estado         is distinct from old.estado         or
       new.codigo         is distinct from old.codigo         or
       new.fecha_primer_cobro is distinct from old.fecha_primer_cobro or
       new.costo_instalacion  is distinct from old.costo_instalacion
    then
      raise exception 'cobrador solo puede cambiar dia_pago/fecha_fin (cambio de fecha de pago)';
    end if;
    -- fecha_fin SOLO hacia adelante: acortarla dispara el DELETE de
    -- limpiar_cuotas_excedentes (0023) = borrado de deuda.
    if new.fecha_fin is distinct from old.fecha_fin
       and old.fecha_fin is not null
       and new.fecha_fin < old.fecha_fin
    then
      raise exception 'cobrador no puede acortar fecha_fin';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_contratos_check_cobrador_update on public.contratos;
create trigger trg_contratos_check_cobrador_update
  before update on public.contratos
  for each row execute function public.contratos_check_cobrador_update();
