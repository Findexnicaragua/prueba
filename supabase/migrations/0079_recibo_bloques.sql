-- 0079 — Settings del "diseñador de recibo" (#8b): visibilidad de bloques
-- opcionales + orden de los bloques del pie.
--
-- El núcleo de dinero (recibo Nº, fecha, cliente, ítems, método, COBRADO/
-- VUELTO/PAGADO) queda SIEMPRE visible y en orden fijo. Lo configurable:
--   - mostrar_empresa: bloque de empresa (nombre/dir/tel/RUC) en el encabezado.
--   - mostrar_cedula:  cédula del cliente.
--   - (ya existían: imprimir_logo, monto_en_letras, mostrar_adeudado, y el
--      título / pie / whatsapp se ocultan dejándolos vacíos.)
--   - orden_pie: orden de los bloques de TEXTO LIBRE del pie. CSV de ids:
--     'pie' (pie libre) y 'whatsapp'. El render los emite en ese orden, cada
--     uno si tiene contenido. (El "saldo adeudado" se controla aparte con
--     mostrar_adeudado y mantiene su posición fija por renderer.)
--
-- Son filas nuevas en `settings` (key-value); no hay columnas nuevas, así que
-- no requiere bump de schema ni redeploy de sync rules (SELECT * ya cubre).

DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'recibo.mostrar_empresa', '"true"', 'boolean', 'recibos',
       'Mostrar datos de la empresa (nombre, dirección, teléfono, RUC) en el recibo', 'admin'),
      (v_tenant.id, 'recibo.mostrar_cedula', '"true"', 'boolean', 'recibos',
       'Mostrar la cédula del cliente en el recibo', 'admin'),
      (v_tenant.id, 'recibo.orden_pie', '"pie,whatsapp"', 'string', 'recibos',
       'Orden de los bloques de texto del pie del recibo (pie libre y WhatsApp)', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;
