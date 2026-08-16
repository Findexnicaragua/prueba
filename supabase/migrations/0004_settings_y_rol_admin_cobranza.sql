-- Settings: configuración global por tenant.
-- Clave/valor con tipo, agrupados por categoría para UI del panel admin.

create table public.settings (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  clave text not null,
  valor jsonb not null,
  tipo text not null check (tipo in ('boolean','number','string','json')),
  categoria text not null,
  descripcion text,
  editable_por text not null default 'admin' check (editable_por in ('admin','admin_cobranza')),
  updated_at timestamptz not null default now(),
  primary key (tenant_id, clave)
);

create index on public.settings (tenant_id, categoria);

alter table public.settings enable row level security;

create policy "tenant_isolation" on public.settings
  for all using (tenant_id = public.current_tenant_id());

-- =========================================================================
-- Rol admin_cobranza
-- Existía sólo admin/cobrador en 0001. admin_cobranza administra clientes,
-- contratos, asignación de cobradores. NO toca settings ni borra cobradores.
-- =========================================================================

alter table public.cobradores drop constraint cobradores_rol_check;

alter table public.cobradores add constraint cobradores_rol_check
  check (rol in ('admin','admin_cobranza','cobrador'));

-- Helper para sync rules y políticas RLS.
create or replace function public.current_user_rol() returns text
language sql stable security definer as $$
  select rol from public.cobradores where id = auth.uid()
$$;

-- =========================================================================
-- RLS de settings: lectura permitida a cualquier usuario del tenant,
-- escritura sólo admin (o admin_cobranza si la setting lo permite).
-- =========================================================================

drop policy "tenant_isolation" on public.settings;

create policy "settings_read" on public.settings
  for select using (tenant_id = public.current_tenant_id());

create policy "settings_write_admin" on public.settings
  for all using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin'
  ) with check (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin'
  );

-- admin_cobranza puede actualizar settings cuyo editable_por sea 'admin_cobranza'.
create policy "settings_update_admin_cobranza" on public.settings
  for update using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin_cobranza'
    and editable_por = 'admin_cobranza'
  );
