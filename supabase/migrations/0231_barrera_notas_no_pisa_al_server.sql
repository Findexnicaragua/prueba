-- 0231 — HOTFIX de 0230: la barrera de notas estaba revirtiendo al PROPIO SERVER
--
-- ── EL BUG ──────────────────────────────────────────────────────────────────
-- `SECURITY DEFINER` cambia el usuario de POSTGRES, no el JWT de la sesión.
-- `auth.uid()` lee `request.jwt.claims`, que es un GUC de SESIÓN: sigue siendo
-- el del usuario logueado aunque estemos adentro de una función del server.
--
-- Consecuencia: cuando un COBRADOR registra un pago, el trigger `cuotas_vmv`
-- dispara `recalc_vencimiento_mas_viejo()` (SECURITY DEFINER, owner postgres),
-- que hace `UPDATE clientes SET vencimiento_mas_viejo = ...`. Para la barrera de
-- 0230 ese UPDATE era indistinguible de uno del cobrador: `auth.uid()` no era
-- NULL y `current_user_rol()` decía 'cobrador' → no entraba por ningún escape →
-- `new := old` lo descartaba en silencio.
--
-- El cliente pagaba y quedaba marcado como vencido: pin rojo en el mapa (que
-- deriva el color de esa columna sin cruzar cuotas), y seguía en la cola de
-- corte — con riesgo de cortarle el servicio a alguien al día. Además rompía
-- INV20 de `invariantes_dinero.sql`.
--
-- El mismo mecanismo rompía la cascada de `propagate_cobrador_id_from_cliente()`:
-- un `admin_usuarios` reasignaba el cobrador de un cliente, la propagación a
-- `clientes` y `cuotas` entraba y la de `contratos` se revertía → el contrato
-- quedaba con el cobrador VIEJO. Escritura parcial, sin un solo error.
--
-- ── EL FIX ──────────────────────────────────────────────────────────────────
-- Un escape que distingue "lo escribió el server" de "lo escribió el usuario",
-- sin enumerar funciones ni columnas:
--
--     current_user IS DISTINCT FROM 'authenticated'
--
-- Un UPDATE que viene derecho de la app corre como el rol `authenticated`.
-- Adentro de una función `SECURITY DEFINER` de owner postgres, `current_user`
-- pasa a ser postgres; los crons y el `service_role` tampoco son
-- `authenticated`. O sea: la barrera se aplica SOLO cuando escribe la app, y
-- cualquier función del server que se agregue mañana queda cubierta sola — que
-- es justo lo que fallaba: 0230 razonaba sobre QUIÉN es el usuario, cuando la
-- pregunta correcta era QUIÉN está escribiendo.
--
-- OJO — NO sirve `current_user <> session_user`, que fue el primer intento y
-- desactivaba la barrera ENTERA: bajo Supabase la conexión entra como
-- `authenticator` y hace `SET ROLE authenticated`, así que los dos difieren en
-- TODA petición normal. Lo cazó la prueba de regresión de acá abajo, no el
-- razonamiento.
--
-- Para que eso funcione las dos funciones pasan a `SECURITY INVOKER`: siendo
-- DEFINER, `current_user` era SIEMPRE el owner y la comparación no distinguía
-- nada. No pierden capacidad: solo leen OLD/NEW y llaman helpers que siguen
-- siendo DEFINER.
--
-- Se conservan los tres escapes de 0230 (server sin JWT, roles con escritura
-- completa, y el cambio de fecha del cobrador).

-- ── CLIENTES ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.clientes_solo_notas_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_notas    text        := new.notas;
  v_ocurrido timestamptz := new.ocurrido_en;
  v_updated  timestamptz := new.updated_at;
BEGIN
  -- Escape 1: server sin sesión de usuario (crons, service_role).
  IF auth.uid() IS NULL THEN
    RETURN new;
  END IF;
  -- Escape 1b (0231): lo está escribiendo una función SECURITY DEFINER del
  -- server DENTRO de la sesión del usuario — p.ej. recalc_vencimiento_mas_viejo
  -- al cobrar, o propagate_cobrador_id_from_cliente al reasignar. Sin esto la
  -- barrera le revertía al server sus propias columnas derivadas.
  IF current_user IS DISTINCT FROM 'authenticated' THEN
    RETURN new;
  END IF;
  -- Escape 2: los roles que ya tenían escritura completa sobre `clientes`.
  IF public.is_super_admin()
     OR public.is_admin_or_cobranza()
     OR public.current_user_rol() = 'admin_usuarios' THEN
    RETURN new;
  END IF;
  -- El resto: SOLO la nota (más las marcas de tiempo).
  new := old;
  new.notas       := v_notas;
  new.ocurrido_en := v_ocurrido;
  new.updated_at  := v_updated;
  RETURN new;
END;
$function$;

-- ── CONTRATOS ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.contratos_solo_notas_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_notas    text        := new.notas;
  v_ocurrido timestamptz := new.ocurrido_en;
  v_dia_pago integer     := new.dia_pago;
  v_fecha_fin date       := new.fecha_fin;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN new;
  END IF;
  -- Escape 1b (0231) — ver el comentario en clientes_solo_notas_trg.
  IF current_user IS DISTINCT FROM 'authenticated' THEN
    RETURN new;
  END IF;
  IF public.is_super_admin() OR public.is_admin_or_cobranza() THEN
    RETURN new;
  END IF;
  new := old;
  new.notas       := v_notas;
  new.ocurrido_en := v_ocurrido;
  -- Escape 3: cambio de fecha de pago del cobrador (policy
  -- `contratos_cambiar_fecha`). Sus límites los sigue aplicando
  -- `contratos_check_cobrador_update`, que corre después.
  IF public.current_user_rol() = 'cobrador'
     AND old.cobrador_id = auth.uid()
     AND public.puede_cambiar_fecha_pago() THEN
    new.dia_pago  := v_dia_pago;
    new.fecha_fin := v_fecha_fin;
  END IF;
  RETURN new;
END;
$function$;
