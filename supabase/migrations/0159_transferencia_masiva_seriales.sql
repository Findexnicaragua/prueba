-- 0159 — Transferencia masiva de equipos entre ubicaciones (módulo Operaciones,
-- super_admin). Mueve TODOS los seriales en_stock de una ubicación a otra, de un
-- golpe. Por cada serial: (1) inserta un movimiento 'transferencia' en el ledger
-- append-only (origen → destino), (2) actualiza inv_seriales.ubicacion_id. El
-- orden importa: primero los movimientos (capturan el origen real), después el
-- UPDATE. Respeta el guard de transiciones (en_stock cambia ubicación libremente;
-- un 'instalado' NO se transfiere — por eso solo en_stock).
--
-- Caso de uso: consolidar bodegas o redistribuir la custodia de un técnico que
-- se va. Patrón data-ops (0147/0154): SECURITY DEFINER + gate + p_tenant +
-- preview (cuenta) + ejecutar (log). Reversible corriéndolo al revés.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_transferir_serial(
  p_tenant uuid, p_origen uuid, p_destino uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is null then raise exception 'Elegí la ubicación de origen'; end if;
  if p_destino is null then raise exception 'Elegí la ubicación de destino'; end if;
  if p_origen = p_destino then raise exception 'La ubicación de origen y la de destino son la misma'; end if;
  if not exists (select 1 from inv_ubicaciones where id = p_destino and tenant_id = p_tenant and activa = true) then
    raise exception 'La ubicación de destino no existe, no está activa, o no es de este tenant';
  end if;
  if not exists (select 1 from inv_ubicaciones where id = p_origen and tenant_id = p_tenant) then
    raise exception 'La ubicación de origen no pertenece a este tenant';
  end if;
  select count(*) into v_afectados from inv_seriales
    where tenant_id = p_tenant and estado = 'en_stock' and ubicacion_id = p_origen;
  select nombre into v_origen_label  from inv_ubicaciones where id = p_origen;
  select nombre into v_destino_label from inv_ubicaciones where id = p_destino;
  return jsonb_build_object(
    'afectados', v_afectados,
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_transferir_serial(
  p_tenant uuid, p_origen uuid, p_destino uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is null then raise exception 'Elegí la ubicación de origen'; end if;
  if p_destino is null then raise exception 'Elegí la ubicación de destino'; end if;
  if p_origen = p_destino then raise exception 'La ubicación de origen y la de destino son la misma'; end if;
  if not exists (select 1 from inv_ubicaciones where id = p_destino and tenant_id = p_tenant and activa = true) then
    raise exception 'La ubicación de destino no existe, no está activa, o no es de este tenant';
  end if;
  if not exists (select 1 from inv_ubicaciones where id = p_origen and tenant_id = p_tenant) then
    raise exception 'La ubicación de origen no pertenece a este tenant';
  end if;
  select nombre into v_origen_label  from inv_ubicaciones where id = p_origen;
  select nombre into v_destino_label from inv_ubicaciones where id = p_destino;

  -- 1. Movimientos PRIMERO (mientras los seriales todavía están en el origen).
  insert into inv_movimientos(
    id, tenant_id, tipo, producto_id, serial_id, cantidad,
    ubicacion_origen_id, ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  select gen_random_uuid(), s.tenant_id, 'transferencia', s.producto_id, s.id, 1,
         p_origen, p_destino, 'Transferencia masiva (Operaciones)', auth.uid(), now(), now()
    from inv_seriales s
   where s.tenant_id = p_tenant and s.estado = 'en_stock' and s.ubicacion_id = p_origen;

  -- 2. UPDATE de la ubicación denormalizada del serial.
  with upd as (
    update inv_seriales set ubicacion_id = p_destino
     where tenant_id = p_tenant and estado = 'en_stock' and ubicacion_id = p_origen
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then
    raise exception 'No hay equipos en stock en "%" para transferir', v_origen_label;
  end if;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'transferir_serial',
            v_origen_label || ' → ' || v_destino_label,
            jsonb_build_object('equipos', v_afectados),
            null, auth.uid(), p_actor_label);
  return jsonb_build_object(
    'ok', true,
    'afectados', jsonb_build_object('equipos', v_afectados),
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;
