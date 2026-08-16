-- =========================================================================
-- 0210 — Permiso del gestor para marcar una orden como verificada (Fase 4)
--
-- La 0209 dejó las órdenes de instalación en 'pendiente' esperando al gestor,
-- pero el gestor NO PODÍA TOCARLAS: la policy `tk_write` de tickets es
-- `is_ticket_staff()` = admin / admin_tickets / tecnico, y `admin_usuarios` no
-- está. Su botón "Verificada" habría escrito local, se habría visto bien, y lo
-- habría rechazado el server al sincronizar. (Tercera vez que aparece este
-- patrón en el proyecto: 0205 con el técnico y el inventario, 0207 con el
-- coordinador. Regla: antes de dar un botón a un rol, chequear su RLS.)
--
-- Se le abre UPDATE sobre tickets, pero acotado a las 3 columnas de la
-- verificación por un trigger — igual que con el coordinador, y por la misma
-- razón: las policies son ROW-level y dejarían pasar la fila entera.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Helper de rol. COALESCE ADENTRO: `current_user_rol()` es NULL sin usuario
--    resuelto, y en un `IF NOT ...` de plpgsql ese NULL saltea el guard
--    (bug real encontrado en 0207).
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin_usuarios()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    (SELECT rol = 'admin_usuarios' FROM public.cobradores WHERE id = auth.uid()),
    false
  )
$function$;

-- -------------------------------------------------------------------------
-- 2. Policy de UPDATE para el gestor.
-- -------------------------------------------------------------------------
DROP POLICY IF EXISTS "tk_update_verificacion" ON public.tickets;
CREATE POLICY "tk_update_verificacion" ON public.tickets
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.is_admin_usuarios()
         AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
  WITH CHECK (tenant_id = public.current_tenant_id()
         AND public.is_admin_usuarios()
         AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));

-- -------------------------------------------------------------------------
-- 3. La barrera de columnas: el gestor SOLO firma la verificación.
--    No cierra, no reasigna, no edita el trabajo.
--
--    Trigger separado del coordinador a propósito: son dos reglas distintas
--    para dos roles distintos, y mezclarlas haría que tocar una arriesgue la
--    otra. `ocurrido_en` va permitido porque el cliente lo re-sella en toda
--    escritura.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tickets_gestor_solo_verificacion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT COALESCE(public.is_admin_usuarios(), false) THEN
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - 'verificacion_estado' - 'verificado_por'
      - 'verificado_en' - 'ocurrido_en')
     IS DISTINCT FROM
     (to_jsonb(OLD) - 'verificacion_estado' - 'verificado_por'
      - 'verificado_en' - 'ocurrido_en') THEN
    RAISE EXCEPTION
      'El gestor solo puede verificar la orden %, no modificarla',
      OLD.correlativo
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_tickets_gestor_solo_verificacion ON public.tickets;
CREATE TRIGGER trg_tickets_gestor_solo_verificacion
  BEFORE UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_gestor_solo_verificacion();

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'is_admin_usuarios existe y NO devuelve NULL' AS chequeo,
       public.is_admin_usuarios() IS NOT NULL AS ok
UNION ALL
SELECT 'la funcion trae COALESCE adentro',
       pg_get_functiondef(oid) LIKE '%COALESCE%'
  FROM pg_proc WHERE proname='is_admin_usuarios'
UNION ALL
SELECT 'la policy de verificacion existe', COUNT(*) = 1
  FROM pg_policies
 WHERE tablename='tickets' AND policyname='tk_update_verificacion'
UNION ALL
SELECT 'el trigger de columnas del gestor esta activo', COUNT(*) = 1
  FROM pg_trigger WHERE tgname='trg_tickets_gestor_solo_verificacion';
