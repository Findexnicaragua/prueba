-- 0099: Inventario — Sub-fase 2A (catálogo). Módulo OPCIONAL, gateado por
-- tenant_modulos ('inventario', es_base=false → deshabilitado por defecto; el
-- super_admin lo habilita por tenant). Per-tenant, RLS, audit. Admin-facing.
--
-- Tablas de catálogo (master data): categorías, proveedores, productos.
-- (Ubicaciones, seriales, recepciones y movimientos llegan en 2B/2C.)
-- Stock NO se materializa: se deriva del ledger (inv_movimientos, 2C). Sin
-- inv_stock ni trigger de proyección en el MVP.

-- =========================================================================
-- 1. Tablas
-- =========================================================================
CREATE TABLE public.inv_categorias (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  orden int NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE TABLE public.inv_proveedores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  telefono text,
  notas text,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE TABLE public.inv_productos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  categoria_id uuid REFERENCES public.inv_categorias(id) ON DELETE SET NULL,
  codigo text,                       -- SKU interno opcional
  nombre text NOT NULL,
  -- Equipo serializado (ONU/router/STB) vs granel (cable/conectores).
  es_serializado boolean NOT NULL DEFAULT false,
  unidad text NOT NULL DEFAULT 'unidad',   -- unidad/metro/rollo/caja...
  -- granel que se mide con decimales (cable por metro) vs entero.
  maneja_decimal boolean NOT NULL DEFAULT false,
  costo_promedio numeric(12,2) NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE INDEX inv_productos_by_categoria
  ON public.inv_productos (tenant_id, categoria_id);

-- =========================================================================
-- 2. RLS — read: miembro del tenant (forward-compat con técnico de Fase 3);
--    write: admin/admin_cobranza; super_admin_all a mano.
-- =========================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['inv_categorias','inv_proveedores','inv_productos']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('CREATE POLICY "inv_read" ON public.%I FOR SELECT USING (tenant_id = public.current_tenant_id());', t);
    EXECUTE format('CREATE POLICY "inv_insert" ON public.%I FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "inv_update" ON public.%I FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "inv_delete" ON public.%I FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "super_admin_all" ON public.%I USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());', t);
  END LOOP;
END $$;

-- =========================================================================
-- 3. Audit log (trigger genérico)
-- =========================================================================
CREATE TRIGGER trg_changelog_inv_categorias
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_categorias
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_inv_proveedores
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_proveedores
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_inv_productos
  AFTER INSERT OR UPDATE OR DELETE ON public.inv_productos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- =========================================================================
-- 4. Gating: que la app sepa qué módulos tiene habilitado el tenant.
-- tenant_modulos tiene PK compuesta (tenant_id, modulo_codigo) y PowerSync
-- exige un `id` por fila para sincronizar. Agregamos un id único; la app lo
-- baja READ-ONLY (la escritura sigue siendo del super_admin vía RPC).
-- =========================================================================
ALTER TABLE public.tenant_modulos
  ADD COLUMN IF NOT EXISTS id uuid NOT NULL DEFAULT gen_random_uuid();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_modulos_id_key'
  ) THEN
    ALTER TABLE public.tenant_modulos
      ADD CONSTRAINT tenant_modulos_id_key UNIQUE (id);
  END IF;
END $$;
