-- 0164 — Reconciliar seriales huérfanos (módulo Operaciones, super_admin). Los
-- equipos 'instalado' cuyo cliente ya no existe quedan con cliente_id NULL (la FK
-- es ON DELETE SET NULL: borrar/eliminar un cliente deja el serial colgado). Esos
-- huérfanos inflan el conteo y rompen la ficha del equipo. Esta operación los
-- devuelve a stock: estado='en_stock' en una ubicación + movimiento 'devolucion'.
-- (Es el fix de la violación INVI2 = 'instalado sin cliente'.)
--
-- Sin input: preview cuenta los huérfanos, ejecutar los reconcilia todos. La
-- transición instalado→en_stock pasa el guard (no es transferencia tardía: el
-- estado destino ES en_stock). Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reconciliar_huerfanos(p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  select count(*) into v_afectados from inv_seriales
   where tenant_id = p_tenant and estado = 'instalado' and cliente_id is null;
  return jsonb_build_object('afectados', v_afectados,
    'label', case when v_afectados = 0
      then 'No hay equipos huérfanos (instalados sin cliente).'
      else 'Se devolverán a stock ' || v_afectados || ' equipo(s) instalado(s) sin cliente.' end);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reconciliar_huerfanos(
  p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_default_ubic uuid;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  select id into v_default_ubic from inv_ubicaciones
   where tenant_id = p_tenant and activa = true
   order by (tipo = 'central') desc, nombre limit 1;
  if v_default_ubic is null then raise exception 'No hay ninguna ubicación activa para devolver los equipos'; end if;

  insert into inv_movimientos(id, tenant_id, tipo, producto_id, serial_id, cantidad,
    ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
  select gen_random_uuid(), s.tenant_id, 'devolucion', s.producto_id, s.id, 1,
    coalesce(s.ubicacion_id, v_default_ubic), 'Reconciliación de equipo huérfano (Operaciones)',
    auth.uid(), now(), now()
   from inv_seriales s
  where s.tenant_id = p_tenant and s.estado = 'instalado' and s.cliente_id is null;

  with upd as (
    update inv_seriales set estado = 'en_stock', ubicacion_id = coalesce(ubicacion_id, v_default_ubic)
     where tenant_id = p_tenant and estado = 'instalado' and cliente_id is null
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then raise exception 'No hay equipos huérfanos para reconciliar'; end if;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reconciliar_huerfanos', 'Equipos huérfanos → stock',
            jsonb_build_object('equipos', v_afectados), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', v_afectados,
    'mensaje', v_afectados || ' equipo(s) huérfano(s) devueltos a stock.');
end; $fn$;
