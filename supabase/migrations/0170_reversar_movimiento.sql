-- 0170 — Reversar un movimiento de inventario mal cargado (módulo Operaciones,
-- super_admin). Para GRANEL: si se cargó mal un ingreso/egreso/ajuste/
-- transferencia, inserta el movimiento INVERSO (NUNCA edita ni borra el original
-- — el ledger es append-only). El stock derivado (Σdestino − Σorigen) se reajusta
-- solo: el inverso usa origen=destino_original y destino=origen_original, misma
-- cantidad, tipo 'ajuste'. Net 0 sobre el original.
--
-- Solo movimientos de GRANEL (serial_id NULL): los de equipos serializados se
-- corrigen con Baja/Recuperar/Corregir estado (su stock se deriva del estado, no
-- del ledger). Patrón data-ops. Input: selector de movimientos granel recientes.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reversar_movimiento(
  p_tenant uuid, p_movimiento uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_tipo text; v_cant numeric; v_serial uuid; v_prod text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_movimiento is null then raise exception 'Elegí el movimiento a reversar'; end if;
  select m.id, m.tipo, m.cantidad, m.serial_id, p.nombre
    into v_id, v_tipo, v_cant, v_serial, v_prod
    from inv_movimientos m join inv_productos p on p.id = m.producto_id
   where m.id = p_movimiento and m.tenant_id = p_tenant;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'El movimiento no existe en este tenant.');
  end if;
  if v_serial is not null then
    return jsonb_build_object('afectados', 0,
      'label', 'Ese movimiento es de un equipo serializado: corregilo con Baja / Recuperar / Corregir estado.');
  end if;
  -- Idempotencia: el motivo de la reversa embebe el id del original.
  if exists (select 1 from inv_movimientos
              where tenant_id = p_tenant and motivo like '%(' || p_movimiento::text || ')%') then
    return jsonb_build_object('afectados', 0, 'label', 'Ese movimiento ya fue reversado.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se reversará: ' || v_tipo || ' ' || v_cant || ' ' || v_prod || ' (se inserta el movimiento inverso).');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reversar_movimiento(
  p_tenant uuid, p_movimiento uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_tipo text; v_cant numeric; v_prod uuid; v_serial uuid; v_org uuid; v_dst uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_movimiento is null then raise exception 'Elegí el movimiento a reversar'; end if;
  select id, tipo, cantidad, producto_id, serial_id, ubicacion_origen_id, ubicacion_destino_id
    into v_id, v_tipo, v_cant, v_prod, v_serial, v_org, v_dst
    from inv_movimientos where id = p_movimiento and tenant_id = p_tenant;
  if v_id is null then raise exception 'El movimiento no existe en este tenant'; end if;
  if v_serial is not null then
    raise exception 'Ese movimiento es de un equipo serializado: usá Baja / Recuperar / Corregir estado';
  end if;
  if exists (select 1 from inv_movimientos
              where tenant_id = p_tenant and motivo like '%(' || p_movimiento::text || ')%') then
    raise exception 'Ese movimiento ya fue reversado';
  end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, cantidad,
    ubicacion_origen_id, ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  values (gen_random_uuid(), p_tenant, 'ajuste', v_prod, v_cant,
    v_dst, v_org, -- inverso: origen=destino_orig, destino=origen_orig
    'Reversa de movimiento ' || v_tipo || ' (' || p_movimiento::text || ')',
    auth.uid(), now(), now());

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reversar_movimiento', 'Reversa: ' || v_tipo || ' ' || v_cant,
            jsonb_build_object('movimientos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Movimiento reversado (' || v_tipo || ' ' || v_cant || ').');
end; $fn$;
