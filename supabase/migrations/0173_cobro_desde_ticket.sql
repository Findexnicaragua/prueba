-- 0173 — Cobro desde el ticket (instalación / reconexión / reinstalación / anexo).
--
-- Modelo (decisión Rubén 2026-06-30): el trabajo de campo nace en un TICKET, así
-- que su cobro+recibo se dispara DESDE el ticket (no desde el cliente). Las
-- multas/otros cargos del admin siguen por el botón del cliente ("Cobro puntual").
--
--   ticket_tipos.precio  → precio DEFAULT del cobro para tickets de ese tipo.
--                          0 = NO cobrable (sin botón). >0 = en el ticket RESUELTO
--                          aparece "Generar cobro" con este monto precargado
--                          (editable). Orthogonal a `efecto` (que sigue manejando
--                          el cambio de estado: corte→suspender, reconexion→reactivar).
--   cuotas.ticket_id     → liga la cuota manual (el cobro puntual) al ticket que la
--                          originó: para el recibo ("Ticket #N") y para no cobrar
--                          dos veces el mismo ticket (la UI chequea si ya hay cobro).
--
-- ADITIVOS (Receta R4): PowerSync los aplica IN-PLACE → NO se bumpea
-- `_dbWipeVersion`. Cadena de integridad: schema.dart + sync-rules (los nuevos
-- campos viajan en los buckets de ticket_tipos/cuotas) + Dart consistente.

ALTER TABLE public.ticket_tipos
  ADD COLUMN IF NOT EXISTS precio numeric NOT NULL DEFAULT 0
    CHECK (precio >= 0);

ALTER TABLE public.cuotas
  ADD COLUMN IF NOT EXISTS ticket_id uuid
    REFERENCES public.tickets(id) ON DELETE SET NULL;

-- El cobro se busca por ticket (¿este ticket ya tiene cobro?) → índice parcial.
CREATE INDEX IF NOT EXISTS cuotas_by_ticket
  ON public.cuotas (ticket_id) WHERE ticket_id IS NOT NULL;
