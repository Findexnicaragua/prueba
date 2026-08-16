-- 0185: clientes.vencimiento_mas_viejo — GUARDA anti escritura no-op
-- Diagnóstico 2026-07-10: churn de sincronización de PowerSync (Data Synced 24 GB).
-- Causa #2 medida (pg_stat): clientes con 62.201 UPDATES (10,7× la tabla entera).
--
-- POR QUÉ: `recalc_vencimiento_mas_viejo` (trigger `cuotas_vmv` en cada cambio de
-- cuota) hacía `UPDATE clientes SET vencimiento_mas_viejo = <nuevo>` SIEMPRE,
-- aunque el valor NO cambiara. Cada cuota FUTURA generada (generación mensual,
-- ~5,8k/mes + colchón) dispara el trigger pero NO mueve el "más viejo" (la nueva
-- vence en el futuro) → escritura no-op → una operación de PowerSync a CADA
-- dispositivo, para nada.
--
-- FIX: computar el valor nuevo y solo escribir si CAMBIÓ (`IS DISTINCT FROM`,
-- maneja NULL correctamente). El valor final y el color del mapa son IDÉNTICOS;
-- solo se evitan las escrituras inútiles. Se pasa de LANGUAGE sql a plpgsql para
-- poder computar el valor una sola vez y compararlo. Server-only.
CREATE OR REPLACE FUNCTION public.recalc_vencimiento_mas_viejo(p_cliente_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new date;
BEGIN
  SELECT MIN(cu.fecha_vencimiento)
    INTO v_new
    FROM public.cuotas cu
    LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
   WHERE cu.cliente_id = p_cliente_id
     AND cu.estado IN ('pendiente', 'parcial')
     AND COALESCE(ct.estado, 'activo') = 'activo';

  -- Guarda: solo escribe (y solo entonces genera operación de PowerSync) si el
  -- valor realmente cambió. Antes escribía siempre → miles de no-ops por la
  -- generación de cuotas futuras.
  UPDATE public.clientes c
     SET vencimiento_mas_viejo = v_new
   WHERE c.id = p_cliente_id
     AND c.vencimiento_mas_viejo IS DISTINCT FROM v_new;
END;
$$;
