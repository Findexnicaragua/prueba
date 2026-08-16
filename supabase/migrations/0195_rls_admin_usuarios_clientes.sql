-- admin_usuarios necesita write en clientes, fotos y etiquetas para gestión
-- de usuarios. NO se amplía is_admin_or_cobranza() porque esa función gatea
-- ~30 tablas incluyendo pagos/cuotas/cargos/contratos — demasiado scope.

CREATE POLICY clientes_write_admin_usuarios ON clientes
  FOR ALL
  USING (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios')
  WITH CHECK (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios');

CREATE POLICY fotos_cliente_write_admin_usuarios ON fotos_cliente
  FOR ALL
  USING (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios')
  WITH CHECK (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios');

CREATE POLICY cliente_etiquetas_write_admin_usuarios ON cliente_etiquetas
  FOR ALL
  USING (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios')
  WITH CHECK (tenant_id = current_tenant_id() AND current_user_rol() = 'admin_usuarios');
