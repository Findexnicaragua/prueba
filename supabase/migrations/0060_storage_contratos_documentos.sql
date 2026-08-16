-- 0060: Bucket de Storage para documentos del contrato + RLS.
-- Path scheme: {tenant_id}/{contrato_id}/{timestamp}.{ext}
-- Permitidos: PDF, JPG, PNG, DOC, DOCX. Límite: 10MB por archivo.

-- 1. Crear bucket (idempotente)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'contratos-documentos',
  'contratos-documentos',
  false,
  10485760,  -- 10 MB
  ARRAY[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- 2. Read: cualquier usuario autenticado del tenant puede leer
DROP POLICY IF EXISTS "storage_read_contratos_documentos" ON storage.objects;
CREATE POLICY "storage_read_contratos_documentos" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'contratos-documentos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
  );

-- 3. Write (INSERT/UPDATE/DELETE): solo admin/admin_cobranza del tenant
DROP POLICY IF EXISTS "storage_write_contratos_documentos" ON storage.objects;
CREATE POLICY "storage_write_contratos_documentos" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'contratos-documentos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  )
  WITH CHECK (
    bucket_id = 'contratos-documentos'
    AND public.storage_path_tenant(name) = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

-- 4. Super admin bypass (consistente con otros buckets)
DROP POLICY IF EXISTS "storage_super_admin_contratos_documentos" ON storage.objects;
CREATE POLICY "storage_super_admin_contratos_documentos" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'contratos-documentos'
    AND public.is_super_admin()
  )
  WITH CHECK (
    bucket_id = 'contratos-documentos'
    AND public.is_super_admin()
  );
