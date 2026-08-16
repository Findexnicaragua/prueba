-- 0045: Actualizar seed_settings_default para incluir los settings de BULK 11.
-- Sin esto, tenants creados DESPUÉS de las migraciones 0040-0044 no tendrían
-- los 19 settings nuevos.

create or replace function public.seed_settings_default(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por) values

  -- ── Empresa ────────────────────────────────────────────────────────
  (p_tenant_id, 'empresa.nombre',    '""'::jsonb, 'string', 'empresa', 'Nombre comercial del ISP',           'admin'),
  (p_tenant_id, 'empresa.direccion', '""'::jsonb, 'string', 'empresa', 'Dirección física para recibo',        'admin'),
  (p_tenant_id, 'empresa.telefono',  '""'::jsonb, 'string', 'empresa', 'Teléfono de contacto para recibo',    'admin'),
  (p_tenant_id, 'empresa.ruc',       '""'::jsonb, 'string', 'empresa', 'RUC para recibo',                     'admin'),
  (p_tenant_id, 'empresa.logo_path', 'null'::jsonb, 'string', 'empresa', 'Ruta del logo en Storage',          'admin'),
  (p_tenant_id, 'empresa.whatsapp',  '""'::jsonb, 'string', 'empresa', 'WhatsApp de la empresa',              'admin'),

  -- ── Cobranza ────────────────────────────────────────────────────────
  (p_tenant_id, 'cobranza.dias_gracia',                   '10'::jsonb,    'number',  'cobranza', 'Días entre vencimiento y notificación de mora', 'admin'),
  (p_tenant_id, 'cobranza.modo_ruta',                     '"libre"'::jsonb, 'string', 'cobranza', 'Modo de visualización de ruta del cobrador', 'admin'),
  (p_tenant_id, 'cobranza.descuentos_habilitados',        'false'::jsonb, 'boolean', 'cobranza', 'Permitir aplicar descuentos en campo', 'admin'),
  (p_tenant_id, 'cobranza.descuento_tipo',                '"monto"'::jsonb, 'string', 'cobranza', 'Tipo de descuento permitido', 'admin'),
  (p_tenant_id, 'cobranza.descuento_max_porcentaje',      '0'::jsonb,     'number',  'cobranza', 'Tope de descuento porcentual', 'admin'),
  (p_tenant_id, 'cobranza.descuento_max_monto',           '0'::jsonb,     'number',  'cobranza', 'Tope de descuento monto', 'admin'),
  (p_tenant_id, 'cobranza.cargo_reconexion_habilitado',   'false'::jsonb, 'boolean', 'cobranza', 'Permitir cobrar reconexión', 'admin'),
  (p_tenant_id, 'cobranza.monto_reconexion',              '0'::jsonb,     'number',  'cobranza', 'Monto de reconexión en C$', 'admin'),
  -- BULK 11 settings
  (p_tenant_id, 'cobranza.cobrador_edita_fecha',          'false'::jsonb, 'boolean', 'cobranza', 'Cobrador puede editar fecha de cobro', 'admin'),
  (p_tenant_id, 'cobranza.cobrador_anula_cobros',         'false'::jsonb, 'boolean', 'cobranza', 'Cobrador puede anular cobros', 'admin'),
  (p_tenant_id, 'cobranza.cobrador_edita_cobros',         'false'::jsonb, 'boolean', 'cobranza', 'Cobrador puede editar cobros post-registro', 'admin'),
  (p_tenant_id, 'cobranza.foto_obligatoria',              'false'::jsonb, 'boolean', 'cobranza', 'Foto de comprobante obligatoria', 'admin'),
  (p_tenant_id, 'cobranza.pago_parcial',                  'true'::jsonb,  'boolean', 'cobranza', 'Permitir pago parcial', 'admin'),
  (p_tenant_id, 'cobranza.pago_adelantado',               'true'::jsonb,  'boolean', 'cobranza', 'Permitir pago adelantado (multi-cuota)', 'admin'),
  (p_tenant_id, 'cobranza.cargo_reconexion',              '0'::jsonb,     'number',  'cobranza', 'Cargo automático por reconexión, 0 = deshabilitado', 'admin'),
  (p_tenant_id, 'cobranza.recrear_pago_anulado',        'false'::jsonb, 'boolean', 'cobranza', 'Permitir recrear pagos anulados por error', 'admin'),
  (p_tenant_id, 'cobranza.dias_cuotas_visibles',        '30'::jsonb,    'number',  'cobranza', 'Días de cuotas futuras visibles para el cobrador', 'admin'),

  -- ── Pagos ────────────────────────────────────────────────────────
  (p_tenant_id, 'pagos.transferencia_habilitada', 'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago por transferencia', 'admin'),
  (p_tenant_id, 'pagos.deposito_habilitado',      'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago por depósito bancario', 'admin'),
  (p_tenant_id, 'pagos.tarjeta_habilitada',       'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago con tarjeta', 'admin'),
  (p_tenant_id, 'pagos.usd_habilitado',           'true'::jsonb,  'boolean', 'pagos', 'Aceptar pagos en USD', 'admin'),
  (p_tenant_id, 'pagos.tasa_usd_cordoba',         '36.50'::jsonb, 'number',  'pagos', 'Tasa de conversión USD → C$', 'admin_cobranza'),
  (p_tenant_id, 'pagos.metodo_efectivo',           'true'::jsonb,  'boolean', 'pagos', 'Aceptar efectivo', 'admin'),
  (p_tenant_id, 'pagos.metodo_transferencia',      'false'::jsonb, 'boolean', 'pagos', 'Aceptar transferencia', 'admin'),
  (p_tenant_id, 'pagos.metodo_tarjeta',            'false'::jsonb, 'boolean', 'pagos', 'Aceptar tarjeta', 'admin'),

  -- ── Moneda ─────────────────────────────────────────────────────────
  (p_tenant_id, 'moneda.principal',               '"NIO"'::jsonb, 'string', 'moneda', 'Moneda principal (NIO/USD)', 'admin'),

  -- ── Cuotas ─────────────────────────────────────────────────────────
  (p_tenant_id, 'cuotas.manuales',                'false'::jsonb, 'boolean', 'cuotas', 'Admin puede crear cuotas manuales', 'admin'),
  (p_tenant_id, 'cuotas.editar_monto',            'false'::jsonb, 'boolean', 'cuotas', 'Admin puede editar monto de cuota', 'admin'),
  (p_tenant_id, 'cuotas.descuento_pronto_pago',   '0'::jsonb,     'number',  'cuotas', 'Descuento por pronto pago, 0 = deshabilitado', 'admin'),
  (p_tenant_id, 'cuotas.descuento_pronto_pago_tipo', '"porcentaje"'::jsonb, 'string', 'cuotas', 'Tipo de descuento pronto pago: porcentaje o monto', 'admin'),

  -- ── Recibos ─────────────────────────────────────────────────────────
  (p_tenant_id, 'recibo.formato_default_mm', '80'::jsonb,    'number',  'recibos', 'Ancho de papel por defecto (57|80)', 'admin'),
  (p_tenant_id, 'recibo.template_57mm',      '""'::jsonb,    'string',  'recibos', 'Plantilla de recibo 57mm', 'admin'),
  (p_tenant_id, 'recibo.template_80mm',      '""'::jsonb,    'string',  'recibos', 'Plantilla de recibo 80mm', 'admin'),
  (p_tenant_id, 'recibo.imprimir_logo',      'true'::jsonb,  'boolean', 'recibos', 'Incluir logo en el recibo', 'admin'),
  (p_tenant_id, 'recibo.pie_libre',          '""'::jsonb,    'string',  'recibos', 'Texto libre al pie del recibo', 'admin'),
  (p_tenant_id, 'recibo.titulo',             '"RECIBO"'::jsonb, 'string', 'recibos', 'Título del documento en el recibo', 'admin'),
  (p_tenant_id, 'recibo.monto_en_letras',    'true'::jsonb,  'boolean', 'recibos', 'Mostrar monto en letras en el recibo', 'admin'),
  (p_tenant_id, 'recibo.mostrar_adeudado',   'true'::jsonb,  'boolean', 'recibos', 'Mostrar tabla de meses adeudados', 'admin'),

  -- ── Auditoría ──────────────────────────────────────────────────────
  (p_tenant_id, 'audit.visible_admin_cobranza', 'false'::jsonb, 'boolean', 'cobranza', 'Permitir a admin de cobranza ver historial de cambios', 'admin')

  on conflict (tenant_id, clave) do nothing;
end;
$$;

-- Backfill: asegurar que tenants existentes tengan todos los settings nuevos.
select public.seed_settings_default(id) from public.tenants;
