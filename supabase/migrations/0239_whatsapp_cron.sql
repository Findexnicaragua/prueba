-- 0239 — Automatización WhatsApp: pg_net + cron whatsapp-lote-hourly.
-- YA CORRIDO A MANO en prod (2026-08-18, primera prueba E2E real de WhatChimp).
-- Este archivo existe para reproducibilidad (traspaso / restore) — es idempotente.
--
-- Auth del lote: la función whatsapp-enviar valida el header `x-cron-secret`
-- contra su secret CRON_SECRET. La comparación vieja contra
-- SUPABASE_SERVICE_ROLE_KEY dejó de matchear tras la migración de claves de
-- Supabase (2026-08) — el env de la función trae una variante distinta de la
-- key activa. El secreto NO vive acá: se crea por fuera con
--   supabase secrets set CRON_SECRET=<random>   (lado función)
--   select vault.create_secret('<random>', 'whatsapp_cron_secret');  (lado cron)
-- Los dos valores deben ser EL MISMO.
--
-- El cron corre cada hora a los :05; la función decide por tenant si es SU hora
-- configurada (cobranza.notif_api_hora, hoy 8 = 8am Nicaragua) y respeta
-- habilitado + token + frecuencia + tope. Tenants con el envío apagado: no-op.

begin;

create extension if not exists pg_net;

select cron.unschedule('whatsapp-lote-hourly')
 where exists (select 1 from cron.job where jobname = 'whatsapp-lote-hourly');

select cron.schedule('whatsapp-lote-hourly', '5 * * * *',
$$select net.http_post(
    url := 'https://vxxzesbmilfolwjhfxgr.supabase.co/functions/v1/whatsapp-enviar',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                         where name = 'whatsapp_cron_secret')),
    body := '{"modo":"lote"}'::jsonb)$$);

commit;
