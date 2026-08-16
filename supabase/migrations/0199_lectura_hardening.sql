-- 0199 — Hardening del rol `lectura` (findings del audit de 0198)
--
-- 1. `password_texto` deja de ser legible por `authenticated`/`anon`.
--
--    ESCALADA DE PRIVILEGIOS REAL, y NO nace con 0198 — 0198 solo la amplió.
--    `cobradores.password_texto` guarda contraseñas EN CLARO (5 filas hoy, 2 de
--    ellas de rol admin). RLS es row-level: cualquier policy que deje ver la
--    FILA de otro miembro deja ver también esa columna. Ya pasaba con
--    `is_admin_or_cobranza()` (un admin_cobranza podía leer la contraseña de un
--    admin y loguearse como él); con `lectura_select` se sumaba el rol nuevo.
--
--    El REVOKE por columna lo corta para TODOS los roles de app de una vez, sin
--    tocar ninguna policy. Se preservan a propósito:
--      · service_role  → lo usan las Edge Functions (invitar-cobrador,
--                        forzar-password-cobrador, ver-password-cobrador), que
--                        validan el rol del caller server-side.
--      · powersync_selfhost → replica; las sync rules NUNCA seleccionan esta
--                        columna (lista explícita), así que no llega al device.
--    Ningún archivo de `lib/` lee `password_texto`.
--
-- 2. Cinco policies de ESCRITURA que no miran el rol.
--
--    Filtran por tenant y por `auth.uid()`, pero no por quién es el usuario, así
--    que un rol de solo lectura las satisface. NO las contiene la barrera del
--    connector: son alcanzables por REST directo, sin pasar por PowerSync.
--    La de `op_log` es la más grave — permite falsificar el historial, que es el
--    único registro de cambios desde que se eliminó `audit_log` (0140), e
--    incluso escribir filas con `actor_id IS NULL` (las del super_admin).

BEGIN;

-- ── 1. Contraseñas en claro ───────────────────────────────────────────────
-- OJO: un `REVOKE SELECT (columna)` NO alcanza si el rol tiene el SELECT a
-- nivel de TABLA — ese grant cubre todas las columnas y gana. Hay que quitar el
-- de tabla y volver a otorgar columna por columna.
--
-- La lista es TODA la tabla menos `password_texto`. Si se agrega una columna
-- nueva a `cobradores`, hay que sumarla acá o los clientes dejan de verla
-- (el grant de columna no cubre lo que no se nombra).
REVOKE SELECT ON public.cobradores FROM authenticated;
REVOKE SELECT ON public.cobradores FROM anon;
GRANT SELECT (id, tenant_id, nombre, telefono, rol, activo, created_at,
              prefijo_recibo, puede_cambiar_fecha, dashboard_pin)
  ON public.cobradores TO authenticated;

-- Backlog (NO se toca acá a propósito): `authenticated` conserva INSERT/UPDATE
-- sobre `password_texto`. No expone credenciales — a lo sumo permite pisar el
-- campo espejo de alguien cuya fila RLS ya deje actualizar (el password real
-- vive en auth.users y no se toca). Revocar el UPDATE por columna obliga a
-- rehacer el GRANT de escritura de TODA la tabla, y equivocarse en una columna
-- rompe la edición de personal; no vale el riesgo por un vector de envenenado.

-- ── 2. Escrituras sin chequeo de rol ──────────────────────────────────────
-- Se reconstruyen con la MISMA condición vigente + `AND NOT is_lectura()`.

DROP POLICY IF EXISTS visitas_insert ON public.visitas;
CREATE POLICY visitas_insert ON public.visitas FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND cobrador_id = auth.uid()
              AND NOT public.is_lectura());

DROP POLICY IF EXISTS op_log_insert ON public.op_log;
CREATE POLICY op_log_insert ON public.op_log FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND (actor_id = auth.uid() OR actor_id IS NULL)
              AND NOT public.is_lectura());

DROP POLICY IF EXISTS op_log_update ON public.op_log;
CREATE POLICY op_log_update ON public.op_log FOR UPDATE
  USING (tenant_id = public.current_tenant_id()
         AND (actor_id = auth.uid() OR actor_id IS NULL)
         AND NOT public.is_lectura())
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND (actor_id = auth.uid() OR actor_id IS NULL)
              AND NOT public.is_lectura());

DROP POLICY IF EXISTS solicitudes_insert ON public.solicitudes_accion;
CREATE POLICY solicitudes_insert ON public.solicitudes_accion FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id()
              AND solicitante_id = auth.uid()
              AND NOT public.is_lectura());

DO $do$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['departamentos','municipios','comunidades'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS geo_insert ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY geo_insert ON public.%I FOR INSERT '
      'WITH CHECK (tenant_id = public.current_tenant_id() '
      'AND NOT public.is_lectura())', t);
  END LOOP;
END
$do$;

COMMIT;
