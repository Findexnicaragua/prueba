-- op_log: faltaba el bypass de super_admin (R10).
--
-- Las policies de 0128/0129 chequean `tenant_id = current_tenant_id()`, pero el
-- super_admin (impersonando un tenant) NO tiene un current_tenant_id() que
-- matchee al tenant impersonado → TODO INSERT/UPDATE de op_log hecho por el
-- super_admin se rechazaba con 42501 ("Sin permiso para esta operación"). Se vio
-- al cambiar un setting desde el Panel admin impersonando (2026-06-20).
-- El READ no se notaba porque el super_admin lee op_log vía las sync rules de
-- PowerSync (bucket impersonated_tenant), no por esta policy.
--
-- Solución: la policy super_admin_all estándar (idéntica a
-- clientes/cuotas/cliente_etiquetas/saldos_favor): permisiva, FOR ALL. Se OR-ea
-- con op_log_insert/op_log_update/op_log_read, así el resto de roles sigue igual.
drop policy if exists "super_admin_all" on public.op_log;
create policy "super_admin_all" on public.op_log
  for all
  using (public.is_super_admin())
  with check (public.is_super_admin());
