-- Refactor: dia_corte (1-28) → dia_pago (1-31), con clamping al último día
-- del mes y ajuste domingo → lunes. La fecha de instalación define el día
-- de pago (decisión de negocio: cliente instalado el 17 paga todos los 17).

-- =========================================================================
-- Rename y ampliación del rango
-- =========================================================================

alter table public.contratos rename column dia_corte to dia_pago;
alter table public.contratos drop constraint contratos_dia_corte_check;
alter table public.contratos add constraint contratos_dia_pago_check
  check (dia_pago between 1 and 31);

-- =========================================================================
-- Función central: fecha de pago para un mes dado
-- =========================================================================
-- Reglas:
--   1. Día clamped al último día real del mes (ej. 31 en feb → 28/29).
--   2. Si cae en domingo, mover al lunes (no se cobra los domingos).
--   3. Feriados nacionales: NO se manejan en esta fase.

create or replace function public.calcular_fecha_pago(p_mes date, p_dia_pago int)
returns date
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_ultimo_dia int;
  v_fecha date;
begin
  v_ultimo_dia := extract(day from (date_trunc('month', p_mes) + interval '1 month - 1 day'))::int;
  v_fecha := (date_trunc('month', p_mes) + ((least(p_dia_pago, v_ultimo_dia) - 1) || ' days')::interval)::date;

  -- extract(dow ...): 0=domingo, 1=lunes, ..., 6=sábado.
  if extract(dow from v_fecha) = 0 then
    v_fecha := v_fecha + 1;
  end if;

  return v_fecha;
end;
$$;

-- =========================================================================
-- Reescribir generar_cuotas_mes usando la función nueva
-- =========================================================================

create or replace function public.generar_cuotas_mes(p_tenant_id uuid, p_periodo date)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
    public.calcular_fecha_pago(p_periodo, c.dia_pago),
    p.precio_mensual,
    'pendiente'
  from public.contratos c
  join public.planes   p   on p.id = c.plan_id
  join public.clientes cli on cli.id = c.cliente_id
  where c.tenant_id = p_tenant_id
    and c.activo = true
    -- Contrato debe estar vigente DURANTE el mes objetivo.
    and c.fecha_inicio <= public.calcular_fecha_pago(p_periodo, c.dia_pago)
    and (c.fecha_fin is null or c.fecha_fin >= date_trunc('month', p_periodo)::date)
  on conflict (contrato_id, periodo) do nothing;

  get diagnostics v_creadas = row_count;
  return v_creadas;
end;
$$;
