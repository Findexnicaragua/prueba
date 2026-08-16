-- 0230 — La nota del cliente y la del contrato las edita CUALQUIER rol menos `lectura`
--
-- Decisión de Rubén (2026-08-10). La nota es contexto operativo — "atiende la
-- hija después de las 3", "el poste está del otro lado, 40 m de cable extra" —
-- y quien lo descubre es el que va a la casa, no la oficina. Si el que lo sabe
-- no la puede escribir, la nota se degrada.
--
-- ── EL PROBLEMA ─────────────────────────────────────────────────────────────
-- La RLS de este proyecto es ROW-level: una policy de UPDATE habilita la FILA
-- ENTERA, no una columna. Y un GRANT por columna no sirve para distinguir roles:
-- los roles de la app (`cobradores.rol`) son un DATO de tabla, no roles de
-- Postgres — TODOS los usuarios son el mismo grantee `authenticated`.
-- Dicho de otro modo: dejar que el cobrador escriba `notas` con una policy
-- suelta lo dejaría escribir `precio_mensual`, `plan_id` y `estado`.
--
-- ── LA SOLUCIÓN ─────────────────────────────────────────────────────────────
-- Policy permisiva + trigger BEFORE UPDATE que hace de barrera por columna.
-- El trigger NO enumera qué revertir: hace `new := old` (descarta TODO) y vuelve
-- a poner SOLO lo permitido. Así una columna que se agregue mañana nace
-- protegida, en vez de nacer con un agujero — que es exactamente cómo se
-- escapan estas cosas.
--
-- REVIERTE EN SILENCIO, NUNCA `raise exception`. Verificado en el connector
-- (`lib/powersync/connector.dart`): un P0001 marca la operación como no
-- retryable y DESCARTA EL CrudEntry COMPLETO. El form de clientes manda sus 16
-- columnas en una sola sentencia, así que abortarla por `notas` le haría perder
-- también el nombre, el teléfono y la dirección recién editados. Con la
-- reversión silenciosa el resto se persiste y el valor bueno vuelve por
-- checkpoint.
--
-- ── LOS TRES ESCAPES DEL TRIGGER (y por qué) ────────────────────────────────
-- 1. `auth.uid() is null` → pasa sin tocar nada. Son los crons y las Edge
--    Functions (service_role): sin esto el trigger revertiría la generación
--    mensual de cuotas, la suspensión automática y todo lo que corre del lado
--    del server. Es el escape más importante de los tres.
-- 2. Los roles que YA tenían escritura completa por sus policies pasan igual
--    (admin/admin_cobranza en las dos tablas; admin_usuarios además en
--    clientes; super_admin siempre). El trigger no les cambia nada.
-- 3. El cobrador conserva `dia_pago` y `fecha_fin` en contratos: es lo que ya le
--    permitía `contratos_cambiar_fecha`, y revertirlo rompería el cambio de
--    fecha de pago. `contratos_check_cobrador_update` (0016) sigue vigente y
--    corre DESPUÉS — los nombres de los triggers nuevos empiezan con `_a_` a
--    propósito, porque Postgres los dispara en orden alfabético y la barrera
--    tiene que reponer los valores viejos ANTES de que el otro se fije si algo
--    cambió (si no, el cobrador comería un "solo puede cambiar dia_pago").
--
-- `lectura` queda afuera por la policy, no por el trigger: no llega a escribir.

-- ── CLIENTES ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.clientes_solo_notas_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_notas    text        := new.notas;
  v_ocurrido timestamptz := new.ocurrido_en;
  v_updated  timestamptz := new.updated_at;
BEGIN
  -- Escape 1: server-side (crons, Edge Functions, service_role).
  IF auth.uid() IS NULL THEN
    RETURN new;
  END IF;
  -- Escape 2: los que ya tenían escritura completa sobre `clientes`.
  IF public.is_super_admin()
     OR public.is_admin_or_cobranza()
     OR public.current_user_rol() = 'admin_usuarios' THEN
    RETURN new;
  END IF;
  -- El resto: SOLO la nota (más las marcas de tiempo, para que el cambio se
  -- propague y quede fechado).
  new := old;
  new.notas       := v_notas;
  new.ocurrido_en := v_ocurrido;
  new.updated_at  := v_updated;
  RETURN new;
END;
$function$;

COMMENT ON FUNCTION public.clientes_solo_notas_trg() IS
  'Barrera por columna: los roles sin escritura completa sobre clientes solo '
  'pueden mover `notas`. Revierte en silencio (nunca raise: un P0001 haría que '
  'el connector descarte el UPDATE entero y se pierdan los demás campos).';

DROP TRIGGER IF EXISTS trg_clientes_a_solo_notas ON public.clientes;
CREATE TRIGGER trg_clientes_a_solo_notas
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_solo_notas_trg();

DROP POLICY IF EXISTS clientes_write_notas ON public.clientes;
CREATE POLICY clientes_write_notas ON public.clientes
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() IS DISTINCT FROM 'lectura')
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND public.current_user_rol() IS DISTINCT FROM 'lectura');

-- ── CONTRATOS ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.contratos_solo_notas_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_notas    text        := new.notas;
  v_ocurrido timestamptz := new.ocurrido_en;
  v_dia_pago integer     := new.dia_pago;
  v_fecha_fin date       := new.fecha_fin;
BEGIN
  -- Escape 1: server-side (crons de facturación, Edge Functions).
  IF auth.uid() IS NULL THEN
    RETURN new;
  END IF;
  -- Escape 2: los que ya tenían escritura completa sobre `contratos`.
  IF public.is_super_admin() OR public.is_admin_or_cobranza() THEN
    RETURN new;
  END IF;
  new := old;
  new.notas       := v_notas;
  new.ocurrido_en := v_ocurrido;
  -- Escape 3: el cambio de fecha de pago del cobrador (policy
  -- `contratos_cambiar_fecha`, gated por el setting). Se repone tal cual; los
  -- límites de ESE camino los sigue aplicando `contratos_check_cobrador_update`,
  -- que corre después.
  IF public.current_user_rol() = 'cobrador'
     AND old.cobrador_id = auth.uid()
     AND public.puede_cambiar_fecha_pago() THEN
    new.dia_pago  := v_dia_pago;
    new.fecha_fin := v_fecha_fin;
  END IF;
  RETURN new;
END;
$function$;

COMMENT ON FUNCTION public.contratos_solo_notas_trg() IS
  'Barrera por columna: los roles sin escritura completa sobre contratos solo '
  'pueden mover `notas` (y el cobrador con permiso, dia_pago/fecha_fin del '
  'cambio de fecha). Revierte en silencio, nunca raise.';

DROP TRIGGER IF EXISTS trg_contratos_a_solo_notas ON public.contratos;
CREATE TRIGGER trg_contratos_a_solo_notas
  BEFORE UPDATE ON public.contratos
  FOR EACH ROW EXECUTE FUNCTION public.contratos_solo_notas_trg();

DROP POLICY IF EXISTS contratos_write_notas ON public.contratos;
CREATE POLICY contratos_write_notas ON public.contratos
  FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND public.current_user_rol() IS DISTINCT FROM 'lectura')
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND public.current_user_rol() IS DISTINCT FROM 'lectura');
