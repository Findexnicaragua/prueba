-- Sistema de logs de errores del cliente Flutter.
--
-- Cada crash/excepción capturada por el cliente (FlutterError.onError,
-- runZonedGuarded, PlatformDispatcher) se inserta acá para que super_admin
-- diagnostique sin pedirle al cliente que abra DevTools.
--
-- Modelo:
--   - INSERT only desde clientes authenticated. La policy exige
--     user_id = auth.uid() para evitar suplantación.
--   - tenant_id es opcional (puede ser null si el cliente no logró
--     leerlo de PowerSync, ej. arranque sin sync). Si se pasa, tiene que
--     coincidir con current_tenant_id() — un user no puede atribuir su
--     error a otro tenant.
--   - super_admin tiene policy ALL: lee todos los logs cross-tenant
--     desde /super/logs y eventualmente puede purgar viejos.
--   - client_log_id: UUID del cliente para idempotencia. Si el cliente
--     reintenta el upload (network blip), el segundo INSERT choca contra
--     el unique constraint y el cliente lo trata como éxito.

-- =========================================================================
-- Tabla
-- =========================================================================

create table if not exists public.error_logs (
  id              uuid        primary key default gen_random_uuid(),
  ts              timestamptz not null    default now(),
  user_id         uuid                    references auth.users(id) on delete set null,
  tenant_id       uuid                    references public.tenants(id) on delete set null,
  error_type      text        not null    check (error_type in ('flutter','zone','platform')),
  message         text        not null,
  stack           text,
  route           text,
  user_agent      text,
  app_version     text,
  client_log_id   uuid,
  reported_at     timestamptz not null    default now()
);


-- =========================================================================
-- Indices
-- =========================================================================
-- Listado global (más reciente primero) — el viewer /super/logs lo usa.
create index if not exists error_logs_ts_idx
  on public.error_logs (ts desc);

-- Filtro por tenant (cuando super_admin pivota en un ISP específico).
create index if not exists error_logs_tenant_ts_idx
  on public.error_logs (tenant_id, ts desc)
  where tenant_id is not null;

-- Filtro por user (cuando se diagnostica el problema de un usuario puntual).
create index if not exists error_logs_user_ts_idx
  on public.error_logs (user_id, ts desc)
  where user_id is not null;

-- Idempotencia: dedupe en reintentos del cliente.
create unique index if not exists error_logs_client_log_id_uidx
  on public.error_logs (client_log_id)
  where client_log_id is not null;


-- =========================================================================
-- RLS
-- =========================================================================

alter table public.error_logs enable row level security;

-- super_admin: ALL (read/insert/update/delete cross-tenant).
drop policy if exists "error_logs_super_admin_all" on public.error_logs;
create policy "error_logs_super_admin_all"
  on public.error_logs
  for all
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- authenticated: INSERT propio. Exige user_id = auth.uid() para evitar
-- suplantación. tenant_id puede ser null (cliente no leyó la tabla
-- cobradores aún) o tiene que coincidir con current_tenant_id() para
-- evitar atribuir el error a otro tenant.
drop policy if exists "error_logs_self_insert" on public.error_logs;
create policy "error_logs_self_insert"
  on public.error_logs
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and (
      tenant_id is null
      or tenant_id = public.current_tenant_id()
    )
  );


-- =========================================================================
-- RPC list_error_logs — el viewer /super/logs la consume.
-- =========================================================================
-- Hace JOIN con tenants y cobradores para mostrar nombres en vez de
-- UUIDs raw. SECURITY DEFINER porque el viewer es exclusivo de
-- super_admin — la guard explícita raisea 42501 si lo invoca otro rol.
--
-- Filtros opcionales: tenant, tipo de error, búsqueda en message (ilike).

create or replace function public.list_error_logs(
  p_tenant_id  uuid default null,
  p_error_type text default null,
  p_search     text default null,
  p_limit      int  default 100
)
returns table(
  id            uuid,
  ts            timestamptz,
  user_id       uuid,
  user_nombre   text,
  tenant_id     uuid,
  tenant_nombre text,
  error_type    text,
  message       text,
  stack         text,
  route         text,
  user_agent    text,
  app_version   text,
  reported_at   timestamptz
)
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
  select
    el.id, el.ts, el.user_id, co.nombre as user_nombre,
    el.tenant_id, t.nombre as tenant_nombre,
    el.error_type, el.message, el.stack, el.route,
    el.user_agent, el.app_version, el.reported_at
  from public.error_logs el
  left join public.tenants t      on t.id  = el.tenant_id
  left join public.cobradores co  on co.id = el.user_id
  where (p_tenant_id  is null or el.tenant_id  = p_tenant_id)
    and (p_error_type is null or el.error_type = p_error_type)
    and (p_search     is null or el.message ilike '%' || p_search || '%')
  order by el.ts desc
  -- Cap a 500 para defender contra p_limit gigantes accidentales del cliente.
  limit least(greatest(p_limit, 1), 500);
end;
$$;

revoke all on function public.list_error_logs(uuid, text, text, int) from public;
grant execute on function public.list_error_logs(uuid, text, text, int) to authenticated;
