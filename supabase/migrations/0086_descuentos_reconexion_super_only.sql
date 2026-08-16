-- 0086 — Descuentos y reconexión pasan a super_admin-only (por tenant).
--
-- Decisión del dueño: el admin del ISP NO debe ver/activar el módulo de
-- descuentos (manual en campo) ni el cargo por reconexión. El super_admin
-- (dueño del SaaS) los habilita por tenant desde la tab "Avanzado", mismo
-- patrón que foto-comprobante / pantallas opcionales (0085). Mientras el super
-- los deje en OFF (default), no aparecen ni en el cobro ni en el contrato.
--
-- Extiende seed_settings_super_only (0085) con las 6 claves. Solo cambia
-- editable_por (el `valor` lo preserva el ON CONFLICT). La RLS endurecida de
-- 0085 (settings_write_admin con `editable_por <> 'super_admin'`) ya impide
-- server-side que el admin las escriba.
--
-- Filas/función — sin columnas nuevas → sin bump de schema.dart ni redeploy de
-- sync rules.

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
     'cobranza', 'Monto de reconexión en C$', 'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

-- Aplicar a todos los tenants existentes (flip de editable_por de las 10 claves).
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;
