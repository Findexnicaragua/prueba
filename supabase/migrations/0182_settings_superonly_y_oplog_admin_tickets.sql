-- 0182 — Dos fixes de F0 (settings super-only + historial de admin_tickets).
--
-- (#4) op_log.campos_visibles es una clave SÓLO del super_admin (define qué
-- campos ve el historial de cada tenant), pero el upsert del cliente
-- (settings_repo.dart) hardcodea editable_por='admin' al crearla. La RLS
-- `settings_write_admin` permite escribir cualquier clave con
-- editable_por <> 'super_admin' → un admin del tenant podía sobreescribir esa
-- clave. Fix: marcarla 'super_admin' (el cliente además la crea así de ahora en
-- más — ver settings_repo.upsert(editablePor:)).
UPDATE public.settings
   SET editable_por = 'super_admin'
 WHERE clave = 'op_log.campos_visibles'
   AND editable_por IS DISTINCT FROM 'super_admin';

-- (#6) El rol admin_tickets NO está en op_log_read (is_admin_or_cobranza =
-- admin/admin_cobranza), así que su "Historial de cambios" del ticket abría
-- vacío. Se le da acceso SCOPEADO a op_log SOLO de las entidades que gestiona
-- (tickets/ticket_tipos/incidentes) — NUNCA el op_log de dinero (cobros/pagos),
-- que no debe ver. Esta policy cubre el acceso REST; el bucket por_admin_tickets
-- sincroniza el MISMO subconjunto (sync-rules).
DROP POLICY IF EXISTS op_log_read_admin_tickets ON public.op_log;
CREATE POLICY op_log_read_admin_tickets ON public.op_log
  FOR SELECT USING (
    tenant_id = public.current_tenant_id()
    AND public.current_user_rol() = 'admin_tickets'
    AND entidad IN ('tickets', 'ticket_tipos', 'incidentes')
  );
