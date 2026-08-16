-- 0166 — Corregir el cliente/contrato de un equipo instalado (módulo
-- Operaciones, super_admin). Si un serial quedó instalado en el cliente
-- equivocado (homónimo, duplicado en la carga), reasigna cliente_id/contrato_id
-- al correcto. Es una corrección de METADATO (el equipo está físicamente bien),
-- así que NO genera movimiento de inventario.
--
-- El guard de transiciones BLOQUEA cambiar el cliente de un 'instalado' (pide
-- pasar por stock). Como es una corrección deliberada del super_admin (el equipo
-- no se movió), se bypassa con `set local session_replication_role = replica`
-- (mismo patrón que el restore 0155), acotado a este UPDATE. Se valida a mano que
-- el contrato pertenezca al cliente. Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_corregir_vinculo(
  p_tenant uuid, p_serial text, p_cliente uuid, p_contrato uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_cur text; v_new text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  if p_cliente is null then raise exception 'Elegí el cliente correcto'; end if;
  select s.id, s.estado, c.nombre into v_id, v_estado, v_cur
    from inv_seriales s left join clientes c on c.id = s.cliente_id
   where s.tenant_id = p_tenant and s.serial = btrim(p_serial);
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el equipo "' || btrim(p_serial) || '" en este tenant.');
  end if;
  if v_estado <> 'instalado' then
    return jsonb_build_object('afectados', 0,
      'label', 'El equipo "' || btrim(p_serial) || '" está "' || v_estado || '": solo se corrige el vínculo de los instalados.');
  end if;
  select nombre into v_new from clientes where id = p_cliente and tenant_id = p_tenant;
  if v_new is null then raise exception 'El cliente destino no existe o no es de este tenant'; end if;
  if p_contrato is not null and not exists (
       select 1 from contratos where id = p_contrato and cliente_id = p_cliente and tenant_id = p_tenant) then
    raise exception 'El contrato elegido no pertenece a ese cliente';
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Equipo "' || btrim(p_serial) || '" instalado en ' || coalesce(v_cur, '(sin cliente)')
             || ' → se reasigna a ' || v_new || '.');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_corregir_vinculo(
  p_tenant uuid, p_serial text, p_cliente uuid, p_contrato uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_new text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_serial is null or btrim(p_serial) = '' then raise exception 'Indicá el número de serie'; end if;
  if p_cliente is null then raise exception 'Elegí el cliente correcto'; end if;
  select id, estado into v_id, v_estado from inv_seriales
   where tenant_id = p_tenant and serial = btrim(p_serial);
  if v_id is null then raise exception 'No existe el equipo "%" en este tenant', btrim(p_serial); end if;
  if v_estado <> 'instalado' then
    raise exception 'El equipo "%" está "%": solo se corrige el vínculo de los instalados', btrim(p_serial), v_estado;
  end if;
  select nombre into v_new from clientes where id = p_cliente and tenant_id = p_tenant;
  if v_new is null then raise exception 'El cliente destino no existe o no es de este tenant'; end if;
  if p_contrato is not null and not exists (
       select 1 from contratos where id = p_contrato and cliente_id = p_cliente and tenant_id = p_tenant) then
    raise exception 'El contrato elegido no pertenece a ese cliente';
  end if;

  -- Bypass del guard de transiciones: es corrección de metadato, no movimiento físico.
  set local session_replication_role = replica;
  update inv_seriales set cliente_id = p_cliente, contrato_id = p_contrato where id = v_id;
  set local session_replication_role = origin; -- reactivar guards para el resto (patrón 0155)

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'corregir_vinculo', 'Equipo ' || btrim(p_serial) || ' → ' || v_new,
            jsonb_build_object('equipos', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Equipo "' || btrim(p_serial) || '" reasignado a ' || v_new || '.');
end; $fn$;
