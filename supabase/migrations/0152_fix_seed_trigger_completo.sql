-- 0152 — Fix: tenants_seed_settings_trg() perdió 5 seed calls en 0151.
--
-- REGRESIÓN (hallada en el audit pre-merge de cambio-de-plan): 0151 hizo
-- CREATE OR REPLACE del trigger de seed partiendo del cuerpo VIEJO de 0134, y al
-- hacerlo DROPEÓ del provisioning de tenants nuevos las llamadas agregadas por
-- 0135/0137/0139/0141/0145: notif (WhatsApp manual), WhatsApp Cloud API +
-- bodies, reportes detallados y los 4 toggles de campos de búsqueda. Los 3
-- tenants vivos NO se afectan (sus settings ya estaban backfilleados por esas
-- migraciones), pero todo tenant CREADO de ahora en más nacería sin esas filas
-- → el panel "solo dibuja claves con fila" (R6) las ocultaría y quedarían
-- inconfigurables. Este fix repone el cuerpo COMPLETO (= 0145 + cambio_plan_0151).
--
-- Regla de proceso (para no repetirlo): al CREATE OR REPLACE de una función
-- ACUMULATIVA, partir SIEMPRE de la ÚLTIMA definición vigente (grep del último
-- CREATE OR REPLACE de esa función en migrations/), no de la que el comentario
-- recuerde. Las 13 funciones seed referenciadas existen en PROD (verificado).

begin;

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
  perform public.seed_settings_notif_0135(new.id);                -- [0135] repuesta
  perform public.seed_settings_whatsapp_api_0137(new.id);         -- [0137] repuesta
  perform public.seed_settings_whatsapp_api_body_0139(new.id);    -- [0139] repuesta
  perform public.seed_settings_reportes_0141(new.id);             -- [0141] repuesta
  perform public.seed_settings_busqueda_0145(new.id);             -- [0145] repuesta
  perform public.seed_settings_cambio_plan_0151(new.id);          -- [0151]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Backfill defensivo: por si algún tenant se creó en la ventana en que el trigger
-- estuvo regresado (0151 → ahora). Las 5 funciones son idempotentes (insert WHERE
-- NOT EXISTS) → no-op para los tenants que ya las tienen.
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_notif_0135(t.id);
    perform public.seed_settings_whatsapp_api_0137(t.id);
    perform public.seed_settings_whatsapp_api_body_0139(t.id);
    perform public.seed_settings_reportes_0141(t.id);
    perform public.seed_settings_busqueda_0145(t.id);
  end loop;
end $$;

-- Verificación dentro de la transacción: el cuerpo del trigger debe referenciar
-- de nuevo las 5 funciones repuestas + cambio_plan, y ningún tenant real debe
-- quedar sin las claves muestra (notif, busqueda, reportes, whatsapp).
select 'trg_refs_5_repuestas+cambio_plan' as chk,
  (pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_notif_0135%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_whatsapp_api_0137%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_whatsapp_api_body_0139%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_reportes_0141%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_busqueda_0145%'
   and pg_get_functiondef('public.tenants_seed_settings_trg()'::regprocedure) like '%seed_settings_cambio_plan_0151%') as ok
union all
select 'tenants_reales_sin_busqueda_por_telefono',
  (select count(*) = 0 from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
     and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='busqueda.por_telefono'))
union all
select 'tenants_reales_sin_reportes_detallados',
  (select count(*) = 0 from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
     and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.reportes_detallados'));

commit;
