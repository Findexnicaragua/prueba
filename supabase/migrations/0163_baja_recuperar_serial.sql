-- 0163 — Dar de baja / recuperar un equipo serializado (módulo Operaciones,
-- super_admin), identificado por su número de serie. Cierra el ciclo de vida del
-- equipo, que estaba incompleto (existía la lista de bajas pero no la ENTRADA a
-- baja). Cada acción genera su movimiento en el ledger append-only + op via
-- data_ops_log. Identificado por serial (match exacto, trim).
--
-- DAR DE BAJA: estado → 'baja' (terminal), limpia cliente_id/contrato_id. NO toca
--   ubicacion_id (si OLD='instalado', cambiar ubicación dispararía el guard de
--   "transferencia tardía"; dejándola quieta, el guard pasa). Movimiento 'baja'.
-- RECUPERAR: 'danado' → 'en_stock' en una ubicación (la del serial, o la primera
--   activa). Movimiento 'ingreso'. (baja es terminal: NO se recupera.)
-- Contrato del input card: preview→{afectados,label}, ejecutar→{afectados,mensaje}.

-- ── DAR DE BAJA: PREVIEW ───────────────────────────────────────────────────
create or replace function public.super_admin_preview_baja_serial(
  p_tenant uuid, p_serial text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_cli text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  select s.id, s.estado, c.nombre into v_id, v_estado, v_cli
    from inv_seriales s left join clientes c on c.id = s.cliente_id
   where s.tenant_id = p_tenant and s.serial = btrim(p_serial);
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el equipo "' || btrim(p_serial) || '" en este tenant.');
  end if;
  if v_estado = 'baja' then
    return jsonb_build_object('afectados', 0, 'label', 'El equipo "' || btrim(p_serial) || '" ya está dado de baja.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se dará de baja el equipo "' || btrim(p_serial) || '" (estado actual: ' || v_estado
             || coalesce(', instalado en ' || v_cli, '') || '). Es terminal.');
end; $fn$;

-- ── DAR DE BAJA: EJECUTAR ──────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_baja_serial(
  p_tenant uuid, p_serial text, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_prod uuid; v_ubic uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  select id, estado, producto_id, ubicacion_id into v_id, v_estado, v_prod, v_ubic
    from inv_seriales where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then raise exception 'No existe el equipo "%" en este tenant', btrim(p_serial); end if;
  if v_estado = 'baja' then raise exception 'El equipo "%" ya está dado de baja', btrim(p_serial); end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
    ubicacion_origen_id, motivo, hecho_por, ocurrido_en, created_at)
  values (gen_random_uuid(), p_tenant, 'baja', v_prod, v_id, 1,
    v_ubic, 'Baja de equipo (Operaciones)', auth.uid(), now(), now());
  -- NO tocamos ubicacion_id (evita el guard de transferencia tardía si era instalado).
  update inv_seriales set estado = 'baja', cliente_id = null, contrato_id = null
   where id = v_id;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'baja_serial', 'Equipo ' || btrim(p_serial),
            jsonb_build_object('equipos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Equipo "' || btrim(p_serial) || '" dado de baja.');
end; $fn$;

-- ── RECUPERAR: PREVIEW ─────────────────────────────────────────────────────
create or replace function public.super_admin_preview_recuperar_serial(
  p_tenant uuid, p_serial text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  select id, estado into v_id, v_estado
    from inv_seriales where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el equipo "' || btrim(p_serial) || '" en este tenant.');
  end if;
  if v_estado <> 'danado' then
    return jsonb_build_object('afectados', 0,
      'label', 'El equipo "' || btrim(p_serial) || '" está "' || v_estado || '": solo se recuperan los dañados.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se recuperará el equipo "' || btrim(p_serial) || '" (dañado → en stock).');
end; $fn$;

-- ── RECUPERAR: EJECUTAR ────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_recuperar_serial(
  p_tenant uuid, p_serial text, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_prod uuid; v_ubic uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  select id, estado, producto_id, ubicacion_id into v_id, v_estado, v_prod, v_ubic
    from inv_seriales where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then raise exception 'No existe el equipo "%" en este tenant', btrim(p_serial); end if;
  if v_estado <> 'danado' then
    raise exception 'El equipo "%" está "%": solo se recuperan los dañados', btrim(p_serial), v_estado;
  end if;
  -- destino: la ubicación que tenía, o la primera activa (central primero).
  if v_ubic is null then
    select id into v_ubic from inv_ubicaciones
     where tenant_id = p_tenant and activa = true
     order by (tipo = 'central') desc, nombre limit 1;
  end if;
  if v_ubic is null then raise exception 'No hay ninguna ubicación activa para recuperar el equipo'; end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
    ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  values (gen_random_uuid(), p_tenant, 'ingreso', v_prod, v_id, 1,
    v_ubic, 'Recuperación de equipo dañado (Operaciones)', auth.uid(), now(), now());
  update inv_seriales set estado = 'en_stock', ubicacion_id = v_ubic where id = v_id;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'recuperar_serial', 'Equipo ' || btrim(p_serial),
            jsonb_build_object('equipos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Equipo "' || btrim(p_serial) || '" recuperado a stock.');
end; $fn$;
