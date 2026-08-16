-- Fixes de la segunda pasada de auditoría:
--   1. search_path en current_user_rol + funciones de 0001/0002/0016
--   2. actualizar_notificaciones_mora marcada SECURITY DEFINER
--   3. RLS de recibos: el cobrador puede marcar SUS recibos como impresos
--   4. notif_update_marca con WITH CHECK
--   5. Reapertura automática de notificación cuando un pago se anula y
--      la cuota baja de 'pagada' a 'parcial'/'pendiente'

-- =========================================================================
-- 1. search_path en funciones legacy
-- =========================================================================

create or replace function public.current_tenant_id() returns uuid
language sql stable security definer
set search_path = public, pg_temp
as $$
  select tenant_id from public.cobradores where id = auth.uid()
$$;

create or replace function public.current_user_rol() returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select rol from public.cobradores where id = auth.uid()
$$;

-- Triggers de 0002 — agregar search_path y reescribir.
create or replace function public.set_cobrador_id_from_cliente()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.cobrador_id is null then
    select cobrador_id into new.cobrador_id
    from public.clientes
    where id = new.cliente_id;
  end if;
  return new;
end;
$$;

create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.cuotas    set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.notificaciones_mora
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id
       and resuelta_en is null;
  end if;
  return new;
end;
$$;

-- =========================================================================
-- 2. actualizar_notificaciones_mora marcada SECURITY DEFINER
-- =========================================================================

create or replace function public.actualizar_notificaciones_mora(p_tenant_id uuid)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dias_gracia int := public.setting_number(p_tenant_id, 'cobranza.dias_gracia', 10)::int;
  v_filas int;
begin
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
    cu.monto - cu.monto_pagado
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
-- 3. RLS recibos: el cobrador puede actualizar campos de impresión propios
-- =========================================================================

create policy "recibos_update_impresion_cobrador" on public.recibos
  for update
  using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'cobrador'
    and cobrador_id = auth.uid()
  )
  with check (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'cobrador'
    and cobrador_id = auth.uid()
  );

-- =========================================================================
-- 4. WITH CHECK en notif_update_marca para evitar reasignación arbitraria
-- =========================================================================

drop policy "notif_update_marca" on public.notificaciones_mora;

create policy "notif_update_marca" on public.notificaciones_mora
  for update
  using (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  )
  with check (
    tenant_id = public.current_tenant_id()
    and (public.is_admin_or_cobranza() or cobrador_id = auth.uid())
  );

-- =========================================================================
-- 5. Trigger: reabrir notificación cuando cuota baja de 'pagada' a otro estado
-- =========================================================================
-- Caso típico: pago se anula → trigger central baja cuota.estado a parcial.
-- Necesitamos reabrir la notificación de mora si existe.

create or replace function public.reabrir_notificacion_al_anular_pago()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.estado = 'pagada' and new.estado in ('parcial','pendiente') then
    update public.notificaciones_mora
       set resuelta_en = null,
           resuelta_por = null
     where cuota_id = new.id
       and resuelta_en is not null;
  end if;
  return new;
end;
$$;

create trigger trg_reabrir_notificacion_al_anular_pago
  after update on public.cuotas
  for each row execute function public.reabrir_notificacion_al_anular_pago();
