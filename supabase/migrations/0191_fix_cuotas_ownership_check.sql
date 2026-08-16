-- 0191 — Fix: quitar ownership check de cuotas_check_cobrador_update
--
-- Bug: cuando Feature C (cambio de fecha de pago) está habilitado, el guard
-- exige cobrador_id=auth.uid() para TODO update — incluyendo el mirror de
-- monto_pagado al registrar un cobro. Si la cuota no está asignada al cobrador
-- (cobrador_id NULL = admin-managed, o asignada a otro), el pago se rechaza
-- con "cobrador solo puede cambiar la fecha de SUS propias cuotas".
--
-- Decisión de producto: cobrador_id es ORGANIZATIVO (rutas, reportes, mapa),
-- NO un gate de acceso. Cualquier cobrador puede cobrar, re-fechar o anular
-- cualquier cuota del tenant. Se elimina el ownership check por completo.

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
      -- ① Structural: bloqueado siempre (monto/contrato/cliente/cobrador/
      --    periodo/tenant + des-anular).
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

      -- ② Anulación legítima: solo con el marcador del flujo de cambio de fecha.
      if new.estado <> old.estado and new.estado = 'anulada'
         and coalesce(new.motivo_anulacion, '') <> 'Absorbida por cambio de fecha de pago'
      then
        raise exception 'cobrador solo puede anular cuotas por cambio de fecha de pago';
      end if;
    else
      -- Guard original (Feature C OFF): el cobrador solo puede tocar
      -- monto_pagado y transiciones de estado por cobro.
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
         (new.estado <> old.estado and new.estado = 'anulada') or
         (new.estado <> old.estado and old.estado = 'anulada')
      then
        raise exception 'cobrador no puede anular ni reactivar cuotas; sólo monto_pagado y transiciones de cobro';
      end if;
    end if;
  end if;
  return new;
end;
$$;
