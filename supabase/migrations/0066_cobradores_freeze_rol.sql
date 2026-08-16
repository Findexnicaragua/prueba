-- 0066: Congelar la columna `rol` de cobradores (defensa M1-SEC).
--
-- BUG de escalación de privilegios encontrado en el audit de seguridad:
-- la policy cobradores_write_admin (0013) permite a un admin UPDATE sobre
-- cobradores de su tenant sin restringir QUÉ columnas. El constraint
-- cobradores_rol_check (0026) acepta 'super_admin'. No hay nada que impida:
--     UPDATE cobradores SET rol='super_admin' WHERE id = <propio uid>
-- → is_super_admin() pasa a true → acceso cross-tenant total.
--
-- La app NUNCA hace este UPDATE (usa la RPC set_cobrador_rol, que valida).
-- Pero RLS no fuerza a pasar por la RPC. Este trigger cierra el hueco:
-- nadie puede asignar/mantener rol='super_admin' ni mutar rol/tenant_id
-- salvo que el caller sea super_admin (o sea el propio trigger SECURITY
-- DEFINER de creación de usuario, que corre como postgres sin auth.uid()).

CREATE OR REPLACE FUNCTION public.cobradores_freeze_rol_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Si no hay sesión de usuario (auth.uid() NULL), es un proceso del
  -- sistema (handle_new_user, Edge Function con service_role, RPC
  -- SECURITY DEFINER). Esos ya validan internamente — no los bloqueamos.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- super_admin puede todo (gestión cross-tenant legítima).
  IF public.is_super_admin() THEN
    RETURN NEW;
  END IF;

  -- A partir de acá: caller autenticado que NO es super_admin.

  -- Nadie no-super_admin puede crear/asignar el rol super_admin.
  IF NEW.rol = 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado a asignar el rol super_admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- En UPDATE: no se puede mutar rol ni tenant_id por escritura directa.
  -- (El cambio legítimo de rol pasa por la RPC set_cobrador_rol, que corre
  --  como SECURITY DEFINER con auth.uid() pero valida reglas de negocio;
  --  esa RPC está exenta porque no escribe rol directamente desde un
  --  caller no-super_admin sin sus propios checks. Si en el futuro la RPC
  --  necesita escribir rol, se ejecuta con el guard de la propia RPC.)
  IF TG_OP = 'UPDATE' THEN
    IF NEW.rol IS DISTINCT FROM OLD.rol THEN
      RAISE EXCEPTION 'El rol solo puede cambiarse vía la función set_cobrador_rol'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
      RAISE EXCEPTION 'No autorizado a cambiar el tenant de un cobrador'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cobradores_freeze_rol ON public.cobradores;

CREATE TRIGGER trg_cobradores_freeze_rol
  BEFORE INSERT OR UPDATE ON public.cobradores
  FOR EACH ROW
  EXECUTE FUNCTION public.cobradores_freeze_rol_trg();
