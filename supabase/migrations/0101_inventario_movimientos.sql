-- 0101: Inventario — Sub-fase 2C (núcleo). Ledger de movimientos + seriales.
--
-- Filosofía: el stock NO se edita directo ni se materializa. Es una PROYECCIÓN
-- derivada del ledger `inv_movimientos` (append-only). Stock de un producto en
-- una ubicación = SUM(cantidad con destino=U) − SUM(cantidad con origen=U).
-- Cada movimiento tiene origen y/o destino:
--   ingreso: solo destino (+) · egreso/baja/consumo: solo origen (−)
--   transferencia: origen (−) + destino (+) · asignacion: origen (−, serial→cliente)
--   devolucion: destino (+) · ajuste: destino (+) u origen (−) según signo
-- `inv_seriales` lleva 1 fila por unidad serializada (ONU/router) con su estado
-- y ubicación/cliente actuales (trazabilidad = su historial de movimientos).

-- =========================================================================
-- 1. Seriales (unidades físicas de productos serializados)
-- =========================================================================
CREATE TABLE public.inv_seriales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  producto_id uuid NOT NULL REFERENCES public.inv_productos(id) ON DELETE RESTRICT,
  serial text NOT NULL,
  mac text,
  estado text NOT NULL DEFAULT 'en_stock'
    CHECK (estado IN ('en_stock','instalado','danado','retirado','baja')),
  ubicacion_id uuid REFERENCES public.inv_ubicaciones(id) ON DELETE SET NULL,
  cliente_id uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  contrato_id uuid REFERENCES public.contratos(id) ON DELETE SET NULL,
  costo_ingreso numeric(12,2),
  notas text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, serial)
);

CREATE INDEX inv_seriales_by_producto ON public.inv_seriales (tenant_id, producto_id);
CREATE INDEX inv_seriales_by_cliente  ON public.inv_seriales (tenant_id, cliente_id);
CREATE INDEX inv_seriales_by_ubicacion ON public.inv_seriales (tenant_id, ubicacion_id);

-- =========================================================================
-- 2. Movimientos (ledger append-only) — fuente de verdad del stock
-- =========================================================================
CREATE TABLE public.inv_movimientos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  tipo text NOT NULL CHECK (tipo IN
    ('ingreso','egreso','ajuste','transferencia','asignacion','consumo','devolucion','baja')),
  producto_id uuid NOT NULL REFERENCES public.inv_productos(id) ON DELETE RESTRICT,
  serial_id uuid REFERENCES public.inv_seriales(id) ON DELETE SET NULL,
  cantidad numeric(12,2) NOT NULL DEFAULT 1,
  ubicacion_origen_id uuid REFERENCES public.inv_ubicaciones(id) ON DELETE SET NULL,
  ubicacion_destino_id uuid REFERENCES public.inv_ubicaciones(id) ON DELETE SET NULL,
  cliente_id uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  contrato_id uuid REFERENCES public.contratos(id) ON DELETE SET NULL,
  proveedor_id uuid REFERENCES public.inv_proveedores(id) ON DELETE SET NULL,
  numero_factura text,
  costo_unitario numeric(12,2),
  motivo text,
  notas text,
  ticket_id uuid,                 -- Fase 3 (consumo desde un ticket); sin FK aún
  hecho_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  ocurrido_en timestamptz NOT NULL DEFAULT now(),   -- device-time (offline)
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX inv_mov_by_producto ON public.inv_movimientos (tenant_id, producto_id);
CREATE INDEX inv_mov_by_serial   ON public.inv_movimientos (serial_id);
CREATE INDEX inv_mov_by_destino  ON public.inv_movimientos (tenant_id, ubicacion_destino_id);
CREATE INDEX inv_mov_by_origen   ON public.inv_movimientos (tenant_id, ubicacion_origen_id);

-- =========================================================================
-- 3. RLS
-- =========================================================================
ALTER TABLE public.inv_seriales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inv_movimientos ENABLE ROW LEVEL SECURITY;

-- Seriales: read miembro del tenant; write admin/admin_cobranza.
CREATE POLICY "inv_read" ON public.inv_seriales
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "inv_insert" ON public.inv_seriales
  FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "inv_update" ON public.inv_seriales
  FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "inv_delete" ON public.inv_seriales
  FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.inv_seriales
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- Movimientos: APPEND-ONLY. read + insert (admin); SIN update/delete (para
-- corregir se agrega un movimiento inverso, como el audit log).
CREATE POLICY "inv_read" ON public.inv_movimientos
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "inv_insert" ON public.inv_movimientos
  FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.inv_movimientos
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- =========================================================================
-- 4. Audit log
-- =========================================================================
CREATE TRIGGER trg_changelog_inv_seriales
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_seriales
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_inv_movimientos
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_movimientos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();
