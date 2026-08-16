-- 0058: Trigger que bloquea remover cobrador_id de cliente con
-- contratos activos. Previene huérfanos operativos.
--
-- Reglas:
--   - Cliente PUEDE existir sin cobrador (captura de prospectos).
--   - Cliente con contratos activos NO PUEDE quedar sin cobrador.
--   - Cambiar cobrador (A → B) está permitido (cascada via trigger 0017).
--   - Sólo se bloquea cambiar a NULL si hay contratos activos.

CREATE OR REPLACE FUNCTION public.clientes_check_cobrador_no_null_con_contratos_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.cobrador_id IS NOT NULL
     AND NEW.cobrador_id IS NULL
     AND EXISTS (
       SELECT 1 FROM public.contratos
       WHERE cliente_id = NEW.id AND estado = 'activo'
     )
  THEN
    RAISE EXCEPTION 'No se puede desasignar el cobrador: el cliente tiene contratos activos. Reasigne primero a otro cobrador.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clientes_check_cobrador_no_null
  ON public.clientes;

CREATE TRIGGER trg_clientes_check_cobrador_no_null
  BEFORE UPDATE OF cobrador_id ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.clientes_check_cobrador_no_null_con_contratos_trg();
