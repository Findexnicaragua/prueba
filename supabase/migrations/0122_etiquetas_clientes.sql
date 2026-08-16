-- 0122: Módulo de Etiquetas personalizables para clientes (P5).
--
-- Feature CORE (NO gateada por tenant_modulos): todos los tenants la tienen.
-- Dos tablas (R10 ×2):
--   - etiquetas: catálogo por tenant (nombre + color hex + icono clave).
--     CRUD del admin/admin_cobranza desde Ajustes.
--   - cliente_etiquetas: relación M2M cliente↔etiqueta. ASIGNAR/QUITAR solo
--     admin/admin_cobranza (decisión P5); el cobrador la LEE (sus clientes).
--
-- Sync al cobrador: el bucket por_cobrador filtra por cobrador_id, así que
-- cliente_etiquetas DENORMALIZA cobrador_id (igual que cuotas/fotos_cliente,
-- 0055/0068). BEFORE INSERT lo copia del cliente; la cascada consolidada de
-- reasignación (propagate_cobrador_id_from_cliente, 0068) lo mantiene al
-- mover el cliente de cobrador. NULL = cliente admin-managed sin cobrador
-- (P3b) → no baja a ningún cobrador.

-- =========================================================================
-- 1. Tablas
-- =========================================================================
CREATE TABLE public.etiquetas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  color text NOT NULL,                 -- hex "#RRGGBB"
  icono text NOT NULL,                 -- clave del icono (mapeada en Dart)
  orden int NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz,             -- device-time UTC (audit offline)
  UNIQUE (tenant_id, nombre)
);

CREATE TABLE public.cliente_etiquetas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  etiqueta_id uuid NOT NULL REFERENCES public.etiquetas(id) ON DELETE CASCADE,
  -- Denormalizado para el bucket por_cobrador. Lo setea el BEFORE INSERT y lo
  -- mantiene la cascada de reasignación. NULL = sin cobrador (admin-managed).
  cobrador_id uuid REFERENCES public.cobradores(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz,
  UNIQUE (tenant_id, cliente_id, etiqueta_id)
);

CREATE INDEX cliente_etiquetas_by_cliente
  ON public.cliente_etiquetas (tenant_id, cliente_id);
CREATE INDEX cliente_etiquetas_by_etiqueta
  ON public.cliente_etiquetas (tenant_id, etiqueta_id);
CREATE INDEX cliente_etiquetas_by_cobrador
  ON public.cliente_etiquetas (tenant_id, cobrador_id);

-- =========================================================================
-- 2. Denormalización de cobrador_id (para sync rules del cobrador)
-- =========================================================================
-- 2a. Al asignar una etiqueta, copiar el cobrador_id actual del cliente.
CREATE OR REPLACE FUNCTION public.cliente_etiquetas_set_cobrador_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.cobrador_id := (
    SELECT cobrador_id FROM public.clientes WHERE id = NEW.cliente_id
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cliente_etiquetas_set_cobrador
  BEFORE INSERT ON public.cliente_etiquetas
  FOR EACH ROW EXECUTE FUNCTION public.cliente_etiquetas_set_cobrador_trg();

-- 2b. Extender la cascada consolidada (0068): al reasignar el cliente,
-- actualizar el cobrador_id de sus etiquetas. CREATE OR REPLACE reemplaza la
-- función entera → se reproduce el cuerpo vigente (0068) + el bloque nuevo.
CREATE OR REPLACE FUNCTION public.propagate_cobrador_id_from_cliente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.cobrador_id IS DISTINCT FROM OLD.cobrador_id THEN
    UPDATE public.contratos
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- Solo cuotas operativas. Las pagadas/anuladas preservan el cobrador_id
    -- del momento del pago (historial inmutable).
    UPDATE public.cuotas
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id
       AND estado IN ('pendiente','parcial');

    UPDATE public.notificaciones_mora
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id
       AND resuelta_en IS NULL;

    UPDATE public.cargos_extra
       SET cobrador_id = NEW.cobrador_id
     WHERE cuota_id IN (
       SELECT id FROM public.cuotas
        WHERE cliente_id = NEW.id
          AND estado IN ('pendiente','parcial')
     );

    UPDATE public.fotos_cliente
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- cliente_etiquetas (P5): organizativo, sigue al cliente.
    UPDATE public.cliente_etiquetas
       SET cobrador_id = NEW.cobrador_id
     WHERE cliente_id = NEW.id;

    -- pagos / recibos NO se propagan: snapshot histórico inmutable.
  END IF;
  RETURN NEW;
END;
$$;

-- =========================================================================
-- 3. RLS — read: miembro del tenant (el cobrador ve las de sus clientes vía
--    sync rules); write: admin/admin_cobranza; super_admin_all a mano.
-- =========================================================================
ALTER TABLE public.etiquetas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cliente_etiquetas ENABLE ROW LEVEL SECURITY;

-- etiquetas (catálogo: read/insert/update/delete del admin)
CREATE POLICY "etiquetas_read" ON public.etiquetas
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "etiquetas_insert" ON public.etiquetas
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "etiquetas_update" ON public.etiquetas
  FOR UPDATE USING (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "etiquetas_delete" ON public.etiquetas
  FOR DELETE USING (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.etiquetas
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- cliente_etiquetas (M2M: read de todos; assign/unassign = insert/delete del
-- admin. No hay UPDATE de usuario — cobrador_id lo mueve la cascada DEFINER).
CREATE POLICY "cliente_etiquetas_read" ON public.cliente_etiquetas
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "cliente_etiquetas_insert" ON public.cliente_etiquetas
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "cliente_etiquetas_delete" ON public.cliente_etiquetas
  FOR DELETE USING (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.cliente_etiquetas
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- =========================================================================
-- 4. Audit log (trigger genérico, guard de profundidad < 2: las updates de
--    cobrador_id por cascada NO se loguean, igual que en cuotas)
-- =========================================================================
CREATE TRIGGER trg_changelog_etiquetas
  AFTER INSERT OR UPDATE OR DELETE ON public.etiquetas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_cliente_etiquetas
  AFTER INSERT OR UPDATE OR DELETE ON public.cliente_etiquetas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();
