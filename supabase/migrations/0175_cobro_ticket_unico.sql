-- 0175 — un ticket = un solo cobro vivo (red dura server-side, audit Fase 2)
--
-- BUG (audit 2026-07-05): el anti-doble-cobro del cobro-desde-ticket (0173)
-- era 100% reactivo en la UI (un stream que oculta "Generar cobro" si ya hay
-- una cuota ligada). Sin garantía dura, dos admins / dos devices / un doble-tap
-- podían generar DOS cuotas manuales no-anuladas del MISMO ticket antes de
-- sincronizar → doble cobro de la misma instalación (viola el modelo de dinero).
-- El índice `cuotas_by_ticket` de 0173 era PARCIAL SIMPLE (no UNIQUE).
--
-- Fix: índice UNIQUE parcial. El 2º INSERT (de otro device) es rechazado al
-- reconciliar (23505) y el connector lo descarta → la cuota fantasma se revierte
-- en el próximo sync. Complementa el re-check client-side dentro de la
-- writeTransaction de crearCuotaManual (para el mismo device offline).
--
-- Sólo cuenta las VIVAS: una cuota anulada libera el ticket para re-cobrar
-- (mismo criterio que el stream de la UI: estado <> 'anulada'). Verificado en
-- prod que no hay duplicados vivos antes de crearlo.

CREATE UNIQUE INDEX IF NOT EXISTS cuotas_unico_cobro_ticket
  ON public.cuotas (ticket_id)
  WHERE ticket_id IS NOT NULL AND estado <> 'anulada';
