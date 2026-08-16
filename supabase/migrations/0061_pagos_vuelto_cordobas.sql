-- 0061: Agregar columna pagos.vuelto_cordobas.
--
-- CRÍTICO contable: hasta ahora pagos.monto_cordobas guardaba lo que
-- el cliente ENTREGÓ (incluyendo vuelto). Esto inflaba el recaudado
-- del contrato cuando había vuelto.
--
-- Modelo nuevo:
--   - monto_cordobas: lo APLICADO a la cuota (lo que ingresó a la caja)
--   - vuelto_cordobas: lo devuelto al cliente
--   - entregado_cordobas (calculado en UI): monto_cordobas + vuelto_cordobas
--
-- Para data legacy: la columna nueva default 0. Los pagos viejos asumen
-- que no hubo vuelto (lo cual puede no ser cierto, pero es lo más seguro
-- para no alterar el monto_cordobas existente).

ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS vuelto_cordobas numeric(10,2) NOT NULL DEFAULT 0
    CHECK (vuelto_cordobas >= 0);

COMMENT ON COLUMN public.pagos.vuelto_cordobas IS
  'Vuelto entregado al cliente cuando el monto pagado > saldo de la cuota. '
  'monto_cordobas siempre es lo APLICADO a la cuota.';
