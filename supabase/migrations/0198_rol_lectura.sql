-- 0198 — Rol `lectura` ("Solo lectura")
--
-- Rol para los dueños del ISP: ve TODO el tenant (incluida la plata) y no
-- puede modificar NADA. Pedido por los dueños de los tenants.
--
-- Modelo de permisos: se agregan policies de SELECT y NINGUNA de escritura.
-- El rol queda fuera de `is_admin_or_cobranza()` A PROPÓSITO — esa función
-- gatea también INSERT/UPDATE/DELETE, así que meterlo ahí le daría permiso de
-- escritura sobre medio esquema. Por eso las policies nuevas son propias y
-- exclusivamente `FOR SELECT`.
--
-- Excepción única de escritura: su propio PIN del dashboard, vía la RPC
-- `set_mi_dashboard_pin` (SECURITY DEFINER, acotada a auth.uid() y a esa sola
-- columna). No se abre policy de UPDATE sobre `cobradores`: una policy
-- `USING (id = auth.uid())` dejaría que el usuario se editara nombre, teléfono
-- y prefijo, y el rol solo lo frena el trigger cobradores_freeze_rol.
--
-- Idempotente (DROP IF EXISTS + CREATE OR REPLACE).

BEGIN;

-- 1. CHECK constraint: sumar 'lectura'
ALTER TABLE public.cobradores DROP CONSTRAINT IF EXISTS cobradores_rol_check;
ALTER TABLE public.cobradores ADD CONSTRAINT cobradores_rol_check
  CHECK (rol IN ('super_admin','admin','admin_cobranza','cobrador',
                 'tecnico','admin_tickets','admin_usuarios','lectura'));

-- 2. handle_new_user: whitelist + prefijo.
-- Partido del cuerpo VIGENTE en la DB (= 0192, verificado antes de escribir
-- esta migración). `lectura` NO cobra → cae al ELSE NULL del CASE del prefijo.
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
                   'tecnico', 'admin_tickets', 'admin_usuarios', 'lectura') THEN
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

-- 3. set_cobrador_rol: permitir migrar a/desde 'lectura'.
-- Partido del cuerpo VIGENTE (= 0192, verificado). `lectura` NO cobra.
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
  IF p_nuevo_rol NOT IN ('admin','admin_cobranza','cobrador','tecnico','admin_tickets','admin_usuarios','lectura') THEN
    RAISE EXCEPTION 'Rol inválido. Permitidos: admin, admin_cobranza, cobrador, tecnico, admin_tickets, admin_usuarios, lectura';
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

-- 4. Helper de rol.
CREATE OR REPLACE FUNCTION public.is_lectura()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.current_user_rol() = 'lectura'
$$;

-- 5. Policies de SELECT (y SOLO de SELECT) sobre las tablas tenant-scoped.
-- La lista sale de: toda tabla con RLS + columna `tenant_id`, MENOS las que son
-- del panel super_admin (super_admin_impersonation, data_op_backups,
-- data_ops_log). `modulos`/`tenants` no se sincronizan al cliente.
DO $do$
DECLARE
  t text;
  tablas text[] := ARRAY[
    'cargos_extra','cliente_etiquetas','clientes','cobradores','comunidades',
    'contrato_suspensiones','contratos','cuotas','departamentos','etiquetas',
    'fotos_cliente','incidentes','inv_categorias','inv_movimientos',
    'inv_productos','inv_proveedores','inv_seriales','inv_ubicaciones',
    'municipios','notificaciones_mora','op_log','pagos','planes','recibos',
    'red_hubs','red_nodos','red_puertos','saldos_favor','settings',
    'solicitudes_accion','tenant_modulos','ticket_adjuntos','ticket_eventos',
    'ticket_materiales','ticket_tipos','tickets','visitas','whatsapp_envios'
  ];
BEGIN
  FOREACH t IN ARRAY tablas LOOP
    EXECUTE format('DROP POLICY IF EXISTS lectura_select ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY lectura_select ON public.%I FOR SELECT '
      'USING (tenant_id = public.current_tenant_id() AND public.is_lectura())', t);
  END LOOP;
END
$do$;

-- 6. Única escritura permitida al rol: su PROPIO PIN del dashboard.
--
-- Va por RPC y no por la tabla porque el cliente del rol `lectura` descarta su
-- cola de subida de PowerSync (barrera 2): un UPDATE local nunca llegaría al
-- server y el PIN se perdería al re-sincronizar. La RPC escribe server-side y
-- PowerSync lo baja de vuelta. Sirve igual para el resto de los roles.
CREATE OR REPLACE FUNCTION public.set_mi_dashboard_pin(p_pin text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING errcode = '42501';
  END IF;
  -- '' = quitar el PIN. Cualquier otro valor debe ser exactamente 4 dígitos.
  IF p_pin <> '' AND p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'El PIN debe tener 4 dígitos';
  END IF;
  UPDATE public.cobradores SET dashboard_pin = p_pin WHERE id = auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION public.set_mi_dashboard_pin(text) FROM public;
GRANT EXECUTE ON FUNCTION public.set_mi_dashboard_pin(text) TO authenticated;

COMMIT;
