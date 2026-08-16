-- 0141 — Toggle 'cobranza.reportes_detallados' (super_admin, Avanzado).
--
-- Rework del módulo de reportes: por defecto el módulo se basa en la PLANTILLA
-- estándar ("Reporte de cobranza", Excel) que pidieron Mairena/Telenet. Los
-- reportes variados de siempre (los 8 PDF + arqueo + menú Excel) NO se borran:
-- se ocultan tras este toggle, que solo el super_admin habilita por tenant.
-- Default OFF (= solo el reporte plantilla). Aditivo, sin cambios de schema.

begin;

create or replace function public.seed_settings_reportes_0141(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, 'cobranza.reportes_detallados', 'false'::jsonb, 'boolean', 'cobranza',
         'Muestra los reportes detallados (legacy) además del reporte de cobranza estándar', 'super_admin'
  where not exists (
    select 1 from public.settings s
     where s.tenant_id = p_tenant and s.clave = 'cobranza.reportes_detallados'
  );
end;
$fn$;

do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_reportes_0141(t.id);
  end loop;
end $$;

-- Trigger de seed: preservar el cuerpo exacto + agregar la nueva llamada.
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
  perform public.seed_settings_whatsapp_api_body_0139(new.id);   -- [0139]
  perform public.seed_settings_reportes_0141(new.id);   -- [0141]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

select 'tenants_sin_toggle' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.reportes_detallados');

commit;
