-- 0111 — RLS hardening: el cobrador no puede DES-anular una cuota.
--
-- El trigger `cuotas_check_cobrador_update` (0022) bloquea que un rol cobrador
-- ponga estado='anulada' (anular es acción de admin). Pero NO cubría el camino
-- inverso: cambiar el estado DESDE 'anulada' a otro valor. Vía su policy
-- `cuotas_update_cobrador_propio`, un cobrador podía "revivir" una cuota anulada
-- (anulada → pendiente/parcial/pagada) y volver a cobrarla, salteándose el
-- control de anulación del admin y la cascada de pagos/recibos (0023).
--
-- FIX (defensivo): el trigger también rechaza cualquier cambio de estado cuando
-- la cuota YA está 'anulada'. Para el cobrador una cuota anulada es TERMINAL;
-- sólo un admin (sin esta restricción) puede reactivarla si hiciera falta. No
-- hay flujo legítimo del cobrador que des-anule (la UI ya oculta/bloquea cobrar
-- cuotas anuladas), así que el bloqueo no rompe nada operativo.
--
-- Idempotente (CREATE OR REPLACE). El trigger `trg_cuotas_check_cobrador_update`
-- (0022) sigue apuntando a esta función por nombre — no hace falta recrearlo.
-- Sólo función server-side: NO toca schema.dart, db.dart ni sync rules.

BEGIN;

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
  return new;
end;
$$;

COMMIT;
