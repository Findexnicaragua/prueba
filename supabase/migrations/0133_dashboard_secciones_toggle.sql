-- 0133 — Secciones del dashboard admin toggleables (super_admin-only, por tenant).
--
-- 7 settings 'dashboard.*_visible' (boolean, default true): el super_admin
-- prende/apaga qué bloques del Resumen ve el admin de cada tenant (grupo
-- super-only en Settings → Avanzado). El panel SOLO dibuja claves con fila →
-- hay que sembrarlas (R6): helper idempotente + backfill a todos los tenants +
-- enganche al seed de tenants nuevos. Default TRUE = no rompe dashboards
-- existentes (coincide con el getter-default en AppSettings). categoria
-- 'cobranza' a propósito (la tab Avanzado lee settings de esa categoría y los
-- agrupa por settings_groups; reclamadas por kGruposAvanzado).

begin;

create or replace function public.seed_settings_dashboard_0133(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('dashboard.cobros_visible','true'::jsonb,'boolean','cobranza','Muestra los KPIs de cobros (Hoy/Semana/Mes) en el Resumen','super_admin'),
    ('dashboard.proyeccion_visible','true'::jsonb,'boolean','cobranza','Muestra la proyección de cobros por cobrador','super_admin'),
    ('dashboard.recuperacion_visible','true'::jsonb,'boolean','cobranza','Muestra la recuperación de mora por cobrador y comunidad','super_admin'),
    ('dashboard.sparkline_visible','true'::jsonb,'boolean','cobranza','Muestra el gráfico de cobros de 7 días','super_admin'),
    ('dashboard.operativo_visible','true'::jsonb,'boolean','cobranza','Muestra los KPIs operativos (clientes, por cobrar, mora)','super_admin'),
    ('dashboard.top_cobradores_visible','true'::jsonb,'boolean','cobranza','Muestra el top de cobradores del mes','super_admin'),
    ('dashboard.distribucion_visible','true'::jsonb,'boolean','cobranza','Muestra la distribución de cuotas','super_admin')
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
    perform public.seed_settings_dashboard_0133(t.id);
  end loop;
end $$;

-- Tenants futuros: enganchar al trigger de seed (preserva el cuerpo de 0132).
create or replace function public.tenants_seed_settings_trg()
returns trigger language plpgsql as $fn$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  perform public.seed_settings_recibo_layout(new.id);
  perform public.seed_settings_ajustes(new.id);
  perform public.seed_settings_faltantes_0132(new.id);
  perform public.seed_settings_dashboard_0133(new.id);   -- [0133]
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
select 'tenants_sin_dashboard' as chk, count(*) as n
  from public.tenants t where t.id <> '00000000-0000-0000-0000-000000000000'
  and not exists (select 1 from public.settings s where s.tenant_id=t.id and s.clave='dashboard.cobros_visible')
union all
select 'telenet_dashboard_keys', count(*)
  from public.settings where tenant_id='ca3b04ca-fd68-4208-8f01-b8f681dcf578' and clave like 'dashboard.%';

commit;
