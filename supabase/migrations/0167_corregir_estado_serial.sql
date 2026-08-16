-- 0167 — Corregir el estado de un equipo serializado (módulo Operaciones,
-- super_admin). ALTO RIESGO: para datos mal importados (un serial que quedó en
-- un estado que no corresponde). Bypassa el guard de transiciones
-- (session_replication_role=replica) porque una corrección puede requerir una
-- transición que el guard normalmente bloquea (p.ej. revertir una baja errónea).
--
-- Para SERIALIZADOS el stock se deriva del ESTADO (COUNT en_stock), no del
-- ledger, así que cambiar el estado ES el cambio de stock (no hace falta
-- movimiento). Acotado a estados SIN cliente: en_stock | danado | retirado | baja
-- (para 'instalado' usar "Corregir cliente de un equipo", que exige cliente).
-- Al pasar a en_stock/baja se limpia el vínculo al cliente. Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_corregir_estado_serial(
  p_tenant uuid, p_serial text, p_estado text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_cur text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  if p_estado is null or p_estado not in ('en_stock','danado','retirado','baja') then
    raise exception 'Estado inválido. Para "instalado" usá Corregir cliente de un equipo';
  end if;
  select id, estado into v_id, v_cur from inv_seriales
   where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el equipo "' || btrim(p_serial) || '" en este tenant.');
  end if;
  if v_cur = p_estado then
    return jsonb_build_object('afectados', 0, 'label', 'El equipo "' || btrim(p_serial) || '" ya está en estado "' || p_estado || '".');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Equipo "' || btrim(p_serial) || '": ' || v_cur || ' → ' || p_estado || '.');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_corregir_estado_serial(
  p_tenant uuid, p_serial text, p_estado text, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_cur text; v_ubic uuid; v_def_ubic uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  if p_estado is null or p_estado not in ('en_stock','danado','retirado','baja') then
    raise exception 'Estado inválido. Para "instalado" usá Corregir cliente de un equipo';
  end if;
  select id, estado, ubicacion_id into v_id, v_cur, v_ubic from inv_seriales
   where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then raise exception 'No existe el equipo "%" en este tenant', btrim(p_serial); end if;
  if v_cur = p_estado then raise exception 'El equipo "%" ya está en estado "%"', btrim(p_serial), p_estado; end if;

  if p_estado = 'en_stock' and v_ubic is null then
    select id into v_def_ubic from inv_ubicaciones
     where tenant_id = p_tenant and activa = true order by (tipo = 'central') desc, nombre limit 1;
    if v_def_ubic is null then raise exception 'No hay ubicación activa para poner el equipo en stock'; end if;
  end if;

  set local session_replication_role = replica; -- bypass guard (corrección deliberada)
  update inv_seriales set
    estado = p_estado,
    cliente_id  = case when p_estado in ('en_stock','baja') then null else cliente_id end,
    contrato_id = case when p_estado in ('en_stock','baja') then null else contrato_id end,
    ubicacion_id = case when p_estado = 'en_stock' then coalesce(v_ubic, v_def_ubic) else ubicacion_id end
   where id = v_id;
  set local session_replication_role = origin; -- reactivar guards para el resto (patrón 0155)

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'corregir_estado_serial',
            'Equipo ' || btrim(p_serial) || ': ' || v_cur || ' → ' || p_estado,
            jsonb_build_object('equipos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1,
    'mensaje', 'Equipo "' || btrim(p_serial) || '" corregido a "' || p_estado || '".');
end; $fn$;
