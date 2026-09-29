-- 0250_atribucion_rpc_super_admin.sql
--
-- QUE: darle rastro a las 5 RPC del panel del super_admin que hoy no escriben
-- NI op_log NI data_ops_log. Verificado 2026-08-23: las 5 dan false en las dos.
--
-- POR QUE: hoy no hay forma de contestar "quien convirtio a X en
-- admin_cobranza", "quien desactivo a este cobrador" ni "quien le reseteo el
-- PIN del dashboard". El ROL decide quien cobra y quien ve la plata. Y peor:
-- `set_cobrador_rol` BORRA `prefijo_recibo` en silencio al degradar a un rol
-- sin cobro - el prefijo es la numeracion del talonario de esa persona, y su
-- perdida no queda registrada en ningun lado.
--
-- DONDE VA CADA UNA:
--   - las 3 de `cobradores` -> `op_log`, entidad 'cobradores'. Se ven SOLAS,
--     sin build: la pantalla de Personal ya monta HistorialOpLog con esa
--     entidad (cobradores_admin_screen.dart). Registro nuevo, cero Dart.
--   - las 2 de `tenants` -> `data_ops_log`. No tienen pantalla de historial
--     dentro del tenant; su lugar es el log de operaciones del Dev.
--
-- ORDEN (importa): el INSERT va SIEMPRE DESPUES del UPDATE, nunca antes. Tres
-- de estas funciones tienen un `RETURN` temprano cuando el valor no cambia; un
-- insert arriba registraria cambios que no ocurrieron.
--
-- PARTIDA: pg_get_functiondef() de las definiciones VIVAS. Los acentos de los
-- mensajes de error se verificaron con chr() contra la base ANTES de reescribir
-- (leccion 0218: un mojibake en un literal comparado contra data crea un falso
-- positivo permanente; aca son mensajes de error, pero un 'Rol invalido' con
-- rombo es igual de feo y se arrastra para siempre).
--
-- ACTOR: `actor_id` NULL + `actor_label` 'System Admin' es la convencion ya
-- vigente para el super_admin (848 filas). `auth.uid()` NO se usa como actor_id
-- en op_log porque el super_admin no pertenece al tenant que esta tocando.

-- ===========================================================================
-- 1) set_cobrador_rol
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.set_cobrador_rol(p_cobrador_id uuid, p_nuevo_rol text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_target_rol     text;
  v_target_prefijo text;
  v_tenant         uuid;
  v_campos         jsonb;
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
  SELECT rol, prefijo_recibo, tenant_id
    INTO v_target_rol, v_target_prefijo, v_tenant
    FROM public.cobradores WHERE id = p_cobrador_id FOR UPDATE;
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

  -- Rastro. El campo `prefijo_recibo` SOLO se agrega si efectivamente se
  -- perdio: la misma condicion del CASE de arriba, negada. Es el dato que se
  -- borraba en silencio.
  v_campos := jsonb_build_array(
    jsonb_build_object('campo','rol','antes',v_target_rol,'despues',p_nuevo_rol));
  IF v_target_prefijo IS NOT NULL
     AND p_nuevo_rol NOT IN ('cobrador','admin','admin_cobranza') THEN
    v_campos := v_campos || jsonb_build_array(
      jsonb_build_object('campo','prefijo_recibo','antes',v_target_prefijo,'despues',NULL));
  END IF;

  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  VALUES (gen_random_uuid(), v_tenant, gen_random_uuid(), 'edicion_entidad',
          'cobradores', p_cobrador_id, NULL, 'System Admin', 'update',
          jsonb_build_object('campos', v_campos)::text, now());
END;
$function$;

-- ===========================================================================
-- 2) set_cobrador_activo
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.set_cobrador_activo(p_cobrador_id uuid, p_activo boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_target_rol    text;
  v_target_activo boolean;
  v_tenant        uuid;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;
  if p_cobrador_id = auth.uid() then
    raise exception 'No podés modificar tu propio estado';
  end if;
  select rol, activo, tenant_id into v_target_rol, v_target_activo, v_tenant
    from public.cobradores where id = p_cobrador_id;
  if v_target_rol is null then
    raise exception 'Cobrador no existe' using errcode = 'P0002';
  end if;
  if v_target_rol = 'super_admin' then
    raise exception 'No se puede modificar a otro super_admin';
  end if;
  if v_target_activo = p_activo then
    return;
  end if;
  update public.cobradores set activo = p_activo where id = p_cobrador_id;

  insert into public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  values (gen_random_uuid(), v_tenant, gen_random_uuid(), 'edicion_entidad',
          'cobradores', p_cobrador_id, null, 'System Admin', 'update',
          jsonb_build_object('campos', jsonb_build_array(
            jsonb_build_object('campo','activo','antes',v_target_activo,
                               'despues',p_activo)))::text, now());
end;
$function$;

-- ===========================================================================
-- 3) forzar_reset_dashboard_pin
--    NUNCA registrar el PIN, ni el viejo ni el nuevo. Solo el hecho.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.forzar_reset_dashboard_pin(p_cobrador_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_mi_rol    text;
  v_mi_tenant uuid;
  v_mi_nombre text;
  v_su_rol    text;
  v_su_tenant uuid;
BEGIN
  SELECT rol, tenant_id, nombre INTO v_mi_rol, v_mi_tenant, v_mi_nombre
    FROM public.cobradores WHERE id = auth.uid();
  IF v_mi_rol IS NULL THEN
    RAISE EXCEPTION 'No autorizado' USING errcode = '42501';
  END IF;
  IF v_mi_rol NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar el cambio de PIN'
      USING errcode = '42501';
  END IF;

  SELECT rol, tenant_id INTO v_su_rol, v_su_tenant
    FROM public.cobradores WHERE id = p_cobrador_id;
  IF v_su_rol IS NULL THEN
    RAISE EXCEPTION 'Ese usuario no existe' USING errcode = 'P0002';
  END IF;
  IF v_su_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede forzar el PIN de un super_admin';
  END IF;
  IF v_mi_rol <> 'super_admin' AND v_su_tenant <> v_mi_tenant THEN
    RAISE EXCEPTION 'Ese usuario es de otra empresa' USING errcode = '42501';
  END IF;

  UPDATE public.cobradores  SET dashboard_pin = '' WHERE id = p_cobrador_id;
  UPDATE public.dashboard_pins SET pin = '', updated_at = now()
   WHERE id = p_cobrador_id;

  -- A diferencia de las otras dos, esta la puede correr un `admin` del ISP
  -- (no solo el super_admin) -> el actor se atribuye de verdad cuando existe.
  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  VALUES (gen_random_uuid(), v_su_tenant, gen_random_uuid(), 'editar',
          'cobradores', p_cobrador_id,
          CASE WHEN v_mi_rol = 'super_admin' THEN NULL ELSE auth.uid() END,
          CASE WHEN v_mi_rol = 'super_admin' THEN 'System Admin'
               ELSE coalesce(v_mi_nombre, 'Administrador') END,
          'update',
          jsonb_build_object('campos', '[]'::jsonb, 'resumen',
            jsonb_build_object('motivo',
              'PIN del dashboard reseteado por el administrador. La persona '
              'define uno nuevo la próxima vez que abre el dashboard.'))::text,
          now());
END;
$function$;

-- ===========================================================================
-- 4) set_tenant_modulo  -> data_ops_log
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.set_tenant_modulo(p_tenant_id uuid, p_modulo text, p_habilitado boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_es_base   boolean;
  v_nombre    text;
  v_antes     boolean;
begin
  if not public.is_super_admin() then
    raise exception 'Solo super_admin' using errcode = '42501';
  end if;
  if p_tenant_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'No se puede modificar el tenant System';
  end if;
  select es_base, nombre into v_es_base, v_nombre
    from public.modulos where codigo = p_modulo;
  if v_es_base is null then
    raise exception 'Módulo % no existe', p_modulo;
  end if;
  if v_es_base and not p_habilitado then
    raise exception 'Módulo % es base y no se puede deshabilitar', p_modulo;
  end if;

  select habilitado into v_antes from public.tenant_modulos
   where tenant_id = p_tenant_id and modulo_codigo = p_modulo;

  insert into public.tenant_modulos (tenant_id, modulo_codigo, habilitado, habilitado_en, habilitado_por)
  values (p_tenant_id, p_modulo, p_habilitado, now(), auth.uid())
  on conflict (tenant_id, modulo_codigo) do update
    set habilitado     = excluded.habilitado,
        habilitado_en  = excluded.habilitado_en,
        habilitado_por = excluded.habilitado_por;

  -- Solo si CAMBIO algo. Prender un modulo ya prendido no es un evento.
  if v_antes is distinct from p_habilitado then
    insert into public.data_ops_log (tenant_id, operacion, target_label,
        afectados, backup_id, actor_id, actor_label)
    values (p_tenant_id,
        case when p_habilitado then 'modulo_habilitado' else 'modulo_deshabilitado' end,
        coalesce(v_nombre, p_modulo),
        jsonb_build_object('modulo', p_modulo, 'antes', v_antes,
                           'despues', p_habilitado),
        null, auth.uid(), 'System Admin');
  end if;
end;
$function$;

-- ===========================================================================
-- 5) set_tenant_activo -> data_ops_log
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.set_tenant_activo(p_tenant_id uuid, p_activo boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_antes  boolean;
  v_nombre text;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin' USING errcode = '42501';
  END IF;
  IF p_tenant_id = '00000000-0000-0000-0000-000000000000' THEN
    RAISE EXCEPTION 'No se puede suspender el tenant System';
  END IF;

  SELECT activo, nombre INTO v_antes, v_nombre
    FROM public.tenants WHERE id = p_tenant_id;

  UPDATE public.tenants SET activo = p_activo WHERE id = p_tenant_id;

  -- El `v_nombre IS NOT NULL` NO es paranoia: si el tenant no existe el UPDATE
  -- no afecta filas (comportamiento historico, que NO se cambia acá) y
  -- `target_label` es NOT NULL. Sin el guard, ese caso pasaria de no-op
  -- silencioso a excepcion - un cambio de conducta que nadie pidio.
  IF v_nombre IS NOT NULL AND v_antes IS DISTINCT FROM p_activo THEN
    INSERT INTO public.data_ops_log (tenant_id, operacion, target_label,
        afectados, backup_id, actor_id, actor_label)
    VALUES (p_tenant_id,
        CASE WHEN p_activo THEN 'tenant_reactivado' ELSE 'tenant_suspendido' END,
        v_nombre,
        jsonb_build_object('antes', v_antes, 'despues', p_activo),
        NULL, auth.uid(), 'System Admin');
  END IF;
END;
$function$;
