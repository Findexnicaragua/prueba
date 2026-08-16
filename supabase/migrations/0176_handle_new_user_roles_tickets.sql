-- 0176 — handle_new_user: soportar roles de tickets + prefijo para admins
--
-- BUG 1 (CRÍTICO, escalación de privilegios — audit Fase 3 2026-07-05):
-- invitar un 'tecnico' o 'admin_tickets' creaba un usuario con rol='admin'.
-- La UI (cobradores) ofrece esos roles y la edge function invitar-cobrador los
-- acepta, pero el trigger handle_new_user (0026) coacciona todo rol fuera de
-- (super_admin,admin,admin_cobranza,cobrador) a 'admin'. El CHECK (0103) y
-- set_cobrador_rol (0140) SÍ se actualizaron con los roles de tickets; el
-- trigger quedó desincronizado → el técnico invitado entraba con acceso total
-- del tenant (clientes, cobros, settings). Fix: agregar 'tecnico','admin_tickets'
-- a la whitelist de v_rol.
--
-- BUG 2 (MEDIO, dato perdido — mismo trigger): al invitar un admin/admin_cobranza
-- con prefijo de recibo, el prefijo se descartaba (solo se guardaba para
-- 'cobrador'). El cliente y la edge function ya lo mandan para los 3 roles que
-- cobran y set_cobrador_rol los trata por igual. Fix: guardar el prefijo para
-- ('cobrador','admin','admin_cobranza').
--
-- Partido del cuerpo VIGENTE (0026:186; 0029/0066 solo lo mencionan en
-- comentarios) — se preserva completo; solo cambian las líneas 208 y 225.
-- Idempotente (CREATE OR REPLACE); no re-descarga nada (no toca schema cliente).

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
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

  if v_rol not in ('super_admin', 'admin', 'admin_cobranza', 'cobrador',
                   'tecnico', 'admin_tickets') then
    v_rol := 'admin';
  end if;

  if v_rol = 'super_admin' then
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  elsif v_tenant_id is null then
    insert into public.tenants (nombre)
      values (coalesce(v_empresa_nombre, 'Mi ISP'))
      returning id into v_tenant_id;
    v_rol := 'admin';
  end if;

  insert into public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) values (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    case when v_rol in ('cobrador', 'admin', 'admin_cobranza')
         then v_prefijo else null end,
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
