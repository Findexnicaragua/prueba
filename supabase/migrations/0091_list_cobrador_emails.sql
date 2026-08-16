-- Migración 0091: RPC para listar el email de los cobradores del tenant.
--
-- El email vive en `auth.users`, no en `cobradores`, y auth.users no es
-- accesible vía RLS normal. Esta RPC SECURITY DEFINER devuelve
-- (cobrador_id, email) para los miembros del tenant del caller, para que
-- la pantalla de Personal muestre el email junto a cada usuario.
--
-- Mismo patrón que check_email_exists_in_auth (0036) y list_error_logs:
-- SECURITY DEFINER + SET search_path = '' (CWE-426). El scope NO se delega
-- a RLS (auth.users no la tiene): se filtra explícitamente por el tenant
-- del caller vía current_tenant_id(), que ya respeta la impersonación del
-- super_admin (0039).
--
-- Guard de rol: sólo admin / admin_cobranza / super_admin pueden ver los
-- emails. Un cobrador raso NO (no gestiona usuarios). El super_admin ve los
-- del tenant que esté impersonando (current_tenant_id() lo resuelve); fuera
-- de impersonación ve los de su propio tenant System (vacío en la práctica).
--
-- Retorna: filas (cobrador_id uuid, email text). Vacío si el caller no
-- tiene permiso (no lanza excepción para que la UI degrade elegante).

CREATE OR REPLACE FUNCTION public.list_cobrador_emails()
RETURNS TABLE (cobrador_id uuid, email text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rol    text;
  v_tenant uuid;
BEGIN
  -- Rol del caller (de la tabla cobradores).
  SELECT c.rol INTO v_rol
  FROM public.cobradores c
  WHERE c.id = auth.uid();

  -- Sólo roles de gestión ven emails. Cobrador raso o caller desconocido
  -- → set vacío (sin error: la UI simplemente no muestra emails).
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'admin_cobranza', 'super_admin') THEN
    RETURN;
  END IF;

  -- Tenant scopeado (respeta impersonación del super_admin vía 0039).
  v_tenant := public.current_tenant_id();
  IF v_tenant IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT c.id, u.email::text
  FROM public.cobradores c
  JOIN auth.users u ON u.id = c.id
  WHERE c.tenant_id = v_tenant;
END;
$$;

REVOKE ALL ON FUNCTION public.list_cobrador_emails() FROM public;
GRANT EXECUTE ON FUNCTION public.list_cobrador_emails() TO authenticated;
