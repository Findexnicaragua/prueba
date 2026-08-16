-- 0097: Geografía global → per-tenant.
--
-- Hasta ahora departamentos/municipios/comunidades eran GLOBALES (sin
-- tenant_id, RLS permisiva). Pasan a ser per-tenant: cada tenant maneja su
-- propia geografía, con RLS scopeada por current_tenant_id() y audit log.
--
-- DATA: es data de prueba (decisión de Rubén) → NO se hace backfill/replicación.
-- Se vacían las tablas globales y se deja clientes.comunidad_id = NULL; el
-- admin recarga la geografía por tenant. (Si en el futuro hubiera data real,
-- esta migración debería replicar + re-apuntar FKs en vez de vaciar.)

-- =========================================================================
-- 1. Limpiar data global (test) y soltar FK de clientes
-- =========================================================================
UPDATE public.clientes SET comunidad_id = NULL WHERE comunidad_id IS NOT NULL;

DELETE FROM public.comunidades;
DELETE FROM public.municipios;
DELETE FROM public.departamentos;

-- =========================================================================
-- 2. Agregar tenant_id (NOT NULL — las tablas quedaron vacías) + FK
-- =========================================================================
ALTER TABLE public.departamentos
  ADD COLUMN tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE public.municipios
  ADD COLUMN tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE public.comunidades
  ADD COLUMN tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE;

-- =========================================================================
-- 3. Unicidad: ahora POR TENANT (antes era global)
-- =========================================================================
ALTER TABLE public.departamentos DROP CONSTRAINT IF EXISTS departamentos_nombre_key;
ALTER TABLE public.departamentos DROP CONSTRAINT IF EXISTS departamentos_codigo_key;
ALTER TABLE public.municipios    DROP CONSTRAINT IF EXISTS municipios_departamento_id_nombre_key;
ALTER TABLE public.comunidades   DROP CONSTRAINT IF EXISTS comunidades_municipio_id_nombre_key;

ALTER TABLE public.departamentos ADD CONSTRAINT departamentos_tenant_nombre_key UNIQUE (tenant_id, nombre);
ALTER TABLE public.municipios    ADD CONSTRAINT municipios_tenant_depto_nombre_key UNIQUE (tenant_id, departamento_id, nombre);
ALTER TABLE public.comunidades   ADD CONSTRAINT comunidades_tenant_muni_nombre_key UNIQUE (tenant_id, municipio_id, nombre);

CREATE INDEX IF NOT EXISTS departamentos_by_tenant ON public.departamentos (tenant_id);
CREATE INDEX IF NOT EXISTS municipios_by_tenant    ON public.municipios (tenant_id, departamento_id);
CREATE INDEX IF NOT EXISTS comunidades_by_tenant   ON public.comunidades (tenant_id, municipio_id);

-- =========================================================================
-- 4. RLS: reemplazar las policies globales por scoping per-tenant
-- =========================================================================
-- Dropear TODAS las policies geo previas (globales). OJO: los nombres cambiaron
-- a lo largo del historial — read=geo_read_authenticated (0003); insert pasó de
-- geo_insert_authenticated (0003) a geo_insert_admins (0016); update/delete son
-- geo_update_admins/geo_delete_admins (0067). Si no dropeamos los nombres REALES,
-- esas policies viejas SIN scoping por tenant sobreviven y (combinadas con OR)
-- anulan el scoping nuevo → fuga cross-tenant en escritura de geografía.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['departamentos','municipios','comunidades']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "geo_read_authenticated" ON public.%I;', t);
    EXECUTE format('DROP POLICY IF EXISTS "geo_insert_authenticated" ON public.%I;', t);
    EXECUTE format('DROP POLICY IF EXISTS "geo_insert_admins" ON public.%I;', t);
    EXECUTE format('DROP POLICY IF EXISTS "geo_update_admins" ON public.%I;', t);
    EXECUTE format('DROP POLICY IF EXISTS "geo_delete_admins" ON public.%I;', t);
  END LOOP;
END $$;

-- Lectura: cualquier miembro del tenant (cobrador necesita la geo del cliente).
-- Insert: cualquier miembro del tenant (preserva el "crear inline" del geo_picker).
-- Update/Delete: solo admin/admin_cobranza.
-- super_admin_all: agregada a mano (el do$$ de 0026 enumera tablas fijas).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['departamentos','municipios','comunidades']
  LOOP
    EXECUTE format('CREATE POLICY "geo_read" ON public.%I FOR SELECT USING (tenant_id = public.current_tenant_id());', t);
    EXECUTE format('CREATE POLICY "geo_insert" ON public.%I FOR INSERT WITH CHECK (tenant_id = public.current_tenant_id());', t);
    EXECUTE format('CREATE POLICY "geo_update" ON public.%I FOR UPDATE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "geo_delete" ON public.%I FOR DELETE USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());', t);
    EXECUTE format('CREATE POLICY "super_admin_all" ON public.%I USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());', t);
  END LOOP;
END $$;

-- =========================================================================
-- 5. Audit log: ahora que tienen tenant_id, aplica el trigger genérico
-- =========================================================================
CREATE TRIGGER trg_changelog_departamentos
  AFTER INSERT OR UPDATE OR DELETE ON public.departamentos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_municipios
  AFTER INSERT OR UPDATE OR DELETE ON public.municipios
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

CREATE TRIGGER trg_changelog_comunidades
  AFTER INSERT OR UPDATE OR DELETE ON public.comunidades
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();
