-- =========================================================================
-- 0208 — Cierre de la orden con intentos de contacto (Fase 3)
--
-- Audio 1 del nuevo dueño: "va a cerrar el ticket una vez que se comunique con
-- el cliente y le diga que todo está arreglado, si no, no lo va a poder
-- cerrar […] tiene que garantizar que el trabajo se haga".
--
-- Decisión de Rubén (opción A+B): el call center registra cada intento de
-- contacto; tras N intentos se habilita "cerrar sin confirmar" con motivo
-- obligatorio, y queda marcado como tal para los reportes.
--
-- La parte B (auto-cierre a los X días) NO se construye acá: YA EXISTE desde
-- 0109 — `tickets_auto_cierre(tenant)` + el cron diario
-- `tickets_auto_cierre_diario` (06:30 UTC). Solo hay que prender el setting
-- `tickets.auto_cierre_dias`, que hoy está en 0 (desactivado) en los 4 tenants.
--
-- 1. `ticket_eventos.tipo_evento` += 'contacto'
-- 2. `tickets.cerrado_sin_confirmar` + `tickets.motivo_cierre`
--
-- ⚠️ Las dos columnas nacen NULLABLES A PROPÓSITO, no por descuido. El SQLite
-- local de PowerSync no tiene DEFAULTs y el conector sube la fila entera: una
-- columna NOT NULL que el cliente no setee viaja como NULL, la rechaza Postgres
-- y TRABA LA COLA DE UPLOAD del dispositivo. Se leen siempre con COALESCE.
-- (Se aprendió en 0205, donde `tipo` sí es NOT NULL y hubo que setearlo
-- explícito en todos los INSERT de Dart para no romper el consumo.)
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Un intento de contacto es un evento más de la bitácora del ticket.
--
--    Se reusa `ticket_eventos` en vez de crear una tabla: ya sincroniza a
--    todos los shells, ya tiene RLS, ya se muestra en el timeline de la orden
--    y ya la lee el historial. Una tabla nueva sería 1 migración + 4 policies
--    + 5 buckets de sync para guardar "llamé y no contestó".
--
--    El CHECK se reescribe COMPLETO desde el vigente (0103).
-- -------------------------------------------------------------------------
ALTER TABLE public.ticket_eventos DROP CONSTRAINT IF EXISTS ticket_eventos_tipo_evento_check;
ALTER TABLE public.ticket_eventos ADD CONSTRAINT ticket_eventos_tipo_evento_check
  CHECK (tipo_evento IN
    ('creado','asignado','cambio_estado','comentario','material','adjunto',
     'reabierto','cerrado','cancelado','contacto'));

-- -------------------------------------------------------------------------
-- 2. Cómo se cerró la orden.
--
--    `cerrado_sin_confirmar` = se cerró SIN que el cliente confirmara que el
--    trabajo quedó bien. No es un error: es una salida legítima tras N
--    intentos fallidos. Se marca para que el ISP pueda MEDIR cuántas cierra a
--    ciegas — si ese número crece, algo anda mal en la operación.
--    `motivo_cierre` es obligatorio en la UI para ese caso.
-- -------------------------------------------------------------------------
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS cerrado_sin_confirmar boolean;
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS motivo_cierre text;

COMMENT ON COLUMN public.tickets.cerrado_sin_confirmar IS
  'true = se cerró tras N intentos fallidos, sin confirmación del cliente. '
  'NULL/false = cierre normal. Nullable a propósito (ver cabecera de 0208).';

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'ticket_eventos admite tipo contacto' AS chequeo,
       pg_get_constraintdef(oid) LIKE '%contacto%' AS ok
  FROM pg_constraint
 WHERE conrelid='public.ticket_eventos'::regclass
   AND conname='ticket_eventos_tipo_evento_check'
UNION ALL
SELECT 'el CHECK no perdio ningun tipo viejo',
       pg_get_constraintdef(oid) LIKE '%material%'
   AND pg_get_constraintdef(oid) LIKE '%adjunto%'
   AND pg_get_constraintdef(oid) LIKE '%reabierto%'
   AND pg_get_constraintdef(oid) LIKE '%cancelado%'
  FROM pg_constraint
 WHERE conrelid='public.ticket_eventos'::regclass
   AND conname='ticket_eventos_tipo_evento_check'
UNION ALL
SELECT 'cerrado_sin_confirmar existe y es NULLABLE',
       data_type='boolean' AND is_nullable='YES'
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets'
   AND column_name='cerrado_sin_confirmar'
UNION ALL
SELECT 'motivo_cierre existe y es NULLABLE',
       data_type='text' AND is_nullable='YES'
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets' AND column_name='motivo_cierre';
