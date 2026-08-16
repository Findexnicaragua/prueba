-- 0179 — op_log append-only ENFORCED por trigger (audit F0, 2026-07-09).
--
-- La policy `op_log_update` (0129) existe SOLO para que el upsert idempotente de
-- PowerSync (connector.dart: INSERT ... ON CONFLICT DO UPDATE) pueda reescribir
-- la MISMA fila en un reintento. Pero su USING/CHECK solo valida tenant+actor —
-- NO impide que un cliente, con su propio JWT, PATCHee una fila histórica con
-- contenido DISTINTO. Desde que 0140 eliminó el `audit_log` forense, `op_log` es
-- el ÚNICO registro de cambios y quedó alterable (un cobrador podría reescribir
-- "Cobró C$500" por "C$50" después de sincronizar).
--
-- Guard: rechazar todo UPDATE que MODIFIQUE una fila existente. El re-upsert
-- legítimo reenvía la fila IDÉNTICA (NEW = OLD) → pasa sin ruido. Cualquier
-- cambio real → excepción 23514 (no-retryable: el connector lo descarta y deja
-- RechazoSync, sin loop). NO se guarda DELETE a propósito: la RLS ya lo bloquea
-- para usuarios normales (no hay policy DELETE) y el super lo conserva vía
-- super_admin_all para el tooling de data-ops/restore.

CREATE OR REPLACE FUNCTION public.op_log_append_only_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW IS DISTINCT FROM OLD THEN
    RAISE EXCEPTION
      'op_log es append-only: no se puede modificar una fila existente (id=%)', OLD.id
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS op_log_append_only_upd ON public.op_log;
CREATE TRIGGER op_log_append_only_upd
  BEFORE UPDATE ON public.op_log
  FOR EACH ROW EXECUTE FUNCTION public.op_log_append_only_guard();
