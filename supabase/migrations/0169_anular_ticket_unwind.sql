-- 0169 — Anular un ticket creado por error, devolviendo sus materiales al stock
-- (módulo Operaciones, super_admin). ALTO RIESGO: cascada. Un ticket duplicado
-- al que ya se le consumió material deja el stock incorrecto (el serial quedó
-- 'instalado', el granel descontado) y bloquea devoluciones. Esta operación lo
-- "desenrolla": por cada material consumido inserta un movimiento 'devolucion'
-- (reversa) y, si es serializado, devuelve el equipo a stock; luego cancela el
-- ticket.
--
-- APPEND-ONLY: NO borra las filas de ticket_materiales (quedan como registro del
-- intento); el stock se corrige con los movimientos de devolución. El serial se
-- revierte SOLO si sigue 'instalado' en el cliente del ticket (idempotente, no
-- pisa un equipo reusado). Bloqueado para resuelto/cerrado/cancelado. Patrón
-- data-ops. Input: correlativo (#).

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_anular_ticket(
  p_tenant uuid, p_correlativo int)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_mats int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  select id, estado into v_id, v_estado from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el ticket #' || p_correlativo || ' en este tenant.');
  end if;
  if v_estado in ('resuelto','cerrado','cancelado') then
    return jsonb_build_object('afectados', 0,
      'label', 'El ticket #' || p_correlativo || ' está "' || v_estado || '": solo se anulan los activos.');
  end if;
  select count(*) into v_mats from ticket_materiales where ticket_id = v_id;
  return jsonb_build_object('afectados', 1,
    'label', 'Ticket #' || p_correlativo || ': se anulará (cancelará) y se devolverán '
             || v_mats || ' material(es) al stock.');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_anular_ticket(
  p_tenant uuid, p_correlativo int, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_cli uuid; v_def uuid; r record; v_devueltos int := 0;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  select id, estado, cliente_id into v_id, v_estado, v_cli
    from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then raise exception 'No existe el ticket #% en este tenant', p_correlativo; end if;
  if v_estado in ('resuelto','cerrado','cancelado') then
    raise exception 'El ticket #% está "%": solo se anulan los activos', p_correlativo, v_estado;
  end if;
  select id into v_def from inv_ubicaciones
   where tenant_id = p_tenant and activa = true order by (tipo = 'central') desc, nombre limit 1;

  for r in select * from ticket_materiales where ticket_id = v_id loop
    if coalesce(r.ubicacion_origen_id, v_def) is null then
      raise exception 'No hay ubicación para devolver un material del ticket (sin origen ni ubicación activa)';
    end if;
    if r.serial_id is not null then
      -- Revertir el serial SOLO si sigue instalado en el cliente del ticket.
      update inv_seriales set estado = 'en_stock', cliente_id = null, contrato_id = null,
             ubicacion_id = coalesce(r.ubicacion_origen_id, v_def)
       where id = r.serial_id and tenant_id = p_tenant and estado = 'instalado'
         and cliente_id is not distinct from v_cli;
      if found then
        insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
          ubicacion_destino_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
        values (gen_random_uuid(), p_tenant, 'devolucion', r.producto_id, r.serial_id, 1,
          coalesce(r.ubicacion_origen_id, v_def), v_id, 'Anulación de ticket (Operaciones)',
          auth.uid(), now(), now());
        v_devueltos := v_devueltos + 1;
      end if;
    else
      -- Granel: devolución de la cantidad consumida.
      insert into inv_movimientos(id, tenant_id, tipo, producto_id, cantidad,
        ubicacion_destino_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
      values (gen_random_uuid(), p_tenant, 'devolucion', r.producto_id, r.cantidad,
        coalesce(r.ubicacion_origen_id, v_def), v_id, 'Anulación de ticket (Operaciones)',
        auth.uid(), now(), now());
      v_devueltos := v_devueltos + 1;
    end if;
  end loop;

  update tickets set estado = 'cancelado' where id = v_id;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'anular_ticket', 'Ticket #' || p_correlativo,
            jsonb_build_object('materiales', v_devueltos), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', v_devueltos,
    'mensaje', 'Ticket #' || p_correlativo || ' anulado. ' || v_devueltos || ' material(es) devueltos al stock.');
end; $fn$;
