-- Fix de op_log (branch changelog-rework) — descubierto en testing en vivo.
--
-- (1) diff: jsonb -> text.
--   El cliente PowerSync guarda diff como STRING de texto JSON (jsonEncode). Al
--   subirlo a una columna jsonb vía PostgREST, Postgres lo mete como jsonb-STRING
--   (jsonb_typeof='string'), no como objeto → doble-encodeado. Como text, el
--   round-trip es identidad (text->text, single) y el cliente lo decodifica con
--   un solo jsonDecode. El schema LOCAL (schema.dart) ya lo declara text.
--
-- (2) policy UPDATE.
--   El conector (powersync/connector.dart) sube cada cambio con supabase.upsert
--   = INSERT ... ON CONFLICT DO UPDATE. op_log no tenía policy UPDATE (diseño
--   append-only), así que en un REINTENTO/conflicto el path de UPDATE daba 42501
--   ("rechazado por el servidor"). El forense INMUTABLE es audit_log (trigger
--   server); op_log es el log de intención para UX → puede tener UPDATE scopeado
--   al dueño sin perder garantías. La app igual nunca actualiza op_log: el
--   upsert solo reescribe la MISMA fila idempotentemente.

alter table public.op_log alter column diff type text using diff::text;

drop policy if exists "op_log_update" on public.op_log;
create policy "op_log_update" on public.op_log
  for update using (
    tenant_id = public.current_tenant_id()
    and (actor_id = auth.uid() or actor_id is null)
  ) with check (
    tenant_id = public.current_tenant_id()
    and (actor_id = auth.uid() or actor_id is null)
  );
