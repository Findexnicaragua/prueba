-- 0137 — WhatsApp Cloud API (envío automático por lote). Feature paga, opt-in.
--
-- Convive con el modo gratis (wa.me manual, configurado en Cobranza). Este modo
-- API se configura SOLO en Avanzado (super_admin) y habilita el envío por LOTE a
-- la hora configurada vía la Cloud API de Meta.
--
-- Contiene:
--   1. Settings de config (super_admin, categoria cobranza, render custom en la
--      tab Avanzado vía _WhatsappApiCard). El ACCESS TOKEN NO va acá (es secreto
--      y los settings sincronizan a los dispositivos) → va en una tabla aparte.
--   2. Tabla `whatsapp_credenciales` (server-only, NO en sync rules): el token.
--      La escribe SOLO la edge function `whatsapp-set-token` (service role).
--   3. Tabla `whatsapp_envios` (server-only): log de a quién/cuándo se notificó,
--      para respetar la frecuencia de re-notificación y el tope diario.
--
-- Las edge functions + el cron se deployan a mano en el Dashboard (ver
-- Install Steps / la guía). Esta migración solo prepara DB + settings.

begin;

-- ── 1) Settings de config del modo API ──────────────────────────────────────
create or replace function public.seed_settings_whatsapp_api_0137(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.notif_api_habilitado','false'::jsonb,'boolean','cobranza','Activa el envío automático por lote vía la API paga de WhatsApp','super_admin'),
    ('cobranza.notif_api_phone_id', to_jsonb(''::text),'string','cobranza','Phone Number ID de la Cloud API de Meta','super_admin'),
    ('cobranza.notif_api_template_gracia', to_jsonb(''::text),'string','cobranza','Nombre de la plantilla aprobada por Meta para próximos a corte (gracia)','super_admin'),
    ('cobranza.notif_api_template_mora', to_jsonb(''::text),'string','cobranza','Nombre de la plantilla aprobada por Meta para mora (corte)','super_admin'),
    ('cobranza.notif_api_template_lang', to_jsonb('es'::text),'string','cobranza','Código de idioma de las plantillas (ej. es, es_NI)','super_admin'),
    ('cobranza.notif_api_hora','8'::jsonb,'number','cobranza','Hora (0-23, Nicaragua) del envío automático diario','super_admin'),
    ('cobranza.notif_api_frecuencia', to_jsonb('semanal'::text),'string','cobranza','Cada cuánto re-notificar al mismo cliente: una_vez_estado | cada_3 | semanal | cada_15 | diario','super_admin'),
    ('cobranza.notif_api_tope_diario','200'::jsonb,'number','cobranza','Tope de mensajes por día (resguardo anti-spam)','super_admin'),
    ('cobranza.notif_api_token_configurado','false'::jsonb,'boolean','cobranza','Refleja si el Access Token está cargado (lo setea la edge function; el token vive en el servidor)','super_admin')
  ) as v(clave,valor,tipo,categoria,descripcion,editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id=p_tenant and s.clave=v.clave
  );
end;
$fn$;

-- Backfill a tenants existentes (excepto el System).
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_whatsapp_api_0137(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0135).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);
  perform public.seed_settings_notif_0135(new.id);
  perform public.seed_settings_whatsapp_api_0137(new.id);   -- [0137]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- ── 2) Token (server-only, NO en sync rules) ─────────────────────────────────
create table if not exists public.whatsapp_credenciales (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  access_token text not null,
  actualizado_en timestamptz not null default now()
);
alter table public.whatsapp_credenciales enable row level security;
-- Sin policies: SOLO el service role (edge function) accede. El cliente nunca la
-- ve (tampoco está en sync rules). Defensa en profundidad contra REST directo.

-- ── 3) Log de envíos (server-only) — para frecuencia + tope ──────────────────
create table if not exists public.whatsapp_envios (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  cliente_id uuid not null,
  estado text not null,            -- 'gracia' | 'mora'
  canal text not null default 'api', -- 'api' | 'wa_me'
  enviado_en timestamptz not null default now(),
  ok boolean not null default true,
  error text
);
create index if not exists whatsapp_envios_lookup
  on public.whatsapp_envios (tenant_id, cliente_id, enviado_en desc);
alter table public.whatsapp_envios enable row level security;
-- El super_admin puede inspeccionar el log; el service role (edge/cron) escribe.
drop policy if exists whatsapp_envios_super_select on public.whatsapp_envios;
create policy whatsapp_envios_super_select on public.whatsapp_envios
  for select using (public.is_super_admin());

-- Verificación dentro de la transacción.
select 'tenants_sin_api_cfg' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.notif_api_habilitado')
union all
select 'tablas_creadas',
  (select count(*) from information_schema.tables
    where table_schema='public' and table_name in ('whatsapp_credenciales','whatsapp_envios'));

commit;
