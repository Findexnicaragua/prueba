-- Sprint A2 — RPCs para el panel Super Admin
--
-- El panel /super/* no sincroniza modulos / tenant_modulos al SQLite local
-- (así esas tablas no se exponen a tenants regulares). En su lugar consume
-- estas RPCs. Todas chequean is_super_admin() y devuelven error 42501 si no.
--
-- Funciones:
--   1. list_modulos()         → catálogo global (cobranza, inventario, …)
--   2. list_tenants_admin()   → tenants + cobradores_count + módulos activos
--   3. set_tenant_modulo(...) → habilita/deshabilita módulo en un tenant

-- =========================================================================
-- 1. Catálogo de módulos del sistema
-- =========================================================================

create or replace function public.list_modulos()
returns table (
  codigo      text,
  nombre      text,
  descripcion text,
  es_base     boolean,
  orden       int
)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select codigo, nombre, descripcion, es_base, orden
  from public.modulos
  order by orden;
$$;

revoke all on function public.list_modulos() from public;
grant execute on function public.list_modulos() to authenticated;

-- =========================================================================
-- 2. Listar tenants con métricas
-- =========================================================================
-- Excluye el tenant 'System' (no es un ISP real).
-- cobradores_count cuenta sólo activos.
-- modulos_habilitados llega como array de códigos para que el cliente lo
-- consuma fácil (chips/badges).

create or replace function public.list_tenants_admin()
returns table (
  id                  uuid,
  nombre              text,
  created_at          timestamptz,
  cobradores_count    bigint,
  modulos_habilitados text[]
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      t.id,
      t.nombre,
      t.created_at,
      (select count(*) from public.cobradores c
         where c.tenant_id = t.id and c.activo) as cobradores_count,
      coalesce(
        (select array_agg(tm.modulo_codigo order by tm.modulo_codigo)
           from public.tenant_modulos tm
          where tm.tenant_id = t.id and tm.habilitado),
        array[]::text[]
      ) as modulos_habilitados
    from public.tenants t
    where t.id <> '00000000-0000-0000-0000-000000000000'
    order by t.created_at desc;
end;
$$;

revoke all on function public.list_tenants_admin() from public;
grant execute on function public.list_tenants_admin() to authenticated;

-- =========================================================================
-- 3. Toggle de módulo para un tenant
-- =========================================================================
-- Reglas:
--   - Sólo super_admin.
--   - No se puede modificar el tenant System.
--   - Módulos con es_base=true no se pueden deshabilitar (cobranza siempre on).
--   - Upsert: registra quién/cuándo cambió el flag.

create or replace function public.set_tenant_modulo(
  p_tenant_id  uuid,
  p_modulo     text,
  p_habilitado boolean
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_es_base boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  if p_tenant_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'No se puede modificar el tenant System';
  end if;

  select es_base into v_es_base
  from public.modulos
  where codigo = p_modulo;

  if v_es_base is null then
    raise exception 'Módulo % no existe', p_modulo;
  end if;

  if v_es_base and not p_habilitado then
    raise exception 'Módulo % es base y no se puede deshabilitar', p_modulo;
  end if;

  insert into public.tenant_modulos (
    tenant_id, modulo_codigo, habilitado, habilitado_en, habilitado_por
  ) values (
    p_tenant_id, p_modulo, p_habilitado, now(), auth.uid()
  )
  on conflict (tenant_id, modulo_codigo) do update
    set habilitado     = excluded.habilitado,
        habilitado_en  = excluded.habilitado_en,
        habilitado_por = excluded.habilitado_por;
end;
$$;

revoke all on function public.set_tenant_modulo(uuid, text, boolean) from public;
grant execute on function public.set_tenant_modulo(uuid, text, boolean) to authenticated;
