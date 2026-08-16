-- 0147 — Funciones del panel "Operaciones de datos" (super_admin).
--
-- 6 funciones SECURITY DEFINER que respaldan el panel de corrección de errores
-- de carga: 3 de PREVIEW (cuentan, NO borran) + 3 de EJECUTAR (snapshot atómico
-- a data_op_backups → borrado en orden FK → limpieza de op_log → registro en
-- data_ops_log). Todas arrancan con el gate `is_super_admin()` (usa auth.uid()
-- → chequea al LLAMADOR, no al definer) + validan que el target pertenezca al
-- tenant en contexto (`p_tenant`, defensa en profundidad: el server reproduce
-- el scope que la UI ya filtra client-side).
--
-- ORDEN DE BORRADO (derivado de las FK reales — CRÍTICO):
--   · pagos.cuota_id es NO ACTION → SIEMPRE borrar `pagos` ANTES que cuotas/
--     contratos (si no, el delete de cuotas falla por la FK).
--   · recibos.pago_id CASCADE → los recibos se van solos al borrar pagos.
--   · cuotas.contrato_id, contrato_suspensiones.contrato_id, cargos_extra.cuota_id,
--     notificaciones_mora.cuota_id, saldos_favor.contrato_id/cliente_id → CASCADE.
--   · cliente_etiquetas/contratos/fotos_cliente/saldos_favor/visitas.cliente_id
--     CASCADE; inv_seriales/inv_movimientos/tickets.cliente_id SET NULL (se
--     desvinculan, NO se borran).
-- Por eso: borrar pagos del scope PRIMERO, después un solo delete del contenedor
-- (contrato o cliente) deja que el CASCADE arrastre el resto.
--
-- SNAPSHOT COMPLETO: el backup incluye TODAS las tablas que el borrado elimina
-- (incl. cargos_extra + notificaciones_mora que caen por cascade de cuotas, y
-- saldos_favor) → restauración fiel.
--
-- op_log: es CLIENT-written, append-only (0128) — NO lo escriben triggers server.
-- El `delete from op_log where entidad_id=any(v_ids)` limpia el historial de
-- intención PREEXISTENTE de las entidades borradas. v_ids se captura ANTES.
--
-- Idempotente: todas son CREATE OR REPLACE; re-correr la migración es seguro.

begin;

-- Drop de firmas viejas (idempotencia: por si se corrió una versión previa con
-- otra aridad — al agregar p_tenant cambia la firma y quedarían overloads que
-- harían ambigua la resolución de PostgREST).
drop function if exists public.super_admin_preview_limpiar_cliente(uuid);
drop function if exists public.super_admin_preview_eliminar_contrato(uuid);
drop function if exists public.super_admin_preview_eliminar_cliente(uuid);
drop function if exists public.super_admin_ejecutar_limpiar_cliente(uuid, text);
drop function if exists public.super_admin_ejecutar_eliminar_contrato(uuid, text);
drop function if exists public.super_admin_ejecutar_eliminar_cliente(uuid, text);

-- ════════════════════════════════════════════════════════════════════════════
-- PREVIEW — limpiar cliente (conserva el cliente, borra su cobranza)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_preview_limpiar_cliente(p_cliente uuid, p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_label text; v_tenant uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo||' — ','')||nombre into v_tenant, v_label from clientes where id=p_cliente;
  if v_tenant is null then raise exception 'Cliente no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El cliente no pertenece al tenant en contexto'; end if;
  return jsonb_build_object(
    'target_label', v_label,
    'conserva', 'El cliente (datos, ubicación, etiquetas, fotos) se conserva. Se borra solo su cobranza.',
    'afectados', jsonb_build_object(
      'contratos',(select count(*) from contratos where cliente_id=p_cliente),
      'cuotas',(select count(*) from cuotas where cliente_id=p_cliente),
      'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
      'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
      'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
      'suspensiones',(select count(*) from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente)));
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- PREVIEW — eliminar contrato (un solo contrato del cliente)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_preview_eliminar_contrato(p_contrato uuid, p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_label text; v_tenant uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo, id::text) into v_tenant, v_label from contratos where id=p_contrato;
  if v_tenant is null then raise exception 'Contrato no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El contrato no pertenece al tenant en contexto'; end if;
  return jsonb_build_object(
    'target_label', v_label,
    'conserva', 'El cliente se conserva. Se borra solo este contrato y su cobranza.',
    'afectados', jsonb_build_object(
      'contratos', 1,
      'cuotas',(select count(*) from cuotas where contrato_id=p_contrato),
      'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
      'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
      'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.contrato_id=p_contrato),
      'suspensiones',(select count(*) from contrato_suspensiones where contrato_id=p_contrato)));
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- PREVIEW — eliminar cliente (borra TODO + el cliente)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_preview_eliminar_cliente(p_cliente uuid, p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_label text; v_tenant uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo||' — ','')||nombre into v_tenant, v_label from clientes where id=p_cliente;
  if v_tenant is null then raise exception 'Cliente no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El cliente no pertenece al tenant en contexto'; end if;
  return jsonb_build_object(
    'target_label', v_label,
    'conserva', 'NADA del cliente se conserva (inventario y tickets quedan desvinculados, no se borran).',
    'afectados', jsonb_build_object(
      'cliente', 1,
      'contratos',(select count(*) from contratos where cliente_id=p_cliente),
      'cuotas',(select count(*) from cuotas where cliente_id=p_cliente),
      'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
      'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
      'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
      'suspensiones',(select count(*) from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
      'etiquetas',(select count(*) from cliente_etiquetas where cliente_id=p_cliente),
      'fotos',(select count(*) from fotos_cliente where cliente_id=p_cliente),
      'visitas',(select count(*) from visitas where cliente_id=p_cliente)));
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- EJECUTAR — limpiar cliente (CONSERVA el cliente, borra su cobranza)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_ejecutar_limpiar_cliente(p_cliente uuid, p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_tenant uuid; v_label text; v_snapshot jsonb; v_afectados jsonb; v_backup_id uuid; v_ids uuid[];
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo||' — ','')||nombre into v_tenant, v_label from clientes where id=p_cliente;
  if v_tenant is null then raise exception 'Cliente no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El cliente no pertenece al tenant en contexto'; end if;
  select array_agg(id) into v_ids from (
    select id from contratos where cliente_id=p_cliente
    union select id from cuotas where cliente_id=p_cliente
    union select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente
    union select r.id from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente
    union select cs.id from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente) x;
  v_snapshot := jsonb_build_object(
    'contratos',(select coalesce(jsonb_agg(t),'[]') from contratos t where t.cliente_id=p_cliente),
    'cuotas',(select coalesce(jsonb_agg(t),'[]') from cuotas t where t.cliente_id=p_cliente),
    'pagos',(select coalesce(jsonb_agg(p),'[]') from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'recibos',(select coalesce(jsonb_agg(r),'[]') from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'cargos_extra',(select coalesce(jsonb_agg(ce),'[]') from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
    'notificaciones_mora',(select coalesce(jsonb_agg(nm),'[]') from notificaciones_mora nm join cuotas c on c.id=nm.cuota_id where c.cliente_id=p_cliente),
    'contrato_suspensiones',(select coalesce(jsonb_agg(cs),'[]') from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
    'op_log',(select coalesce(jsonb_agg(o),'[]') from op_log o where o.entidad_id = any(v_ids)));
  v_afectados := jsonb_build_object(
    'contratos',(select count(*) from contratos where cliente_id=p_cliente),
    'cuotas',(select count(*) from cuotas where cliente_id=p_cliente),
    'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
    'suspensiones',(select count(*) from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
    'historial',(select count(*) from op_log o where o.entidad_id = any(v_ids)));
  insert into data_op_backups(tenant_id,operacion,target_label,snapshot,actor_id,actor_label)
    values (v_tenant,'limpiar_cliente',v_label,v_snapshot,auth.uid(),p_actor_label) returning id into v_backup_id;
  delete from pagos where id in (select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente);
  delete from contratos where cliente_id=p_cliente;
  delete from op_log where entidad_id = any(v_ids);
  insert into data_ops_log(tenant_id,operacion,target_label,afectados,backup_id,actor_id,actor_label)
    values (v_tenant,'limpiar_cliente',v_label,v_afectados,v_backup_id,auth.uid(),p_actor_label);
  return jsonb_build_object('ok',true,'backup_id',v_backup_id,'afectados',v_afectados,'target_label',v_label);
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- EJECUTAR — eliminar contrato (un solo contrato; cliente intacto)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_ejecutar_eliminar_contrato(p_contrato uuid, p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_tenant uuid; v_label text; v_cliente uuid; v_saldo_resto numeric;
        v_snapshot jsonb; v_afectados jsonb; v_backup_id uuid; v_ids uuid[];
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo, id::text), cliente_id into v_tenant, v_label, v_cliente
    from contratos where id=p_contrato;
  if v_tenant is null then raise exception 'Contrato no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El contrato no pertenece al tenant en contexto'; end if;
  -- GUARD de crédito (cross-contrato): el saldo a favor es a nivel CLIENTE y
  -- cruza contratos. Borrar las filas saldos_favor de ESTE contrato (cascade)
  -- sin las del otro contrato descuadraría el libro. Bloqueamos si, al sacar
  -- las filas de este contrato, el saldo restante del cliente quedaría NEGATIVO
  -- (= este contrato originó crédito que se consumió en otro contrato).
  select coalesce(sum(case
           when tipo='acreditado' then monto
           when tipo in ('aplicado','devuelto','condonado','revertido') then -monto
           else 0 end), 0)
    into v_saldo_resto
    from saldos_favor
   where cliente_id = v_cliente
     and (contrato_id is null or contrato_id <> p_contrato);
  if v_saldo_resto < -0.005 then
    raise exception 'No se puede eliminar solo este contrato: el cliente tiene crédito a favor que cruza contratos y quedaría inconsistente (saldo negativo). Usá "Eliminar cliente completo" o pedí ayuda.';
  end if;
  select array_agg(id) into v_ids from (
    select id from contratos where id=p_contrato
    union select id from cuotas where contrato_id=p_contrato
    union select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato
    union select r.id from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato
    union select id from contrato_suspensiones where contrato_id=p_contrato) x;
  v_snapshot := jsonb_build_object(
    'contratos',(select coalesce(jsonb_agg(t),'[]') from contratos t where t.id=p_contrato),
    'cuotas',(select coalesce(jsonb_agg(t),'[]') from cuotas t where t.contrato_id=p_contrato),
    'pagos',(select coalesce(jsonb_agg(p),'[]') from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
    'recibos',(select coalesce(jsonb_agg(r),'[]') from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
    'cargos_extra',(select coalesce(jsonb_agg(ce),'[]') from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.contrato_id=p_contrato),
    'notificaciones_mora',(select coalesce(jsonb_agg(nm),'[]') from notificaciones_mora nm join cuotas c on c.id=nm.cuota_id where c.contrato_id=p_contrato),
    'contrato_suspensiones',(select coalesce(jsonb_agg(t),'[]') from contrato_suspensiones t where t.contrato_id=p_contrato),
    'saldos_favor',(select coalesce(jsonb_agg(t),'[]') from saldos_favor t where t.contrato_id=p_contrato),
    'op_log',(select coalesce(jsonb_agg(o),'[]') from op_log o where o.entidad_id = any(v_ids)));
  v_afectados := jsonb_build_object(
    'contratos', 1,
    'cuotas',(select count(*) from cuotas where contrato_id=p_contrato),
    'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
    'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato),
    'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.contrato_id=p_contrato),
    'suspensiones',(select count(*) from contrato_suspensiones where contrato_id=p_contrato),
    'historial',(select count(*) from op_log o where o.entidad_id = any(v_ids)));
  insert into data_op_backups(tenant_id,operacion,target_label,snapshot,actor_id,actor_label)
    values (v_tenant,'eliminar_contrato',v_label,v_snapshot,auth.uid(),p_actor_label) returning id into v_backup_id;
  delete from pagos where id in (select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.contrato_id=p_contrato);
  delete from contratos where id=p_contrato;
  delete from op_log where entidad_id = any(v_ids);
  insert into data_ops_log(tenant_id,operacion,target_label,afectados,backup_id,actor_id,actor_label)
    values (v_tenant,'eliminar_contrato',v_label,v_afectados,v_backup_id,auth.uid(),p_actor_label);
  return jsonb_build_object('ok',true,'backup_id',v_backup_id,'afectados',v_afectados,'target_label',v_label);
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- EJECUTAR — eliminar cliente (borra TODO + el cliente)
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.super_admin_ejecutar_eliminar_cliente(p_cliente uuid, p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_tenant uuid; v_label text; v_snapshot jsonb; v_afectados jsonb; v_backup_id uuid; v_ids uuid[];
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  select tenant_id, coalesce(codigo||' — ','')||nombre into v_tenant, v_label from clientes where id=p_cliente;
  if v_tenant is null then raise exception 'Cliente no existe'; end if;
  if v_tenant <> p_tenant then raise exception 'El cliente no pertenece al tenant en contexto'; end if;
  select array_agg(id) into v_ids from (
    select p_cliente as id
    union select id from contratos where cliente_id=p_cliente
    union select id from cuotas where cliente_id=p_cliente
    union select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente
    union select r.id from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente
    union select cs.id from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente) x;
  v_snapshot := jsonb_build_object(
    'cliente',(select coalesce(jsonb_agg(t),'[]') from clientes t where t.id=p_cliente),
    'contratos',(select coalesce(jsonb_agg(t),'[]') from contratos t where t.cliente_id=p_cliente),
    'cuotas',(select coalesce(jsonb_agg(t),'[]') from cuotas t where t.cliente_id=p_cliente),
    'pagos',(select coalesce(jsonb_agg(p),'[]') from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'recibos',(select coalesce(jsonb_agg(r),'[]') from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'cargos_extra',(select coalesce(jsonb_agg(ce),'[]') from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
    'notificaciones_mora',(select coalesce(jsonb_agg(nm),'[]') from notificaciones_mora nm join cuotas c on c.id=nm.cuota_id where c.cliente_id=p_cliente),
    'contrato_suspensiones',(select coalesce(jsonb_agg(cs),'[]') from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
    'cliente_etiquetas',(select coalesce(jsonb_agg(t),'[]') from cliente_etiquetas t where t.cliente_id=p_cliente),
    'fotos_cliente',(select coalesce(jsonb_agg(t),'[]') from fotos_cliente t where t.cliente_id=p_cliente),
    'visitas',(select coalesce(jsonb_agg(t),'[]') from visitas t where t.cliente_id=p_cliente),
    'saldos_favor',(select coalesce(jsonb_agg(t),'[]') from saldos_favor t where t.cliente_id=p_cliente),
    'op_log',(select coalesce(jsonb_agg(o),'[]') from op_log o where o.entidad_id = any(v_ids)));
  v_afectados := jsonb_build_object(
    'cliente', 1,
    'contratos',(select count(*) from contratos where cliente_id=p_cliente),
    'cuotas',(select count(*) from cuotas where cliente_id=p_cliente),
    'pagos',(select count(*) from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'recibos',(select count(*) from recibos r join pagos p on p.id=r.pago_id join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente),
    'cargos',(select count(*) from cargos_extra ce join cuotas c on c.id=ce.cuota_id where c.cliente_id=p_cliente),
    'suspensiones',(select count(*) from contrato_suspensiones cs join contratos ct on ct.id=cs.contrato_id where ct.cliente_id=p_cliente),
    'etiquetas',(select count(*) from cliente_etiquetas where cliente_id=p_cliente),
    'fotos',(select count(*) from fotos_cliente where cliente_id=p_cliente),
    'visitas',(select count(*) from visitas where cliente_id=p_cliente),
    'historial',(select count(*) from op_log o where o.entidad_id = any(v_ids)));
  insert into data_op_backups(tenant_id,operacion,target_label,snapshot,actor_id,actor_label)
    values (v_tenant,'eliminar_cliente',v_label,v_snapshot,auth.uid(),p_actor_label) returning id into v_backup_id;
  delete from pagos where id in (select p.id from pagos p join cuotas c on c.id=p.cuota_id where c.cliente_id=p_cliente);
  delete from clientes where id=p_cliente;
  delete from op_log where entidad_id = any(v_ids);
  insert into data_ops_log(tenant_id,operacion,target_label,afectados,backup_id,actor_id,actor_label)
    values (v_tenant,'eliminar_cliente',v_label,v_afectados,v_backup_id,auth.uid(),p_actor_label);
  return jsonb_build_object('ok',true,'backup_id',v_backup_id,'afectados',v_afectados,'target_label',v_label);
end; $fn$;

commit;

-- Verificación: las 6 funciones existen con la firma nueva (p_tenant).
select proname, pronargs from pg_proc
 where proname like 'super_admin_%_cliente' or proname like 'super_admin_%_contrato'
 order by proname;
