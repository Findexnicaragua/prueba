-- Migración 0039: Impersonación de tenants por super_admin.
--
-- Permite al super_admin "entrar" a cualquier tenant y operar como
-- admin. El mecanismo es una tabla mínima que indica qué tenant está
-- viendo el super_admin actualmente. La función current_tenant_id()
-- la checa primero: si hay una row, retorna ese tenant_id. Si no,
-- retorna el tenant real del cobrador (System para super_admin).
--
-- El super_admin NO aparece en la lista de miembros del tenant porque
-- su row en cobradores tiene tenant_id = System. Cuando current_tenant_id()
-- retorna el tenant impersonado, el WHERE tenant_id = current_tenant_id()
-- excluye la row del super_admin naturalmente.

-- 1. Tabla de impersonación: una row por super_admin activo.
CREATE TABLE IF NOT EXISTS public.super_admin_impersonation (
  user_id   uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  started_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.super_admin_impersonation ENABLE ROW LEVEL SECURITY;

-- Solo super_admin puede leer/escribir su propia row.
CREATE POLICY "super_admin_own" ON public.super_admin_impersonation
  FOR ALL USING (
    public.is_super_admin() AND user_id = auth.uid()
  )
  WITH CHECK (
    public.is_super_admin() AND user_id = auth.uid()
  );

-- 2. Modificar current_tenant_id() para soportar impersonación.
-- Si el caller es super_admin y tiene una row en la tabla, retorna
-- ese tenant. Sino, retorna el tenant del cobrador (comportamiento
-- original). Para users normales, no cambia nada.
CREATE OR REPLACE FUNCTION public.current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN public.is_super_admin() THEN
      COALESCE(
        (SELECT tenant_id FROM public.super_admin_impersonation
         WHERE user_id = auth.uid()),
        (SELECT tenant_id FROM public.cobradores WHERE id = auth.uid())
      )
    ELSE
      (SELECT tenant_id FROM public.cobradores WHERE id = auth.uid())
  END
$$;
