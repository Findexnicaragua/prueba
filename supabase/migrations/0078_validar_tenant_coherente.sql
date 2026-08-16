-- 0078 — Defensa server-side de coherencia de tenant en el rastro de dinero.
--
-- Contexto (#9): se detectó que el super_admin impersonando podía registrar
-- un pago/cargo cuyo `tenant_id` quedaba en el tenant System (su fila real)
-- en vez del tenant impersonado, generando pagos/recibos huérfanos invisibles
-- para el ISP y rompiendo los invariantes de dinero #4/#10. El fix principal
-- es client-side (se bloquean esas acciones impersonando), pero acá agregamos
-- una defensa en profundidad a nivel DB: rechazar cualquier INSERT donde el
-- tenant del hijo no coincida con el de su padre.
--
--   pagos.tenant_id        debe == cuotas.tenant_id   (por cuota_id)
--   cargos_extra.tenant_id debe == cuotas.tenant_id   (por cuota_id)
--   recibos.tenant_id      debe == pagos.tenant_id    (por pago_id)
--   visitas.tenant_id      debe == clientes.tenant_id (por cliente_id)
--
-- Se valida en INSERT y en los UPDATE que MUEVEN la fila de tenant/padre
-- (cambian tenant_id o el link cuota_id/pago_id/cliente_id). Los UPDATE
-- benignos (anular, editar notas/monto) NO se validan → no bloquean filas
-- legacy que pudieran ser incoherentes. Esto cierra el vector UPDATE-move del
-- super_admin (que evade el scoping de RLS via super_admin_all). SECURITY
-- DEFINER para leer el tenant real del padre sin que RLS lo oculte y haga
-- pasar la validación por error.

create or replace function public.validar_tenant_coherente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_padre uuid;
begin
  -- En UPDATE solo validamos si la fila se "mueve" de tenant o de padre
  -- (cambia tenant_id o el link al padre). Un UPDATE benigno (anular, editar
  -- notas/monto) NO se valida → no bloquea filas legacy que pudieran ser
  -- incoherentes. Esto cierra el vector UPDATE-move del super_admin (que evade
  -- el scoping de RLS por la policy super_admin_all) sin romper anular/editar.
  if tg_op = 'UPDATE'
     and new.tenant_id is not distinct from old.tenant_id
     and (
       (tg_table_name in ('pagos', 'cargos_extra')
          and new.cuota_id is not distinct from old.cuota_id)
       or (tg_table_name = 'recibos'
          and new.pago_id is not distinct from old.pago_id)
       or (tg_table_name = 'visitas'
          and new.cliente_id is not distinct from old.cliente_id)
     ) then
    return new;
  end if;

  if tg_table_name = 'pagos' then
    select tenant_id into v_tenant_padre
      from public.cuotas where id = new.cuota_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del pago (%) no coincide con el de su cuota (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  elsif tg_table_name = 'cargos_extra' then
    select tenant_id into v_tenant_padre
      from public.cuotas where id = new.cuota_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del cargo (%) no coincide con el de su cuota (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  elsif tg_table_name = 'recibos' then
    select tenant_id into v_tenant_padre
      from public.pagos where id = new.pago_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del recibo (%) no coincide con el de su pago (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  elsif tg_table_name = 'visitas' then
    select tenant_id into v_tenant_padre
      from public.clientes where id = new.cliente_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id de la visita (%) no coincide con el de su cliente (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists validar_tenant_coherente_pagos on public.pagos;
create trigger validar_tenant_coherente_pagos
  before insert or update on public.pagos
  for each row execute function public.validar_tenant_coherente();

drop trigger if exists validar_tenant_coherente_cargos on public.cargos_extra;
create trigger validar_tenant_coherente_cargos
  before insert or update on public.cargos_extra
  for each row execute function public.validar_tenant_coherente();

drop trigger if exists validar_tenant_coherente_recibos on public.recibos;
create trigger validar_tenant_coherente_recibos
  before insert or update on public.recibos
  for each row execute function public.validar_tenant_coherente();

drop trigger if exists validar_tenant_coherente_visitas on public.visitas;
create trigger validar_tenant_coherente_visitas
  before insert or update on public.visitas
  for each row execute function public.validar_tenant_coherente();
