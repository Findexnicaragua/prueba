-- 0044: Agregar setting para tipo de descuento pronto pago.
-- Antes se usaba un heuristic (< 100 = porcentaje, >= 100 = fijo).
-- Ahora el admin elige explícitamente el tipo.

INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion)
SELECT
  t.id,
  'cuotas.descuento_pronto_pago_tipo',
  '"porcentaje"',
  'string',
  'cuotas',
  'Tipo de descuento pronto pago: porcentaje o monto'
FROM tenants t
WHERE NOT EXISTS (
  SELECT 1 FROM settings s
  WHERE s.tenant_id = t.id AND s.clave = 'cuotas.descuento_pronto_pago_tipo'
);
