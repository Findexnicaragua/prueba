-- 0112 — Resolver la notificación de mora también al ANULAR la cuota.
--
-- `resolver_notificacion_al_pagar` (0008) cierra la notificación de mora cuando
-- la cuota pasa a 'pagada'. Pero al ANULAR una cuota (ej. al cancelar un
-- contrato, que anula sus cuotas pendientes — típicamente ya en mora, que es por
-- lo que se cancela) la notificación quedaba ABIERTA → mora fantasma en el panel
-- del admin y del cobrador para una cuota que ya no se cobra.
--
-- FIX: resolver la notificación cuando la cuota deja los estados "abiertos"
-- (pasa a 'pagada' O 'anulada'). El caso 'pagada' se comporta idéntico que antes
-- (no hay regresión). Idempotente (CREATE OR REPLACE); el trigger
-- `trg_resolver_notificacion_al_pagar` (0008) sigue apuntando a esta función por
-- nombre. Sólo server-side: NO toca schema.dart, db.dart ni sync rules.

BEGIN;

create or replace function public.resolver_notificacion_al_pagar()
returns trigger language plpgsql as $$
begin
  if new.estado in ('pagada', 'anulada')
     and old.estado not in ('pagada', 'anulada') then
    update public.notificaciones_mora
       set resuelta_en = now()
     where cuota_id = new.id
       and resuelta_en is null;
  end if;
  return new;
end;
$$;

COMMIT;
