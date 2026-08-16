-- 0177 — Toggle 'cobranza.cobro_extra' (super_admin, Avanzado).
--
-- El "cobro extra" (cobro puntual: multa / otro cargo que decide el admin) se
-- mostraba SIEMPRE: el botón "Cobro extra" en el detalle del cliente y el
-- "Generar cobro" en el detalle de un ticket. Debe ser un módulo que SOLO el
-- super_admin habilita por tenant. Default OFF (= oculto en ambos lados).
-- Mismo patrón que 'cobranza.reportes_detallados' (0141). Aditivo, sin schema.
--
-- El cuerpo del trigger de seed se parte del ÚLTIMO vigente (0152) y solo se
-- AGREGA la nueva llamada (lección 0151→0152: no perder performs).

begin;

create or replace function public.seed_settings_cobro_extra_0177(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, 'cobranza.cobro_extra', 'false'::jsonb, 'boolean', 'cobranza',
         'Habilita el cobro puntual (multa / otro cargo) desde el cliente y desde tickets', 'super_admin'
  where not exists (
    select 1 from public.settings s
     where s.tenant_id = p_tenant and s.clave = 'cobranza.cobro_extra'
  );
end;
$fn$;

do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_cobro_extra_0177(t.id);
  end loop;
end $$;

-- Trigger de seed: cuerpo VIGENTE (0152) + la nueva llamada [0177].
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
  perform public.seed_settings_cobro_extra_0177(new.id);          -- [0177]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

select 'tenants_sin_cobro_extra' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.cobro_extra');

commit;
