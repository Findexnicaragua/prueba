-- Migración 0038: restringir acceso a check_email_exists_in_auth.
--
-- Security audit finding: la RPC era callable por cualquier user
-- autenticado → user enumeration (probar si un email existe).
-- Las Edge Functions ya usan service_role para llamarla, así que
-- revocar acceso a public/anon/authenticated no rompe nada.

REVOKE EXECUTE ON FUNCTION check_email_exists_in_auth FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION check_email_exists_in_auth TO service_role;
