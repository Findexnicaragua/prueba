-- 0202 — El PIN se muda a su propia tabla, visible SOLO para su dueño
--
-- Por qué una tabla y no dejarlo como columna de `cobradores`: para que un
-- admin no vea el PIN ajeno habría que sincronizar la MISMA fila con distintas
-- columnas según el bucket (tenant-wide sin el PIN, self con él). Cuando dos
-- buckets traen la misma fila, cuál gana no es determinista — y equivocarse
-- acá significa o filtrar el PIN o borrárselo al dueño. Con una tabla aparte
-- la regla es inequívoca: el bucket self trae SOLO tu fila, y nadie más la ve.
--
-- `cobradores.dashboard_pin_configurado` (0201, columna generada) sigue siendo
-- lo que viaja tenant-wide para que Personal muestre "tiene PIN / sin PIN".
-- `cobradores.dashboard_pin` queda como respaldo de la generada y deja de
-- sincronizarse a NINGÚN cliente (ver sync-rules.yaml).

BEGIN;

CREATE TABLE IF NOT EXISTS public.dashboard_pins (
  id          uuid PRIMARY KEY REFERENCES public.cobradores(id) ON DELETE CASCADE,
  tenant_id   uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  pin         text NOT NULL DEFAULT '',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- El PK es el propio cobrador_id: una fila por usuario, sin duplicados
-- posibles. `id` (y no `cobrador_id`) porque PowerSync exige que la PK se
-- llame así.
COMMENT ON TABLE public.dashboard_pins IS
  'PIN del Resumen, uno por usuario. Solo su dueño lo lee (RLS + bucket self).';

-- Backfill desde donde vivía hasta ahora.
INSERT INTO public.dashboard_pins (id, tenant_id, pin)
SELECT c.id, c.tenant_id, COALESCE(c.dashboard_pin, '')
  FROM public.cobradores c
 WHERE COALESCE(c.dashboard_pin, '') <> ''
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.dashboard_pins ENABLE ROW LEVEL SECURITY;

-- SOLO tu propia fila. No hay policy que deje ver la de otro: ni el admin del
-- tenant. Para ayudar a alguien que lo olvidó está `forzar_reset_dashboard_pin`
-- (0201), que lo BORRA sin leerlo.
DROP POLICY IF EXISTS dashboard_pins_self ON public.dashboard_pins;
CREATE POLICY dashboard_pins_self ON public.dashboard_pins
  FOR SELECT USING (id = auth.uid());

-- super_admin_all a mano, como toda tabla tenant-scoped (regla de AGENTS): sin
-- esto el super_admin impersonando no puede operar.
DROP POLICY IF EXISTS super_admin_all ON public.dashboard_pins;
CREATE POLICY super_admin_all ON public.dashboard_pins
  FOR ALL USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- Escritura: nadie escribe directo. Va por las RPC de abajo, que son las que
-- garantizan que solo toques el tuyo.

-- Guardar el PROPIO PIN (reemplaza el UPDATE sobre cobradores de 0198).
CREATE OR REPLACE FUNCTION public.set_mi_dashboard_pin(p_pin text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_tenant uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING errcode = '42501';
  END IF;
  -- '' = quitar el PIN. Cualquier otro valor, exactamente 4 dígitos.
  IF p_pin <> '' AND p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'El PIN debe tener 4 dígitos';
  END IF;

  SELECT tenant_id INTO v_tenant FROM public.cobradores WHERE id = auth.uid();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'No autorizado' USING errcode = '42501';
  END IF;

  INSERT INTO public.dashboard_pins (id, tenant_id, pin, updated_at)
       VALUES (auth.uid(), v_tenant, p_pin, now())
  ON CONFLICT (id) DO UPDATE SET pin = excluded.pin, updated_at = now();

  -- Espejo en `cobradores` para que `dashboard_pin_configurado` (generada, lo
  -- único que ven los demás) siga diciendo la verdad.
  UPDATE public.cobradores SET dashboard_pin = p_pin WHERE id = auth.uid();
END;
$$;

-- Reset forzado: además de `cobradores`, limpia la tabla nueva.
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

  UPDATE public.cobradores  SET dashboard_pin = '' WHERE id = p_cobrador_id;
  UPDATE public.dashboard_pins SET pin = '', updated_at = now()
   WHERE id = p_cobrador_id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_mi_dashboard_pin(text) FROM public;
GRANT EXECUTE ON FUNCTION public.set_mi_dashboard_pin(text) TO authenticated;
REVOKE ALL ON FUNCTION public.forzar_reset_dashboard_pin(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.forzar_reset_dashboard_pin(uuid) TO authenticated;

-- El PIN de `cobradores` deja de ser legible por la app: ya nadie lo lee de
-- ahí (el propio llega por `dashboard_pins`, el ajeno no llega). PowerSync
-- replica con su propio rol, así que el backfill y el espejo siguen andando.
REVOKE SELECT (dashboard_pin) ON public.cobradores FROM authenticated;

COMMIT;
