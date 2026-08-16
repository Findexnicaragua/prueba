-- 0165 — Ajuste por conteo físico (módulo Operaciones, super_admin). Para
-- productos GRANEL (es_serializado=false): el admin ingresa lo que contó
-- físicamente en una ubicación, y la operación inserta un movimiento 'ajuste'
-- por la DIFERENCIA contra el stock derivado del ledger. Convierte el "egreso
-- suelto con cuenta a mano" en un flujo claro y auditado.
--
-- Stock granel derivado = Σ(cantidad con destino=U) − Σ(cantidad con origen=U)
-- para ese producto. diff = contado − actual. Si diff>0 → ajuste con destino=U
-- (suma); si diff<0 → ajuste con origen=U (resta). cantidad SIEMPRE positiva
-- (INVI7). Append-only: es un movimiento nuevo, nunca edita. Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_ajuste_conteo(
  p_tenant uuid, p_producto uuid, p_ubicacion uuid, p_contado numeric)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_actual numeric; v_diff numeric; v_pnom text; v_unom text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_producto is null then raise exception 'Elegí el producto'; end if;
  if p_ubicacion is null then raise exception 'Elegí la ubicación'; end if;
  if p_contado is null or p_contado < 0 then raise exception 'Indicá la cantidad contada (>= 0)'; end if;
  select nombre into v_pnom from inv_productos
   where id = p_producto and tenant_id = p_tenant and es_serializado = false;
  if v_pnom is null then raise exception 'El producto no existe, no es de este tenant, o es serializado (el conteo es para granel)'; end if;
  select nombre into v_unom from inv_ubicaciones where id = p_ubicacion and tenant_id = p_tenant;
  if v_unom is null then raise exception 'La ubicación no existe o no es de este tenant'; end if;

  select coalesce(sum(case when ubicacion_destino_id = p_ubicacion then cantidad else 0 end), 0)
       - coalesce(sum(case when ubicacion_origen_id  = p_ubicacion then cantidad else 0 end), 0)
    into v_actual
    from inv_movimientos where tenant_id = p_tenant and producto_id = p_producto;
  v_diff := p_contado - v_actual;
  return jsonb_build_object(
    'afectados', case when v_diff = 0 then 0 else 1 end,
    'label', case when v_diff = 0
      then v_pnom || ' en ' || v_unom || ': sistema y conteo coinciden (' || v_actual || '). Sin ajuste.'
      else v_pnom || ' en ' || v_unom || ' — sistema: ' || v_actual || ' · contado: ' || p_contado
           || ' · ajuste: ' || case when v_diff > 0 then '+' else '' end || v_diff end);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_ajuste_conteo(
  p_tenant uuid, p_producto uuid, p_ubicacion uuid, p_contado numeric, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_actual numeric; v_diff numeric; v_pnom text; v_unom text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_producto is null then raise exception 'Elegí el producto'; end if;
  if p_ubicacion is null then raise exception 'Elegí la ubicación'; end if;
  if p_contado is null or p_contado < 0 then raise exception 'Indicá la cantidad contada (>= 0)'; end if;
  select nombre into v_pnom from inv_productos
   where id = p_producto and tenant_id = p_tenant and es_serializado = false;
  if v_pnom is null then raise exception 'El producto no existe, no es de este tenant, o es serializado'; end if;
  select nombre into v_unom from inv_ubicaciones where id = p_ubicacion and tenant_id = p_tenant;
  if v_unom is null then raise exception 'La ubicación no existe o no es de este tenant'; end if;

  select coalesce(sum(case when ubicacion_destino_id = p_ubicacion then cantidad else 0 end), 0)
       - coalesce(sum(case when ubicacion_origen_id  = p_ubicacion then cantidad else 0 end), 0)
    into v_actual
    from inv_movimientos where tenant_id = p_tenant and producto_id = p_producto;
  v_diff := p_contado - v_actual;
  if v_diff = 0 then raise exception 'No hay diferencia entre el sistema (%) y el conteo', v_actual; end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, cantidad,
    ubicacion_origen_id, ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  values (gen_random_uuid(), p_tenant, 'ajuste', p_producto, abs(v_diff),
    case when v_diff < 0 then p_ubicacion end, case when v_diff > 0 then p_ubicacion end,
    'Conteo físico (Operaciones)', auth.uid(), now(), now());

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'ajuste_conteo', v_pnom || ' @ ' || v_unom,
            jsonb_build_object('ajuste', abs(v_diff)), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1,
    'mensaje', 'Ajuste de ' || case when v_diff > 0 then '+' else '' end || v_diff
               || ' aplicado a ' || v_pnom || ' en ' || v_unom || '.');
end; $fn$;
