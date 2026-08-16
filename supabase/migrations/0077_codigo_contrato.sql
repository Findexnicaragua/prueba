-- 0077_codigo_contrato.sql
--
-- Feature: "código de contrato" — identificador simbólico legible por contrato,
-- MISMA DINÁMICA que el código de cliente (0071): manual, único por tenant
-- (case-insensitive), inmutable una vez asignado (solo super_admin corrige un
-- typo, queda en audit_log vía el trigger de changelog).
--
-- A diferencia del de cliente, es OPCIONAL a nivel app (un ISP puede no querer
-- codificar contratos). Nullable a nivel DB para tolerar contratos legacy +
-- offline. `contratos` usa SELECT * en las sync rules → REDEPLOYAR sync rules
-- para que la columna baje a los clientes.

BEGIN;

-- 1. Columna.
ALTER TABLE public.contratos ADD COLUMN IF NOT EXISTS codigo text;

-- 2. Unicidad por tenant, case-insensitive, ignorando NULLs (contratos legacy
--    sin código + offline). El upper() hace que CT27 y ct27 colisionen.
CREATE UNIQUE INDEX IF NOT EXISTS contratos_codigo_tenant_uq
  ON public.contratos (tenant_id, upper(codigo))
  WHERE codigo IS NOT NULL;

-- 3. Inmutabilidad: una vez asignado (no-NULL), solo el super_admin puede
--    cambiarlo. La asignación inicial (NULL → valor) siempre se permite.
--    Mismo patrón que clientes_codigo_inmutable_trg (0071).
CREATE OR REPLACE FUNCTION public.contratos_codigo_inmutable_trg()
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
      'El código del contrato es inmutable una vez asignado (actual: %).', OLD.codigo
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contratos_codigo_inmutable ON public.contratos;
CREATE TRIGGER trg_contratos_codigo_inmutable
  BEFORE UPDATE ON public.contratos
  FOR EACH ROW
  EXECUTE FUNCTION public.contratos_codigo_inmutable_trg();

COMMIT;
