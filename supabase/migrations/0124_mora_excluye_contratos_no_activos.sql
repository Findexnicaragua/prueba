-- 0124: el cron de mora NO debe generar notificaciones para cuotas de
-- contratos NO activos. Un contrato suspendido —o, con el nuevo cancelar
-- (0123), cancelado— deja cuotas vivas pendientes/parciales; el cron las
-- tomaba a diario y el badge de mora del cobrador las contaba, PERO la lista
-- de Cobros/mora y el mapa las excluyen (filtran estado='activo') → badge
-- fantasma que no baja desde su pantalla. Fix: filtrar por estado de contrato
-- = 'activo' en el INSERT, alineando suspendido y cancelado con Cobros/mapa
-- (la deuda de esos contratos se cobra desde el detalle del contrato).
-- Solo reescribe la función; sin cambio de schema. Detectado por el audit
-- adversarial del feature de cancelación.

create or replace function public.actualizar_notificaciones_mora(p_tenant_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
set timezone = 'America/Managua'
as $$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
  -- row_security off: el cron corre sin auth.uid(); SECURITY DEFINER da rol
  -- postgres (BYPASSRLS), lo explicitamos por las dudas.
  set local row_security = off;

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
    cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado
  from public.cuotas cu
  where cu.tenant_id = p_tenant_id
    and cu.estado in ('pendiente','parcial')
    and (cu.fecha_vencimiento + (v_dias_gracia || ' days')::interval)::date < current_date
    -- Solo contratos ACTIVOS (0124): suspendido/cancelado salen del flujo de
    -- mora del cobrador aunque conserven cuotas vivas.
    and coalesce(
          (select ct.estado from public.contratos ct where ct.id = cu.contrato_id),
          'activo') = 'activo'
  on conflict (cuota_id) do update
    set dias_mora      = excluded.dias_mora,
        monto_adeudado = excluded.monto_adeudado;

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;
