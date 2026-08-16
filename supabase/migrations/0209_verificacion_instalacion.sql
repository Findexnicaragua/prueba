-- =========================================================================
-- 0209 — La orden cerrada pasa al gestor para verificar (Fase 4)
--
-- Audio 2 del nuevo dueño: "el ticket ya realizado se le manda al gestor del
-- cliente ya con todos los datos, ya solo para que verifique que lo que se
-- escribió en el contrato es lo mismo que está escrito en la orden […] y el
-- número de contrato […] y una vez pasa al super administrador para que lo
-- apruebe. El punto interesante es que del ticket pase al gestor de usuario
-- EN EL MISMO SISTEMA".
--
-- (El "super administrador" que aprueba es el rol `admin` del tenant, aclarado
-- por Rubén — no el `super_admin` del SaaS, que ahora se muestra como "Dev".)
--
-- QUÉ SE REUSA EN VEZ DE CONSTRUIR:
--   · `ticket_tipos.efecto = 'instalacion'` (0172) YA marca qué órdenes crean
--     servicio. No hace falta un flag nuevo: si el tipo instala, se verifica.
--   · La aprobación del admin YA existe: `solicitudes_accion` (0193), con sus
--     estados y su aprobador. Esta migración NO la toca.
--
-- POR QUÉ UN TRIGGER Y NO CÓDIGO EN LA APP: una orden se cierra por TRES
-- caminos distintos —el cierre normal, el "cerrar sin confirmar" (0208) y el
-- cron de auto-cierre (0109, que corre sin ninguna app abierta)—. Marcarlo
-- desde Dart dejaría afuera el tercero justamente en el caso más probable:
-- la instalación que nadie confirmó y se cerró sola de madrugada.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Estado de la verificación.
--    NULL = no aplica (la orden no instala nada). 'pendiente' = esperando al
--    gestor. 'verificada' = el gestor comparó la orden contra el contrato.
--    Nullable a propósito (ver la cabecera de 0208: una NOT NULL que el
--    cliente no setee traba la cola de upload del dispositivo).
-- -------------------------------------------------------------------------
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS verificacion_estado text;
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS verificado_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL;
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS verificado_en timestamptz;

ALTER TABLE public.tickets DROP CONSTRAINT IF EXISTS tickets_verificacion_estado_check;
ALTER TABLE public.tickets ADD CONSTRAINT tickets_verificacion_estado_check
  CHECK (verificacion_estado IS NULL
         OR verificacion_estado IN ('pendiente','verificada'));

-- Índice para la bandeja del gestor: son pocas filas sobre muchas órdenes.
CREATE INDEX IF NOT EXISTS tickets_verificacion_pendiente_idx
  ON public.tickets (tenant_id)
  WHERE verificacion_estado = 'pendiente';

-- -------------------------------------------------------------------------
-- 2. Al cerrarse una orden de instalación, queda pendiente de verificar.
--
--    Solo en la TRANSICIÓN a 'cerrado' (no en cada UPDATE de una ya cerrada) y
--    solo si todavía no tiene estado de verificación — así un re-cierre tras
--    una reapertura no borra que el gestor ya la había verificado.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tickets_marcar_verificacion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.estado = 'cerrado'
     AND OLD.estado IS DISTINCT FROM 'cerrado'
     AND NEW.verificacion_estado IS NULL
     AND EXISTS (SELECT 1 FROM public.ticket_tipos tt
                  WHERE tt.id = NEW.tipo_id
                    AND tt.tenant_id = NEW.tenant_id
                    AND tt.efecto = 'instalacion')
  THEN
    NEW.verificacion_estado := 'pendiente';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_tickets_marcar_verificacion ON public.tickets;
CREATE TRIGGER trg_tickets_marcar_verificacion
  BEFORE UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_marcar_verificacion();

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 5 filas deben dar ok = true.
-- =========================================================================
SELECT 'verificacion_estado existe y es NULLABLE' AS chequeo,
       data_type='text' AND is_nullable='YES' AS ok
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets'
   AND column_name='verificacion_estado'
UNION ALL
SELECT 'verificado_por y verificado_en existen', COUNT(*) = 2
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='tickets'
   AND column_name IN ('verificado_por','verificado_en')
UNION ALL
SELECT 'el CHECK acepta NULL y los 2 estados',
       pg_get_constraintdef(oid) LIKE '%pendiente%'
   AND pg_get_constraintdef(oid) LIKE '%verificada%'
  FROM pg_constraint
 WHERE conrelid='public.tickets'::regclass
   AND conname='tickets_verificacion_estado_check'
UNION ALL
SELECT 'el trigger esta activo', COUNT(*) = 1
  FROM pg_trigger WHERE tgname='trg_tickets_marcar_verificacion'
UNION ALL
SELECT 'el indice de la bandeja existe', COUNT(*) = 1
  FROM pg_indexes
 WHERE schemaname='public' AND indexname='tickets_verificacion_pendiente_idx';
