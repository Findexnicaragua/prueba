-- 0064: Backfill de pagos legacy con vuelto (anteriores a migración 0061).
--
-- Antes del fix del vuelto (0061), pagos.monto_cordobas guardaba lo que el
-- cliente ENTREGÓ. Si pagó de más, la cuota quedó con monto_pagado > total
-- (sobrepago, viola INV4) y el recaudado del contrato quedó inflado.
--
-- Este script repara la corrupción histórica: por cada cuota sobrepagada,
-- mueve el exceso del pago más reciente a vuelto_cordobas. El trigger
-- trg_pagos_update_recalcular recalcula cuota.monto_pagado automáticamente.
--
-- IDEMPOTENTE: solo toca pagos cuya cuota está sobrepagada. Correrlo de
-- nuevo no hace nada (ya no hay sobrepago tras la primera corrida).
--
-- Detectado por: supabase/tests/invariantes_dinero.sql → INV4.

WITH sobrepago AS (
  SELECT cu.id AS cuota_id,
         cu.monto_pagado - (cu.monto + COALESCE(cu.cargos_neto, 0)) AS exceso
  FROM public.cuotas cu
  WHERE cu.estado <> 'anulada'
    AND cu.monto_pagado > (cu.monto + COALESCE(cu.cargos_neto, 0)) + 0.01
),
pago_objetivo AS (
  -- El pago más reciente NO anulado de cada cuota sobrepagada.
  -- Es el que recibió el exceso (el cliente entregó de más en ese cobro).
  SELECT DISTINCT ON (p.cuota_id)
         p.id AS pago_id, s.exceso
  FROM public.pagos p
  JOIN sobrepago s ON s.cuota_id = p.cuota_id
  WHERE p.anulado = false
  ORDER BY p.cuota_id, p.fecha_pago DESC
)
UPDATE public.pagos p
SET monto_cordobas  = p.monto_cordobas - po.exceso,
    vuelto_cordobas = p.vuelto_cordobas + po.exceso
FROM pago_objetivo po
WHERE p.id = po.pago_id
  AND p.monto_cordobas >= po.exceso;  -- guard defensivo: no dejar negativo
