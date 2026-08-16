-- Batch 2 — Cambiar rol de un miembro del tenant
--
-- RPC `set_cobrador_rol(p_cobrador_id, p_nuevo_rol)`:
--   - Sólo super_admin (errcode 42501 si no).
--   - No permite modificarse a sí mismo.
--   - No permite modificar a otro super_admin (defensa contra escalation
--     entre super_admins).
--   - El nuevo rol debe ser uno de: admin / admin_cobranza / cobrador.
--     No permite escalar a super_admin desde acá (el rol super_admin se
--     asigna sólo manualmente por el dueño del SaaS).
--   - Idempotencia: si ya tiene el rol pedido, no hace nada (no escribe
--     audit duplicado).
--   - Limpieza de prefijo_recibo: si el target deja de ser cobrador,
--     prefijo se setea a NULL (no aplica a otros roles).
--   - Audit log: registra el cambio de rol con valor anterior/nuevo.
--
-- Nota: si el cobrador afectado está logueado en otra sesión, sus reglas
-- de sync de PowerSync (que dependen del rol) sólo se actualizan al
-- próximo login. El super_admin debería avisar al usuario que cierre
-- sesión y vuelva a entrar para ver el panel correcto.

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

  -- Si deja de ser cobrador, prefijo_recibo no aplica.
  update public.cobradores
  set rol = p_nuevo_rol,
      prefijo_recibo = case
        when p_nuevo_rol = 'cobrador' then prefijo_recibo
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
