-- 0160 — Cerrar (cancelar) tickets viejos sin actividad en masa (módulo
-- Operaciones, super_admin). Cancela los tickets en estados transitivos
-- (abierto/asignado/en_progreso/en_espera/reabierto — NUNCA 'resuelto', que cierra
-- por otro carril) que llevan > N días sin actividad: creados hace más de N días
-- Y sin ningún ticket_evento en los últimos N días. Limpia el histórico de
-- trabajos atascados o nunca iniciados.
--
-- El UPDATE a 'cancelado' pasa por la matriz de transiciones (todos los estados
-- de scope → cancelado son válidos) y dispara el auto-evento 'cancelado' por
-- ticket. Patrón data-ops: SECURITY DEFINER + gate + p_tenant + preview + log.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_cerrar_tickets_viejos(
  p_tenant uuid, p_dias int)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_cutoff timestamptz;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_dias is null or p_dias < 1 then raise exception 'Indicá un número de días válido (>= 1)'; end if;
  v_cutoff := now() - (p_dias || ' days')::interval;
  select count(*) into v_afectados from tickets t
   where t.tenant_id = p_tenant
     and t.estado in ('abierto','asignado','en_progreso','en_espera','reabierto')
     and t.created_at < v_cutoff
     and not exists (select 1 from ticket_eventos e
                      where e.ticket_id = t.id and e.ocurrido_en >= v_cutoff);
  return jsonb_build_object('afectados', v_afectados,
    'label', case when v_afectados = 0
      then 'No hay tickets sin actividad de más de ' || p_dias || ' días.'
      else 'Se cancelarán ' || v_afectados || ' ticket(s) sin actividad de más de ' || p_dias || ' días.' end);
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_cerrar_tickets_viejos(
  p_tenant uuid, p_dias int, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_afectados int; v_cutoff timestamptz;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_dias is null or p_dias < 1 then raise exception 'Indicá un número de días válido (>= 1)'; end if;
  v_cutoff := now() - (p_dias || ' days')::interval;
  with upd as (
    update tickets t set estado = 'cancelado'
     where t.tenant_id = p_tenant
       and t.estado in ('abierto','asignado','en_progreso','en_espera','reabierto')
       and t.created_at < v_cutoff
       and not exists (select 1 from ticket_eventos e
                        where e.ticket_id = t.id and e.ocurrido_en >= v_cutoff)
    returning 1)
  select count(*) into v_afectados from upd;
  if v_afectados = 0 then
    raise exception 'No hay tickets sin actividad de más de % días para cancelar', p_dias;
  end if;
  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'cerrar_tickets_viejos',
            'Sin actividad > ' || p_dias || ' días',
            jsonb_build_object('tickets', v_afectados),
            null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', v_afectados,
    'mensaje', v_afectados || ' ticket(s) cancelados.');
end; $fn$;
