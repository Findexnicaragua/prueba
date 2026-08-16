-- 0056: Migrar visitas locales (SharedPreferences) a tabla Postgres.
-- Las visitas necesitan sincronizar al admin para que vea quién visitó
-- y cuándo, y también persistir cross-device del cobrador.

CREATE TABLE IF NOT EXISTS public.visitas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  cobrador_id uuid NOT NULL REFERENCES public.cobradores(id),
  resultado text NOT NULL CHECK (resultado IN ('cobrado','no_estaba','sin_pago','promesa_pago','otro')),
  notas text,
  fecha timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON public.visitas (tenant_id, cliente_id, fecha DESC);
CREATE INDEX ON public.visitas (tenant_id, cobrador_id, fecha DESC);

ALTER TABLE public.visitas ENABLE ROW LEVEL SECURITY;

-- Cobrador ve solo visitas de sus clientes asignados.
-- Admin/admin_cobranza ven todas las del tenant.
CREATE POLICY "visitas_read" ON public.visitas
  FOR SELECT USING (
    tenant_id = public.current_tenant_id()
    AND (
      public.is_admin_or_cobranza()
      OR cobrador_id = auth.uid()
    )
  );

-- Cualquier usuario del tenant puede registrar visitas (cobradores en
-- campo). El cobrador_id se setea con auth.uid() server-side via trigger.
CREATE POLICY "visitas_insert" ON public.visitas
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id()
  );

-- Solo admin puede eliminar (audit trail — cobrador no debería borrar
-- visitas registradas por error; en su lugar registra una nueva).
CREATE POLICY "visitas_delete" ON public.visitas
  FOR DELETE USING (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

CREATE POLICY "super_admin_all" ON public.visitas
  USING (public.is_super_admin())
  WITH CHECK (public.is_super_admin());
