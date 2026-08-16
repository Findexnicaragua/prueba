-- 0050: Eliminar overload viejo de audit_registrar (6 params).
-- La migración 0047 creó una versión con 7 params (incluyendo p_accion).
-- La versión vieja de 0020 (6 params) seguía existiendo como overload,
-- causando error "function is not unique" cuando el trigger de settings
-- la llamaba con 6 args ambiguos.

DROP FUNCTION IF EXISTS public.audit_registrar(uuid, text, uuid, text, jsonb, jsonb);
