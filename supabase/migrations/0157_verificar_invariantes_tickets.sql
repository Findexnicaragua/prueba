-- 0157 — RPC `super_admin_verificar_invariantes_tickets`: chequeos de integridad
-- de TICKETS + Incidentes (estado, SLA, fechas, vínculo a incidentes), scopeados
-- a un tenant, desde el módulo Operaciones. Read-only, SECURITY DEFINER + gate
-- is_super_admin() (patrón 0153). Tickets no tenía red de seguridad: un device
-- con reloj mal o un ticket colgado de un incidente resuelto pasaban inadvertidos.
--
-- Devuelve 1 fila por invariante: (invariante, violaciones, ejemplo_ids). Todas
-- en 0 = tickets sanos. OJO SLA wall-clock: created_at es device-time local-naive
-- (parseTicketWallClock) — el chequeo de "fecha futura" usa un margen amplio
-- (2 días) para no marcar falsos positivos por huso horario (Nicaragua UTC-6).
-- Estados ticket: abierto|asignado|en_progreso|en_espera|resuelto|cerrado|reabierto|cancelado.

create or replace function public.super_admin_verificar_invariantes_tickets(p_tenant uuid)
returns table(invariante text, violaciones bigint, ejemplo_ids text)
language plpgsql security definer set search_path=public as $fn$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  invt1 as (
    -- Reloj de device adelantado → ticket nace con fecha futura → SLA monstruo.
    select 'INVT1: ningún ticket con fecha de creación futura'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(string_agg(id::text, ', ' order by id), '')::text as ejemplo_ids
    from (select id from public.tickets
           where tenant_id = p_tenant and created_at > now() + interval '2 days'
           limit 10) t
  ),
  invt2 as (
    select 'INVT2: pausa de SLA (segundos_pausado) no negativa'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.tickets
           where tenant_id = p_tenant and coalesce(segundos_pausado, 0) < 0
           limit 10) t
  ),
  invt3 as (
    -- El outage se resolvió pero un ticket suyo sigue activo → foto incorrecta.
    select 'INVT3: ningún ticket activo en un incidente ya resuelto'::text,
           count(*)::bigint,
           coalesce(string_agg(t.id::text, ', ' order by t.id), '')::text
    from (select t.id from public.tickets t
            join public.incidentes i on i.id = t.incidente_id
           where t.tenant_id = p_tenant
             and t.estado not in ('resuelto', 'cerrado', 'cancelado')
             and i.estado = 'resuelto'
           limit 10) t
  ),
  invt4 as (
    select 'INVT4: ticket asignado tiene técnico'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.tickets
           where tenant_id = p_tenant and estado = 'asignado' and asignado_a is null
           limit 10) t
  ),
  invt5 as (
    select 'INVT5: tenant_id de hija == tenant_id del ticket'::text,
           count(*)::bigint,
           coalesce(string_agg(ofensor, ', ' order by ofensor), '')::text
    from (
      select 'evento:' || e.id::text as ofensor
        from public.ticket_eventos e join public.tickets t on t.id = e.ticket_id
       where e.tenant_id = p_tenant and e.tenant_id <> t.tenant_id
      union all
      select 'material:' || m.id::text
        from public.ticket_materiales m join public.tickets t on t.id = m.ticket_id
       where m.tenant_id = p_tenant and m.tenant_id <> t.tenant_id
      union all
      select 'adjunto:' || a.id::text
        from public.ticket_adjuntos a join public.tickets t on t.id = a.ticket_id
       where a.tenant_id = p_tenant and a.tenant_id <> t.tenant_id
      limit 10) t
  ),
  invt6 as (
    select 'INVT6: fechas coherentes (resuelto antes de cerrado)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.tickets
           where tenant_id = p_tenant
             and resuelto_en is not null and cerrado_en is not null
             and resuelto_en > cerrado_en
           limit 10) t
  ),
  invt7 as (
    -- Por la matriz de transiciones, todo cierre pasa por 'resuelto' → tiene fecha.
    select 'INVT7: ticket resuelto/cerrado tiene fecha de resolución'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.tickets
           where tenant_id = p_tenant and estado in ('resuelto', 'cerrado')
             and resuelto_en is null
           limit 10) t
  )
  select * from invt1
  union all select * from invt2
  union all select * from invt3
  union all select * from invt4
  union all select * from invt5
  union all select * from invt6
  union all select * from invt7
  order by invariante;
end;
$fn$;
