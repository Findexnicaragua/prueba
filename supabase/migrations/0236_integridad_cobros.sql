-- 0236 — Que un cobro perdido NO dependa de que un cliente reclame.
--
-- POR QUÉ: el 28-29/07/2026 se perdieron 10 cobros de Derling Merlo en Telenet
-- (COL-00020..29). El cobrador los registró, imprimió los recibos y se los dio
-- al cliente; las filas nunca llegaron al servidor. Se descubrió el 17/08, por
-- WhatsApp de un cliente al que le seguían cobrando julio. 19 días ciegos.
--
-- Ya había pasado antes: los OF-12292..12311 se backfillearon a mano (ver 0215).
--
-- Dos agujeros distintos, dos piezas acá:
--
--   1. `sync_rechazos` — cuando el server RECHAZA un write, el connector lo
--      descarta para no trabar la cola (correcto: si no, ese cobrador deja de
--      sincronizar para siempre) y hoy deja el aviso SOLO en el device
--      (RechazosSyncService → shared_preferences). Nadie más se entera: ni la
--      oficina, ni el super_admin. Y si el equipo se pierde o se reinstala, el
--      único registro del contenido desaparece. Ahora sube acá.
--
--   2. `recibos_huecos()` — un salto en el correlativo del talonario es la
--      firma inequívoca de filas que no llegaron. Se puede detectar sin que
--      nadie reclame.
--
-- OJO con el ALCANCE de (2): hasta 0215 (01/08/2026) el correlativo lo asignaba
-- el DEVICE, así que un hueco = filas perdidas. Desde 0215 lo asigna el server
-- con un contador atómico, que no saltea → un hueco nuevo significa otra cosa
-- (rollback tras consumir número, o borrado). En los dos casos hay que mirarlo.

begin;

-- ── 1) Rechazos de sync, en el SERVIDOR ─────────────────────────────────────
create table if not exists public.sync_rechazos (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references public.tenants(id) on delete cascade,
  cobrador_id   uuid,
  tabla         text not null,
  registro_id   text not null,
  op            text not null,               -- put | patch | delete
  codigo        text,                        -- SQLSTATE del rechazo
  mensaje       text,
  payload       jsonb,                       -- el write completo, para rehacerlo
  ocurrido_en   timestamptz not null,        -- cuándo falló en el device
  created_at    timestamptz not null default now(),
  resuelto      boolean not null default false,
  resuelto_en   timestamptz,
  resuelto_por  uuid
);

create index if not exists sync_rechazos_lookup
  on public.sync_rechazos (tenant_id, resuelto, ocurrido_en desc);

alter table public.sync_rechazos enable row level security;

-- INSERT deliberadamente PERMISIVO: basta estar autenticado.
--
-- Es el punto clave de todo esto. Si le pusiéramos las mismas condiciones que
-- a `pagos` (tenant_id = current_tenant_id(), rol, etc.), el aviso podría ser
-- rechazado POR EL MISMO MOTIVO que hizo fallar al cobro — y volveríamos al
-- punto de partida, sin rastro. Una tabla de alertas tiene que aceptar
-- cualquier alerta; el filtro va en la LECTURA, no en la escritura.
create policy sync_rechazos_insert on public.sync_rechazos
  for insert to authenticated with check (true);

-- Lectura: admin/cobranza de su tenant.
create policy sync_rechazos_read on public.sync_rechazos
  for select using (
    tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza()
  );

-- Marcar resuelto: mismo alcance que la lectura.
create policy sync_rechazos_update on public.sync_rechazos
  for update using (
    tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza()
  ) with check (
    tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza()
  );

-- super_admin_all A MANO (R10): sin esto el super_admin impersonando no puede
-- escribir — su current_tenant_id() no matchea el tenant impersonado. Es el
-- bug que tuvo op_log entre 0128 y 0131.
create policy sync_rechazos_super_all on public.sync_rechazos
  for all using (public.is_super_admin()) with check (public.is_super_admin());

comment on table public.sync_rechazos is
  'Writes que el servidor RECHAZÓ y el connector descartó. El payload es el '
  'único registro del contenido: sirve para rehacer el cobro a mano. '
  'INSERT permisivo a propósito (0236).';

-- ── 2) Huecos en el talonario ───────────────────────────────────────────────
--
-- Devuelve SOLO los huecos reales. Descarta dos fuentes de falso positivo que
-- inflaban el resultado de 6 a 19 huecos y de 11 a 90 recibos:
--
--   a. IMPORTADOS del sistema viejo: 21.538 de los 25.095 recibos de Mairena
--      tienen created_at a medianoche UTC (venían con fecha, sin hora). Sus
--      correlativos son del talonario ANTERIOR y sus huecos no son nuestros.
--      Se detectan porque el recibo "siguiente" tiene fecha ANTERIOR al previo
--      — imposible en algo secuencial de verdad.
--   b. Solo se reporta el hueco si AMBOS extremos son recibos generados por la
--      app (con hora real). Un importado en el medio no cuenta.
create or replace function public.recibos_huecos()
returns table (
  tenant        text,
  prefijo       text,
  cobrador      text,
  desde         int,
  hasta         int,
  faltan        int,
  ok_antes      timestamptz,
  ok_despues    timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  with r as (
    select t.nombre as tenant, r.prefijo, r.correlativo, r.created_at,
           (r.created_at::time <> '00:00:00') as real_now,
           lag(r.correlativo) over w as prev_corr,
           lag(r.created_at)  over w as prev_at,
           lag(r.cobrador_id) over w as prev_cob,
           lag(r.created_at::time <> '00:00:00') over w as prev_real
    from public.recibos r
    join public.tenants t on t.id = r.tenant_id
    window w as (partition by r.tenant_id, r.prefijo order by r.correlativo)
  )
  select r.tenant, r.prefijo, coalesce(co.nombre, '?') as cobrador,
         r.prev_corr + 1, r.correlativo - 1, (r.correlativo - r.prev_corr - 1),
         r.prev_at, r.created_at
  from r left join public.cobradores co on co.id = r.prev_cob
  where r.correlativo - r.prev_corr > 1
    and r.real_now and r.prev_real
  order by (r.correlativo - r.prev_corr - 1) desc, r.tenant, r.prefijo;
$fn$;

revoke all on function public.recibos_huecos() from public;
grant execute on function public.recibos_huecos() to authenticated;

comment on function public.recibos_huecos() is
  'Huecos REALES en el correlativo de recibos (excluye importados del sistema '
  'viejo). Un hueco = filas que el device creó y el server nunca recibió (0236).';

commit;

-- Verificación (correr aparte):
--   select * from public.recibos_huecos();
--   -- Al 17/08/2026 devuelve 6 filas; la única con perfil de cobro en calle es
--   -- Telenet/COL 20-29 (Derling, 28→30 jul). El resto son tandas de testing
--   -- (clientes 'PRUEBA' y 'Juan Diaz Perez').
