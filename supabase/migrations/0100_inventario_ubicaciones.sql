-- 0100: Inventario — Sub-fase 2B. Ubicaciones (bodegas/custodias).
-- Master data. central/bodega/vehiculo + 'tecnico' (custodia por técnico,
-- se cablea en Fase 3 con el rol técnico; cobrador_id queda preparado).
-- Per-tenant, RLS, audit. (inv_proveedores ya existe en 0099.)

CREATE TABLE public.inv_ubicaciones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  tipo text NOT NULL DEFAULT 'central'
    CHECK (tipo IN ('central','bodega','vehiculo','tecnico')),
  -- Para tipo='tecnico': a qué empleado pertenece la custodia (Fase 3).
  cobrador_id uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  activa boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE INDEX inv_ubicaciones_by_tenant ON public.inv_ubicaciones (tenant_id);

ALTER TABLE public.inv_ubicaciones ENABLE ROW LEVEL SECURITY;

CREATE POLICY "inv_read" ON public.inv_ubicaciones
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "inv_insert" ON public.inv_ubicaciones
  FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "inv_update" ON public.inv_ubicaciones
  FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "inv_delete" ON public.inv_ubicaciones
  FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.inv_ubicaciones
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

CREATE TRIGGER trg_changelog_inv_ubicaciones
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_ubicaciones
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();
