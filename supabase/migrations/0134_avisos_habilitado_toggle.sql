-- 0134 — Toggle super_admin para la pantalla de Avisos (gracia/mora).
--
-- Setting 'cobranza.avisos_habilitado' (boolean, default FALSE = opt-in): el
-- super_admin lo prende por tenant para que admin/admin_cobranza vean la
-- pantalla "Avisos" (clientes próximos a corte / en mora). El panel SOLO dibuja
-- claves con fila → hay que sembrarla (R6): helper idempotente + backfill a
-- todos los tenants + enganche al seed de tenants nuevos. categoria 'cobranza'
-- a propósito (la tab Avanzado lee settings de esa categoría; reclamada por
-- kGruposAvanzado). Default FALSE: no aparece hasta que el super_admin lo prenda.

begin;

create or replace function public.seed_settings_avisos_0134(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.avisos_habilitado','false'::jsonb,'boolean','cobranza','Muestra la pantalla "Avisos" (clientes próximos a corte y en mora) a admin/admin_cobranza','super_admin')
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
    perform public.seed_settings_avisos_0134(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0133).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);
  perform public.seed_settings_avisos_0134(new.id);   -- [0134]
  update public.settings set valor = '5'::jsonb
    where tenant_id = new.id and clave = 'cobranza.dias_cuotas_visibles';
  update public.settings set editable_por = 'super_admin'
    where tenant_id = new.id
      and clave in ('cobranza.pago_parcial','cobranza.pago_adelantado',
                    'cobranza.cobrador_anula_cobros','cobranza.cobrador_edita_cobros');
  return new;
end;
$fn$;

-- Verificación dentro de la transacción.
select 'tenants_sin_avisos' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.avisos_habilitado')
union all
select 'avisos_editable_por_ok', count(*)
  from public.settings where clave='cobranza.avisos_habilitado' and editable_por='super_admin';

commit;
