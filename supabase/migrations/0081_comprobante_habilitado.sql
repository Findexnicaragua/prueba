-- 0081 — Switch maestro de la foto de comprobante (gateado por super_admin).
--
-- Hoy el cobro muestra el picker de foto para métodos con comprobante
-- (transferencia). Para no consumir Storage de cada tenant sin decisión del
-- dueño del SaaS, la foto pasa a estar APAGADA por defecto: el cobro guarda
-- solo el número de referencia. El super_admin (entrando al tenant) puede
-- habilitarla por tenant desde el panel de settings.
--
-- `fotoObligatoria` (cobranza.foto_obligatoria, 0010) queda como sub-opción:
-- solo aplica si este switch está en ON. Ambos toggles se muestran únicamente
-- al super_admin en la UI (gate `esSuperAdmin`, client-side).
--
-- Fila nueva en `settings` (key-value), sin columnas → sin bump de schema ni
-- redeploy de sync rules (SELECT * ya cubre).

DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
       'cobranza',
       'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
       'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;
