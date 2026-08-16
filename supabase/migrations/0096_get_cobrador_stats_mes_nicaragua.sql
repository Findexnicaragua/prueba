-- 0096 — get_cobrador_stats: "pagos del mes" en mes de Nicaragua
--
-- PROBLEMA (borde de mes): la función contaba los pagos del mes con
-- `p.fecha_pago >= date_trunc('month', now())`. `now()` es UTC y, más sutil,
-- `fecha_pago` se guarda como hora LOCAL de Nicaragua etiquetada como UTC (el
-- cliente escribe wall-clock sin offset y la sesión de Postgres es UTC). Por
-- eso ni el código actual ni un simple `set timezone='America/Managua'` dan el
-- mes correcto: con `set timezone` el corte de inicio de mes (00:00 Nica =
-- 06:00 UTC) deja afuera los pagos de la madrugada del día 1 (00:00–05:59 Nica),
-- que están guardados con su wall-clock < 06:00.
--
-- FIX: comparar en el MISMO espacio wall-clock que usa el dashboard del cliente
-- (`date(fecha_pago)` crudo). Se recupera el wall-clock de Nicaragua del pago
-- con `fecha_pago AT TIME ZONE 'UTC'` (timestamptz → timestamp sin tz = la hora
-- que se guardó) y se compara contra el inicio del mes ACTUAL de Nicaragua,
-- `date_trunc('month', now() AT TIME ZONE 'America/Managua')`. Ambos lados son
-- `timestamp` sin zona, en hora Nicaragua. Así el conteo del super_admin coincide
-- con los KPIs del dashboard en todos los casos, incluido el borde de mes.
--
-- Solo redefine la función (idempotente). NO toca schema.dart, db.dart ni sync
-- rules. Mantiene firma, gates y grants idénticos.

BEGIN;

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
           and (p.fecha_pago at time zone 'UTC')
               >= date_trunc('month', now() at time zone 'America/Managua'))::bigint
        as pagos_mes_count,
      coalesce(
        (select sum(p.monto_cordobas) from public.pagos p
          where p.cobrador_id = c.id
            and p.anulado = false
            and (p.fecha_pago at time zone 'UTC')
                >= date_trunc('month', now() at time zone 'America/Managua')),
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

COMMIT;
