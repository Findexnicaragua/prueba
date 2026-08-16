-- =========================================================================
-- 0211 — Una orden reabierta vuelve a verificarse (audit profundo 2026-07-26)
--
-- La 0209 marcaba 'pendiente' solo si `verificacion_estado IS NULL`, con la
-- idea de "no pisar que el gestor ya la había verificado". Auditado en frío,
-- ese razonamiento es más débil que el riesgo que abre:
--
--   una instalación se verifica → se REABRE → el técnico vuelve, cambia el
--   equipo, corrige la dirección, la re-cierra → y el gestor NUNCA la ve otra
--   vez. Queda con el sello de una verificación que se hizo sobre datos que
--   ya no existen.
--
-- Verificar de más cuesta un minuto; dar por verificado un trabajo que cambió
-- es exactamente lo que este paso existe para evitar.
--
-- El trigger solo dispara en la TRANSICIÓN a 'cerrado' (`OLD.estado IS
-- DISTINCT FROM 'cerrado'`), así que un UPDATE cualquiera sobre una orden ya
-- cerrada NO la vuelve a marcar: solo un ciclo real de reapertura y cierre.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.tickets_marcar_verificacion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.estado = 'cerrado'
     AND OLD.estado IS DISTINCT FROM 'cerrado'
     AND EXISTS (SELECT 1 FROM public.ticket_tipos tt
                  WHERE tt.id = NEW.tipo_id
                    AND tt.tenant_id = NEW.tenant_id
                    AND tt.efecto = 'instalacion')
  THEN
    -- Sin el `IS NULL` de 0209: cada cierre de una instalación vuelve a pedir
    -- verificación, incluso si ya la tuvo antes de una reapertura. Se limpian
    -- el quién y el cuándo para que no quede el sello viejo colgado.
    NEW.verificacion_estado := 'pendiente';
    NEW.verificado_por := NULL;
    NEW.verificado_en := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 2 filas deben dar ok = true.
-- =========================================================================
SELECT 'el trigger ya NO exige que la verificacion este vacia' AS chequeo,
       pg_get_functiondef(oid) NOT LIKE '%NEW.verificacion_estado IS NULL%' AS ok
  FROM pg_proc WHERE proname='tickets_marcar_verificacion'
UNION ALL
SELECT 'limpia el sello viejo al re-pedir verificacion',
       pg_get_functiondef(oid) LIKE '%NEW.verificado_por := NULL%'
  FROM pg_proc WHERE proname='tickets_marcar_verificacion';
