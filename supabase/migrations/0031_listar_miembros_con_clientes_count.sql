-- Hot-fix: extender `list_cobradores_tenant` para devolver el count de
-- clientes activos asignados a cada cobrador.
--
-- Por qué: cuando un cobrador se cambia de rol o se desactiva, los
-- clientes con `cobrador_id = <ese-id>` quedan huérfanos semánticamente
-- (la FK sigue válida pero el "cobrador" asignado ya no opera como tal).
-- El super_admin necesita saber cuántos clientes va a dejar sin cobrador
-- antes de confirmar el cambio.
--
-- Sólo se incluyen clientes con activo=true. El campo es bigint para
-- ser consistente con la salida de COUNT(*) de PostgreSQL.

drop function if exists public.list_cobradores_tenant(uuid);

create or replace function public.list_cobradores_tenant(p_tenant_id uuid)
returns table (
  id                  uuid,
  email               text,
  nombre              text,
  telefono            text,
  rol                 text,
  activo              boolean,
  prefijo_recibo      text,
  created_at          timestamptz,
  last_sign_in_at     timestamptz,
  email_confirmed_at  timestamptz,
  invited_at          timestamptz,
  clientes_asignados  bigint
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  if p_tenant_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'No se puede listar miembros del tenant System';
  end if;

  return query
    select
      c.id,
      u.email::text,
      c.nombre,
      c.telefono,
      c.rol,
      c.activo,
      c.prefijo_recibo,
      c.created_at,
      u.last_sign_in_at,
      u.email_confirmed_at,
      u.invited_at,
      (select count(*) from public.clientes cl
         where cl.cobrador_id = c.id and cl.activo)::bigint
        as clientes_asignados
    from public.cobradores c
    join auth.users u on u.id = c.id
    where c.tenant_id = p_tenant_id
      and c.rol <> 'super_admin'
    order by
      c.activo desc,
      case c.rol
        when 'admin' then 1
        when 'admin_cobranza' then 2
        when 'cobrador' then 3
        else 4
      end,
      c.nombre;
end;
$$;

revoke all on function public.list_cobradores_tenant(uuid) from public;
grant execute on function public.list_cobradores_tenant(uuid) to authenticated;

-- Partial index para el count: el subselect filtra por cobrador_id +
-- activo en cada fila de la lista. Sin este índice y con tenants grandes
-- el planner puede caer en seq-scan de clientes.
create index if not exists clientes_cobrador_activo_idx
  on public.clientes (cobrador_id)
  where activo;
