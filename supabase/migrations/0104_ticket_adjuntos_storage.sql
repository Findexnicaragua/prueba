-- 0104: Storage bucket para los adjuntos (fotos) de tickets — Fase 3 (3A).
--
-- Convención de path: {tenant_id}/{ticket_id}/{timestamp}.{ext} → la policy filtra
-- por tenant con el primer segmento (`storage_path_tenant`, 0019). Read = miembro
-- del tenant; write = staff de tickets (`is_ticket_staff`, 0103). Depende de 0103.
-- Idempotente + transaccional.

BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
  ('ticket-adjuntos', 'ticket-adjuntos', false, 5 * 1024 * 1024,
   array['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

-- LECTURA: cualquier miembro del tenant ve los adjuntos del tenant.
DROP POLICY IF EXISTS "storage_read_ticket_adjuntos" ON storage.objects;
CREATE POLICY "storage_read_ticket_adjuntos" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'ticket-adjuntos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
  );

-- ESCRITURA: el staff de tickets (admin / admin_tickets / técnico).
DROP POLICY IF EXISTS "storage_write_ticket_adjuntos" ON storage.objects;
CREATE POLICY "storage_write_ticket_adjuntos" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'ticket-adjuntos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
    AND public.is_ticket_staff()
  )
  WITH CHECK (
    bucket_id = 'ticket-adjuntos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
    AND public.is_ticket_staff()
  );

COMMIT;
