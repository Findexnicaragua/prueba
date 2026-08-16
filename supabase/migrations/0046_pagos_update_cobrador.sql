-- 0046: Permitir al cobrador UPDATE/soft-delete en sus propios pagos.
-- Antes solo admin/admin_cobranza podían hacer UPDATE en pagos.
-- Los toggles cobranza.cobrador_edita_cobros y cobrador_anula_cobros
-- controlan la UI; la RLS permite el UPDATE server-side.

DROP POLICY "pagos_update_admins" ON public.pagos;

CREATE POLICY "pagos_update" ON public.pagos
  FOR UPDATE USING (
    tenant_id = public.current_tenant_id()
    AND (
      public.is_admin_or_cobranza()
      OR (public.current_user_rol() = 'cobrador' AND cobrador_id = auth.uid())
    )
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND (
      public.is_admin_or_cobranza()
      OR (public.current_user_rol() = 'cobrador' AND cobrador_id = auth.uid())
    )
  );
