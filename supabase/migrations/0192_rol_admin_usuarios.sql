-- 0192 — Fase 3: rol admin_usuarios
--
-- Nuevo rol para personal administrativo que gestiona la cartera de clientes
-- (altas, contratos, suspensiones) SIN acceso a dinero ni cobros.
-- Sub-fase A: permisos directos (sin cola de aprobación).
--
-- Cambios:
--   1. CHECK constraint: agregar 'admin_usuarios'
--   2. handle_new_user: whitelist + prefijo (admin_usuarios NO cobra → sin prefijo)
--   3. set_cobrador_rol: permitir el nuevo rol
--
-- is_admin_or_cobranza() NO se modifica: admin_usuarios no es cobranza.
-- No hay tabla nueva ni columna nueva → sin bump de schema ni sync rules schema.
-- Idempotente (CREATE OR REPLACE + DROP IF EXISTS).

BEGIN;

-- 1. CHECK constraint
ALTER TABLE public.cobradores DROP CONSTRAINT IF EXISTS cobradores_rol_check;
ALTER TABLE public.cobradores ADD CONSTRAINT cobradores_rol_check
  CHECK (rol IN ('super_admin','admin','admin_cobranza','cobrador',
                 'tecnico','admin_tickets','admin_usuarios'));

-- 2. handle_new_user: agregar 'admin_usuarios' a la whitelist.
-- Partido del cuerpo VIGENTE de 0176. admin_usuarios NO cobra → sin prefijo
-- (cae al else null del CASE).
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id      uuid;
  v_rol            text;
  v_nombre         text;
  v_telefono       text;
  v_prefijo        text;
  v_empresa_nombre text;
BEGIN
  v_tenant_id      := (new.raw_user_meta_data ->> 'tenant_id')::uuid;
  v_rol            := coalesce(new.raw_user_meta_data ->> 'rol', 'admin');
  v_nombre         := coalesce(
                        new.raw_user_meta_data ->> 'nombre',
                        split_part(new.email, '@', 1)
                      );
  v_telefono       := new.raw_user_meta_data ->> 'telefono';
  v_prefijo        := new.raw_user_meta_data ->> 'prefijo_recibo';
  v_empresa_nombre := new.raw_user_meta_data ->> 'empresa_nombre';

  IF v_rol NOT IN ('super_admin', 'admin', 'admin_cobranza', 'cobrador',
                   'tecnico', 'admin_tickets', 'admin_usuarios') THEN
    v_rol := 'admin';
  END IF;

  IF v_rol = 'super_admin' THEN
    v_tenant_id := '00000000-0000-0000-0000-000000000000';
  ELSIF v_tenant_id IS NULL THEN
    INSERT INTO public.tenants (nombre)
      VALUES (coalesce(v_empresa_nombre, 'Mi ISP'))
      RETURNING id INTO v_tenant_id;
    v_rol := 'admin';
  END IF;

  INSERT INTO public.cobradores (
    id, tenant_id, nombre, telefono, rol, prefijo_recibo, activo
  ) VALUES (
    new.id, v_tenant_id, v_nombre, v_telefono, v_rol,
    CASE WHEN v_rol IN ('cobrador', 'admin', 'admin_cobranza')
         THEN v_prefijo ELSE NULL END,
    true
  )
  ON CONFLICT (id) DO UPDATE
    SET tenant_id      = excluded.tenant_id,
        nombre         = excluded.nombre,
        telefono       = excluded.telefono,
        rol            = excluded.rol,
        prefijo_recibo = excluded.prefijo_recibo;

  RETURN new;
END;
$$;

-- 3. set_cobrador_rol: agregar admin_usuarios.
-- Partido del cuerpo VIGENTE de 0140. admin_usuarios NO cobra → sin prefijo.
CREATE OR REPLACE FUNCTION public.set_cobrador_rol(p_cobrador_id uuid, p_nuevo_rol text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_target_rol text;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin' USING errcode = '42501';
  END IF;
  IF p_cobrador_id = auth.uid() THEN
    RAISE EXCEPTION 'No podés modificar tu propio rol';
  END IF;
  IF p_nuevo_rol NOT IN ('admin','admin_cobranza','cobrador','tecnico','admin_tickets','admin_usuarios') THEN
    RAISE EXCEPTION 'Rol inválido. Permitidos: admin, admin_cobranza, cobrador, tecnico, admin_tickets, admin_usuarios';
  END IF;
  SELECT rol INTO v_target_rol FROM public.cobradores WHERE id = p_cobrador_id FOR UPDATE;
  IF v_target_rol IS NULL THEN
    RAISE EXCEPTION 'Cobrador no existe' USING errcode = 'P0002';
  END IF;
  IF v_target_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede modificar el rol de otro super_admin';
  END IF;
  IF v_target_rol = p_nuevo_rol THEN
    RETURN;
  END IF;
  UPDATE public.cobradores
     SET rol = p_nuevo_rol,
         prefijo_recibo = CASE WHEN p_nuevo_rol IN ('cobrador','admin','admin_cobranza')
                               THEN prefijo_recibo ELSE NULL END
   WHERE id = p_cobrador_id;
END;
$fn$;

COMMIT;
