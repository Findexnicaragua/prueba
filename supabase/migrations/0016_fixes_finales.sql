-- Fixes finales de la auditoría:
--   1. actualizar_notificaciones_mora ya no resetea resuelta_en al recalcular.
--   2. Propagación de cobrador_id a notificaciones_mora cuando se reasigna cliente
--      (pagos/recibos/cargos_extra quedan con el cobrador original como auditoría).
--   3. Catálogos geo: inserción restringida a admin/admin_cobranza para evitar
--      basura ad infinitum.

-- =========================================================================
-- 1. actualizar_notificaciones_mora: no resetear resuelta_en
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
    -- resuelta_en/resuelta_por NO se tocan: si el trigger en cuotas las marcó
    -- como resueltas al pagarse, queda como histórico. Si después el pago se
    -- anula, la lógica de anulación es responsable de reabrir la notif.

  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;

-- =========================================================================
-- 2. Propagación a notificaciones_mora cuando se reasigna cliente
-- =========================================================================
-- Solo notificaciones NO resueltas se mueven al nuevo cobrador. Las
-- resueltas quedan con el cobrador histórico que la resolvió (auditoría).

create or replace function public.propagate_cobrador_id_from_cliente()
returns trigger
language plpgsql as $$
begin
  if new.cobrador_id is distinct from old.cobrador_id then
    update public.contratos set cobrador_id = new.cobrador_id where cliente_id = new.id;
    update public.cuotas    set cobrador_id = new.cobrador_id where cliente_id = new.id;

    update public.notificaciones_mora
       set cobrador_id = new.cobrador_id
     where cliente_id = new.id
       and resuelta_en is null;
    -- pagos / recibos / cargos_extra NO se propagan: snapshot histórico
    -- del cobrador que los ejecutó.
  end if;
  return new;
end;
$$;

-- =========================================================================
-- 3. Catálogos geo: inserción sólo admin/admin_cobranza
-- =========================================================================

drop policy "geo_insert_authenticated" on public.departamentos;
drop policy "geo_insert_authenticated" on public.municipios;
drop policy "geo_insert_authenticated" on public.comunidades;

create policy "geo_insert_admins" on public.departamentos
  for insert to authenticated
  with check (public.is_admin_or_cobranza());

create policy "geo_insert_admins" on public.municipios
  for insert to authenticated
  with check (public.is_admin_or_cobranza());

create policy "geo_insert_admins" on public.comunidades
  for insert to authenticated
  with check (public.is_admin_or_cobranza());
