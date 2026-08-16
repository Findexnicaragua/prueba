-- =========================================================================
-- 0172 — Integración órdenes de trabajo (tickets) ↔ cobranza/servicio (FASE 1)
-- =========================================================================
-- Solo METADATOS para trazabilidad y para derivar las colas. CERO trigger de
-- plata, cero acoplamiento con pagos/cuotas. El cobro y el estado de servicio
-- siguen donde están hoy (cobro→recibo; suspenderContrato/reactivarContrato).
-- El admin encadena las acciones de facturación a mano, asistido por las colas
-- que derivan de estos dos campos.
--   corte→suspensión y pago→reconexión→reactivación quedan MANUALES (con badge).
-- Diseño: factibilidad 2026-06-29 (recomendación "link liviano" + taxonomía de
-- dos puertas). El automatismo por trigger SECURITY DEFINER es Fase 2 (diferido).
--
-- ADITIVO PURO (columnas nullable / con default + índice) → NO se bumpea
-- _dbWipeVersion: PowerSync lo aplica in-place sin re-descargar (política R4).
-- =========================================================================

-- (1) Vínculo de la orden de trabajo a un CONTRATO específico. Hoy `tickets`
--     solo conoce el cliente (0103:130), pero un cliente puede tener varios
--     contratos → sin esto no se sabe QUÉ servicio cortar/reconectar. NULL =
--     instalación pre-contrato / outage / trabajo sin contrato. ON DELETE SET
--     NULL: borrar el contrato no borra la orden de trabajo.
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS contrato_id uuid
    REFERENCES public.contratos(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS tickets_by_contrato
  ON public.tickets (tenant_id, contrato_id);

-- (2) Semántica de SISTEMA sobre el catálogo free-form de tipos (0103:109): qué
--     EFECTO de servicio tiene una orden de ese tipo. Es lo único que permite
--     derivar las colas. 'ninguno' = reparación / reclamo / cualquier trabajo
--     sin efecto en facturación (DEFAULT seguro → los tipos existentes quedan
--     neutros y el admin re-clasifica los que correspondan).
ALTER TABLE public.ticket_tipos
  ADD COLUMN IF NOT EXISTS efecto text NOT NULL DEFAULT 'ninguno'
    CHECK (efecto IN ('ninguno','instalacion','corte','reconexion'));
