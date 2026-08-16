-- RLS por rol: el `tenant_isolation` actual es FOR ALL — un cobrador puede
-- UPDATE/DELETE clientes/cuotas/pagos de otros cobradores vía API directa
-- (Supabase REST o supabase-flutter), aunque el sync rule no le baje sus filas.
-- Esta migración endurece las políticas según el rol del usuario.

-- Helper: ¿es admin?
create or replace function public.is_admin() returns boolean
language sql stable security definer
set search_path = public, pg_temp as $$
  select public.current_user_rol() = 'admin'
$$;

-- Helper: ¿es admin o admin_cobranza?
create or replace function public.is_admin_or_cobranza() returns boolean
language sql stable security definer
set search_path = public, pg_temp as $$
  select public.current_user_rol() in ('admin','admin_cobranza')
$$;

-- =========================================================================
-- planes — sólo admin escribe
-- =========================================================================
drop policy "tenant_isolation" on public.planes;

create policy "planes_read" on public.planes
  for select using (tenant_id = public.current_tenant_id());

create policy "planes_write_admin" on public.planes
  for all using (tenant_id = public.current_tenant_id() and public.is_admin())
  with check (tenant_id = public.current_tenant_id() and public.is_admin());

-- =========================================================================
-- cobradores — sólo admin escribe; cobrador ve su propia fila + admins ven todo
-- =========================================================================
drop policy "tenant_isolation_cobradores" on public.cobradores;

create policy "cobradores_read_self_or_admin" on public.cobradores
  for select using (
    tenant_id = public.current_tenant_id()
    and (id = auth.uid() or public.is_admin_or_cobranza())
  );

create policy "cobradores_write_admin" on public.cobradores
  for all using (tenant_id = public.current_tenant_id() and public.is_admin())
  with check (tenant_id = public.current_tenant_id() and public.is_admin());

-- =========================================================================
-- clientes — admin/admin_cobranza escriben; cobrador sólo lee los suyos
-- =========================================================================
drop policy "tenant_isolation" on public.clientes;

create policy "clientes_read" on public.clientes
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "clientes_write_admins" on public.clientes
  for all using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

-- =========================================================================
-- contratos — igual que clientes
-- =========================================================================
drop policy "tenant_isolation" on public.contratos;

create policy "contratos_read" on public.contratos
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "contratos_write_admins" on public.contratos
  for all using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

-- =========================================================================
-- cuotas — admins gestionan (anular, regenerar); cobrador sólo lee las suyas
-- =========================================================================
drop policy "tenant_isolation" on public.cuotas;

create policy "cuotas_read" on public.cuotas
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "cuotas_write_admins" on public.cuotas
  for all using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

-- =========================================================================
-- pagos — cobrador inserta los suyos; admins gestionan/anulan
-- =========================================================================
drop policy "tenant_isolation" on public.pagos;

create policy "pagos_read" on public.pagos
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "pagos_insert_propio" on public.pagos
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      (public.is_admin_or_cobranza())
      or (public.current_user_rol() = 'cobrador' and cobrador_id = auth.uid())
    )
  );

create policy "pagos_update_admins" on public.pagos
  for update using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

create policy "pagos_delete_admin" on public.pagos
  for delete using (tenant_id = public.current_tenant_id() and public.is_admin());

-- =========================================================================
-- recibos — igual patrón que pagos
-- =========================================================================
drop policy "tenant_isolation" on public.recibos;

create policy "recibos_read" on public.recibos
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "recibos_insert_propio" on public.recibos
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (public.current_user_rol() = 'cobrador' and cobrador_id = auth.uid())
    )
  );

create policy "recibos_update_admins" on public.recibos
  for update using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

-- =========================================================================
-- cargos_extra — cobrador aplica para sus cuotas; admins también
-- =========================================================================
drop policy "tenant_isolation" on public.cargos_extra;

create policy "cargos_read" on public.cargos_extra
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

create policy "cargos_insert" on public.cargos_extra
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (public.current_user_rol() = 'cobrador' and cobrador_id = auth.uid())
    )
  );

create policy "cargos_write_admins" on public.cargos_extra
  for update using (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza())
  with check (tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza());

create policy "cargos_delete_admin" on public.cargos_extra
  for delete using (tenant_id = public.current_tenant_id() and public.is_admin());

-- =========================================================================
-- notificaciones_mora — el cobrador ve/marca las suyas; admins ven todas
-- =========================================================================
drop policy "tenant_isolation" on public.notificaciones_mora;

create policy "notif_read" on public.notificaciones_mora
  for select using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

-- Marcar vista: el cobrador asignado o admins.
create policy "notif_update_marca" on public.notificaciones_mora
  for update using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

-- Sólo admins insertan/borran (el cron las genera con superuser).
create policy "notif_write_admin" on public.notificaciones_mora
  for insert with check (
    tenant_id = public.current_tenant_id() and public.is_admin_or_cobranza()
  );

create policy "notif_delete_admin" on public.notificaciones_mora
  for delete using (tenant_id = public.current_tenant_id() and public.is_admin());
