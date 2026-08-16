-- 0067: Policies UPDATE/DELETE para tablas geo (fix M2-DB).
--
-- departamentos/municipios/comunidades tenían SELECT (0003) e INSERT
-- (geo_insert_admins, 0016) pero NINGUNA policy UPDATE/DELETE. Con RLS
-- habilitado, eso = operación denegada silenciosamente. /admin/geografia
-- expone editar/borrar, así que esas acciones fallaban sin error claro.
--
-- Decisión del producto: el admin puede editar/borrar geo. Las tablas geo
-- son globales (sin tenant_id) — cualquier admin de cualquier tenant las
-- gestiona (catálogo compartido de Nicaragua). super_admin también.

-- Helper: admin de cualquier tenant o super_admin.
-- is_admin() ya cubre admin del tenant; is_super_admin() para Rubén.

-- ── departamentos ──────────────────────────────────────────────────────
DROP POLICY IF EXISTS "geo_update_admins" ON public.departamentos;
CREATE POLICY "geo_update_admins" ON public.departamentos
  FOR UPDATE TO authenticated
  USING (public.is_admin() OR public.is_super_admin())
  WITH CHECK (public.is_admin() OR public.is_super_admin());

DROP POLICY IF EXISTS "geo_delete_admins" ON public.departamentos;
CREATE POLICY "geo_delete_admins" ON public.departamentos
  FOR DELETE TO authenticated
  USING (public.is_admin() OR public.is_super_admin());

-- ── municipios ─────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "geo_update_admins" ON public.municipios;
CREATE POLICY "geo_update_admins" ON public.municipios
  FOR UPDATE TO authenticated
  USING (public.is_admin() OR public.is_super_admin())
  WITH CHECK (public.is_admin() OR public.is_super_admin());

DROP POLICY IF EXISTS "geo_delete_admins" ON public.municipios;
CREATE POLICY "geo_delete_admins" ON public.municipios
  FOR DELETE TO authenticated
  USING (public.is_admin() OR public.is_super_admin());

-- ── comunidades ────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "geo_update_admins" ON public.comunidades;
CREATE POLICY "geo_update_admins" ON public.comunidades
  FOR UPDATE TO authenticated
  USING (public.is_admin() OR public.is_super_admin())
  WITH CHECK (public.is_admin() OR public.is_super_admin());

DROP POLICY IF EXISTS "geo_delete_admins" ON public.comunidades;
CREATE POLICY "geo_delete_admins" ON public.comunidades
  FOR DELETE TO authenticated
  USING (public.is_admin() OR public.is_super_admin());
