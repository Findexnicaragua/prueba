-- Batch 1 — Listar miembros de un tenant (panel Super Admin)
--
-- RPC `list_cobradores_tenant` que devuelve la lista de cobradores de un
-- tenant + metadata de auth.users (email, último login, invitación
-- pendiente). Sólo super_admin la puede llamar. No expone System.
--
-- El orden es: activos primero, luego por jerarquía de rol (admin >
-- admin_cobranza > cobrador), luego por nombre alfabético.

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
  invited_at          timestamptz
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
      u.invited_at
    from public.cobradores c
    join auth.users u on u.id = c.id
    where c.tenant_id = p_tenant_id
      -- Defensa: filas super_admin no deberían tener un tenant_id distinto a
      -- System, pero por si quedaron históricas, no las exponemos al panel
      -- de otro tenant.
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
