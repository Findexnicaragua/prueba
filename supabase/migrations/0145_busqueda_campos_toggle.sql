-- 0145 — Toggles de campos de búsqueda de cliente (super_admin, Avanzado).
--
-- La búsqueda de cliente (5 listas: clientes admin, lista del cobrador, Cobros,
-- global, mapa) matcheaba SIEMPRE nombre + código + cédula + teléfono +
-- código-de-contrato. El teléfono mete falsos positivos (buscar "003" trae todo
-- número con 003). Estos toggles dejan que el super_admin elija qué campos
-- entran, por tenant. El NOMBRE no es toggle (siempre entra). Default TRUE =
-- comportamiento previo (no cambia nada hasta que el super_admin apague alguno).
-- Aditivo, sin cambios de schema. Lo consume el helper busquedaClienteSql.

begin;

create or replace function public.seed_settings_busqueda_0145(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, x.clave, 'true'::jsonb, 'boolean', 'cobranza', x.descripcion, 'super_admin'
    from (values
      ('busqueda.por_codigo',   'Buscar clientes por su código'),
      ('busqueda.por_cedula',   'Buscar clientes por cédula'),
      ('busqueda.por_telefono', 'Buscar clientes por teléfono (apagalo si mete falsos positivos)'),
      ('busqueda.por_contrato', 'Buscar clientes por el código de sus contratos')
    ) as x(clave, descripcion)
   where not exists (
     select 1 from public.settings s
      where s.tenant_id = p_tenant and s.clave = x.clave
   );
end;
$fn$;

-- Backfill de los tenants existentes.
do $$
declare t record;
begin
  for t in select id from public.tenants where id <> '00000000-0000-0000-0000-000000000000' loop
    perform public.seed_settings_busqueda_0145(t.id);
  end loop;
end $$;

-- Trigger de seed: MISMO cuerpo actual + la llamada nueva (para tenants nuevos).
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
  perform public.seed_settings_busqueda_0145(new.id);   -- [0145]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

commit;

-- Verificación: ningún tenant real sin el toggle.
select 'tenants_sin_toggle' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='busqueda.por_telefono');
