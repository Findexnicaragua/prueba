-- Hardening de RLS detectado en la auditoría triple:
--
-- 1. El cobrador hace UPDATE local en cuotas (monto_pagado, estado) al
--    registrar un cobro. Sin policy, RLS rechaza y la queue PowerSync se
--    atasca reintentando indefinidamente.
--    → Nueva policy cuotas_update_via_pago_cobrador + trigger que
--      restringe columnas mutables.
--
-- 2. recibos_update_impresion_cobrador permite UPDATE de cobrador en sus
--    recibos pero no restringe columnas. Cobrador podía mutar prefijo,
--    correlativo, numero_completo, anulado — saltándose el flujo de
--    anulación admin y rompiendo la unicidad.
--    → Trigger BEFORE UPDATE que congela columnas críticas.
--
-- 3. pagos_insert_propio / cargos_insert no validan que cuota_id
--    pertenezca al cobrador. Via API directa, cobrador A podría insertar
--    pago/cargo contra cuota de B.
--    → EXISTS subquery en check.
--
-- 4. Storage 'comprobantes-pago' sin scoping por pago_id. Cualquier rol
--    del tenant puede sobreescribir foto de cualquier pago.
--    → Para cobrador, validar que pago_id en el path es suyo.

-- =========================================================================
-- 1. CUOTAS: cobrador puede UPDATE sus cuotas para reflejar cobros locales
-- =========================================================================

create policy "cuotas_update_cobrador_propio" on public.cuotas
  for update
  using (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.current_user_rol() = 'cobrador'
  )
  with check (
    tenant_id = public.current_tenant_id()
    and cobrador_id = auth.uid()
    and public.current_user_rol() = 'cobrador'
  );

-- Trigger BEFORE UPDATE: el cobrador SOLO puede mutar monto_pagado y
-- estado. Cualquier intento de tocar monto, periodo, contrato_id, etc.
-- desde un rol cobrador es rechazado. Admins quedan sin restricción.
create or replace function public.cuotas_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text;
begin
  v_rol := public.current_user_rol();
  if v_rol = 'cobrador' then
    if new.monto         is distinct from old.monto         or
       new.contrato_id   is distinct from old.contrato_id   or
       new.cliente_id    is distinct from old.cliente_id    or
       new.cobrador_id   is distinct from old.cobrador_id   or
       new.periodo       is distinct from old.periodo       or
       new.fecha_vencimiento is distinct from old.fecha_vencimiento or
       new.tenant_id     is distinct from old.tenant_id     or
       new.anulada_en    is distinct from old.anulada_en    or
       new.anulada_por   is distinct from old.anulada_por   or
       new.motivo_anulacion is distinct from old.motivo_anulacion or
       (new.estado <> old.estado and new.estado = 'anulada')
    then
      raise exception 'cobrador solo puede modificar monto_pagado y estado (no anulada) de sus cuotas';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_cuotas_check_cobrador_update
  before update on public.cuotas
  for each row execute function public.cuotas_check_cobrador_update();

-- =========================================================================
-- 2. RECIBOS: trigger que congela columnas críticas para cobrador
-- =========================================================================

create or replace function public.recibos_check_cobrador_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text;
begin
  v_rol := public.current_user_rol();
  if v_rol = 'cobrador' then
    if new.prefijo          is distinct from old.prefijo          or
       new.correlativo      is distinct from old.correlativo      or
       new.numero_completo  is distinct from old.numero_completo  or
       new.pago_id          is distinct from old.pago_id          or
       new.cobrador_id      is distinct from old.cobrador_id      or
       new.tenant_id        is distinct from old.tenant_id        or
       new.anulado          is distinct from old.anulado          or
       new.anulado_en       is distinct from old.anulado_en       or
       new.anulado_por      is distinct from old.anulado_por
    then
      raise exception 'cobrador solo puede modificar campos de impresion en recibos (impreso_en, reimpresiones, ultimo_formato_mm)';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_recibos_check_cobrador_update
  before update on public.recibos
  for each row execute function public.recibos_check_cobrador_update();

-- =========================================================================
-- 3. PAGOS / CARGOS_EXTRA: validar que cuota_id pertenezca al cobrador
-- =========================================================================
-- Nota: las policies actuales (pagos_insert_propio, cargos_insert) sólo
-- piden cobrador_id = auth.uid(). Endurecemos con EXISTS.

drop policy "pagos_insert_propio" on public.pagos;

create policy "pagos_insert_propio" on public.pagos
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (
        public.current_user_rol() = 'cobrador'
        and cobrador_id = auth.uid()
        and exists (
          select 1 from public.cuotas
           where id = pagos.cuota_id
             and cobrador_id = auth.uid()
        )
      )
    )
  );

drop policy "cargos_insert" on public.cargos_extra;

create policy "cargos_insert" on public.cargos_extra
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (
        public.current_user_rol() = 'cobrador'
        and cobrador_id = auth.uid()
        and exists (
          select 1 from public.cuotas
           where id = cargos_extra.cuota_id
             and cobrador_id = auth.uid()
        )
      )
    )
  );

-- =========================================================================
-- 4. STORAGE: comprobantes-pago scoping por pago_id propio
-- =========================================================================
-- Path: {tenant}/comp/{pago_id}.jpg → extraer pago_id de split_part(name, '/', 3)
--   sin extensión.

drop policy "storage_write_comprobantes" on storage.objects;

create policy "storage_write_comprobantes_select_y_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = replace(split_part(name, '/', 3), '.jpg', '')
           and cobrador_id = auth.uid()
      )
    )
  );

create policy "storage_update_comprobantes" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or exists (
        select 1 from public.pagos
         where id::text = replace(split_part(name, '/', 3), '.jpg', '')
           and cobrador_id = auth.uid()
      )
    )
  );

-- Borrado: sólo admins. Si alguien necesita borrar comprobantes (caso
-- excepcional), debe pasar por admin.
create policy "storage_delete_comprobantes_admin" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and public.storage_path_tenant(name) = public.current_tenant_id()
    and public.is_admin()
  );
