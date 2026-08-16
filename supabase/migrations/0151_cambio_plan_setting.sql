-- 0151 — Toggle super_admin para el "Cambio de plan" del contrato.
--
-- Setting 'cobranza.cambio_plan_habilitado' (boolean, default FALSE = opt-in): el
-- super_admin lo prende por tenant para que admin/admin_cobranza vean el botón
-- "Cambiar plan" en el Detalle de contrato. El panel SOLO dibuja claves con fila
-- → hay que sembrarla (R6): helper idempotente + backfill a todos los tenants +
-- enganche al seed de tenants nuevos. categoria 'cobranza' (la tab Avanzado lee
-- esa categoría). Default FALSE: no aparece hasta que el super_admin lo prenda.
-- Calca exacto el molde de 0134 (avisos_habilitado).

begin;

create or replace function public.seed_settings_cambio_plan_0151(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('cobranza.cambio_plan_habilitado','false'::jsonb,'boolean','cobranza','Muestra el botón "Cambiar plan" en el detalle de contrato a admin/admin_cobranza','super_admin')
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
    perform public.seed_settings_cambio_plan_0151(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0134).
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
  perform public.seed_settings_cambio_plan_0151(new.id);   -- [0151]
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
select 'tenants_sin_cambio_plan' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='cobranza.cambio_plan_habilitado')
union all
select 'cambio_plan_editable_por_ok', count(*)
  from public.settings where clave='cobranza.cambio_plan_habilitado' and editable_por='super_admin';

commit;
