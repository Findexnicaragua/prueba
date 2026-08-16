-- Settings default por tenant: cuando se crea un tenant nuevo, sembrar
-- la configuración base. Después el admin la ajusta desde el panel.

create or replace function public.seed_settings_default(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por) values

  -- ── Empresa (datos del recibo) ──────────────────────────────────────
  (p_tenant_id, 'empresa.nombre',    '""'::jsonb, 'string', 'empresa', 'Nombre comercial del ISP',           'admin'),
  (p_tenant_id, 'empresa.direccion', '""'::jsonb, 'string', 'empresa', 'Dirección física para recibo',        'admin'),
  (p_tenant_id, 'empresa.telefono',  '""'::jsonb, 'string', 'empresa', 'Teléfono de contacto para recibo',    'admin'),
  (p_tenant_id, 'empresa.ruc',       '""'::jsonb, 'string', 'empresa', 'RUC para recibo',                     'admin'),
  (p_tenant_id, 'empresa.logo_path', 'null'::jsonb, 'string', 'empresa', 'Ruta del logo en Storage',          'admin'),

  -- ── Cobranza ────────────────────────────────────────────────────────
  (p_tenant_id, 'cobranza.dias_gracia',                   '10'::jsonb,  'number',  'cobranza', 'Días entre vencimiento y notificación de mora', 'admin'),
  (p_tenant_id, 'cobranza.modo_ruta',                     '"libre"'::jsonb, 'string', 'cobranza', 'Modo de visualización de ruta del cobrador (libre|planificada)', 'admin'),
  (p_tenant_id, 'cobranza.descuentos_habilitados',        'false'::jsonb, 'boolean', 'cobranza', 'Permitir aplicar descuentos en campo', 'admin'),
  (p_tenant_id, 'cobranza.descuento_tipo',                '"monto"'::jsonb, 'string', 'cobranza', 'Tipo de descuento permitido (monto|porcentaje|ambos)', 'admin'),
  (p_tenant_id, 'cobranza.descuento_max_porcentaje',      '0'::jsonb, 'number', 'cobranza', 'Tope de descuento porcentual sin aprobación (0=deshabilitado)', 'admin'),
  (p_tenant_id, 'cobranza.descuento_max_monto',           '0'::jsonb, 'number', 'cobranza', 'Tope de descuento monto sin aprobación (0=deshabilitado)', 'admin'),
  (p_tenant_id, 'cobranza.cargo_reconexion_habilitado',   'false'::jsonb, 'boolean', 'cobranza', 'Permitir cobrar reconexión', 'admin'),
  (p_tenant_id, 'cobranza.monto_reconexion',              '0'::jsonb, 'number', 'cobranza', 'Monto de reconexión en C$', 'admin'),

  -- ── Métodos de pago ─────────────────────────────────────────────────
  -- Efectivo siempre habilitado (no requiere setting).
  (p_tenant_id, 'pagos.transferencia_habilitada', 'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago por transferencia', 'admin'),
  (p_tenant_id, 'pagos.deposito_habilitado',      'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago por depósito bancario', 'admin'),
  (p_tenant_id, 'pagos.tarjeta_habilitada',       'false'::jsonb, 'boolean', 'pagos', 'Habilitar pago con tarjeta (simbólico, sin pasarela)', 'admin'),
  (p_tenant_id, 'pagos.usd_habilitado',           'true'::jsonb,  'boolean', 'pagos', 'Aceptar pagos en USD', 'admin'),
  (p_tenant_id, 'pagos.tasa_usd_cordoba',         '36.50'::jsonb, 'number',  'pagos', 'Tasa de conversión USD → C$', 'admin_cobranza'),

  -- ── Recibos ─────────────────────────────────────────────────────────
  (p_tenant_id, 'recibo.formato_default_mm', '80'::jsonb, 'number', 'recibos', 'Ancho de papel por defecto (57|80)', 'admin'),
  (p_tenant_id, 'recibo.template_57mm',      '""'::jsonb, 'string', 'recibos', 'Plantilla de recibo 57mm con placeholders', 'admin'),
  (p_tenant_id, 'recibo.template_80mm',      '""'::jsonb, 'string', 'recibos', 'Plantilla de recibo 80mm con placeholders', 'admin'),
  (p_tenant_id, 'recibo.imprimir_logo',      'true'::jsonb, 'boolean', 'recibos', 'Incluir logo en el recibo', 'admin'),
  (p_tenant_id, 'recibo.pie_libre',          '""'::jsonb, 'string', 'recibos', 'Texto libre al pie del recibo (gracias, etc.)', 'admin')

  on conflict (tenant_id, clave) do nothing;
end;
$$;

-- =========================================================================
-- Trigger AFTER INSERT en tenants: siembra automáticamente settings default
-- =========================================================================

create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  return new;
end;
$$;

create trigger trg_tenants_seed_settings
  after insert on public.tenants
  for each row execute function public.tenants_seed_settings_trg();

-- =========================================================================
-- Backfill: sembrar settings para tenants que ya existían antes de esta migración
-- =========================================================================

select public.seed_settings_default(id) from public.tenants;
