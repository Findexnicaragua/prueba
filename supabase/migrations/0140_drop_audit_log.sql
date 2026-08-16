-- 0140 — Eliminar por completo el sistema `audit_log` (forense server-side).
--
-- Decisión de Rubén (2026-06-21): `op_log` (change-log escrito por el cliente)
-- cubre el historial que la app muestra; `audit_log` era forense/debug y casi no
-- se usaba (1 panel gateado + el RPC list_audit_cobrador + config de campos).
-- Se elimina TODO el sistema audit_log. `op_log` NO se toca.
--
-- ⚠️ MIGRACIÓN DESTRUCTIVA — ORDEN DE DEPLOY OBLIGATORIO (prod):
--   1) Deployar las edge functions SIN inserts a audit_log (forzar-password,
--      eliminar-cobrador, cambiar-email, reenviar-invitacion).
--   2) Releasear la app SIN el panel /admin/audit, sin el insert de impersonación,
--      sin la tabla en schema.dart, sin el RPC list_audit_cobrador.
--   3) Flipear las sync rules (sacar audit_log de los 3 buckets) en PowerSync.
--   4) RECIÉN AHÍ correr esta migración.
-- Si se corre antes, los escritores vivos (triggers→no; edge/impersonación→sí)
-- y lectores (panel/RPC) fallan. Los triggers se van acá (server-side, instantáneo
-- para todos). Lista de triggers/funciones VERIFICADA contra prod (vxxz).

begin;

-- ── 1) Triggers de change-log (todos llaman audit_changelog_trg) + settings ──
drop trigger if exists trg_audit_settings              on public.settings;
drop trigger if exists trg_changelog_cargos_extra      on public.cargos_extra;
drop trigger if exists trg_changelog_cliente_etiquetas on public.cliente_etiquetas;
drop trigger if exists trg_changelog_clientes          on public.clientes;
drop trigger if exists trg_changelog_cobradores        on public.cobradores;
drop trigger if exists trg_changelog_comunidades       on public.comunidades;
drop trigger if exists trg_changelog_contrato_suspensiones on public.contrato_suspensiones;
drop trigger if exists trg_changelog_contratos         on public.contratos;
drop trigger if exists trg_changelog_cuotas            on public.cuotas;
drop trigger if exists trg_changelog_departamentos     on public.departamentos;
drop trigger if exists trg_changelog_etiquetas         on public.etiquetas;
drop trigger if exists trg_changelog_fotos_cliente     on public.fotos_cliente;
drop trigger if exists trg_changelog_incidentes        on public.incidentes;
drop trigger if exists trg_changelog_inv_categorias    on public.inv_categorias;
drop trigger if exists trg_changelog_inv_movimientos   on public.inv_movimientos;
drop trigger if exists trg_changelog_inv_productos     on public.inv_productos;
drop trigger if exists trg_changelog_inv_proveedores   on public.inv_proveedores;
drop trigger if exists trg_changelog_inv_seriales      on public.inv_seriales;
drop trigger if exists trg_changelog_inv_ubicaciones   on public.inv_ubicaciones;
drop trigger if exists trg_changelog_municipios        on public.municipios;
drop trigger if exists trg_changelog_pagos             on public.pagos;
drop trigger if exists trg_changelog_planes            on public.planes;
drop trigger if exists trg_changelog_recibos           on public.recibos;
drop trigger if exists trg_changelog_red_hubs          on public.red_hubs;
drop trigger if exists trg_changelog_red_nodos         on public.red_nodos;
drop trigger if exists trg_changelog_red_puertos       on public.red_puertos;
drop trigger if exists trg_changelog_saldos_favor      on public.saldos_favor;
drop trigger if exists trg_changelog_ticket_adjuntos   on public.ticket_adjuntos;
drop trigger if exists trg_changelog_ticket_eventos    on public.ticket_eventos;
drop trigger if exists trg_changelog_ticket_materiales on public.ticket_materiales;
drop trigger if exists trg_changelog_ticket_tipos      on public.ticket_tipos;
drop trigger if exists trg_changelog_tickets           on public.tickets;
drop trigger if exists trg_changelog_visitas           on public.visitas;

-- ── 2) Funciones (changelog + deprecated huérfanas + reset + el RPC) ──────────
drop function if exists public.audit_changelog_trg();
drop function if exists public.audit_settings_trg();
drop function if exists public.audit_clientes_cobrador_trg();
drop function if exists public.audit_cuotas_anulacion_trg();
drop function if exists public.audit_pagos_anulacion_trg();
drop function if exists public.audit_recibos_anulacion_trg();
drop function if exists public.audit_registrar(uuid, text, uuid, text, jsonb, jsonb, text, timestamptz);
drop function if exists public.audit_reset_password(uuid);
drop function if exists public.list_audit_cobrador(uuid, integer);

-- ── 2b) RPCs vivos que insertaban en audit_log → redefinir SIN ese insert ─────
-- (set_cobrador_rol/activo + set_tenant_modulo los llama el panel super_admin;
-- si no se redefinen, revientan al dropear la tabla). Idempotentes.
create or replace function public.set_cobrador_rol(p_cobrador_id uuid, p_nuevo_rol text)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_target_rol text;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;
  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio rol';
  end if;
  if p_nuevo_rol not in ('admin','admin_cobranza','cobrador','tecnico','admin_tickets') then
    raise exception 'Rol inválido. Permitidos: admin, admin_cobranza, cobrador, tecnico, admin_tickets';
  end if;
  select rol into v_target_rol from public.cobradores where id = p_cobrador_id for update;
  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;
  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar el rol de otro super_admin';
  end if;
  if v_target_rol = p_nuevo_rol then
    return;
  end if;
  update public.cobradores
     set rol = p_nuevo_rol,
         prefijo_recibo = case when p_nuevo_rol in ('cobrador','admin','admin_cobranza')
                               then prefijo_recibo else null end
   where id = p_cobrador_id;
end;
$fn$;

create or replace function public.set_cobrador_activo(p_cobrador_id uuid, p_activo boolean)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_target_rol    text;
  v_target_activo boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;
  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio estado';
  end if;
  select rol, activo into v_target_rol, v_target_activo
    from public.cobradores where id = p_cobrador_id;
  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;
  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar a otro super_admin';
  end if;
  if v_target_activo = p_activo then
    return;
  end if;
  update public.cobradores set activo = p_activo where id = p_cobrador_id;
end;
$fn$;

create or replace function public.set_tenant_modulo(p_tenant_id uuid, p_modulo text, p_habilitado boolean)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_es_base boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;
  if p_tenant_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'No se puede modificar el tenant System';
  end if;
  select es_base into v_es_base from public.modulos where codigo = p_modulo;
  if v_es_base is null then
    raise exception 'Módulo % no existe', p_modulo;
  end if;
  if v_es_base and not p_habilitado then
    raise exception 'Módulo % es base y no se puede deshabilitar', p_modulo;
  end if;
  insert into public.tenant_modulos (tenant_id, modulo_codigo, habilitado, habilitado_en, habilitado_por)
  values (p_tenant_id, p_modulo, p_habilitado, now(), auth.uid())
  on conflict (tenant_id, modulo_codigo) do update
    set habilitado     = excluded.habilitado,
        habilitado_en  = excluded.habilitado_en,
        habilitado_por = excluded.habilitado_por;
end;
$fn$;

-- ── 3) Setting del PANEL muerto (cobranza.audit_visible_admin) ────────────────
-- OJO: NO tocar 'audit.visible_admin_cobranza' — pese al nombre "audit", gatea un
-- historial de op_log VIVO (pagos_admin_screen → HistorialOpLog para admin_cobranza).
-- Tampoco 'audit.campos_visibles' se borra acá (queda huérfano inofensivo; el
-- configurador viejo se retira del lado app).
delete from public.settings where clave = 'cobranza.audit_visible_admin';

-- ── 4) La tabla (PUNTO DE NO RETORNO — se va el histórico forense) ────────────
drop table if exists public.audit_log;

-- Verificación
select 'triggers_audit_restantes' as chk, count(*) as n
  from pg_trigger t join pg_proc p on p.oid=t.tgfoid
  where not t.tgisinternal and (p.proname ilike '%audit%' or p.proname ilike '%changelog%')
union all
select 'audit_log_existe', case when to_regclass('public.audit_log') is null then 0 else 1 end;

commit;
