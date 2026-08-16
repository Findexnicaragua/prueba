-- 0161 — Reabrir un ticket cerrado/cancelado por error (módulo Operaciones,
-- super_admin), identificado por su correlativo (#N visible en la app). El
-- UPDATE estado='reabierto' pasa por la matriz (cerrado→reabierto y
-- cancelado→reabierto son válidas) y dispara el auto-evento 'reabierto'. Solo
-- aplica a cerrados/cancelados (los activos no se reabren).
--
-- Patrón data-ops: SECURITY DEFINER + gate + p_tenant + preview + log. Contrato
-- del input card: preview→{afectados,label}, ejecutar→{afectados,mensaje}.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_reabrir_ticket(
  p_tenant uuid, p_correlativo int)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_titulo text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  select id, estado, titulo into v_id, v_estado, v_titulo
    from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el ticket #' || p_correlativo || ' en este tenant.');
  end if;
  if v_estado not in ('cerrado','cancelado') then
    return jsonb_build_object('afectados', 0,
      'label', 'El ticket #' || p_correlativo || ' está "' || v_estado || '": solo se reabren cerrados o cancelados.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Se reabrirá el ticket #' || p_correlativo || ' — "' || coalesce(v_titulo,'') || '" (' || v_estado || ').');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_reabrir_ticket(
  p_tenant uuid, p_correlativo int, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  select id, estado into v_id, v_estado
    from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then raise exception 'No existe el ticket #% en este tenant', p_correlativo; end if;
  if v_estado not in ('cerrado','cancelado') then
    raise exception 'El ticket #% está "%": solo se reabren cerrados o cancelados', p_correlativo, v_estado;
  end if;
  update tickets set estado = 'reabierto' where id = v_id;
  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'reabrir_ticket', 'Ticket #' || p_correlativo,
            jsonb_build_object('tickets', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1, 'mensaje', 'Ticket #' || p_correlativo || ' reabierto.');
end; $fn$;
