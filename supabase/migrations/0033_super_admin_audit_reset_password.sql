-- Auditoría del reset password vía email (cliente)
--
-- El flow de reset password se ejecuta del lado cliente con
-- auth.resetPasswordForEmail (API pública), sin pasar por Edge Function.
-- Eso significa que no quedaba registro del intento en audit_log a
-- diferencia del resto de las acciones del panel super_admin.
--
-- Esta RPC permite al cliente registrar el evento en audit_log con los
-- mismos guards de seguridad (sólo super_admin) y el mismo formato del
-- resto de los audit entries. El cliente la llama tras un reset exitoso.
--
-- Race conocida: si el reset email se envió pero la RPC de audit falla,
-- el audit queda incompleto. Acceptable porque el cobrador puede ver el
-- email de reset igual y completar el flow; el audit row es para
-- trazabilidad del super_admin, no para correctness funcional.

create or replace function public.audit_reset_password(p_cobrador_id uuid)
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

  select tenant_id, rol
    into v_target_tenant, v_target_rol
  from public.cobradores
  where id = p_cobrador_id;

  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;

  if v_target_rol = 'super_admin' then
    raise exception 'No se puede auditar reset de otro super_admin';
  end if;

  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) values (
    v_target_tenant,
    'auth.users',
    p_cobrador_id,
    'reset_password_email',
    null,
    jsonb_build_object('action', 'reset_password_email_sent'),
    auth.uid(),
    'super_admin'
  );
end;
$$;

revoke all on function public.audit_reset_password(uuid) from public;
grant execute on function public.audit_reset_password(uuid) to authenticated;
