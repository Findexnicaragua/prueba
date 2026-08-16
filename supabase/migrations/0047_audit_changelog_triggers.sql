-- 0047: Change Log genérico — captura full-row en audit_log.
-- Principio: todo feature nuevo debe incluir change log como base.

-- 1. Agregar columna accion (backwards-compatible).
ALTER TABLE public.audit_log ADD COLUMN IF NOT EXISTS accion text NOT NULL DEFAULT 'update';

-- 2. Actualizar helper para aceptar accion.
CREATE OR REPLACE FUNCTION public.audit_registrar(
  p_tenant_id uuid,
  p_tabla text,
  p_registro_id uuid,
  p_campo text,
  p_valor_anterior jsonb,
  p_valor_nuevo jsonb,
  p_accion text DEFAULT 'update'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, accion,
    user_id, user_rol
  ) VALUES (
    p_tenant_id, p_tabla, p_registro_id, p_campo,
    p_valor_anterior, p_valor_nuevo, p_accion,
    auth.uid(), public.current_user_rol()
  );
END;
$$;

-- 3. Trigger genérico full-row (reutilizable para cualquier tabla).
CREATE OR REPLACE FUNCTION public.audit_changelog_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    PERFORM public.audit_registrar(
      NEW.tenant_id, TG_TABLE_NAME, NEW.id, NULL,
      to_jsonb(OLD), to_jsonb(NEW), 'update'
    );
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    PERFORM public.audit_registrar(
      NEW.tenant_id, TG_TABLE_NAME, NEW.id, NULL,
      NULL, to_jsonb(NEW), 'create'
    );
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public.audit_registrar(
      OLD.tenant_id, TG_TABLE_NAME, OLD.id, NULL,
      to_jsonb(OLD), NULL, 'delete'
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

-- 4. Reemplazar triggers específicos con el genérico.
-- Drop old specific triggers para evitar duplicados.
DROP TRIGGER IF EXISTS trg_audit_pagos_anulacion ON public.pagos;
DROP TRIGGER IF EXISTS trg_audit_cuotas_anulacion ON public.cuotas;
DROP TRIGGER IF EXISTS trg_audit_clientes_cobrador ON public.clientes;
DROP TRIGGER IF EXISTS trg_audit_recibos_anulacion ON public.recibos;

-- Crear triggers genéricos (AFTER UPDATE captura ediciones + anulaciones).
-- WHEN pg_trigger_depth() < 2: evita entradas fantasma por triggers en
-- cascada (ej: pago UPDATE → trigger recalcula cuota → fire changelog
-- de cuota con cambios no iniciados por el usuario).
CREATE TRIGGER trg_changelog_pagos
  AFTER UPDATE ON public.pagos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_cuotas
  AFTER UPDATE ON public.cuotas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_clientes
  AFTER UPDATE ON public.clientes
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_contratos
  AFTER UPDATE ON public.contratos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_recibos
  AFTER UPDATE ON public.recibos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- 5. RLS: permitir lectura a admin_cobranza (controlado por setting en UI).
-- Antes solo admin podía leer. Ahora admin + admin_cobranza.
DROP POLICY IF EXISTS "audit_read_admin" ON public.audit_log;

CREATE POLICY "audit_read" ON public.audit_log
  FOR SELECT USING (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

-- 6. Setting: toggle visibilidad para admin_cobranza.
INSERT INTO public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
SELECT id, 'audit.visible_admin_cobranza', 'false'::jsonb, 'boolean', 'cobranza',
       'Permitir a admin de cobranza ver historial de cambios', 'admin'
FROM public.tenants
ON CONFLICT (tenant_id, clave) DO NOTHING;
