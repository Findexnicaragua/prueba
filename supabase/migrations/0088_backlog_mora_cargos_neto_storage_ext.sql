-- 0088 — Limpieza de backlog del audit total:
--   1. actualizar_notificaciones_mora: monto_adeudado con cargos_neto (L3).
--   2. Storage RLS de comprobantes: extraer pago_id sin acoplar a '.jpg' (DB F2).
--
-- Sin columnas/tablas nuevas → sin bump de schema ni redeploy de sync rules.

-- =========================================================================
-- 1. monto_adeudado de la mora = monto + cargos_neto − monto_pagado (igual que
--    el saldo en TODA la app). Antes omitía cargos_neto → el reporte de mora
--    y la bandeja quedaban levemente inexactos con reconexión/descuentos.
--
--    OJO: CREATE OR REPLACE reescribe la función → hay que RE-DECLARAR el
--    `SET timezone='America/Managua'` (0087) y `SET search_path`, o se pierden.
-- =========================================================================
create or replace function public.actualizar_notificaciones_mora(p_tenant_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
set timezone = 'America/Managua'
as $$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
  -- row_security off: el cron corre sin auth.uid(); SECURITY DEFINER da rol
  -- postgres (BYPASSRLS), lo explicitamos por las dudas.
  set local row_security = off;

  insert into public.notificaciones_mora (
    tenant_id, cuota_id, cliente_id, cobrador_id,
    dias_mora, monto_adeudado
  )
  select
    cu.tenant_id,
    cu.id,
    cu.cliente_id,
    cu.cobrador_id,
    greatest((current_date - cu.fecha_vencimiento) - v_dias_gracia, 0),
    cu.monto + coalesce(cu.cargos_neto, 0) - cu.monto_pagado
  from public.cuotas cu
  where cu.tenant_id = p_tenant_id
    and cu.estado in ('pendiente','parcial')
    and (cu.fecha_vencimiento + (v_dias_gracia || ' days')::interval)::date < current_date
  on conflict (cuota_id) do update
    set dias_mora      = excluded.dias_mora,
        monto_adeudado = excluded.monto_adeudado;

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;

-- =========================================================================
-- 2. Storage RLS de comprobantes-pago: extraer pago_id del path
--    {tenant}/comp/{pago_id}.{ext} sin asumir '.jpg'. `regexp_replace` quita
--    CUALQUIER extensión final → si mañana se sube .png/.webp, el EXISTS de
--    pago sigue matcheando (antes el cobrador no podría subir no-jpg).
-- =========================================================================
drop policy "storage_write_comprobantes_select_y_insert" on storage.objects;
create policy "storage_write_comprobantes_select_y_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = regexp_replace(split_part(name, '/', 3), '\.[^.]+$', '')
           and cobrador_id = auth.uid()
      )
    )
  );

drop policy "storage_update_comprobantes" on storage.objects;
create policy "storage_update_comprobantes" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = regexp_replace(split_part(name, '/', 3), '\.[^.]+$', '')
           and cobrador_id = auth.uid()
      )
    )
  );
