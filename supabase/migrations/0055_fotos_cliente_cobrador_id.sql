-- 0055: Denormalizar cobrador_id en fotos_cliente para sync rules.
-- PowerSync exige que cada query use TODOS los parámetros del bucket.
-- El bucket por_cobrador tiene cobrador_id + tenant_id, así que
-- fotos_cliente necesita cobrador_id para sincronizar al cobrador.

-- 1. Agregar columna
ALTER TABLE public.fotos_cliente
  ADD COLUMN IF NOT EXISTS cobrador_id uuid REFERENCES public.cobradores(id);

-- 2. Poblar rows existentes (si hay alguna)
UPDATE public.fotos_cliente fc
SET cobrador_id = c.cobrador_id
FROM public.clientes c
WHERE fc.cliente_id = c.id;

-- 3. Trigger: al insertar foto, copiar cobrador_id del cliente
CREATE OR REPLACE FUNCTION public.fotos_cliente_set_cobrador_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.cobrador_id := (
    SELECT cobrador_id FROM public.clientes WHERE id = NEW.cliente_id
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_fotos_cliente_set_cobrador
  BEFORE INSERT ON public.fotos_cliente
  FOR EACH ROW EXECUTE FUNCTION public.fotos_cliente_set_cobrador_trg();

-- 4. Trigger cascada: al reasignar cliente, actualizar cobrador_id de sus fotos
CREATE OR REPLACE FUNCTION public.clientes_cascade_cobrador_fotos_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.cobrador_id IS DISTINCT FROM OLD.cobrador_id THEN
    UPDATE public.fotos_cliente
    SET cobrador_id = NEW.cobrador_id
    WHERE cliente_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_clientes_cascade_cobrador_fotos
  AFTER UPDATE OF cobrador_id ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_cascade_cobrador_fotos_trg();
