-- Migración 0036: RPC para verificar si un email existe en auth.users.
--
-- Reemplaza el patrón `listUsers({ perPage: 1000 })` en la Edge Function
-- `cambiar-email-cobrador`. El listUsers tiene un tope de 1000 users —
-- con más de 1000, la verificación da falsos negativos y se crean emails
-- duplicados. Este RPC consulta auth.users directamente sin límite.
--
-- SECURITY DEFINER porque auth.users no es accesible via RLS normal.
-- SET search_path = '' para evitar inyección de schema en funciones
-- SECURITY DEFINER (best practice CWE-426).
--
-- Parámetros:
--   p_email: email a verificar (case-insensitive).
--   p_exclude_user_id: excluir un user específico (para el caso de
--     cambiar-email donde el target ya tiene un email distinto).
--
-- Retorna: true si el email está tomado por OTRO user, false si no.

CREATE OR REPLACE FUNCTION check_email_exists_in_auth(
  p_email text,
  p_exclude_user_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS(
    SELECT 1 FROM auth.users
    WHERE lower(email) = lower(p_email)
      AND (p_exclude_user_id IS NULL OR id != p_exclude_user_id)
  );
$$;
