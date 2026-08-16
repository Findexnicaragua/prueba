-- Pagos del escenario de Test Tenant. Cada uno se aplica a la cuota EXACTA por
-- (cliente, fecha de vencimiento), así no depende de ids que cambian al
-- re-sembrar.
--
--   Ana   paga el 20-jul su cuota del 20-jul  → a tiempo (gracia vence 30-jul)
--   Carla paga el  5-ago su cuota del 18-jul  → TARDE (gracia vencía el 28-jul)
--   Dani  paga el  1-ago su cuota del 20-jun  → deuda de un ciclo ANTERIOR
--   Beto  no paga                              → queda en mora
--
-- `fecha_pago` va local-naive a propósito (convención del proyecto: su
-- wall-clock sostiene el bucketing por date()).
BEGIN;

INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas,
                          monto_original, metodo, moneda, tasa_conversion,
                          fecha_pago, vuelto_cordobas, anulado, en_revision,
                          ocurrido_en)
SELECT gen_random_uuid(),
       '8583a8f0-191d-4750-a07d-923c01a45300',
       cu.id,
       '79c45dce-d5a6-4568-9835-dcb89d9909db',   -- Cobrador Test
       cu.monto, cu.monto, 'efectivo', 'NIO', 1,
       x.pagado, 0, false, false, now()
  FROM (VALUES
    ('T0001', DATE '2026-07-20', TIMESTAMP '2026-07-20 10:15:00'),
    ('T0003', DATE '2026-07-18', TIMESTAMP '2026-08-05 16:40:00'),
    ('T0004', DATE '2026-06-20', TIMESTAMP '2026-08-01 09:05:00')
  ) AS x(cli, vence, pagado)
  JOIN public.clientes c
    ON c.codigo = x.cli
   AND c.tenant_id = '8583a8f0-191d-4750-a07d-923c01a45300'
  JOIN public.cuotas cu
    ON cu.cliente_id = c.id
   AND cu.fecha_vencimiento = x.vence;

COMMIT;
