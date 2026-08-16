-- 0117 — Rediseño de descuentos (decisión Rubén 2026-06-11, sesión de
-- rediseño post-feedback): las PROMOS van por el MISMO riel que los ajustes
-- (cargos_extra origen='promo', mismo diálogo con selector Ajuste/Promo) y
-- los descuentos del COBRO pasan a exigir motivo también en el server
-- (paridad real de reglas: "admin y cobrador, mismas reglas").
--
-- Server-side NO cambia el modelo: cero columnas nuevas (origen='promo' ya
-- existía en el CHECK de 0115 reservado para Sprint 3). Guards + una regla
-- de estado (§3, condonación). Cambios:
--   1. trg_cargos_ajuste_guard ahora también gobierna origen='promo'
--      (mismas validaciones: feature ON, rol admin, solo descuento, motivo,
--      topes ajuste_max_*).
--   2. trg_cargos_cobro_motivo_guard (nuevo): un descuento de origen='cobro'
--      exige motivo (descripcion). Los automáticos ya lo traían ("Descuento
--      pronto pago"); el manual del diálogo nuevo siempre manda motivo.
--      Los topes descuento_max_* del cobrador siguen UI-only (un tope server
--      rebotaría el pronto-pago automático, que no es negociación del
--      cobrador); INV4/INV13 detectan abusos a posteriori.
--
-- ⚠️ Transición: deployar JUNTO con la app de esta rama. Una cola offline
-- de una app VIEJA con descuento manual sin motivo sería rechazada por el
-- guard (P0001 → va a "Cambios sin sincronizar" del Perfil). Riesgo bajo:
-- el feature de descuentos del cobrador estaba recién en testing.
--
-- Sin cambios de schema → NO requiere bump de PowerSync ni redeploy de
-- sync rules.

BEGIN;

-- =========================================================================
-- 1. Guard de ajustes extendido a promos. El cuerpo ya era origen-agnóstico
--    (valida settings/rol/tipo/motivo/topes); se recrea solo para que los
--    mensajes cubran ambos casos y queda el trigger con WHEN ampliado.
--    Sin bypass para super_admin a propósito (igual que 0115).
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
  -- Cascadas y re-upserts NO se re-validan (audit Fase 4 de 0115): un
  -- UPDATE que no toca los campos gobernados (p.ej. la reasignación de
  -- cobrador de 0068, o el re-upsert idéntico de un retry de batch de
  -- PowerSync) pasa de largo — sin esto, deshabilitar el feature o bajar
  -- topes REBOTABA cascadas sobre descuentos históricos legítimos.
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
    raise exception 'Solo un admin puede aplicar ajustes o promos';
  end if;
  if new.tipo not in ('descuento_monto', 'descuento_porcentaje') then
    raise exception
      'Un ajuste o promo solo puede ser un descuento (monto o porcentaje)';
  end if;
  if new.descripcion is null or btrim(new.descripcion) = '' then
    raise exception 'El descuento requiere un motivo';
  end if;

  v_max_pct := public.setting_number(
      new.tenant_id, 'cobranza.ajuste_max_porcentaje', 0);
  v_max_monto := public.setting_number(
      new.tenant_id, 'cobranza.ajuste_max_monto', 0);
  if v_max_pct > 0
     and new.tipo = 'descuento_porcentaje'
     and coalesce(new.porcentaje, 0) > v_max_pct then
    raise exception
      'El descuento excede el tope configurado de % por ciento', v_max_pct;
  end if;
  if v_max_monto > 0 and new.monto > v_max_monto + 0.01 then
    raise exception
      'El descuento excede el tope de C$% configurado', v_max_monto;
  end if;
  -- Limitación documentada (0115, BAJA): el guard NO valida monto ≤ saldo
  -- (carrera offline cobro+descuento puede sobrepagar; el repo lo valida
  -- con su snapshot local e INV4 lo detecta a posteriori).
  return new;
end $$;

drop trigger if exists trg_cargos_ajuste_guard on public.cargos_extra;
create trigger trg_cargos_ajuste_guard
  before insert or update on public.cargos_extra
  for each row
  when (new.origen in ('ajuste', 'promo'))
  execute function public.cargos_ajuste_guard_trg();

-- =========================================================================
-- 2. Motivo obligatorio para descuentos del cobro (manuales del cobrador y
--    automáticos). Scope estricto origen='cobro': NO toca 'liquidacion'
--    (cancelar contrato pone su propia descripcion) ni 'ajuste'/'promo'
--    (guard propio arriba).
-- =========================================================================
create or replace function public.cargos_cobro_motivo_guard_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Mismo passthrough de cascadas/re-upserts que el guard de ajustes: las
  -- filas históricas pre-0117 (descuentos sin motivo del diálogo viejo) no
  -- deben rebotar cuando una cascada las toque sin cambiar lo gobernado.
  if tg_op = 'UPDATE'
     and new.tipo = old.tipo
     and new.monto = old.monto
     and coalesce(new.porcentaje, -1) = coalesce(old.porcentaje, -1)
     and coalesce(new.descripcion, '') = coalesce(old.descripcion, '')
     and new.origen = old.origen then
    return new;
  end if;
  if new.tipo in ('descuento_monto', 'descuento_porcentaje')
     and (new.descripcion is null or btrim(new.descripcion) = '') then
    raise exception 'El descuento del cobro requiere un motivo';
  end if;
  return new;
end $$;

drop trigger if exists trg_cargos_cobro_motivo_guard on public.cargos_extra;
create trigger trg_cargos_cobro_motivo_guard
  before insert or update on public.cargos_extra
  for each row
  when (new.origen = 'cobro')
  execute function public.cargos_cobro_motivo_guard_trg();

-- =========================================================================
-- 3. CONDONACIÓN (audit Fase 4 del rediseño, finding ALTO): una promo o
--    ajuste del 100% dejaba la cuota 'pendiente' con saldo 0 — nunca
--    'pagada' (la regla v_total_pagado <= 0 → 'pendiente' corría primero)
--    y esa cuota BLOQUEABA el orden de cobro del contrato (es la más
--    antigua pendiente y un cobro de C$0 es inválido). Regla nueva, ANTES
--    del resto: total a cobrar <= 0 → 'pagada' (saldada sin plata).
--    Quitar el descuento revierte: el total vuelve a >0 y el recálculo la
--    devuelve a 'pendiente'. ESPEJO EXACTO del cliente
--    (lib/data/utils/cuota_estado.dart) — cambiar uno = cambiar el otro.
--    Cuerpo base: 0083 (guard polimórfico de tg_table_name intacto).
-- =========================================================================
create or replace function public.recalcular_cuota_desde_pagos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_total_a_cobrar numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  -- Guard polimórfico (lección de 0078, blindado en 0083): operar SOLO
  -- sobre las 2 tablas conocidas, que tienen cuota_id + ocurrido_en.
  if tg_table_name not in ('pagos', 'cargos_extra') then
    return coalesce(new, old);
  end if;

  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0)
    into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false;

  select estado into v_estado_actual from public.cuotas where id = v_cuota_id;
  if v_estado_actual = 'anulada' then
    return coalesce(new, old);
  end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(v_cuota_id);

  if v_total_a_cobrar <= 0 then
    -- Condonada (0117): descuento del 100% → no queda nada que cobrar.
    v_nuevo_estado := 'pagada';
  elsif v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado,
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

COMMIT;

-- Verificación post-deploy (correr a mano):
--   select tgname from pg_trigger
--    where tgrelid = 'public.cargos_extra'::regclass
--      and tgname in ('trg_cargos_ajuste_guard',
--                     'trg_cargos_cobro_motivo_guard');          -- 2 filas
--   -- El WHEN del guard de ajustes debe incluir 'promo':
--   select pg_get_triggerdef(oid) from pg_trigger
--    where tgrelid = 'public.cargos_extra'::regclass
--      and tgname = 'trg_cargos_ajuste_guard';  -- ... IN ('ajuste','promo')
--   -- La condonación quedó en la función de recálculo:
--   select prosrc like '%Condonada (0117)%' from pg_proc
--    where proname = 'recalcular_cuota_desde_pagos';             -- true
