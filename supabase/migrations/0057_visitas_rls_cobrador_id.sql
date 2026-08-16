-- 0057: Reforzar RLS de visitas — el cobrador_id en INSERT debe
-- coincidir con auth.uid() para prevenir que un cobrador autenticado
-- registre visitas en nombre de otro vía REST directo.
-- El comentario original de 0056 mencionaba un trigger que setea
-- cobrador_id server-side, pero ese trigger no se creó. Esta política
-- es la defensa correcta.

DROP POLICY IF EXISTS "visitas_insert" ON public.visitas;

CREATE POLICY "visitas_insert" ON public.visitas
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND cobrador_id = auth.uid()
  );
