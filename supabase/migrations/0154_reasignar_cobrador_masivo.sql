-- 0154 — Reasignar cobrador en masa (módulo Operaciones, super_admin). Mueve
-- TODOS los clientes de un cobrador (o de "sin cobrador") a otro, de un golpe.
-- El UPDATE de clientes.cobrador_id dispara el trigger 0002
-- (trg_propagate_cobrador_id_clientes) que propaga a contratos y cuotas → la
-- denormalización queda consistente (INV8/INV9) y PowerSync mueve las filas al
-- nuevo cobrador. NO toca dinero ni el historial de QUIÉN cobró
-- (pagos/recibos.cobrador_id intactos): cobrador_id de cliente es ORGANIZATIVO.
--
-- Patrón data-ops (0147): SECURITY DEFINER + gate is_super_admin() + p_tenant +
-- preview (cuenta) + ejecutar (log en data_ops_log, sin backup — es reversible
-- corriendo la operación inversa). NULL = "sin cobrador" (admin-managed).

-- ── PREVIEW: cuántos clientes se reasignarían ──────────────────────────────
create or replace function public.super_admin_preview_reasignar_cobrador(
  p_tenant uuid, p_origen uuid, p_destino uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is not distinct from p_destino then
    raise exception 'El cobrador de origen y el de destino son el mismo';
  end if;
  if p_destino is not null and not exists (
       select 1 from cobradores where id = p_destino and tenant_id = p_tenant and activo = true) then
    raise exception 'El cobrador de destino no existe, no está activo, o no es de este tenant';
  end if;
  if p_origen is not null and not exists (
       select 1 from cobradores where id = p_origen and tenant_id = p_tenant) then
    raise exception 'El cobrador de origen no pertenece a este tenant';
  end if;
  select count(*) into v_afectados from clientes
    where tenant_id = p_tenant and cobrador_id is not distinct from p_origen;
  v_origen_label  := case when p_origen  is null then 'Sin cobrador (admin)'
                          else (select coalesce(nombre, id::text) from cobradores where id = p_origen) end;
  v_destino_label := case when p_destino is null then 'Sin cobrador (admin)'
                          else (select coalesce(nombre, id::text) from cobradores where id = p_destino) end;
  return jsonb_build_object(
    'afectados', v_afectados,
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;

-- ── EJECUTAR: reasigna + registra en data_ops_log ──────────────────────────
create or replace function public.super_admin_ejecutar_reasignar_cobrador(
  p_tenant uuid, p_origen uuid, p_destino uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is not distinct from p_destino then
    raise exception 'El cobrador de origen y el de destino son el mismo';
  end if;
  if p_destino is not null and not exists (
       select 1 from cobradores where id = p_destino and tenant_id = p_tenant and activo = true) then
    raise exception 'El cobrador de destino no existe, no está activo, o no es de este tenant';
  end if;
  if p_origen is not null and not exists (
       select 1 from cobradores where id = p_origen and tenant_id = p_tenant) then
    raise exception 'El cobrador de origen no pertenece a este tenant';
  end if;
  v_origen_label  := case when p_origen  is null then 'Sin cobrador (admin)'
                          else (select coalesce(nombre, id::text) from cobradores where id = p_origen) end;
  v_destino_label := case when p_destino is null then 'Sin cobrador (admin)'
                          else (select coalesce(nombre, id::text) from cobradores where id = p_destino) end;
  -- El UPDATE dispara trg_propagate_cobrador_id_clientes (0002) por cada fila →
  -- propaga a contratos/cuotas. Filtro tenant_id: el super_admin impersonando
  -- tiene clientes de varios tenants en su SQLite, pero acá es server-side y el
  -- UPDATE solo toca los del tenant en contexto.
  with upd as (
    update clientes set cobrador_id = p_destino
     where tenant_id = p_tenant and cobrador_id is not distinct from p_origen
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then
    raise exception 'No hay clientes asignados a "%" para reasignar', v_origen_label;
  end if;
  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reasignar_cobrador',
            v_origen_label || ' → ' || v_destino_label,
            jsonb_build_object('clientes', v_afectados),
            null, auth.uid(), p_actor_label);
  return jsonb_build_object(
    'ok', true,
    'afectados', jsonb_build_object('clientes', v_afectados),
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;
