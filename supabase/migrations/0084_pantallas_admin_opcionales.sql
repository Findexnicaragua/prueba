-- 0084 — Pantallas admin opcionales gateadas por super_admin (por tenant).
--
-- /admin/pagos (historial de pagos del tenant + anular) y /admin/notificaciones
-- (gestión de mora) existían como rutas/pantallas pero SIN punto de entrada en
-- el menú (BULK 12 las dejó huérfanas). Decisión: que el super_admin las
-- habilite por tenant desde el panel de settings del admin (mismo patrón que la
-- foto de comprobante). Default OFF → el item del menú no aparece.
--
-- Los toggles se muestran SOLO al super_admin en la UI (gate `esSuperAdmin` +
-- `superAdminOnly` en settings_admin). Los getters
-- `pantallaPagosHabilitada`/`pantallaNotificacionesHabilitada` controlan la
-- visibilidad del item en `admin_shell` (`_menuVisible` + `settingKey`).
--
-- Filas nuevas en `settings` (key-value), sin columnas → sin bump de schema ni
-- redeploy de sync rules.

DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
       'cobranza',
       'Muestra la pantalla de historial de pagos del tenant (admin)', 'admin'),
      (v_tenant.id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
       'cobranza',
       'Muestra la pantalla de gestión de notificaciones de mora (admin)', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;
