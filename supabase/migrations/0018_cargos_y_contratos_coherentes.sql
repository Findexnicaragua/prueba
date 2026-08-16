-- Cierre de gaps detectados en la 2da auditoría:
--   - Cargos extra (descuentos/reconexiones) afectan el estado de la cuota.
--   - Cambios de dia_pago / fecha_fin propagan a las cuotas futuras.

-- =========================================================================
-- 1. Helper: total real a cobrar de una cuota considerando cargos extra
-- =========================================================================
-- total = cuota.monto - SUM(descuentos) + SUM(cargos sumados)
-- Descuentos: tipos 'descuento_monto' y 'descuento_porcentaje' (monto ya
-- normalizado a C$ por la app al aplicar el descuento).
-- Cargos sumados: 'reconexion', 'otro'.

create or replace function public.cuota_total_a_cobrar(p_cuota_id uuid)
returns numeric
language sql stable
security definer
set search_path = public, pg_temp
as $$
  select
    cu.monto
    - coalesce((
        select sum(ce.monto)
          from public.cargos_extra ce
         where ce.cuota_id = cu.id
           and ce.tipo in ('descuento_monto','descuento_porcentaje')
      ), 0)
    + coalesce((
        select sum(ce.monto)
          from public.cargos_extra ce
         where ce.cuota_id = cu.id
           and ce.tipo in ('reconexion','otro')
      ), 0)
  from public.cuotas cu
  where cu.id = p_cuota_id
$$;

-- =========================================================================
-- 2. Reescribir recalcular_cuota_desde_pagos para considerar cargos extra
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

  if v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

-- =========================================================================
-- 3. Trigger en cargos_extra: recalcular cuota cuando se aplica un cargo
-- =========================================================================
-- Reusa la misma función — vale tanto para pagos.cuota_id como para
-- cargos_extra.cuota_id porque ambos tienen esa columna.

create trigger trg_cargos_extra_recalcular_cuota
  after insert or update or delete on public.cargos_extra
  for each row execute function public.recalcular_cuota_desde_pagos();

-- =========================================================================
-- 4. Trigger UPDATE en contratos: mantener cuotas futuras coherentes
-- =========================================================================
-- - Cambia dia_pago: recalcula fecha_vencimiento de cuotas FUTURAS pendientes.
-- - Cambia fecha_fin: regenera el rango (idempotente vía ON CONFLICT).

create or replace function public.contratos_actualizar_cuotas_futuras_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_mes_actual date := date_trunc('month', current_date)::date;
begin
  if new.dia_pago is distinct from old.dia_pago then
    update public.cuotas
       set fecha_vencimiento = public.calcular_fecha_pago(periodo, new.dia_pago)
     where contrato_id = new.id
       and periodo >= v_mes_actual
       and estado = 'pendiente';
  end if;

  if new.fecha_fin is distinct from old.fecha_fin then
    perform public.generar_cuotas_contrato(new.id);
  end if;

  return new;
end;
$$;

create trigger trg_contratos_actualizar_cuotas_futuras
  after update of dia_pago, fecha_fin on public.contratos
  for each row execute function public.contratos_actualizar_cuotas_futuras_trg();
