-- 0158 — Reasignar técnico en masa (módulo Operaciones, super_admin). Mueve los
-- tickets ACTIVOS de un técnico a otro, de un golpe. Gemelo de 0154 (reasignar
-- cobrador), para el módulo de tickets. El UPDATE de tickets.asignado_a dispara
-- trg_tickets_eventos_auto (un evento 'asignado' por ticket → audit). NO cambia
-- el estado del ticket, así que NO pasa por la matriz de transiciones.
--
-- Solo tickets ACTIVOS (estado NOT IN resuelto/cerrado/cancelado): en los tickets
-- terminados, asignado_a es el registro histórico de quién lo trabajó y NO se
-- toca (igual que el trigger 0122 congela el cobrador de las cuotas pagadas).
--
-- Patrón data-ops (0147/0154): SECURITY DEFINER + gate is_super_admin() +
-- p_tenant + preview (cuenta) + ejecutar (log en data_ops_log, reversible
-- corriéndolo al revés). Origen y destino son cobradores (staff) del tenant.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reasignar_tecnico(
  p_tenant uuid, p_origen uuid, p_destino uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is null then raise exception 'Elegí el técnico de origen'; end if;
  if p_destino is null then raise exception 'Elegí el técnico de destino'; end if;
  if p_origen = p_destino then raise exception 'El técnico de origen y el de destino son el mismo'; end if;
  if not exists (select 1 from cobradores where id = p_destino and tenant_id = p_tenant and activo = true) then
    raise exception 'El técnico de destino no existe, no está activo, o no es de este tenant';
  end if;
  if not exists (select 1 from cobradores where id = p_origen and tenant_id = p_tenant) then
    raise exception 'El técnico de origen no pertenece a este tenant';
  end if;
  select count(*) into v_afectados from tickets
    where tenant_id = p_tenant and asignado_a = p_origen
      and estado not in ('resuelto', 'cerrado', 'cancelado');
  select coalesce(nombre, id::text) into v_origen_label  from cobradores where id = p_origen;
  select coalesce(nombre, id::text) into v_destino_label from cobradores where id = p_destino;
  return jsonb_build_object(
    'afectados', v_afectados,
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reasignar_tecnico(
  p_tenant uuid, p_origen uuid, p_destino uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_origen_label text; v_destino_label text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_origen is null then raise exception 'Elegí el técnico de origen'; end if;
  if p_destino is null then raise exception 'Elegí el técnico de destino'; end if;
  if p_origen = p_destino then raise exception 'El técnico de origen y el de destino son el mismo'; end if;
  if not exists (select 1 from cobradores where id = p_destino and tenant_id = p_tenant and activo = true) then
    raise exception 'El técnico de destino no existe, no está activo, o no es de este tenant';
  end if;
  if not exists (select 1 from cobradores where id = p_origen and tenant_id = p_tenant) then
    raise exception 'El técnico de origen no pertenece a este tenant';
  end if;
  select coalesce(nombre, id::text) into v_origen_label  from cobradores where id = p_origen;
  select coalesce(nombre, id::text) into v_destino_label from cobradores where id = p_destino;
  with upd as (
    update tickets set asignado_a = p_destino
     where tenant_id = p_tenant and asignado_a = p_origen
       and estado not in ('resuelto', 'cerrado', 'cancelado')
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then
    raise exception 'No hay tickets activos asignados a "%" para reasignar', v_origen_label;
  end if;
  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reasignar_tecnico',
            v_origen_label || ' → ' || v_destino_label,
            jsonb_build_object('tickets', v_afectados),
            null, auth.uid(), p_actor_label);
  return jsonb_build_object(
    'ok', true,
    'afectados', jsonb_build_object('tickets', v_afectados),
    'origen_label', v_origen_label,
    'destino_label', v_destino_label);
end; $fn$;
