-- 0085 — Enforce server-side de los settings "super_admin-only".
--
-- PROBLEMA (audit): los toggles que el dueño del SaaS controla por tenant
-- (foto de comprobante → consume Storage; pantallas admin opcionales) se
-- gateaban SOLO en la UI (`esSuperAdmin` client-side). Server-side, la policy
-- `settings_write_admin` (0004) dejaba a CUALQUIER admin del tenant escribir
-- CUALQUIER fila de `settings`. Un admin podía re-activar la foto de
-- comprobante o las pantallas que el super_admin dejó en OFF, escribiendo el
-- setting por PowerSync/REST. No cruzaba tenants (RLS lo scopa), pero anulaba
-- el control de costo/política del SaaS.
--
-- FIX: marcar esas claves con `editable_por='super_admin'` y endurecer la
-- policy para que el admin NO pueda tocarlas. El super_admin las sigue
-- escribiendo vía la policy `super_admin_all` (0026), que ya cubre `settings`.
--
-- Filas/constraint/policy — sin columnas nuevas → sin bump de schema.dart ni
-- redeploy de sync rules (la app lee `editable_por` por SELECT *, ya cubierto).

-- =========================================================================
-- 1. Permitir 'super_admin' como valor de editable_por
--    (el CHECK inline de 0004 sólo aceptaba 'admin' | 'admin_cobranza').
-- =========================================================================
alter table public.settings drop constraint settings_editable_por_check;
alter table public.settings add constraint settings_editable_por_check
  check (editable_por in ('admin', 'admin_cobranza', 'super_admin'));

-- =========================================================================
-- 2. Helper: sembrar/marcar las 4 claves super-only de un tenant.
--    ON CONFLICT DO UPDATE editable_por (preserva `valor` existente): sirve
--    para tenants nuevos (INSERT) y para re-marcar foto_obligatoria, que ya
--    la siembra seed_settings_default con editable_por='admin'.
-- =========================================================================
create or replace function public.seed_settings_super_only(p_tenant_id uuid)
returns void
language plpgsql as $$
begin
  insert into public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  values
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
     'super_admin')
  on conflict (tenant_id, clave) do update set editable_por = 'super_admin';
end $$;

-- =========================================================================
-- 3. Aplicar a todos los tenants existentes.
-- =========================================================================
do $$
declare
  v_t record;
begin
  for v_t in select id from public.tenants loop
    perform public.seed_settings_super_only(v_t.id);
  end loop;
end $$;

-- =========================================================================
-- 4. Tenant nuevo: además del seed default, sembrar las super-only.
--    (seed_settings_default no las incluye — se agregaron en 0081/0084 sólo
--    para tenants existentes; sin esto, un tenant nuevo no las tendría.)
-- =========================================================================
create or replace function public.tenants_seed_settings_trg()
returns trigger
language plpgsql as $$
begin
  perform public.seed_settings_default(new.id);
  perform public.seed_settings_super_only(new.id);
  return new;
end $$;

-- =========================================================================
-- 5. Endurecer settings_write_admin: el admin NO puede escribir las claves
--    super-only. El super_admin las escribe vía super_admin_all (0026).
--    admin_cobranza sigue con su policy propia (sólo claves admin_cobranza).
-- =========================================================================
drop policy "settings_write_admin" on public.settings;
create policy "settings_write_admin" on public.settings
  for all using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin'
    and editable_por <> 'super_admin'
  ) with check (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'admin'
    and editable_por <> 'super_admin'
  );
