-- 0053: Tabla para fotos múltiples del cliente (max 10).
-- Reemplaza el campo foto_path (single) en clientes.

CREATE TABLE IF NOT EXISTS public.fotos_cliente (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.cobradores(id)
);

CREATE INDEX ON public.fotos_cliente (tenant_id, cliente_id);

ALTER TABLE public.fotos_cliente ENABLE ROW LEVEL SECURITY;

CREATE POLICY "fotos_cliente_read" ON public.fotos_cliente
  FOR SELECT USING (tenant_id = public.current_tenant_id());

CREATE POLICY "fotos_cliente_insert" ON public.fotos_cliente
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

CREATE POLICY "fotos_cliente_delete" ON public.fotos_cliente
  FOR DELETE USING (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

CREATE POLICY "super_admin_all" ON public.fotos_cliente
  USING (public.is_super_admin())
  WITH CHECK (public.is_super_admin());
