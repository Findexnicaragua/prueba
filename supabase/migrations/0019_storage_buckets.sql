-- Storage buckets para fotos del sistema.
-- Convención de paths: {tenant_id}/{...}.{ext} para que la policy filtre por
-- tenant mirando el primer segmento.
--
-- Buckets:
--   fotos-clientes:      foto del cliente            ({tenant}/cli/{cliente_id}.jpg)
--   comprobantes-pago:   foto del comprobante         ({tenant}/comp/{pago_id}.jpg)
--   logos-empresa:       logo en recibo               ({tenant}/logo.png)

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('fotos-clientes',     'fotos-clientes',     false, 2 * 1024 * 1024, array['image/jpeg','image/png','image/webp']),
  ('comprobantes-pago',  'comprobantes-pago',  false, 2 * 1024 * 1024, array['image/jpeg','image/png','image/webp']),
  ('logos-empresa',      'logos-empresa',      false, 1 * 1024 * 1024, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- =========================================================================
-- Helpers reutilizables: primer segmento del path = tenant uuid
-- =========================================================================

create or replace function public.storage_path_tenant(p_name text) returns uuid
language sql immutable
set search_path = public, pg_temp
as $$
  select case
    when split_part(p_name, '/', 1) ~* '^[0-9a-f-]{36}$'
      then split_part(p_name, '/', 1)::uuid
    else null
  end
$$;

-- =========================================================================
-- Policies: lectura por tenant; escritura según rol y bucket
-- =========================================================================

-- LECTURA: todos los usuarios autenticados del tenant pueden ver fotos del tenant.
create policy "storage_read_por_tenant" on storage.objects
  for select to authenticated
  using (
    bucket_id in ('fotos-clientes','comprobantes-pago','logos-empresa')
    and public.storage_path_tenant(name) = public.current_tenant_id()
  );

-- ESCRITURA — fotos-clientes: admin/admin_cobranza (crean el cliente con foto).
create policy "storage_write_fotos_clientes" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'fotos-clientes'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin_or_cobranza()
  )
  with check (
    bucket_id = 'fotos-clientes'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin_or_cobranza()
  );

-- ESCRITURA — comprobantes-pago: cobrador sube los suyos; admins también.
create policy "storage_write_comprobantes" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
  )
  with check (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
  );

-- ESCRITURA — logos-empresa: sólo admin.
create policy "storage_write_logos" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'logos-empresa'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin()
  )
  with check (
    bucket_id = 'logos-empresa'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin()
  );
