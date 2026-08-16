-- 0098: Topología de red per-tenant (Nodo → Hub → Puerto).
--
-- Catálogo jerárquico que cada tenant arma con su infraestructura. El cliente
-- se conecta a un Puerto (clientes.puerto_id); Hub y Nodo se derivan de la
-- cadena. Greenfield (sin data previa). Mismo patrón que geografía per-tenant.
-- Solo nombre/código por nivel (sin capacidad/ocupación por ahora).

-- =========================================================================
-- 1. Tablas
-- =========================================================================
CREATE TABLE public.red_nodos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  codigo text,
  -- Tipo de nodo (ISP nica suele ser mixto). Da contexto a los incidentes.
  tipo text CHECK (tipo IS NULL OR tipo IN ('fibra','wireless','hibrido')),
  -- Ubicación física del nodo (torre/OLT) para el futuro mapa de outages.
  lat double precision,
  lng double precision,
  notas text,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nombre)
);

CREATE TABLE public.red_hubs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nodo_id uuid NOT NULL REFERENCES public.red_nodos(id) ON DELETE RESTRICT,
  nombre text NOT NULL,
  codigo text,
  notas text,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, nodo_id, nombre)
);

CREATE TABLE public.red_puertos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  hub_id uuid NOT NULL REFERENCES public.red_hubs(id) ON DELETE RESTRICT,
  nombre text NOT NULL,
  codigo text,
  notas text,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, hub_id, nombre)
);

CREATE INDEX red_hubs_by_nodo    ON public.red_hubs (tenant_id, nodo_id);
CREATE INDEX red_puertos_by_hub  ON public.red_puertos (tenant_id, hub_id);

-- Cliente → Puerto (opcional). Nodo/Hub se derivan de la cadena.
-- ON DELETE SET NULL: borrar/recablear un puerto NO debe bloquearse por tener
-- clientes; el cliente sigue existiendo, solo pierde su punto de conexión.
ALTER TABLE public.clientes
  ADD COLUMN puerto_id uuid REFERENCES public.red_puertos(id) ON DELETE SET NULL;
CREATE INDEX clientes_by_puerto ON public.clientes (puerto_id);

-- =========================================================================
-- 2. RLS — read: miembro del tenant; write: admin/admin_cobranza
-- =========================================================================
ALTER TABLE public.red_nodos   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.red_hubs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.red_puertos ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['red_nodos','red_hubs','red_puertos']
  LOOP
    EXECUTE format('CREATE POLICY "red_read" ON public.%I FOR SELECT USING (tenant_id = public.current_tenant_id());', t);
    EXECUTE format('CREATE POLICY "red_insert" ON public.%I FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "red_update" ON public.%I FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "red_delete" ON public.%I FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "super_admin_all" ON public.%I USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());', t);
  END LOOP;
END $$;

-- =========================================================================
-- 3. Audit log (trigger genérico)
-- =========================================================================
CREATE TRIGGER trg_changelog_red_nodos
  AFTER INSERT OR UPDATE OR DELETE ON public.red_nodos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_red_hubs
  AFTER INSERT OR UPDATE OR DELETE ON public.red_hubs
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_red_puertos
  AFTER INSERT OR UPDATE OR DELETE ON public.red_puertos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();
