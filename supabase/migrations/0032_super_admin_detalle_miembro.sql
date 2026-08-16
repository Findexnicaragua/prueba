-- Batch 3 paso 1 — RPCs para pantalla de detalle del miembro
--
-- Dos RPCs, ambas gateadas por is_super_admin():
--   1. get_cobrador_stats: stats agregadas (last_sign_in, # clientes
--      asignados, # pagos del mes, $ cobrado del mes).
--   2. list_audit_cobrador: últimos N eventos del audit_log donde el
--      miembro fue afectado (registro_id = cobrador_id).
--
-- Excluye la lógica de pagos cuando el cobrador no es rol cobrador
-- (admins no cobran, devuelven 0). Las queries usan los índices que ya
-- existen para clientes (cobrador_activo_idx) y pagos (by_cobrador_fecha).

-- =========================================================================
-- 1. get_cobrador_stats: stats agregadas para un miembro
-- =========================================================================

create or replace function public.get_cobrador_stats(p_cobrador_id uuid)
returns table (
  id                  uuid,
  last_sign_in_at     timestamptz,
  clientes_asignados  bigint,
  pagos_mes_count     bigint,
  pagos_mes_total     numeric
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      c.id,
      u.last_sign_in_at,
      (select count(*) from public.clientes cl
         where cl.cobrador_id = c.id and cl.activo)::bigint
        as clientes_asignados,
      (select count(*) from public.pagos p
         where p.cobrador_id = c.id
           and p.anulado = false
           and p.fecha_pago >= date_trunc('month', now()))::bigint
        as pagos_mes_count,
      coalesce(
        (select sum(p.monto_cordobas) from public.pagos p
          where p.cobrador_id = c.id
            and p.anulado = false
            and p.fecha_pago >= date_trunc('month', now())),
        0
      ) as pagos_mes_total
    from public.cobradores c
    join auth.users u on u.id = c.id
    where c.id = p_cobrador_id
      and c.rol <> 'super_admin';
end;
$$;

revoke all on function public.get_cobrador_stats(uuid) from public;
grant execute on function public.get_cobrador_stats(uuid) to authenticated;

-- =========================================================================
-- 2. list_audit_cobrador: timeline de eventos sobre el miembro
-- =========================================================================
-- Devuelve los últimos N eventos del audit_log donde el miembro fue el
-- TARGET (registro_id), no donde fue el ACTOR. Útil para responder
-- "¿qué le pasó a este usuario en los últimos 50 cambios?".
--
-- Hace JOIN con auth.users + cobradores del autor del cambio para mostrar
-- nombre + email en la UI sin queries adicionales.

create or replace function public.list_audit_cobrador(
  p_cobrador_id uuid,
  p_limit int default 50
)
returns table (
  id              uuid,
  tabla           text,
  campo           text,
  valor_anterior  jsonb,
  valor_nuevo     jsonb,
  user_id         uuid,
  user_rol        text,
  user_email      text,
  user_nombre     text,
  created_at      timestamptz
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  return query
    select
      a.id,
      a.tabla,
      a.campo,
      a.valor_anterior,
      a.valor_nuevo,
      a.user_id,
      a.user_rol,
      u.email::text as user_email,
      c.nombre as user_nombre,
      a.created_at
    from public.audit_log a
    left join auth.users u on u.id = a.user_id
    left join public.cobradores c on c.id = a.user_id
    where a.registro_id = p_cobrador_id
      -- Defense in depth: aunque la chance de colisión UUID entre tablas
      -- es astronómica, restringimos a las tablas donde nuestras acciones
      -- sobre cobradores escriben audit (cobradores, auth.users).
      and a.tabla in ('cobradores', 'auth.users')
    order by a.created_at desc
    limit greatest(p_limit, 1);
end;
$$;

revoke all on function public.list_audit_cobrador(uuid, int) from public;
grant execute on function public.list_audit_cobrador(uuid, int) to authenticated;
