-- 0102: Guardas server-side de borrado + ledger estrictamente append-only.
--
-- Hallazgos del audit integral de Fase 2:
--  · (Agent 7, MEDIA) inv_ubicaciones / inv_proveedores tienen FK ON DELETE
--    SET NULL hacia seriales/movimientos → la guarda client-side de "en uso"
--    corre sobre SQLite local; multi-device offline podía borrar una ubicación/
--    proveedor en uso y dejar el movimiento/serial huérfano (ubicacion_id NULL)
--    en silencio. Agregamos un BEFORE DELETE server-side que rechaza el borrado.
--  · (R1) red_puertos tiene FK SET NULL hacia clientes.puerto_id; comunidades
--    es NO ACTION (restrict) hacia clientes.comunidad_id (corrige el comentario
--    original que decía SET NULL — audit 2026-06-24) → mismo riesgo de uso:
--    borrar un puerto/comunidad en uso rompería el vínculo. Mismo guard server.
--  · (Agent 4, F3) la policy super_admin_all de inv_movimientos era FOR ALL →
--    permitía al super_admin UPDATE/DELETE del ledger append-only. La acotamos
--    a SELECT + INSERT (corregir = movimiento inverso, como el audit_log).
--
-- Los guards son CASCADE-SAFE: si el tenant ya no existe (borrado del tenant en
-- progreso, ej. rollback de crear-tenant) NO bloquean, así no rompen el cascade.
-- `inv_productos` NO necesita guard: sus FK (seriales/movimientos.producto_id)
-- ya son ON DELETE RESTRICT (el server lo rechaza solo).
--
-- IDEMPOTENTE: cada CREATE TRIGGER/POLICY lleva su DROP ... IF EXISTS y todo va
-- en una transacción → se puede re-correr por Dashboard sin dejar estado a medias.

BEGIN;

-- =========================================================================
-- 1. Guard: inv_ubicaciones en uso (seriales o movimientos)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.inv_ubicaciones_guard_borrado()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Cascade del tenant: el tenant ya se borró → no bloquear.
  IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE id = OLD.tenant_id) THEN
    RETURN OLD;
  END IF;
  IF EXISTS (SELECT 1 FROM public.inv_seriales WHERE ubicacion_id = OLD.id)
     OR EXISTS (SELECT 1 FROM public.inv_movimientos
                 WHERE ubicacion_origen_id = OLD.id
                    OR ubicacion_destino_id = OLD.id) THEN
    RAISE EXCEPTION 'No se puede eliminar la ubicación: tiene equipos o movimientos asociados';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_inv_ubicaciones_guard_borrado ON public.inv_ubicaciones;
CREATE TRIGGER trg_inv_ubicaciones_guard_borrado
  BEFORE DELETE ON public.inv_ubicaciones
  FOR EACH ROW EXECUTE FUNCTION public.inv_ubicaciones_guard_borrado();

-- =========================================================================
-- 2. Guard: inv_proveedores en uso (movimientos)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.inv_proveedores_guard_borrado()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE id = OLD.tenant_id) THEN
    RETURN OLD;
  END IF;
  IF EXISTS (SELECT 1 FROM public.inv_movimientos WHERE proveedor_id = OLD.id) THEN
    RAISE EXCEPTION 'No se puede eliminar el proveedor: tiene movimientos asociados';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_inv_proveedores_guard_borrado ON public.inv_proveedores;
CREATE TRIGGER trg_inv_proveedores_guard_borrado
  BEFORE DELETE ON public.inv_proveedores
  FOR EACH ROW EXECUTE FUNCTION public.inv_proveedores_guard_borrado();

-- =========================================================================
-- 3. Guard: red_puertos en uso (clientes.puerto_id) — cierra R1
-- =========================================================================
CREATE OR REPLACE FUNCTION public.red_puertos_guard_borrado()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE id = OLD.tenant_id) THEN
    RETURN OLD;
  END IF;
  IF EXISTS (SELECT 1 FROM public.clientes WHERE puerto_id = OLD.id) THEN
    RAISE EXCEPTION 'No se puede eliminar el puerto: tiene clientes conectados';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_red_puertos_guard_borrado ON public.red_puertos;
CREATE TRIGGER trg_red_puertos_guard_borrado
  BEFORE DELETE ON public.red_puertos
  FOR EACH ROW EXECUTE FUNCTION public.red_puertos_guard_borrado();

-- =========================================================================
-- 4. Guard: comunidades en uso (clientes.comunidad_id) — R1 geo
-- =========================================================================
CREATE OR REPLACE FUNCTION public.comunidades_guard_borrado()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE id = OLD.tenant_id) THEN
    RETURN OLD;
  END IF;
  IF EXISTS (SELECT 1 FROM public.clientes WHERE comunidad_id = OLD.id) THEN
    RAISE EXCEPTION 'No se puede eliminar la comunidad: tiene clientes asignados';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_comunidades_guard_borrado ON public.comunidades;
CREATE TRIGGER trg_comunidades_guard_borrado
  BEFORE DELETE ON public.comunidades
  FOR EACH ROW EXECUTE FUNCTION public.comunidades_guard_borrado();

-- =========================================================================
-- 5. Ledger append-only estricto: super_admin solo SELECT + INSERT
-- =========================================================================
DROP POLICY IF EXISTS "super_admin_all" ON public.inv_movimientos;
DROP POLICY IF EXISTS "super_admin_select" ON public.inv_movimientos;
DROP POLICY IF EXISTS "super_admin_insert" ON public.inv_movimientos;

CREATE POLICY "super_admin_select" ON public.inv_movimientos
  FOR SELECT USING (public.is_super_admin());
CREATE POLICY "super_admin_insert" ON public.inv_movimientos
  FOR INSERT WITH CHECK (public.is_super_admin());

COMMIT;
