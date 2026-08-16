-- 0123: Cancelar contrato con la MISMA dinámica de dinero que suspender, pero
-- PERMANENTE (sin reactivación). El cancelar viejo anulaba TODA la deuda y
-- liquidaba parciales a 0; ahora deja viva/cobrable la deuda real (meses
-- cumplidos + mora previa), prorratea el mes en curso por ventana de servicio
-- del día_pago y anula solo los meses futuros (igual que suspender). La lógica
-- vive en ContratosRepo.cancelarContrato (espeja suspenderContrato).
--
-- Esta migración solo agrega a `contratos` las columnas para registrar la
-- cancelación + el snapshot de deuda (para reimprimir el documento, como hace
-- contrato_suspensiones). NO nueva tabla: `contratos` ya tiene RLS y ya
-- sincroniza (los buckets usan SELECT * → las columnas bajan solas). El estado
-- 'cancelado' ya está permitido por el CHECK de contratos.

ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS cancelado_en timestamptz,
  ADD COLUMN IF NOT EXISTS cancelado_por uuid REFERENCES public.cobradores(id),
  ADD COLUMN IF NOT EXISTS motivo_cancelacion text,
  ADD COLUMN IF NOT EXISTS cancelacion_deuda_snapshot jsonb;
