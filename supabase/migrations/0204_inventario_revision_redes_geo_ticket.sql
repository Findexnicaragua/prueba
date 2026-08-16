-- =========================================================================
-- 0204 — Ciclo del material (revisión / redes / descarte) + geo en la orden
--
-- Pedido del nuevo dueño (audios 2026-07-26, ver BITACORA):
--   "del técnico pasa a revisión y de revisión pasa a la bodega si está bueno
--    y si está malo pasa a descarte […] y los materiales que están instalados
--    en las redes […] del técnico regresa lo malo a revisión"
--   "el técnico va a poner la geolocalizacion como parte de la orden"
--
-- Los tres cambios son ADITIVOS (amplían CHECKs / agregan columnas nullables):
--   1. inv_seriales.estado      += 'en_revision'
--   2. inv_ubicaciones.tipo     += 'redes'
--   3. tickets.lat / tickets.lng (nuevas, NULL = orden sin ubicación marcada)
--
-- NO se bumpea `_dbWipeVersion`: PowerSync aplica aditivos in-place (R4).
-- 'descarte' NO es un estado nuevo — es el label de 'baja' (solo Dart).
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. inv_seriales.estado: sumar 'en_revision'
--
-- Limbo entre que el equipo vuelve del cliente/red y que se decide su destino.
-- Desde acá el equipo sale a 'en_stock' (sirve) o a 'baja' (descarte).
-- El CHECK se reescribe COMPLETO a partir del vigente (0101) — no existe otra
-- migración que lo haya tocado (verificado con grep sobre migrations/).
-- -------------------------------------------------------------------------
ALTER TABLE public.inv_seriales DROP CONSTRAINT IF EXISTS inv_seriales_estado_check;
ALTER TABLE public.inv_seriales ADD CONSTRAINT inv_seriales_estado_check
  CHECK (estado IN ('en_stock','instalado','danado','retirado','baja','en_revision'));

-- -------------------------------------------------------------------------
-- 2. inv_ubicaciones.tipo: sumar 'redes'
--
-- Material que queda montado en la planta (troncales, splitters, herrajes):
-- no tiene cliente dueño, pero tampoco está en bodega. Sin él, el material de
-- construcción no tiene dónde vivir y quedaba mal contado como 'en_stock'.
-- -------------------------------------------------------------------------
ALTER TABLE public.inv_ubicaciones DROP CONSTRAINT IF EXISTS inv_ubicaciones_tipo_check;
ALTER TABLE public.inv_ubicaciones ADD CONSTRAINT inv_ubicaciones_tipo_check
  CHECK (tipo IN ('central','bodega','vehiculo','tecnico','redes'));

-- -------------------------------------------------------------------------
-- 3. tickets.lat / tickets.lng
--
-- Ubicación REAL donde el técnico ejecutó la orden. Es del TICKET, no del
-- cliente: la casa puede estar mal geolocalizada en la ficha, y lo que importa
-- para auditar el trabajo es dónde se paró el técnico. Nullable a propósito —
-- las órdenes viejas y las que no se ejecutan en sitio no tienen ubicación.
-- Convención `lat`/`lng` en `real`, igual que clientes (schema.dart).
-- -------------------------------------------------------------------------
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS lat double precision;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS lng double precision;

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO (no por existencia — lección de la 0192: el
-- CHECK existía pero sin el valor nuevo y la verificación lo dio por bueno).
-- Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT
  'inv_seriales.estado admite en_revision' AS chequeo,
  pg_get_constraintdef(oid) LIKE '%en_revision%' AS ok
  FROM pg_constraint
 WHERE conrelid = 'public.inv_seriales'::regclass
   AND conname  = 'inv_seriales_estado_check'
UNION ALL
SELECT
  'inv_ubicaciones.tipo admite redes',
  pg_get_constraintdef(oid) LIKE '%redes%'
  FROM pg_constraint
 WHERE conrelid = 'public.inv_ubicaciones'::regclass
   AND conname  = 'inv_ubicaciones_tipo_check'
UNION ALL
SELECT
  'tickets.lat existe y es double precision',
  data_type = 'double precision'
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'tickets' AND column_name = 'lat'
UNION ALL
SELECT
  'tickets.lng existe y es double precision',
  data_type = 'double precision'
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'tickets' AND column_name = 'lng';
