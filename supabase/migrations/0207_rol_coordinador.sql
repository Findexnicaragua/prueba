-- =========================================================================
-- 0207 — Rol `coordinador` (Fase 2)
--
-- Del diagrama del nuevo dueño: "EL COORDINADOR NO PODRÁ MODIFICAR LOS
-- TRABAJOS, SOLO ORDENAR" + audio 1: "del ticket se le manda al coordinador
-- para que organice qué técnico, qué cuadrilla lleva los trabajos".
--
-- Alcance aprobado por Rubén (2026-07-26):
--   · Escribe SOLO `asignado_a` y `orden_cola`. Nada más: ni título, ni
--     descripción, ni tipo, ni cliente, ni estado, ni prioridad.
--   · Ve TODAS las órdenes del tenant (para repartir carga entre técnicos).
--   · No toca dinero.
--
-- ⚠️ POR QUÉ HAY UN TRIGGER Y NO ALCANZA LA RLS: las policies de Postgres son
-- ROW-level, no column-level — dejan pasar o bloquean la fila entera. Un
-- `FOR UPDATE USING (is_coordinador())` le permitiría reescribir el título o
-- cerrar la orden. Restringir por columna con `GRANT UPDATE (col)` tampoco
-- sirve acá: Supabase autentica a todos con el MISMO rol de Postgres
-- (`authenticated`), así que el GRANT afectaría a admins y técnicos también.
-- La única barrera real es un trigger que compare OLD vs NEW. (Misma lección
-- que `cobradores.password_texto` en 0199.)
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. CHECK del rol — reescrito COMPLETO desde el vigente (0198) + coordinador
-- -------------------------------------------------------------------------
ALTER TABLE public.cobradores DROP CONSTRAINT IF EXISTS cobradores_rol_check;
ALTER TABLE public.cobradores ADD CONSTRAINT cobradores_rol_check
  CHECK (rol IN ('super_admin','admin','admin_cobranza','cobrador',
                 'tecnico','admin_tickets','admin_usuarios','lectura',
                 'coordinador'));

-- -------------------------------------------------------------------------
-- 2. Helper de rol, en la línea de is_ticket_staff / is_lectura
-- -------------------------------------------------------------------------
-- El COALESCE va ADENTRO, como `is_super_admin()` — no como `is_lectura()` /
-- `is_ticket_staff()`, que devuelven NULL si el usuario no tiene fila en
-- `cobradores`. En una policy RLS ese NULL es inocuo (la fila se filtra, falla
-- cerrado), pero en un `IF NOT ...` de plpgsql NO se cumple y saltea el guard.
-- Blindarlo acá evita que cada llamador nuevo tenga que acordarse.
CREATE OR REPLACE FUNCTION public.is_coordinador()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    (SELECT rol = 'coordinador' FROM public.cobradores WHERE id = auth.uid()),
    false
  )
$function$;

-- -------------------------------------------------------------------------
-- 3. handle_new_user: sumar 'coordinador' a la whitelist.
--
--    El cuerpo se copió de la definición VIVA en la DB (pg_get_functiondef),
--    NO de la migración que la creó — lección 0151→0152: reescribirla desde un
--    cuerpo viejo pierde en silencio lo que se le agregó en el medio.
--    Único cambio respecto del vivo: 'coordinador' en el IF de la whitelist.
--    `coordinador` no cobra → cae en el ELSE NULL del prefijo, sin tocar nada.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
BEGIN
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  IF v_rol NOT IN ('super_admin', 'admin', 'admin_cobranza', 'cobrador',
                   'tecnico', 'admin_tickets', 'admin_usuarios', 'lectura',
                   'coordinador') THEN
    v_rol := 'admin';
  END IF;

  IF v_rol = 'super_admin' THEN
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  ELSIF v_tenant_id IS NULL THEN
    INSERT INTO public.tenants (nombre)
      VALUES (coalesce(v_empresa_nombre, 'Mi ISP'))
      RETURNING id INTO v_tenant_id;
    v_rol := 'admin';
  END IF;

  INSERT INTO public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) VALUES (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    CASE WHEN v_rol IN ('cobrador', 'admin', 'admin_cobranza')
         THEN v_prefijo ELSE NULL END,
    true
  )
  ON CONFLICT (id) DO UPDATE
    SET tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  RETURN new;
END;
$function$;

-- -------------------------------------------------------------------------
-- 4. RLS: el coordinador puede UPDATE de tickets de su tenant.
--    Qué columnas, lo decide el trigger del punto 5.
--    (SELECT ya lo tiene por `tk_read`, que es tenant-wide.)
-- -------------------------------------------------------------------------
DROP POLICY IF EXISTS "tk_update_coordinador" ON public.tickets;
CREATE POLICY "tk_update_coordinador" ON public.tickets
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.is_coordinador()
         AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'))
  WITH CHECK (tenant_id = public.current_tenant_id()
         AND public.is_coordinador()
         AND public.tenant_tiene_modulo(public.current_tenant_id(), 'tickets'));

-- -------------------------------------------------------------------------
-- 5. LA barrera real: el coordinador solo mueve asignación y posición.
--
--    `ocurrido_en` entra en la lista permitida porque el cliente lo re-sella
--    en CUALQUIER escritura (es el reloj de la intención, no contenido del
--    trabajo). Sin él, una reasignación legítima sería rechazada.
--
--    Se compara el row entero menos las columnas permitidas: así una columna
--    que se agregue en el futuro queda protegida sola, sin tener que acordarse
--    de venir a editar este trigger.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tickets_coordinador_solo_orden()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- COALESCE OBLIGATORIO, no es defensivo de más: `current_user_rol()` devuelve
  -- NULL cuando no hay usuario resuelto (service_role, la CLI, un contexto sin
  -- auth.uid()), así que `is_coordinador()` da NULL — y en plpgsql `IF NOT NULL`
  -- NO se cumple, con lo cual el RETURN temprano se salteaba y el trigger
  -- bloqueaba escrituras legítimas de cualquiera. Encontrado en la prueba
  -- end-to-end: un UPDATE normal de título/estado murió con "el coordinador
  -- solo puede asignar y ordenar".
  IF NOT COALESCE(public.is_coordinador(), false) THEN
    RETURN NEW;  -- admin/técnico/etc. siguen con sus reglas de siempre
  END IF;
  IF (to_jsonb(NEW) - 'asignado_a' - 'orden_cola' - 'ocurrido_en')
     IS DISTINCT FROM
     (to_jsonb(OLD) - 'asignado_a' - 'orden_cola' - 'ocurrido_en') THEN
    RAISE EXCEPTION
      'El coordinador solo puede asignar y ordenar la orden %, no modificarla',
      OLD.correlativo
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;

-- ⚠️ ESTA BARRERA DEPENDE DEL ORDEN DE LOS TRIGGERS (nota agregada 2026-08-10).
-- Postgres dispara los BEFORE UPDATE en orden ALFABÉTICO por nombre. En
-- `tickets` conviven 7, y los que corren DESPUÉS de éste
-- (`trg_tickets_correlativo`, `trg_tickets_eventos_auto`,
-- `trg_tickets_marcar_verificacion`, `trg_tickets_validar_transicion`) verían un
-- NEW ya corregido y podrían re-aplicar lo que esta barrera revirtió.
-- Un trigger nuevo con un nombre alfabéticamente anterior la desarma EN
-- SILENCIO: sin error, y ningún test lo caza (es comportamiento de runtime de
-- Postgres). Antes de agregar uno, ver la advertencia de ARQUITECTURA §R10 y
-- verificar el orden real con:
--   select tgname from pg_trigger
--    where tgrelid='public.tickets'::regclass and not tgisinternal
--    order by tgname;
DROP TRIGGER IF EXISTS trg_tickets_coordinador_solo_orden ON public.tickets;
CREATE TRIGGER trg_tickets_coordinador_solo_orden
  BEFORE UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_coordinador_solo_orden();

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 5 filas deben dar ok = true.
-- =========================================================================
SELECT 'el CHECK de rol admite coordinador' AS chequeo,
       pg_get_constraintdef(oid) LIKE '%coordinador%' AS ok
  FROM pg_constraint
 WHERE conrelid='public.cobradores'::regclass AND conname='cobradores_rol_check'
UNION ALL
SELECT 'is_coordinador existe', COUNT(*) = 1
  FROM pg_proc WHERE proname='is_coordinador'
UNION ALL
SELECT 'handle_new_user acepta coordinador',
       pg_get_functiondef(oid) LIKE '%coordinador%'
  FROM pg_proc WHERE proname='handle_new_user'
UNION ALL
SELECT 'handle_new_user NO perdio ningun rol viejo',
       pg_get_functiondef(oid) LIKE '%admin_usuarios%'
   AND pg_get_functiondef(oid) LIKE '%lectura%'
   AND pg_get_functiondef(oid) LIKE '%admin_tickets%'
  FROM pg_proc WHERE proname='handle_new_user'
UNION ALL
SELECT 'el trigger de columnas esta activo', COUNT(*) = 1
  FROM pg_trigger WHERE tgname='trg_tickets_coordinador_solo_orden';
