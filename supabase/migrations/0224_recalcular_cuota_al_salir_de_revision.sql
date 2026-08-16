-- 0224 — el recálculo de la cuota también dispara al salir de CUARENTENA.
--
-- BUG (audit 2026-08-08). `trg_pagos_update_recalcular` escuchaba
--   AFTER UPDATE OF monto_cordobas, cuota_id, anulado
-- pero NO `en_revision`. Y `recalcular_cuota_desde_pagos()` suma
--   WHERE anulado = false AND en_revision = false
-- o sea que `en_revision` SÍ cambia el resultado del recálculo, pero no lo
-- disparaba. La combinación es venenosa por el ORDEN en que resuelve la app:
--
--   `pagos_repo.elegirCobroVerdadero()` (pagos_repo.dart:834)
--     1. anula los OTROS pagos vivos de la cuota  → dispara el trigger, y como
--        el pago ELEGIDO todavía tiene en_revision = true, no lo suma:
--        la cuota queda en monto_pagado = 0, estado 'pendiente'.
--     2. recién entonces hace UPDATE pagos SET en_revision = 0 sobre el elegido
--        → ESTE update no dispara nada.
--
-- Resultado: cuota PENDIENTE con la plata ya cobrada. Traba oldest-first en ese
-- contrato, infla la mora del cliente, impide desactivarlo (guard 0220) y
-- empuja al cobrador a cobrarle en la calle un mes ya pagado.
--
-- El comentario de pagos_repo.dart:828 ("El server recalcula monto_pagado/estado
-- (triggers 0083/0216)") era FALSO para este camino; se corrige aparte.
--
-- ESTADO AL APLICAR: 0 cuotas dañadas en producción (nadie resolvió todavía una
-- cuarentena eligiendo el pago retenido). Es prevención, no reparación — por eso
-- la migración no repara nada: no hay nada que reparar.
--
-- Nota: `cuotas_forzar_derivados_trg` (0216, BEFORE UPDATE en cuotas) ya reparaba
-- el caso de rebote — cualquier escritura posterior sobre esa fila de cuotas
-- recalcula desde `pagos`. Por eso el daño no era permanente, pero sí quedaba
-- vivo hasta que algo volviera a tocar la cuota.

DROP TRIGGER IF EXISTS trg_pagos_update_recalcular ON public.pagos;

CREATE TRIGGER trg_pagos_update_recalcular
  AFTER UPDATE OF monto_cordobas, cuota_id, anulado, en_revision
  ON public.pagos
  FOR EACH ROW
  EXECUTE FUNCTION recalcular_cuota_desde_pagos();

COMMENT ON TRIGGER trg_pagos_update_recalcular ON public.pagos IS
  'Recalcula monto_pagado/estado de la cuota. Escucha en_revision desde 0224: '
  'sacar un pago de cuarentena CAMBIA el resultado de recalcular_cuota_desde_pagos '
  '(su WHERE filtra en_revision), asi que tiene que disparar. Si se agrega otra '
  'columna al predicado de pagos vivos, agregarla tambien a esta lista.';
