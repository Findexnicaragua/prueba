-- 0071_codigo_cliente.sql
--
-- Feature: "código de cliente" — identificador simbólico legible que cada
-- ISP asigna a sus clientes (ej. CL00027). NO reemplaza el UUID (que sigue
-- siendo PK y FK interno de TODO); es la identidad VISUAL del cliente en
-- toda la app y en los módulos futuros (inventario, técnicos, etc.).
--
-- Reglas (decididas con el usuario):
--   - Manual, alfanumérico, obligatorio a nivel app al crear.
--   - Único por tenant, case-insensitive (CL27 == cl27 == Cl27).
--   - Inmutable una vez asignado; SOLO el super_admin puede corregir un typo
--     (queda registrado en audit_log vía el trigger genérico de changelog).
--
-- La columna es nullable a nivel DB para tolerar offline y clientes legacy;
-- la obligatoriedad se valida en el form. `clientes` usa SELECT * en las
-- sync rules → REDEPLOYAR sync rules para que la columna baje a los clientes.

BEGIN;

-- 1. Columna.
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS codigo text;

-- 2. Unicidad por tenant, case-insensitive, ignorando NULLs (clientes legacy
--    sin código aún + offline). El upper() hace que CL27 y cl27 colisionen.
CREATE UNIQUE INDEX IF NOT EXISTS clientes_codigo_tenant_uq
  ON public.clientes (tenant_id, upper(codigo))
  WHERE codigo IS NOT NULL;

-- 3. Inmutabilidad: una vez asignado (no-NULL), solo el super_admin puede
--    cambiarlo. admin/cobrador reciben excepción. La asignación inicial
--    (NULL → valor) siempre se permite. Mismo patrón que cobradores_freeze_rol.
CREATE OR REPLACE FUNCTION public.clientes_codigo_inmutable_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.codigo IS NOT NULL
     AND NEW.codigo IS DISTINCT FROM OLD.codigo
     AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION
      'El código del cliente es inmutable una vez asignado (actual: %).', OLD.codigo
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clientes_codigo_inmutable ON public.clientes;
CREATE TRIGGER trg_clientes_codigo_inmutable
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.clientes_codigo_inmutable_trg();

COMMIT;
