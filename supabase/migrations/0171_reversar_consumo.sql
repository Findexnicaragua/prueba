-- 0171 — Reversar el consumo de UN material de un ticket (módulo Operaciones,
-- super_admin). Versión fina de "Anular ticket" (0169): si el técnico cargó mal
-- UN material (serial equivocado, pieza no usada), revierte solo ese consumo SIN
-- cancelar el ticket. Por cada consumo: inserta un movimiento 'devolucion'
-- (reversa) y, si es serializado, devuelve el equipo a stock.
--
-- APPEND-ONLY: NO borra la fila de ticket_materiales (queda como registro). El
-- serial se revierte SOLO si sigue 'instalado' en el cliente del ticket
-- (idempotente). Para granel, reversar dos veces duplicaría la devolución — el
-- super_admin lo hace deliberadamente una vez. Patrón data-ops. Input: selector
-- de consumos recientes.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reversar_consumo(
  p_tenant uuid, p_material uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_corr int; v_serial text; v_prod text; v_cant numeric;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_material is null then raise exception 'Elegí el consumo a reversar'; end if;
  select tm.id, t.correlativo, s.serial, p.nombre, tm.cantidad
    into v_id, v_corr, v_serial, v_prod, v_cant
    from ticket_materiales tm
    join tickets t on t.id = tm.ticket_id
    join inv_productos p on p.id = tm.producto_id
    left join inv_seriales s on s.id = tm.serial_id
   where tm.id = p_material and tm.tenant_id = p_tenant;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'El consumo no existe en este tenant.');
  end if;
  -- Idempotencia: la devolución embebe el id del material en el motivo.
  if exists (select 1 from inv_movimientos
              where tenant_id = p_tenant and motivo like '%[' || p_material::text || ']%') then
    return jsonb_build_object('afectados', 0, 'label', 'Ese consumo ya fue reversado.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se reversará el consumo del ticket #' || v_corr || ': '
             || coalesce(v_serial, v_prod || ' ' || v_cant) || ' (vuelve al stock).');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reversar_consumo(
  p_tenant uuid, p_material uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_tk uuid; v_corr int; v_cli uuid; v_prod uuid; v_serial uuid;
        v_cant numeric; v_org uuid; v_def uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_material is null then raise exception 'Elegí el consumo a reversar'; end if;
  select tm.ticket_id, tm.producto_id, tm.serial_id, tm.cantidad, tm.ubicacion_origen_id,
         t.cliente_id, t.correlativo
    into v_tk, v_prod, v_serial, v_cant, v_org, v_cli, v_corr
    from ticket_materiales tm join tickets t on t.id = tm.ticket_id
   where tm.id = p_material and tm.tenant_id = p_tenant;
  if v_tk is null then raise exception 'El consumo no existe en este tenant'; end if;
  if exists (select 1 from inv_movimientos
              where tenant_id = p_tenant and motivo like '%[' || p_material::text || ']%') then
    raise exception 'Ese consumo ya fue reversado';
  end if;
  select id into v_def from inv_ubicaciones
   where tenant_id = p_tenant and activa = true order by (tipo = 'central') desc, nombre limit 1;
  if coalesce(v_org, v_def) is null then
    raise exception 'No hay ninguna ubicación para devolver el material';
  end if;

  if v_serial is not null then
    update inv_seriales set estado = 'en_stock', cliente_id = null, contrato_id = null,
           ubicacion_id = coalesce(v_org, v_def)
     where id = v_serial and tenant_id = p_tenant and estado = 'instalado'
       and cliente_id is not distinct from v_cli;
    if not found then
      raise exception 'El equipo de ese consumo ya no está instalado en el cliente del ticket (ya se revirtió o se movió)';
    end if;
    insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
      ubicacion_destino_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
    values (gen_random_uuid(), p_tenant, 'devolucion', v_prod, v_serial, 1,
      coalesce(v_org, v_def), v_tk, 'Reversa de consumo (Operaciones) [' || p_material::text || ']', auth.uid(), now(), now());
  else
    insert into inv_movimientos(id, tenant_id, tipo, producto_id, cantidad,
      ubicacion_destino_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
    values (gen_random_uuid(), p_tenant, 'devolucion', v_prod, v_cant,
      coalesce(v_org, v_def), v_tk, 'Reversa de consumo (Operaciones) [' || p_material::text || ']', auth.uid(), now(), now());
  end if;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reversar_consumo', 'Consumo del ticket #' || v_corr,
            jsonb_build_object('materiales', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Consumo del ticket #' || v_corr || ' reversado.');
end; $fn$;
