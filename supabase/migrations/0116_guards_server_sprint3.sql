-- 0116 — Guards server-side del mega-sprint de correcciones (audit 2026-06-11,
-- Sprints 3/4: fixes #4, #9, #10, M18, M23 + filas audit fantasma).
--
-- Regla que cierra este archivo (lección 0046/0085): TODO control de dinero
-- o de integridad que un setting "apaga" tiene que vivir en el server — la
-- UI solo lo refleja. Un cobrador con su JWT puede hablarle a PostgREST
-- directo; las cascadas offline llegan en cualquier orden.

BEGIN;

-- =========================================================================
-- 1. (#4, HIGH del audit) Enforce server-side de cobrador_anula_cobros /
--    cobrador_edita_cobros. La policy 0046 dejaba al cobrador UPDATEar SUS
--    pagos vía REST aunque el admin tuviera los toggles en OFF (default):
--    vector de fraude real — cobrar en efectivo, anular por REST y quedarse
--    la plata (solo quedaba rastro en audit_log). Los toggles ahora son
--    control duro, como esperan los admins.
--    Columnas LIBRES a propósito: foto_comprobante_path (el worker de fotos
--    la setea post-upload), lat/lng, ocurrido_en, client_local_id.
--    Re-upserts idénticos de PowerSync (retry de batch) pasan: nada cambia.
-- =========================================================================
create or replace function public.pagos_guard_cobrador_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.current_user_rol() <> 'cobrador' then
    return new;
  end if;

  if new.anulado is distinct from old.anulado
     and not public.setting_bool(
           new.tenant_id, 'cobranza.cobrador_anula_cobros', false) then
    raise exception
      'Anular cobros está deshabilitado para cobradores en esta empresa';
  end if;

  if (new.monto_cordobas  is distinct from old.monto_cordobas
      or new.vuelto_cordobas is distinct from old.vuelto_cordobas
      or new.monto_original  is distinct from old.monto_original
      or new.tasa_conversion is distinct from old.tasa_conversion
      or new.metodo          is distinct from old.metodo
      or new.referencia      is distinct from old.referencia
      or new.notas           is distinct from old.notas
      or new.fecha_pago      is distinct from old.fecha_pago
      or new.cuota_id        is distinct from old.cuota_id)
     and not public.setting_bool(
           new.tenant_id, 'cobranza.cobrador_edita_cobros', false) then
    raise exception
      'Editar cobros está deshabilitado para cobradores en esta empresa';
  end if;
  return new;
end $$;

drop trigger if exists trg_pagos_guard_cobrador on public.pagos;
create trigger trg_pagos_guard_cobrador
  before update on public.pagos
  for each row execute function public.pagos_guard_cobrador_trg();

-- =========================================================================
-- 2. (#9, HIGH) Change log para `cobradores` — era la ÚNICA entidad editable
--    de las 27 sin trigger: cambiar el prefijo de recibo (numeración =
--    rastro de dinero) o desactivar a alguien no dejaba registro.
--    El cliente complementa con labels + historial en su pantalla.
-- =========================================================================
drop trigger if exists trg_changelog_cobradores on public.cobradores;
create trigger trg_changelog_cobradores
  after insert or update or delete on public.cobradores
  for each row when (pg_trigger_depth() < 2)
  execute function public.audit_changelog_trg();

-- =========================================================================
-- 3. (#10, HIGH) Transiciones de estado de inv_seriales — "server gana".
--    El write-path directo del admin (asignar/devolver/transferir) validaba
--    SOLO contra su SQLite local: dos devices offline podían asignar el
--    MISMO equipo a clientes distintos (last-writer-wins) o pisar el consumo
--    del técnico. Reglas mínimas que cierran ambos casos sin romper flujos:
--      a) pasar A 'instalado' exige venir de 'en_stock';
--      b) un 'instalado' no cambia de cliente sin pasar por stock.
--    El connector surfacea el rechazo (aviso persistente del Sprint 1).
-- =========================================================================
create or replace function public.inv_seriales_guard_transicion_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.estado = 'instalado'
     and old.estado is distinct from new.estado
     and old.estado <> 'en_stock' then
    raise exception
      'El equipo % no está en stock (estado actual: %)', old.serial, old.estado;
  end if;
  if new.estado = 'instalado' and old.estado = 'instalado'
     and new.cliente_id is distinct from old.cliente_id then
    raise exception
      'El equipo % ya está instalado en otro cliente; devolvelo a stock primero',
      old.serial;
  end if;
  return new;
end $$;

drop trigger if exists trg_inv_seriales_guard_transicion on public.inv_seriales;
create trigger trg_inv_seriales_guard_transicion
  before update on public.inv_seriales
  for each row execute function public.inv_seriales_guard_transicion_trg();

-- =========================================================================
-- 4. (M18) Correlativo de tickets: MAX+1 se calcula en el CLIENTE por
--    tenant — dos admins offline colisionaban (23505) y el ticket entero se
--    DESCARTABA de la cola. El server ahora re-asigna en conflicto: el
--    correlativo local es provisorio; el definitivo baja con el sync.
-- =========================================================================
create or replace function public.tickets_correlativo_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- `id <> new.id` (QA Fase 4): sin esto, el RE-UPSERT de un retry de
  -- PowerSync encontraba SU PROPIA fila como "conflicto" y renumeraba el
  -- ticket en cada reintento (EXCLUDED hereda el NEW post-trigger).
  if exists (select 1 from public.tickets
              where tenant_id = new.tenant_id
                and correlativo = new.correlativo
                and id <> new.id) then
    select coalesce(max(correlativo), 0) + 1
      into new.correlativo
      from public.tickets
     where tenant_id = new.tenant_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_tickets_correlativo on public.tickets;
create trigger trg_tickets_correlativo
  before insert on public.tickets
  for each row execute function public.tickets_correlativo_trg();

-- =========================================================================
-- 5. (M23) audit_log append-only TAMBIÉN para el super_admin: la
--    super_admin_all FOR ALL (0026) le permitía UPDATE/DELETE del log —
--    contradice la invariante #4. Mismo cierre que 0102 hizo para
--    inv_movimientos. El INSERT directo es legítimo (impersonación).
-- =========================================================================
drop policy if exists "super_admin_all" on public.audit_log;
drop policy if exists "super_admin_select" on public.audit_log;
drop policy if exists "super_admin_insert" on public.audit_log;
create policy "super_admin_select" on public.audit_log
  for select using (public.is_super_admin());
create policy "super_admin_insert" on public.audit_log
  for insert with check (public.is_super_admin());

-- =========================================================================
-- 6. (LOW del audit offline) Filas 'update' FANTASMA en el change log: el
--    retry de un batch parcial de PowerSync re-upserta filas idénticas y
--    cada una generaba una entrada update con old == new (ruido en los
--    historiales con conexión flaky). Guard no-op en la función genérica —
--    cubre las 28 tablas de una vez. (Cuerpo = versión 0069 + el guard.)
-- =========================================================================
create or replace function public.audit_changelog_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dev timestamptz;
begin
  if tg_op = 'UPDATE' then
    if to_jsonb(old) = to_jsonb(new) then
      return new; -- no-op (re-upsert de retry): sin entrada fantasma
    end if;
    v_dev := (to_jsonb(new)->>'ocurrido_en')::timestamptz;
    perform public.audit_registrar(
      new.tenant_id, tg_table_name, new.id, null,
      to_jsonb(old), to_jsonb(new), 'update', v_dev
    );
    return new;
  elsif tg_op = 'INSERT' then
    v_dev := (to_jsonb(new)->>'ocurrido_en')::timestamptz;
    perform public.audit_registrar(
      new.tenant_id, tg_table_name, new.id, null,
      null, to_jsonb(new), 'create', v_dev
    );
    return new;
  elsif tg_op = 'DELETE' then
    v_dev := (to_jsonb(old)->>'ocurrido_en')::timestamptz;
    perform public.audit_registrar(
      old.tenant_id, tg_table_name, old.id, null,
      to_jsonb(old), null, 'delete', v_dev
    );
    return old;
  end if;
  return null;
end;
$$;

COMMIT;

-- Verificación post-deploy (correr a mano):
--   select tgname from pg_trigger where tgrelid = 'public.pagos'::regclass
--     and tgname = 'trg_pagos_guard_cobrador';                    -- 1 fila
--   select tgname from pg_trigger where tgrelid = 'public.cobradores'::regclass
--     and tgname = 'trg_changelog_cobradores';                    -- 1 fila
--   select tgname from pg_trigger where tgrelid = 'public.inv_seriales'::regclass
--     and tgname = 'trg_inv_seriales_guard_transicion';           -- 1 fila
--   select tgname from pg_trigger where tgrelid = 'public.tickets'::regclass
--     and tgname = 'trg_tickets_correlativo';                     -- 1 fila
--   select policyname from pg_policies where tablename = 'audit_log'
--     and policyname like 'super_admin%';     -- super_admin_select + _insert
