-- Auto-creación de filas en `cobradores` cuando un usuario se registra
-- en auth.users. Resuelve dos casos:
--
--   A) Bootstrap del primer admin:
--      Sin metadata.tenant_id → crea un tenant nuevo y asigna rol=admin.
--      El nombre de la empresa puede venir en metadata.empresa_nombre
--      (sino default 'Mi ISP', se ajusta en onboarding wizard).
--
--   B) Invitación de un usuario por admin (Edge Function 'invitar-cobrador'):
--      metadata.tenant_id presente + rol + nombre + prefijo (opcional).
--      Crea la fila en cobradores ligada a ese tenant.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
begin
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  -- Validar rol.
  if v_rol not in ('admin', 'admin_cobranza', 'cobrador') then
    v_rol := 'admin';
  end if;

  -- Caso A: bootstrap del primer admin (sin tenant en metadata).
  if v_tenant_id is null then
    insert into public.tenants (nombre)
      values (coalesce(v_empresa_nombre, 'Mi ISP'))
      returning id into v_tenant_id;
    -- El trigger trg_tenants_seed_settings se dispara aquí (settings default).
    v_rol := 'admin';  -- el primer usuario del tenant SIEMPRE es admin.
  end if;

  -- Caso B: usuario invitado por admin existente, con tenant ya determinado.
  -- Insertamos la fila en cobradores. ON CONFLICT por si esto se ejecuta
  -- doble (raro: trigger inviteUserByEmail + signup).
  insert into public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) values (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    case when v_rol = 'cobrador' then v_prefijo else null end,
    true
  )
  on conflict (id) do update
    set tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  return new;
end;
$$;

-- Trigger AFTER INSERT en auth.users (esquema controlado por Supabase).
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
