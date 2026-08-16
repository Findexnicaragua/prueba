-- op_log — Log de INTENCIÓN del usuario (rework de change log, branch changelog-rework).
--
-- A diferencia de audit_log (que el trigger genérico audit_changelog_trg llena
-- por-fila, fan-outeando una intención en N filas), op_log lo escribe el CLIENTE
-- dentro de su writeTransaction: UNA fila por cada OBJETO afectado por la
-- intención, scoped a los atributos de ESE objeto (la cuota no hereda del
-- contrato). Todas las filas de una misma intención comparten op_id, actor y
-- ocurrido_en.
--
-- Append-only. Lo LEEN admin/admin_cobranza (igual que audit_log). El cobrador
-- lo ESCRIBE (registra sus cobros offline) pero NO lo descarga. Offline-first:
-- PowerSync lo sincroniza como cualquier tabla.
--
-- audit_log y su trigger NO se tocan acá (quedan como forense/archivo; la UI
-- dejará de leerlos en una fase posterior). Diseño completo: CHANGELOG-REWORK.md.

create table public.op_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id),
  op_id       uuid not null,             -- agrupador de intención (generaliza grupo_cobro)
  tipo_op     text not null,             -- 'cobro'|'suspension'|'edicion_entidad'|... (enum app)
  entidad     text not null,             -- objeto-cabecera: 'cuotas'|'contratos'|'clientes'|...
  entidad_id  uuid not null,             -- PK del objeto (para WHERE entidad_id = ?)
  actor_id    uuid,                      -- usuario real de sesión; NULL = "System Admin" (super_admin)
  actor_label text not null,             -- 'Ruby Admin' | 'María' | 'System Admin'
  accion      text not null,             -- 'create' | 'update' | 'delete'
  diff        jsonb not null,            -- {campos:[{campo,antes,despues}], resumen:{...}}
  ocurrido_en timestamptz not null,      -- device-time UTC (orden cronológico real)
  created_at  timestamptz not null default now()  -- server-time al sincronizar (desempate)
);

create index on public.op_log (tenant_id, entidad, entidad_id, ocurrido_en desc);
create index on public.op_log (tenant_id, op_id);

alter table public.op_log enable row level security;

-- LECTURA: mismo modelo que audit_log (0047) — admin + admin_cobranza del tenant.
-- (La visibilidad efectiva para admin_cobranza la gatea el setting
-- audit.visible_admin_cobranza en la UI, igual que hoy.)
create policy "op_log_read" on public.op_log
  for select using (
    tenant_id = public.current_tenant_id()
    and public.is_admin_or_cobranza()
  );

-- INSERCIÓN: cualquier miembro del tenant registra SU propia acción (el cobrador
-- escribe sus cobros offline). actor_id debe ser el propio auth.uid() o NULL
-- (System Admin / super_admin impersonando) → evita spoofear el actor de otro.
-- Append-only: SIN policy UPDATE/DELETE → bloqueadas.
create policy "op_log_insert" on public.op_log
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (actor_id = auth.uid() or actor_id is null)
  );
