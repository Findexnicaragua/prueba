-- 0109 — SLA accionable: auto-cierre de tickets resueltos (cron diario).
--
-- Cierra automáticamente los tickets en estado 'resuelto' que llevan más de N
-- días sin reapertura (N = setting per-tenant `tickets.auto_cierre_dias`; 0 =
-- desactivado, que es el DEFAULT). Deja el rastro en la bitácora (`ticket_eventos`)
-- con autor = NULL (= "Sistema" en la UI). Reversible: `cerrado→reabierto` sigue
-- siendo una transición válida.
--
-- Simplicidad a propósito (no repetir el lío de Nodos): NO crea tablas ni
-- columnas ni vínculos nuevos. Usa SOLO columnas que `tickets` ya tiene
-- (`estado`, `resuelto_en`, `cerrado_en`). NO toca el cálculo del SLA (se basa en
-- `resuelto_en`, no en el deadline) → cero lógica de SLA en el server. Sin bump de
-- schema, sin redeploy de sync rules (los cambios de estado/cerrado_en viajan por
-- el `SELECT *` existente).
--
-- Patrón espejado del cron de mora (0009/0011/0034): SECURITY DEFINER per-tenant +
-- `setting_number` + cron diario. La transición resuelto→cerrado ya está validada
-- por el CHECK + el trigger de 0103; los triggers de pausa/audit conviven sin tocar.

begin;

-- =========================================================================
-- 1. Función per-tenant. En el cron `auth.uid()` es NULL (no hay usuario) → la
--    RLS de tickets/ticket_eventos bloquearía el write; por eso SECURITY DEFINER
--    + `row_security = off` explícito (idéntico a actualizar_notificaciones_mora).
-- =========================================================================
create or replace function public.tickets_auto_cierre(p_tenant_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dias int := public.setting_number(p_tenant_id, 'tickets.auto_cierre_dias', 0)::int;
  v_filas int := 0;
begin
  -- 0 (o ausente) = desactivado. Default → el cron no cierra nada hasta que el
  -- admin lo prenda en el editor de Tipos.
  if v_dias <= 0 then
    return 0;
  end if;
  set local row_security = off;

  -- Cierra los 'resuelto' vencidos y registra el evento de bitácora de cada uno.
  -- CTE data-modifying: el UPDATE corre una vez; `eventos` lee su RETURNING e
  -- inserta un evento por ticket cerrado; el SELECT final cuenta desde `eventos`
  -- (así ambas CTE se ejecutan con seguridad). hecho_por = NULL = "Sistema".
  with cerrados as (
    update public.tickets t
       set estado = 'cerrado',
           cerrado_en = now(),
           ocurrido_en = now()
     where t.tenant_id = p_tenant_id
       and t.estado = 'resuelto'
       and t.resuelto_en is not null
       and t.resuelto_en < now() - (v_dias || ' days')::interval
    returning t.id, t.tenant_id
  ),
  eventos as (
    insert into public.ticket_eventos
      (id, tenant_id, ticket_id, tipo_evento, comentario, hecho_por,
       ocurrido_en, created_at)
    select gen_random_uuid(), c.tenant_id, c.id, 'cerrado',
           'Cerrado automáticamente tras ' || v_dias || ' días sin reapertura',
           null, now(), now()
      from cerrados c
    returning 1
  )
  select count(*)::int into v_filas from eventos;

  return v_filas;
end $$;

-- =========================================================================
-- 2. Cron diario (06:30 UTC = 00:30 Nicaragua; no colisiona con generar_cuotas
--    06:05 ni mora 12:00). Idempotente: desagenda por nombre si ya existe, luego
--    agenda. La hora exacta no afecta el resultado (es "N días desde resuelto_en",
--    no un corte de día calendario), así que no necesita SET timezone.
-- =========================================================================
select cron.unschedule(jobid)
  from cron.job where jobname = 'tickets_auto_cierre_diario';
select cron.schedule(
  'tickets_auto_cierre_diario',
  '30 6 * * *',
  $$ select public.tickets_auto_cierre(t.id) from public.tenants t; $$
);

commit;
