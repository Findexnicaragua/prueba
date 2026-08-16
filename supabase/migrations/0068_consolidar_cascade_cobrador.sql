-- 0068: Consolidar la cascada de reasignación de cobrador (fix M6-DB).
--
-- Había dos triggers independientes sobre clientes AFTER UPDATE OF cobrador_id:
--   - trg_propagate_cobrador_id_clientes (0002/0034) → contratos, cuotas,
--     notificaciones_mora, cargos_extra
--   - trg_clientes_cascade_cobrador_fotos (0055) → fotos_cliente
-- Funcionaban, pero fragmentados: agregar una tabla dependiente nueva exige
-- recordar tocar el lugar correcto. Riesgo de desincronización a futuro.
--
-- Fix: una sola función propagate_cobrador_id_from_cliente que cubre TODAS
-- las tablas dependientes (incluida fotos_cliente). Un solo trigger.

CREATE OR REPLACE FUNCTION public.propagate_cobrador_id_from_cliente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.cobrador_id IS DISTINCT FROM OLD.cobrador_id THEN
    UPDATE public.contratos
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- Solo cuotas operativas. Las pagadas/anuladas preservan el cobrador_id
    -- del momento del pago (historial inmutable).
    UPDATE public.cuotas
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id
       AND estado IN ('pendiente','parcial');

    UPDATE public.notificaciones_mora
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id
       AND resuelta_en IS NULL;

    UPDATE public.cargos_extra
       SET cobrador_id = NEW.cobrador_id
     WHERE cuota_id IN (
       SELECT id FROM public.cuotas
        WHERE cliente_id = NEW.id
          AND estado IN ('pendiente','parcial')
     );

    -- fotos_cliente: consolidado acá (antes trigger separado 0055).
    UPDATE public.fotos_cliente
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- pagos / recibos NO se propagan: snapshot histórico inmutable.
  END IF;
  RETURN NEW;
END;
$$;

-- Eliminar el trigger separado de fotos (su lógica ya vive en la función
-- consolidada). El trigger principal trg_propagate_cobrador_id_clientes
-- sigue apuntando a la misma función actualizada — no hace falta recrearlo.
DROP TRIGGER IF EXISTS trg_clientes_cascade_cobrador_fotos ON public.clientes;

-- La función clientes_cascade_cobrador_fotos_trg queda huérfana (sin trigger
-- que la use). La dejamos por compatibilidad de rollback; no se ejecuta.
