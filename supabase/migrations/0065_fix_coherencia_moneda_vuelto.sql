-- 0065: Corregir constraint pagos_coherencia_moneda para el modelo de vuelto.
--
-- BUG CRÍTICO DE PRODUCCIÓN encontrado al correr el backfill 0064:
-- el constraint viejo (migración 0005) exigía para NIO:
--     monto_cordobas = monto_original
-- Eso era válido ANTES del vuelto, cuando monto_cordobas == lo entregado.
--
-- Con el modelo de vuelto (0061):
--   - monto_original  = lo ENTREGADO en moneda original
--   - monto_cordobas  = lo APLICADO a la cuota
--   - vuelto_cordobas = lo devuelto al cliente (siempre NIO)
--   - Invariante: entregado = aplicado + vuelto
--
-- Para NIO (tasa=1): monto_original = monto_cordobas + vuelto_cordobas.
-- Sin este fix, CUALQUIER cobro NIO con vuelto sería rechazado por el
-- constraint. (USD se deja laxo: tasa>0, por redondeo de conversión; INV1
-- en invariantes_dinero.sql verifica la coherencia USD con tolerancia.)
--
-- Legacy sin vuelto: monto_original = monto_cordobas + 0 → sigue cumpliendo.

ALTER TABLE public.pagos DROP CONSTRAINT IF EXISTS pagos_coherencia_moneda;

ALTER TABLE public.pagos ADD CONSTRAINT pagos_coherencia_moneda
  CHECK (
    (moneda = 'NIO'
       AND tasa_conversion = 1
       AND ABS(monto_original - (monto_cordobas + vuelto_cordobas)) < 0.01)
    OR
    (moneda = 'USD' AND tasa_conversion > 0)
  );
