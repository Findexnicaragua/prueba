-- Migración 0093: set_cobrador_rol conserva el prefijo de los roles que cobran.
--
-- La versión original (0030) limpiaba prefijo_recibo a NULL para cualquier
-- rol distinto de 'cobrador'. Ahora que los 3 roles que cobran (cobrador /
-- admin / admin_cobranza) llevan prefijo, ese borrado al cambiar de rol
-- entre ellos perdería el correlativo del usuario.
--
-- Cambio MÍNIMO: el CASE de prefijo_recibo ahora conserva el prefijo cuando
-- el rol nuevo es cobrador, admin o admin_cobranza; sólo lo limpia para
-- super_admin (rol que igual no se puede asignar desde esta RPC — el guard
-- de p_nuevo_rol lo rechaza — pero lo dejamos explícito por claridad). El
-- resto de la lógica (guards, idempotencia, audit) se preserva idéntico.

create or replace function public.set_cobrador_rol(
  p_cobrador_id uuid,
  p_nuevo_rol   text
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_target_tenant uuid;
  v_target_rol    text;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio rol';
  end if;

  if p_nuevo_rol not in ('admin', 'admin_cobranza', 'cobrador') then
    raise exception
      'Rol inválido. Permitidos: admin, admin_cobranza, cobrador';
  end if;

  -- FOR UPDATE: lock de la fila para que dos super_admins concurrentes no
  -- pasen ambos el check de idempotencia y escriban audit rows con
  -- valores anterior/nuevo inconsistentes.
  select tenant_id, rol
    into v_target_tenant, v_target_rol
  from public.cobradores
  where id = p_cobrador_id
  for update;

  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;

  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar el rol de otro super_admin';
  end if;

  -- Idempotencia.
  if v_target_rol = p_nuevo_rol then
    return;
  end if;

  -- El prefijo se conserva para los 3 roles que cobran (cobrador, admin,
  -- admin_cobranza). Sólo se limpiaría para super_admin (inalcanzable acá
  -- por el guard de p_nuevo_rol, pero explícito por claridad).
  update public.cobradores
  set rol = p_nuevo_rol,
      prefijo_recibo = case
        when p_nuevo_rol in ('cobrador', 'admin', 'admin_cobranza')
          then prefijo_recibo
        else null
      end
  where id = p_cobrador_id;

  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) values (
    v_target_tenant,
    'cobradores',
    p_cobrador_id,
    'rol',
    to_jsonb(v_target_rol),
    to_jsonb(p_nuevo_rol),
    auth.uid(),
    'super_admin'
  );
end;
$$;

revoke all on function public.set_cobrador_rol(uuid, text) from public;
grant execute on function public.set_cobrador_rol(uuid, text) to authenticated;
