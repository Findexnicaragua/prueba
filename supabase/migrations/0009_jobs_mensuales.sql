-- Jobs SQL: generación mensual de cuotas + actualización de notificaciones de mora.
-- Se programan con pg_cron (Supabase Cloud lo incluye).

create extension if not exists pg_cron;

-- =========================================================================
-- Helper: leer setting numérico de un tenant
-- =========================================================================

create or replace function public.setting_number(p_tenant_id uuid, p_clave text, p_default numeric)
returns numeric
language sql stable as $$
  select coalesce(
    (select (valor)::text::numeric
       from public.settings
      where tenant_id = p_tenant_id and clave = p_clave),
    p_default
  )
$$;

-- =========================================================================
-- Generar cuotas del mes para un tenant
-- =========================================================================
-- Idempotente: si la cuota ya existe (mismo contrato + periodo), no la duplica.
-- Devuelve cantidad de cuotas creadas.

create or replace function public.generar_cuotas_mes(p_tenant_id uuid, p_periodo date)
returns int
language plpgsql as $$
declare
  v_creadas int;
begin
  insert into public.cuotas (
    tenant_id, contrato_id, cliente_id, cobrador_id,
    periodo, fecha_vencimiento, monto, estado
  )
  select
    c.tenant_id,
    c.id,
    c.cliente_id,
    cli.cobrador_id,
    date_trunc('month', p_periodo)::date,
    -- Vencimiento = primer día del mes + (dia_corte - 1) días.
    -- dia_corte ∈ [1,28] (check en 0001), no hay rebose de mes.
    (date_trunc('month', p_periodo) + ((c.dia_corte - 1) || ' days')::interval)::date,
    p.precio_mensual,
    'pendiente'
  from public.contratos c
  join public.planes   p   on p.id = c.plan_id
  join public.clientes cli on cli.id = c.cliente_id
  where c.tenant_id = p_tenant_id
    and c.activo = true
    and c.fecha_inicio <= (date_trunc('month', p_periodo) + interval '1 month')::date
    and (c.fecha_fin is null or c.fecha_fin >= date_trunc('month', p_periodo)::date)
  on conflict (contrato_id, periodo) do nothing;

  get diagnostics v_creadas = row_count;
  return v_creadas;
end;
$$;

-- =========================================================================
-- Actualizar notificaciones de mora
-- =========================================================================
-- Para cada cuota cuyo (vencimiento + dias_gracia) ya pasó y aún tiene saldo:
--   - upsert una notificación
--   - recalcula dias_mora y monto_adeudado
-- No toca cuotas pagadas/anuladas (no entran al WHERE).

create or replace function public.actualizar_notificaciones_mora(p_tenant_id uuid)
returns int
language plpgsql as $$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
  insert into public.notificaciones_mora (
    tenant_id, cuota_id, cliente_id, cobrador_id,
    dias_mora, monto_adeudado
  )
  select
    cu.tenant_id,
    cu.id,
    cu.cliente_id,
    cu.cobrador_id,
    greatest((current_date - cu.fecha_vencimiento) - v_dias_gracia, 0),
    cu.monto - cu.monto_pagado
  from public.cuotas cu
  where cu.tenant_id = p_tenant_id
    and cu.estado in ('pendiente','parcial')
    and (cu.fecha_vencimiento + (v_dias_gracia || ' days')::interval)::date < current_date
  on conflict (cuota_id) do update
    set dias_mora      = excluded.dias_mora,
        monto_adeudado = excluded.monto_adeudado,
        resuelta_en    = null,  -- reactivar si volvió a caer
        resuelta_por   = null;

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;

-- =========================================================================
-- Cron jobs
-- =========================================================================

-- 1) Generar cuotas el primer día del mes a las 00:05 (todos los tenants).
select cron.schedule(
  'generar_cuotas_mensual',
  '5 0 1 * *',
  $$
    select public.generar_cuotas_mes(t.id, current_date)
    from public.tenants t;
  $$
);

-- 2) Actualizar notificaciones de mora diariamente a las 06:00.
select cron.schedule(
  'actualizar_notificaciones_mora_diario',
  '0 6 * * *',
  $$
    select public.actualizar_notificaciones_mora(t.id)
    from public.tenants t;
  $$
);
