-- 0162 — Resolver un incidente y cerrar sus tickets de un golpe (módulo
-- Operaciones, super_admin). Marca el incidente como resuelto (estado='resuelto',
-- fin=now) Y lleva cada uno de sus tickets ACTIVOS a 'resuelto'. Elimina el peor
-- dolor de los cortes masivos: cerrar 50+ tickets a mano.
--
-- Transición por la matriz: en_progreso/en_espera/reabierto → resuelto directo;
-- abierto/asignado pasan por 'en_progreso' (paso intermedio válido) antes de
-- 'resuelto'. Cada UPDATE valida la transición y dispara su auto-evento. Se setea
-- resuelto_en=now() (INVT7). Solo incidentes ABIERTOS.
--
-- afectados=1 cuando el incidente es resolvable (la acción principal SIEMPRE
-- ocurre, aunque tenga 0 tickets) → el botón ejecutar se muestra. Patrón data-ops.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_resolver_incidente(
  p_tenant uuid, p_incidente uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_estado text; v_titulo text; v_activos int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_incidente is null then raise exception 'Elegí el incidente'; end if;
  select estado, titulo into v_estado, v_titulo
    from incidentes where id = p_incidente and tenant_id = p_tenant;
  if v_estado is null then
    return jsonb_build_object('afectados', 0, 'label', 'El incidente no existe en este tenant.');
  end if;
  if v_estado <> 'abierto' then
    return jsonb_build_object('afectados', 0,
      'label', 'El incidente "' || coalesce(v_titulo,'') || '" ya está resuelto.');
  end if;
  select count(*) into v_activos from tickets
    where incidente_id = p_incidente and tenant_id = p_tenant
      and estado in ('abierto','asignado','en_progreso','en_espera','reabierto');
  return jsonb_build_object('afectados', 1,
    'label', 'Se resolverá el incidente "' || coalesce(v_titulo,'') || '" y se cerrarán '
             || v_activos || ' ticket(s) activo(s).');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_resolver_incidente(
  p_tenant uuid, p_incidente uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_estado text; v_titulo text; r record; v_cerrados int := 0;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_incidente is null then raise exception 'Elegí el incidente'; end if;
  select estado, titulo into v_estado, v_titulo
    from incidentes where id = p_incidente and tenant_id = p_tenant;
  if v_estado is null then raise exception 'El incidente no existe en este tenant'; end if;
  if v_estado <> 'abierto' then raise exception 'El incidente ya está resuelto'; end if;

  for r in select id, estado from tickets
            where incidente_id = p_incidente and tenant_id = p_tenant
              and estado in ('abierto','asignado','en_progreso','en_espera','reabierto') loop
    if r.estado in ('abierto','asignado') then
      update tickets set estado = 'en_progreso' where id = r.id; -- paso intermedio (matriz)
    end if;
    update tickets set estado = 'resuelto', resuelto_en = now() where id = r.id;
    v_cerrados := v_cerrados + 1;
  end loop;

  update incidentes set estado = 'resuelto', fin = now() where id = p_incidente;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'resolver_incidente',
            'Incidente: ' || coalesce(v_titulo, p_incidente::text),
            jsonb_build_object('tickets', v_cerrados), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', v_cerrados,
    'mensaje', 'Incidente resuelto. ' || v_cerrados || ' ticket(s) cerrados.');
end; $fn$;
