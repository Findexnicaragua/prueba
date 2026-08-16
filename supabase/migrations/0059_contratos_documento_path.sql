-- 0059: Agregar documento_path al contrato.
-- Permite adjuntar PDF/Word/foto del contrato firmado.
-- Solo admin/admin_cobranza pueden subir/eliminar (UI gateado).
-- Storage bucket: contratos-documentos.

ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS documento_path text;

-- Comment para documentar el path scheme: tenant_id/contrato_id/<timestamp>.<ext>
COMMENT ON COLUMN public.contratos.documento_path IS
  'Path en Storage bucket contratos-documentos: {tenant_id}/{contrato_id}/{timestamp}.{ext}';
