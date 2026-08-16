-- 0190: Permitir que cobradores lean sus PROPIOS op_log entries.
--
-- Problema: el upload de PowerSync usa .upsert() que PostgREST traduce a
-- INSERT ON CONFLICT DO UPDATE ... RETURNING * — Postgres necesita que el
-- usuario pueda SELECT la fila para que la operación completa funcione.
-- La policy existente (op_log_read) solo permite SELECT a admin/admin_cobranza.
-- Los cobradores podían INSERTAR pero no ver la fila resultante → 42501.
--
-- Fix: policy SELECT mínima para cobradores sobre sus propias filas.
-- El cobrador NO necesita leer op_log ajeno (su historial lo recibe por
-- PowerSync sync rules); esto es solo para que el upsert cierre.

CREATE POLICY op_log_read_cobrador ON op_log
  FOR SELECT
  USING (
    tenant_id = current_tenant_id()
    AND actor_id = auth.uid()
  );
