-- 0201 — El PIN del dashboard deja de viajar al equipo de los demás
--
-- 0197 puso `dashboard_pin` en `cobradores` y las sync rules lo bajan
-- tenant-wide: cada admin tenía en su SQLite local el PIN EN CLARO de todos
-- sus pares. El "PIN por usuario" no aislaba a un admin de otro.
--
-- Cambio (decisión de Rubén 2026-07-26): nadie ve el PIN ajeno, ni para
-- ayudar. Si alguien lo olvida, otro admin FUERZA el cambio (se lo borra sin
-- verlo) y la persona configura uno nuevo al entrar al Resumen.
--
--   · `dashboard_pin_configurado` — columna GENERADA (booleana). Es lo que
--     viaja tenant-wide: alcanza para que Personal muestre "tiene PIN / sin
--     PIN" sin exponer el valor. Al ser generada no se puede desincronizar.
--   · `dashboard_pin` sale de los buckets tenant-wide (ver sync-rules.yaml);
--     solo llega por el bucket self-scoped de cada usuario.
--   · `forzar_reset_dashboard_pin(uuid)` — un admin borra el PIN de otro sin
--     leerlo. No devuelve el valor viejo.
--
-- Idempotente.

BEGIN;

-- 1. Columna generada: "¿tiene PIN?" sin decir cuál.
ALTER TABLE public.cobradores
  ADD COLUMN IF NOT EXISTS dashboard_pin_configurado boolean
  GENERATED ALWAYS AS (dashboard_pin IS NOT NULL AND dashboard_pin <> '') STORED;

-- 2. Reset forzado: borra el PIN de otro miembro SIN devolverlo.
--
-- Guard de rol: solo admin o super_admin, y dentro del propio tenant (el
-- super_admin bypassa el chequeo de tenant, igual que el resto de sus RPCs).
-- No se puede usar sobre un super_admin.
CREATE OR REPLACE FUNCTION public.forzar_reset_dashboard_pin(p_cobrador_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_mi_rol    text;
  v_mi_tenant uuid;
  v_su_rol    text;
  v_su_tenant uuid;
BEGIN
  SELECT rol, tenant_id INTO v_mi_rol, v_mi_tenant
    FROM public.cobradores WHERE id = auth.uid();
  IF v_mi_rol IS NULL THEN
    RAISE EXCEPTION 'No autorizado' USING errcode = '42501';
  END IF;
  IF v_mi_rol NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar el cambio de PIN'
      USING errcode = '42501';
  END IF;

  SELECT rol, tenant_id INTO v_su_rol, v_su_tenant
    FROM public.cobradores WHERE id = p_cobrador_id;
  IF v_su_rol IS NULL THEN
    RAISE EXCEPTION 'Ese usuario no existe' USING errcode = 'P0002';
  END IF;
  IF v_su_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede forzar el PIN de un super_admin';
  END IF;
  IF v_mi_rol <> 'super_admin' AND v_su_tenant <> v_mi_tenant THEN
    RAISE EXCEPTION 'Ese usuario es de otra empresa' USING errcode = '42501';
  END IF;

  UPDATE public.cobradores SET dashboard_pin = '' WHERE id = p_cobrador_id;
END;
$$;

REVOKE ALL ON FUNCTION public.forzar_reset_dashboard_pin(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.forzar_reset_dashboard_pin(uuid) TO authenticated;

-- 3. La columna nueva se lee tenant-wide; el PIN NO.
-- (El REVOKE de 0199 dejó a `authenticated` con grants por columna: hay que
-- sumar la nueva o los clientes no la ven.)
GRANT SELECT (dashboard_pin_configurado) ON public.cobradores TO authenticated;

COMMIT;
