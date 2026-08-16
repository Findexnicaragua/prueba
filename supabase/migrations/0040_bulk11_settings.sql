-- Migración 0040: settings adicionales para BULK 11.
--
-- Agrega toggles y configuraciones del plan BULK11-PLAN.md:
-- - Cobranza: permisos del cobrador, métodos de pago, reconexión.
-- - Moneda: tasa de cambio, moneda principal.
-- - Cuotas: cuotas manuales, editar monto, descuento pronto pago.

-- Función helper para insertar setting solo si no existe (idempotente).
-- Usamos DO block para no fallar si se corre 2 veces.
DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP

    -- Cobranza: permisos cobrador
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'cobranza.cobrador_edita_fecha', '"false"', 'boolean', 'cobranza',
       'Permite al cobrador modificar la fecha del cobro', 'admin'),
      (v_tenant.id, 'cobranza.cobrador_anula_cobros', '"false"', 'boolean', 'cobranza',
       'Permite al cobrador anular sus propios cobros', 'admin'),
      (v_tenant.id, 'cobranza.cobrador_edita_cobros', '"false"', 'boolean', 'cobranza',
       'Permite al cobrador editar cobros ya registrados', 'admin'),
      (v_tenant.id, 'cobranza.foto_obligatoria', '"false"', 'boolean', 'cobranza',
       'Requiere foto del comprobante al cobrar', 'admin'),
      (v_tenant.id, 'cobranza.pago_parcial', '"true"', 'boolean', 'cobranza',
       'Permite pagos parciales de cuotas', 'admin'),
      (v_tenant.id, 'cobranza.pago_adelantado', '"true"', 'boolean', 'cobranza',
       'Permite pagar múltiples cuotas en un solo cobro', 'admin'),
      (v_tenant.id, 'cobranza.cargo_reconexion', '"0"', 'number', 'cobranza',
       'Cargo automático por reconexión (0 = deshabilitado)', 'admin'),

      -- Métodos de pago
      (v_tenant.id, 'pagos.metodo_efectivo', '"true"', 'boolean', 'pagos',
       'Habilitar pago en efectivo', 'admin'),
      (v_tenant.id, 'pagos.metodo_transferencia', '"false"', 'boolean', 'pagos',
       'Habilitar pago por transferencia', 'admin'),
      (v_tenant.id, 'pagos.metodo_tarjeta', '"false"', 'boolean', 'pagos',
       'Habilitar pago con tarjeta', 'admin'),

      -- Moneda
      (v_tenant.id, 'moneda.principal', '"NIO"', 'string', 'moneda',
       'Moneda principal del tenant (NIO o USD)', 'admin'),

      -- Cuotas
      (v_tenant.id, 'cuotas.manuales', '"false"', 'boolean', 'cuotas',
       'Permite al admin crear cuotas fuera de contrato', 'admin'),
      (v_tenant.id, 'cuotas.editar_monto', '"false"', 'boolean', 'cuotas',
       'Permite al admin modificar monto de cuota generada', 'admin'),
      (v_tenant.id, 'cuotas.descuento_pronto_pago', '"0"', 'number', 'cuotas',
       'Descuento por pronto pago (% si <100, monto fijo si >=100. 0 = deshabilitado)', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;

  END LOOP;
END $$;
