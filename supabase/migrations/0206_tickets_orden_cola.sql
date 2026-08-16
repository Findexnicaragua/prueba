-- =========================================================================
-- 0206 — Orden de la cola del técnico (Fase 2)
--
-- Pedido del nuevo dueño (audio 6): "quiero que el técnico pueda ver la
-- siguiente orden, pero no la pueda manipular hasta que haya terminado la
-- primera […] hay la opción que el coordinador, porque no encontraron a la
-- persona, pues pueda pasarlo para segundo lugar, tercer lugar o último".
--
-- El BLOQUEO en sí no necesita esta columna (alcanzaba con ordenar por fecha),
-- pero el REORDENAMIENTO del coordinador sí. Se agrega ahora para que la cola
-- se construya desde el principio sobre su orden definitivo: si el bloqueo se
-- montara sobre `created_at` y después se cambiara, la orden "activa" de un
-- técnico podría saltar de la noche a la mañana.
--
-- NULL = sin posición asignada → va después de las ordenadas, por antigüedad.
-- Así ningún ticket existente cambia de lugar al aplicar esta migración.
--
-- Aditivo (columna nullable) → sin bump de `_dbWipeVersion`.
-- =========================================================================

BEGIN;

ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS orden_cola integer;

COMMENT ON COLUMN public.tickets.orden_cola IS
  'Posición en la cola del técnico asignado. NULL = sin posición explícita '
  '(se ordena por created_at, después de las que sí la tienen). Lo setea el '
  'coordinador al reordenar; ver kEstadosOcupanTecnico en cola_tecnico.dart.';

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 2 filas deben dar ok = true.
-- =========================================================================
SELECT 'tickets.orden_cola existe y es integer nullable' AS chequeo,
       data_type = 'integer' AND is_nullable = 'YES' AS ok
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets' AND column_name='orden_cola'
UNION ALL
SELECT 'ningun ticket existente quedo con posicion (todos NULL)',
       COUNT(*) FILTER (WHERE orden_cola IS NOT NULL) = 0
  FROM public.tickets;
