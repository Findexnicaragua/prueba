-- 0225 — saber QUÉ VERSIÓN de la app corre cada dispositivo.
--
-- POR QUÉ. Hasta ahora no había forma de saberlo: no existe ninguna columna de
-- versión en la base. Eso hizo que dos auditorías sacaran conclusiones falsas al
-- leer datos de producción como si los hubiera producido el código de `main`
-- (audit 2026-08-09: se dio por "agujero vivo" algo que ya estaba arreglado, y
-- se explicó por "versiones viejas" un campo que nunca existió). También es lo
-- que impide responder "¿el digitador ya tiene el guard?" sin preguntarle.
--
-- DISEÑO. Es TELEMETRÍA, no dato de negocio:
--   · NO entra al schema de PowerSync. La app la escribe DIRECTO por Supabase al
--     abrir sesión, best-effort — si falla, no pasa nada. Así no ocupa lugar en
--     la cola de sync ni compite con los writes que sí importan.
--   · Una fila por DISPOSITIVO (no por sesión): se upsertea. No crece sin techo.
--   · Sin FK a `cobradores`: si se borra el usuario, la telemetría no debe
--     bloquear el borrado ni desaparecer.
create table if not exists public.app_dispositivos (
  id           uuid primary key,          -- id estable del install (lo genera el device)
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  usuario_id   uuid not null,             -- auth.uid() — sin FK, ver arriba
  usuario_nombre text,                    -- desnormalizado: sobrevive al borrado
  rol          text,
  version      text not null,             -- "0.31.26+249"
  plataforma   text,                      -- windows | android | otro
  modelo       text,                      -- para correlacionar bugs de impresora
  primera_vez  timestamptz not null default now(),
  visto_en     timestamptz not null default now()
);

create index if not exists app_dispositivos_tenant_visto_idx
  on public.app_dispositivos (tenant_id, visto_en desc);
create index if not exists app_dispositivos_version_idx
  on public.app_dispositivos (version);

alter table public.app_dispositivos enable row level security;

-- El dispositivo se reporta a SÍ MISMO. No puede escribir la fila de otro.
drop policy if exists app_disp_self_insert on public.app_dispositivos;
create policy app_disp_self_insert on public.app_dispositivos
  for insert to authenticated
  with check (tenant_id = current_tenant_id() and usuario_id = auth.uid());

drop policy if exists app_disp_self_update on public.app_dispositivos;
create policy app_disp_self_update on public.app_dispositivos
  for update to authenticated
  using (tenant_id = current_tenant_id() and usuario_id = auth.uid())
  with check (tenant_id = current_tenant_id() and usuario_id = auth.uid());

-- Leer: el admin del tenant (para saber a quién le falta actualizar).
drop policy if exists app_disp_read on public.app_dispositivos;
create policy app_disp_read on public.app_dispositivos
  for select to authenticated
  using (tenant_id = current_tenant_id() and is_admin_or_cobranza());

-- Toda tabla tenant-scoped nace con esta policy A MANO (regla de AGENTS R10):
-- sin ella el super_admin impersonando no puede escribir, porque su
-- current_tenant_id() no matchea el tenant impersonado.
drop policy if exists super_admin_all on public.app_dispositivos;
create policy super_admin_all on public.app_dispositivos
  for all to authenticated
  using (is_super_admin()) with check (is_super_admin());

comment on table public.app_dispositivos is
  'Telemetria: que version de la app corre cada dispositivo. La escribe el propio '
  'device al abrir sesion, DIRECTO por Supabase (no por PowerSync). Una fila por '
  'install, se upsertea. Sirve para saber si un fix ya llego a la gente antes de '
  'sacar conclusiones sobre datos de produccion.';
