-- 0089 — Visibilidad de Auditoría para el admin → super_admin-only (por tenant).
--
-- Decisión del dueño: el panel de Auditoría (/admin/audit) ya NO es visible por
-- defecto para el admin del ISP. El super_admin (dueño del SaaS) lo habilita por
-- tenant desde la tab "Avanzado" de Settings, mismo patrón que pantallas
-- opcionales / descuentos / reconexión (0085/0086). El super_admin lo ve siempre
-- (es config del SaaS); el admin sólo si el toggle está en ON. admin_cobranza
-- nunca lo ve (sigue gateado por rol en el router).
--
-- Extiende seed_settings_super_only (0085/0086) con la clave nueva. La RLS
-- endurecida de 0085 (settings_write_admin con `editable_por <> 'super_admin'`)
-- ya impide server-side que el admin la escriba.
--
-- Default OFF: por pedido explícito, la opción arranca oculta para los admins.
--
-- Sin columnas nuevas → sin bump de schema.dart ni redeploy de sync rules
-- (la tabla settings ya sincroniza con SELECT *).

create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
    -- Foto de comprobante + pantallas opcionales (0085).
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    -- Descuentos (manual en campo) → super-only (0086).
    (p_tenant_id, 'cobranza.descuentos_habilitados', 'false'::jsonb, 'boolean',
     'cobranza', 'Permitir aplicar descuentos en campo', 'super_admin'),
    (p_tenant_id, 'cobranza.descuento_tipo', '"monto"'::jsonb, 'string',
     'cobranza', 'Tipo de descuento permitido (monto|porcentaje|ambos)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_monto', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento monto sin aprobación (0=deshabilitado)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_porcentaje', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento porcentual sin aprobación (0=deshabilitado)',
     'super_admin'),
    -- Reconexión → super-only (0086).
    (p_tenant_id, 'cobranza.cargo_reconexion_habilitado', 'false'::jsonb,
     'boolean', 'cobranza', 'Permitir cobrar reconexión', 'super_admin'),
    (p_tenant_id, 'cobranza.monto_reconexion', '0'::jsonb, 'number',
     'cobranza', 'Monto de reconexión en C$', 'super_admin'),
    -- Visibilidad del panel de Auditoría para el admin → super-only (0089).
    (p_tenant_id, 'cobranza.audit_visible_admin', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra el panel de Auditoría (historial de cambios) al admin del tenant',
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

-- Aplicar a todos los tenants existentes: siembra la clave nueva (los demás ya
-- existen, el ON CONFLICT preserva su `valor` y sólo reafirma editable_por).
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;
