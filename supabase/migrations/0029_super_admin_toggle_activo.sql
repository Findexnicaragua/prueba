-- Batch 1 paso 2 — Activar / Desactivar miembro del tenant
--
-- RPC `set_cobrador_activo(p_cobrador_id, p_activo)`:
--   - Sólo super_admin (errcode 42501 si no).
--   - No permite modificarse a sí mismo (defensa contra auto-baneo).
--   - No permite modificar a otro super_admin (defensa contra escalation
--     entre super_admins en el futuro).
--   - Update directo en public.cobradores.activo, mantiene la fila — no
--     borra nada — así historial / pagos / auditoría siguen referenciando.

create or replace function public.set_cobrador_activo(
  p_cobrador_id uuid,
  p_activo      boolean
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_target_tenant uuid;
  v_target_rol    text;
  v_target_activo boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;

  -- Defensa de auto-modificación. Funciona porque cobradores.id = auth.uid()
  -- por invariante del trigger handle_new_user (migración 0024) — si se
  -- desacopla en el futuro, este check necesita actualizarse.
  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio estado';
  end if;

  select tenant_id, rol, activo
    into v_target_tenant, v_target_rol, v_target_activo
  from public.cobradores
  where id = p_cobrador_id;

  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;

  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar a otro super_admin';
  end if;

  -- Si ya está en el estado pedido, no hacemos nada (idempotencia + evita
  -- registrar audit duplicado).
  if v_target_activo = p_activo then
    return;
  end if;

  update public.cobradores
  set activo = p_activo
  where id = p_cobrador_id;

  -- Auditoría: desactivar/reactivar un usuario es security-sensitive.
  insert into public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) values (
    v_target_tenant,
    'cobradores',
    p_cobrador_id,
    'activo',
    to_jsonb(v_target_activo),
    to_jsonb(p_activo),
    auth.uid(),
    'super_admin'
  );
end;
$$;

revoke all on function public.set_cobrador_activo(uuid, boolean) from public;
grant execute on function public.set_cobrador_activo(uuid, boolean) to authenticated;
