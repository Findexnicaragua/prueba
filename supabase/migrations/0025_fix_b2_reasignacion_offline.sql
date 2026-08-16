-- Fix B2: cobro de cliente reasignado offline rechaza por RLS.
--
-- Escenario:
--   1. Cobrador A tiene cliente X asignado, baja sus cuotas via sync.
--   2. A va al campo offline y cobra cuota de X.
--   3. Mientras A está offline, admin reasigna cliente X → cobrador B.
--   4. propagate_cobrador_id_from_cliente cambia cuotas.cobrador_id → B.
--   5. A vuelve a tener internet, PowerSync sube su pago.
--   6. Policy pagos_insert_propio rechaza: cuota.cobrador_id ya no es A.
--      Queue atascada para siempre.
--
-- Solución: relajar el EXISTS para que el cobrador pueda insertar pago
-- contra cualquier cuota DE SU TENANT, mientras el pago tenga
-- cobrador_id = auth.uid(). La auditoría queda intacta (cobrador_id del
-- pago apunta a quien cobró). El cobrador no puede inventar cuotas
-- porque sólo ve las suyas via sync.

drop policy "pagos_insert_propio" on public.pagos;

create policy "pagos_insert_propio" on public.pagos
  for insert with check (
    tenant_id = public.current_tenant_id()
    and (
      public.is_admin_or_cobranza()
      or (
        public.current_user_rol() = 'cobrador'
        and cobrador_id = auth.uid()
        -- La cuota debe existir en el tenant. Quitamos la restricción
        -- 'cuotas.cobrador_id = auth.uid()' para que un cobro hecho
        -- offline antes de una reasignación se acepte al subir.
        and exists (
          select 1 from public.cuotas
           where id = pagos.cuota_id
             and tenant_id = public.current_tenant_id()
        )
      )
    )
  );

-- Idem para cargos_extra.
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
             and tenant_id = public.current_tenant_id()
        )
      )
    )
  );

-- Para UPDATE de cuotas: el cobrador necesita poder actualizar
-- monto_pagado/estado de su cobro offline aunque la cuota ya esté
-- reasignada. Cambiamos `cobrador_id = auth.uid()` a "cobrador del
-- tenant" — el trigger BEFORE UPDATE (cuotas_check_cobrador_update,
-- migración 0022) sigue restringiendo qué columnas puede tocar.

drop policy "cuotas_update_cobrador_propio" on public.cuotas;

create policy "cuotas_update_cobrador_propio" on public.cuotas
  for update
  using (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'cobrador'
  )
  with check (
    tenant_id = public.current_tenant_id()
    and public.current_user_rol() = 'cobrador'
  );

-- =========================================================================
-- E1 — Bloquear contratos con cobrador_id = NULL
-- =========================================================================
-- Cuando un cliente no tiene cobrador asignado, las cuotas se generan con
-- cobrador_id=NULL y son invisibles para todos los cobradores via sync
-- rules. Forzamos que el contrato falle si el cliente no tiene cobrador
-- asignado.

create or replace function public.contratos_check_cliente_con_cobrador()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cobrador_id uuid;
begin
  select cobrador_id into v_cobrador_id
    from public.clientes where id = new.cliente_id;
  if v_cobrador_id is null then
    raise exception 'Cliente sin cobrador asignado. Asignale uno antes de crear contrato.';
  end if;
  return new;
end;
$$;

create trigger trg_contratos_check_cliente_con_cobrador
  before insert on public.contratos
  for each row execute function public.contratos_check_cliente_con_cobrador();
