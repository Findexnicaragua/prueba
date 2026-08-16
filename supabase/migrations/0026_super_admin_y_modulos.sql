-- Sprint A1 — Rol super_admin + sistema de módulos por tenant
--
-- Cambios:
--   1. Rol 'super_admin' agregado al CHECK constraint de cobradores.
--   2. Tenant 'System' (UUID 0000-...) para alojar a los super_admin.
--   3. Tabla `modulos` (catálogo de módulos del sistema).
--   4. Tabla `tenant_modulos` (qué módulos tiene habilitado cada tenant).
--   5. Funciones helper: is_super_admin(), tenant_tiene_modulo().
--      Se definen DESPUÉS de las tablas que referencian (orden importante).
--   6. Policies de modulos + tenant_modulos.
--   7. Backfill módulos base en tenants existentes.
--   8. Trigger: al crear un tenant, auto-habilita los módulos base.
--   9. RLS 'super_admin_all' en todas las tablas operativas + storage.
--   10. handle_new_user actualizado: super_admin → tenant System.

-- =========================================================================
-- 1. Rol super_admin
-- =========================================================================

alter table public.cobradores drop constraint if exists cobradores_rol_check;
alter table public.cobradores add constraint cobradores_rol_check
  check (rol in ('super_admin', 'admin', 'admin_cobranza', 'cobrador'));

-- =========================================================================
-- 2. Tenant 'System' (UUID fijo, conocido)
-- =========================================================================

insert into public.tenants (id, nombre)
  values ('00000000-0000-0000-0000-000000000000', 'System')
  on conflict (id) do nothing;

-- =========================================================================
-- 3. Tabla `modulos`
-- =========================================================================

create table if not exists public.modulos (
  codigo text primary key,
  nombre text not null,
  descripcion text,
  es_base boolean not null default false,
  orden int not null default 0,
  created_at timestamptz not null default now()
);

insert into public.modulos (codigo, nombre, descripcion, es_base, orden) values
  ('cobranza',   'Cobranza',
   'Gestión de clientes, contratos, cuotas, cobros e impresión de recibos.',
   true,  10),
  ('inventario', 'Inventario',
   'Gestión de equipos (routers, ONUs, etc.) asignados a clientes.',
   false, 20)
on conflict (codigo) do nothing;

alter table public.modulos enable row level security;

-- =========================================================================
-- 4. Tabla `tenant_modulos`
-- =========================================================================

create table if not exists public.tenant_modulos (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  modulo_codigo text not null references public.modulos(codigo) on delete restrict,
  habilitado boolean not null default true,
  habilitado_en timestamptz not null default now(),
  habilitado_por uuid references public.cobradores(id) on delete set null,
  primary key (tenant_id, modulo_codigo)
);

alter table public.tenant_modulos enable row level security;

-- =========================================================================
-- 5. Funciones helper (DESPUÉS de las tablas que usan)
-- =========================================================================

create or replace function public.is_super_admin() returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select rol = 'super_admin' from public.cobradores where id = auth.uid()),
    false
  )
$$;

create or replace function public.tenant_tiene_modulo(p_tenant_id uuid, p_modulo text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select habilitado from public.tenant_modulos
      where tenant_id = p_tenant_id and modulo_codigo = p_modulo),
    false
  )
$$;

-- =========================================================================
-- 6. Policies (ahora is_super_admin existe)
-- =========================================================================

drop policy if exists "modulos_read" on public.modulos;
create policy "modulos_read" on public.modulos
  for select to authenticated using (true);

drop policy if exists "modulos_super_admin_write" on public.modulos;
create policy "modulos_super_admin_write" on public.modulos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

drop policy if exists "tenant_modulos_read" on public.tenant_modulos;
create policy "tenant_modulos_read" on public.tenant_modulos
  for select using (
    tenant_id = public.current_tenant_id() or public.is_super_admin()
  );

drop policy if exists "tenant_modulos_super_admin_write" on public.tenant_modulos;
create policy "tenant_modulos_super_admin_write" on public.tenant_modulos
  for all using (public.is_super_admin())
  with check (public.is_super_admin());

-- =========================================================================
-- 7. Backfill módulos base en tenants existentes
-- =========================================================================

insert into public.tenant_modulos (tenant_id, modulo_codigo)
  select t.id, m.codigo
  from public.tenants t cross join public.modulos m
  where m.es_base = true
on conflict do nothing;

-- =========================================================================
-- 8. Trigger: nuevo tenant → auto-habilita módulos base
-- =========================================================================

create or replace function public.tenants_habilitar_modulos_base_trg()
returns trigger language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.tenant_modulos (tenant_id, modulo_codigo)
    select new.id, codigo from public.modulos where es_base = true
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_tenants_habilitar_modulos_base on public.tenants;
create trigger trg_tenants_habilitar_modulos_base
  after insert on public.tenants
  for each row execute function public.tenants_habilitar_modulos_base_trg();

-- =========================================================================
-- 9. RLS: super_admin tiene acceso cross-tenant
-- =========================================================================

do $$
declare
  v_table text;
  v_tables text[] := array[
    'tenants','cobradores','planes','clientes','contratos','cuotas',
    'pagos','recibos','cargos_extra','notificaciones_mora','settings','audit_log'
  ];
begin
  foreach v_table in array v_tables loop
    execute format('drop policy if exists "super_admin_all" on public.%I', v_table);
    execute format(
      'create policy "super_admin_all" on public.%I for all using (public.is_super_admin()) with check (public.is_super_admin())',
      v_table
    );
  end loop;
end $$;

drop policy if exists "storage_super_admin" on storage.objects;
create policy "storage_super_admin" on storage.objects
  for all to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- =========================================================================
-- 10. handle_new_user actualizado para soportar super_admin
-- =========================================================================
-- - rol='super_admin' → tenant System (00000000-...).
-- - sin tenant_id y rol != super_admin → crea tenant nuevo (admin del ISP).
-- - con tenant_id → invitación (cobrador / admin_cobranza / admin).

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
begin
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  if v_rol not in ('super_admin', 'admin', 'admin_cobranza', 'cobrador') then
    v_rol := 'admin';
  end if;

  if v_rol = 'super_admin' then
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  elsif v_tenant_id is null then
    insert into public.tenants (nombre)
      values (coalesce(v_empresa_nombre, 'Mi ISP'))
      returning id into v_tenant_id;
    v_rol := 'admin';
  end if;

  insert into public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) values (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    case when v_rol = 'cobrador' then v_prefijo else null end,
    true
  )
  on conflict (id) do update
    set tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  return new;
end;
$$;
