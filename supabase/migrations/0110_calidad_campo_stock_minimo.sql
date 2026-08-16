-- 0110 — Calidad de campo (checklists) + Inventario v2 (stock mínimo).
--
-- Approach SIMPLE (lección de Nodos): NO crea tablas ni jerarquías ni vínculos
-- nuevos. Solo 3 columnas en tablas que ya existen. La firma del cliente NO está
-- acá: reusa `ticket_adjuntos` (0104), cero schema.
--
-- 1. CHECKLISTS — el tipo define el template, el ticket guarda su SNAPSHOT.
--    `ticket_tipos.checklist_template` (JSONB): lista de pasos que edita el admin,
--      ej. ["Verificar señal","Configurar router"].
--    `tickets.checklist` (JSONB): snapshot al crear, [{"texto":..,"hecho":bool}].
--      El snapshot evita que editar el template rompa los tickets ya creados (cada
--      ticket es dueño de su copia — no queda linkeado frágil al template).
--    El técnico tilda → update del JSONB en el ticket que ya posee (offline-safe).
--
-- 2. STOCK MÍNIMO — `inv_productos.stock_minimo` (numeric, 0 = sin alerta). La
--    alerta es DERIVADA en el cliente (lista resalta bajo-mínimo + badge), sin cron
--    ni tabla de notificaciones — el stock se computa del ledger.
--
-- Sin RLS nueva (las columnas heredan la de su tabla) ni triggers nuevos (los
-- cambios los capturan los audit triggers existentes). Idempotente.
--
-- ⚠️ Cadena de integridad: schema.dart declara las 3 columnas, `_schemaVersion`
-- 25→26 (db.dart), y redeploy de sync rules (el SELECT * de tickets/ticket_tipos/
-- inv_productos ya las cubre).

begin;

alter table public.ticket_tipos
  add column if not exists checklist_template jsonb not null default '[]'::jsonb;

alter table public.tickets
  add column if not exists checklist jsonb not null default '[]'::jsonb;

alter table public.inv_productos
  add column if not exists stock_minimo numeric not null default 0;

commit;
