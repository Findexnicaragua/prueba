-- Fix doble-encoding de la columna datos (jsonb) en solicitudes_accion.
-- PowerSync envía el valor como string JSON literal → Postgres lo guarda como
-- jsonb "string" en vez de jsonb "object". Este trigger desempaqueta
-- automáticamente antes de guardar.

CREATE OR REPLACE FUNCTION fix_solicitud_datos_jsonb()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(NEW.datos) = 'string' THEN
    NEW.datos := (NEW.datos #>> '{}')::jsonb;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fix_solicitud_datos ON solicitudes_accion;
CREATE TRIGGER trg_fix_solicitud_datos
  BEFORE INSERT OR UPDATE ON solicitudes_accion
  FOR EACH ROW EXECUTE FUNCTION fix_solicitud_datos_jsonb();
