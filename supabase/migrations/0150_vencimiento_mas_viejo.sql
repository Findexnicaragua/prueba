-- 0150: precalcular `vencimiento_mas_viejo` por cliente (Opción 2 — mapa rápido)
--
-- QUÉ: la FECHA de vencimiento de la cuota pendiente/parcial MÁS VIEJA de cada
-- cliente, contando solo contratos activos (+ cuotas manuales sin contrato).
-- Es la MISMA condición que el LEFT JOIN cuotas del mapa.
--
-- POR QUÉ: el mapa calculaba el estado de cada pin cruzando TODAS las cuotas de
-- 4.442 clientes + GROUP BY (lento, ~16s en "Ver todo", peor en teléfonos). Con
-- esta columna el cliente lee 1 fecha por pin y deriva el estado al vuelo.
--
-- CLAVE: guardamos una FECHA (dato), NO un estado ni un color.
--  * El ESTADO (mora/gracia/hoy/próxima/fuera de rango/sin deuda) lo deriva el
--    CLIENTE de esta fecha + diasGracia/diasVisibles (mismo `_estadoDe`).
--  * El COLOR sigue saliendo del setting configurable `coloresEstados` al
--    renderizar — acá NO se hardcodea nada de color.
--  * Como es una fecha (date-independent), NO hace falta cron diario: el color
--    se computa contra "hoy" en cada apertura → siempre al día, aun offline.
--
-- El dominante = la cuota más vieja (precedencia mora>gracia>hoy>próxima por
-- antigüedad de vencimiento) → con MIN(vencimiento) alcanza para el color.

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS vencimiento_mas_viejo date;

-- Recalcula la columna para UN cliente. SECURITY DEFINER: el trigger debe poder
-- escribir `clientes` aunque el usuario que dispara el cambio (p.ej. un cobrador
-- registrando un pago) no tenga UPDATE directo sobre `clientes` por RLS. El
-- cliente_id viene siempre de la cuota/contrato del propio tenant → sin fuga
-- cross-tenant. search_path fijo por seguridad (SECURITY DEFINER).
CREATE OR REPLACE FUNCTION public.recalc_vencimiento_mas_viejo(p_cliente_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.clientes c
     SET vencimiento_mas_viejo = (
       SELECT MIN(cu.fecha_vencimiento)
         FROM public.cuotas cu
         LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
        WHERE cu.cliente_id = p_cliente_id
          AND cu.estado IN ('pendiente', 'parcial')
          AND COALESCE(ct.estado, 'activo') = 'activo'
     )
   WHERE c.id = p_cliente_id;
$$;

-- Trigger en cuotas: cualquier cambio que afecte el set pendiente/vencimiento
-- recalcula el cliente (y el viejo si el cliente_id cambió o en DELETE).
CREATE OR REPLACE FUNCTION public.trg_cuotas_vmv()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.recalc_vencimiento_mas_viejo(OLD.cliente_id);
    RETURN OLD;
  END IF;
  PERFORM public.recalc_vencimiento_mas_viejo(NEW.cliente_id);
  IF TG_OP = 'UPDATE' AND NEW.cliente_id IS DISTINCT FROM OLD.cliente_id THEN
    PERFORM public.recalc_vencimiento_mas_viejo(OLD.cliente_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS cuotas_vmv ON public.cuotas;
CREATE TRIGGER cuotas_vmv
  AFTER INSERT OR DELETE OR
        UPDATE OF estado, fecha_vencimiento, contrato_id, cliente_id
  ON public.cuotas
  FOR EACH ROW EXECUTE FUNCTION public.trg_cuotas_vmv();

-- Trigger en contratos: suspender/reactivar/cancelar cambia qué cuotas cuentan
-- → recalcula el cliente.
CREATE OR REPLACE FUNCTION public.trg_contratos_vmv()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM public.recalc_vencimiento_mas_viejo(NEW.cliente_id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS contratos_vmv ON public.contratos;
CREATE TRIGGER contratos_vmv
  AFTER UPDATE OF estado ON public.contratos
  FOR EACH ROW
  WHEN (NEW.estado IS DISTINCT FROM OLD.estado)
  EXECUTE FUNCTION public.trg_contratos_vmv();

-- Backfill de todos los clientes existentes (UPDATE directo, no dispara el
-- trigger de cuotas).
UPDATE public.clientes c
   SET vencimiento_mas_viejo = (
     SELECT MIN(cu.fecha_vencimiento)
       FROM public.cuotas cu
       LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
      WHERE cu.cliente_id = c.id
        AND cu.estado IN ('pendiente', 'parcial')
        AND COALESCE(ct.estado, 'activo') = 'activo'
   );
