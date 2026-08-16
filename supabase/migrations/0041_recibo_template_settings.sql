-- Migración 0041: settings del template de recibo.
DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'recibo.titulo', '"RECIBO"', 'string', 'recibos',
       'Titulo del documento en el recibo (ej: COBRO, RECIBO)', 'admin'),
      (v_tenant.id, 'recibo.monto_en_letras', '"true"', 'boolean', 'recibos',
       'Mostrar monto en letras en el recibo', 'admin'),
      (v_tenant.id, 'recibo.mostrar_adeudado', '"true"', 'boolean', 'recibos',
       'Mostrar tabla de meses adeudados en el recibo', 'admin'),
      (v_tenant.id, 'empresa.whatsapp', '""', 'string', 'empresa',
       'Numero de WhatsApp de la empresa (aparece en recibo)', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;
