-- 0168 — Corregir la fecha de creación (y por ende el SLA) de un ticket (módulo
-- Operaciones, super_admin). ALTO RIESGO: muta created_at, que es WALL-CLOCK
-- local-naive y ancla el SLA. Un device con el reloj adelantado hace nacer el
-- ticket con created_at en el futuro → SLA monstruo / ya-vencido. Esta operación
-- reancla la fecha a la correcta y resetea la pausa acumulada (segundos_pausado).
--
-- created_at se setea al MEDIODÍA de la fecha indicada, en UTC (SET LOCAL
-- timezone='UTC'). OJO convención (regla 1b): created_at es timestamptz pero la
-- app lo escribe NAIVE (DateTime.now().toIso8601String(), sin offset) → Postgres
-- lo guarda como-si-UTC y parseTicketWallClock re-lee los COMPONENTES ignorando la
-- Z → el wall-clock local round-trips. Por eso acá NO se convierte vía Managua
-- (guardaría +6h → SLA corrido); se escribe el instante en UTC: '2026-..-.. 12:00:00+00'
-- → la app lee 12:00. NO dispara triggers (created_at no es estado).
-- Bloqueado para cerrados/cancelados (su SLA es histórico). Verificá el SLA en la
-- app tras correrlo. Patrón data-ops. Input: correlativo (#) + fecha AAAA-MM-DD.

-- ── PREVIEW ────────────────────────────────────────────────────────────────
create or replace function public.super_admin_preview_corregir_sla(
  p_tenant uuid, p_correlativo int, p_fecha text)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text; v_actual date;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  if p_fecha is null or btrim(p_fecha) = '' then raise exception 'Indicá la fecha (AAAA-MM-DD)'; end if;
  begin perform p_fecha::date; exception when others then raise exception 'Fecha inválida. Usá el formato AAAA-MM-DD'; end;
  select id, estado, created_at::date into v_id, v_estado, v_actual
    from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then
    return jsonb_build_object('afectados', 0, 'label', 'No existe el ticket #' || p_correlativo || ' en este tenant.');
  end if;
  if v_estado in ('cerrado','cancelado') then
    return jsonb_build_object('afectados', 0,
      'label', 'El ticket #' || p_correlativo || ' está "' || v_estado || '": su SLA es histórico, no se corrige.');
  end if;
  return jsonb_build_object('afectados', 1,
    'label', 'Ticket #' || p_correlativo || ': fecha de creación ' || v_actual || ' → ' || p_fecha::date
             || ' (se reinicia la pausa del SLA).');
end; $fn$;

-- ── EJECUTAR ───────────────────────────────────────────────────────────────
create or replace function public.super_admin_ejecutar_corregir_sla(
  p_tenant uuid, p_correlativo int, p_fecha text, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_estado text;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_correlativo is null then raise exception 'Indicá el número de ticket'; end if;
  if p_fecha is null or btrim(p_fecha) = '' then raise exception 'Indicá la fecha (AAAA-MM-DD)'; end if;
  begin perform p_fecha::date; exception when others then raise exception 'Fecha inválida. Usá el formato AAAA-MM-DD'; end;
  select id, estado into v_id, v_estado from tickets where tenant_id = p_tenant and correlativo = p_correlativo;
  if v_id is null then raise exception 'No existe el ticket #% en este tenant', p_correlativo; end if;
  if v_estado in ('cerrado','cancelado') then
    raise exception 'El ticket #% está "%": su SLA es histórico, no se corrige', p_correlativo, v_estado;
  end if;

  set local timezone = 'UTC';
  update tickets set
    created_at = (p_fecha || ' 12:00:00')::timestamptz,
    segundos_pausado = 0,
    en_espera_desde = null
   where id = v_id;

  insert into data_ops_log(tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'corregir_sla', 'Ticket #' || p_correlativo || ' → ' || p_fecha::date,
            jsonb_build_object('tickets', 1), null, auth.uid(), p_actor_label);
  return jsonb_build_object('afectados', 1,
    'mensaje', 'Ticket #' || p_correlativo || ': fecha corregida a ' || p_fecha::date || '. Verificá el SLA en la app.');
end; $fn$;
