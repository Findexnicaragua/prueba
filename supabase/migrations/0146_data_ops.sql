-- 0146 — Operaciones de datos del super_admin (corrección de errores de carga).
--
-- Backend del panel "Operaciones" (super_admin): la edge function
-- `super-admin-data-op` ejecuta borrados predefinidos (limpiar_cliente /
-- eliminar_cliente / eliminar_contrato) con PREVIEW + confirmación + BACKUP +
-- registro. Estas 2 tablas son el backup (restaurable) y el log (historial).
-- NO se sincronizan a clientes: el panel las lee por REST con el JWT del
-- super_admin (igual que tenants/tenant_modulos). Aditivas, sin cambios a otras
-- tablas. El INSERT lo hace el service_role (edge fn); el super_admin solo LEE.

begin;

-- Snapshot de las filas borradas por una operación (para poder restaurar).
create table if not exists public.data_op_backups (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  operacion    text not null,        -- limpiar_cliente | eliminar_cliente | eliminar_contrato
  target_label text not null,        -- ej. 'SE0020 — David Pineda Saenz'
  snapshot     jsonb not null,       -- las filas eliminadas, por tabla
  actor_id     uuid,
  actor_label  text,
  created_at   timestamptz not null default now()
);

-- Registro de cada operación ejecutada (el "Historial de operaciones").
create table if not exists public.data_ops_log (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  operacion    text not null,
  target_label text not null,
  afectados    jsonb not null,       -- {contratos:8, cuotas:64, pagos:47, ...}
  backup_id    uuid references public.data_op_backups(id) on delete set null,
  actor_id     uuid,
  actor_label  text,
  created_at   timestamptz not null default now()
);

create index if not exists data_ops_log_tenant_idx
  on public.data_ops_log (tenant_id, created_at desc);

alter table public.data_op_backups enable row level security;
alter table public.data_ops_log    enable row level security;

-- Solo el super_admin LEE (vía REST con su JWT). El INSERT lo hace el
-- service_role de la edge function (bypassa RLS). Sin policies de INSERT/
-- UPDATE/DELETE para usuarios normales → nadie más las toca.
drop policy if exists data_op_backups_super_read on public.data_op_backups;
create policy data_op_backups_super_read on public.data_op_backups
  for select using (public.is_super_admin());

drop policy if exists data_ops_log_super_read on public.data_ops_log;
create policy data_ops_log_super_read on public.data_ops_log
  for select using (public.is_super_admin());

commit;

-- Verificación.
select to_regclass('public.data_op_backups') AS backups,
       to_regclass('public.data_ops_log')    AS log;
