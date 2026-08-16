-- 0082 — FIX CRÍTICO de validar_tenant_coherente() (0078).
--
-- BUG: la función es polimórfica (un solo trigger en pagos / cargos_extra /
-- recibos / visitas) y arrancaba con una condición COMPARTIDA que referenciaba
-- `new.pago_id` y `new.cliente_id` en un OR:
--
--   if tg_op = 'UPDATE' and ... (
--        (tg_table_name in ('pagos','cargos_extra') and new.cuota_id ...) or
--        (tg_table_name = 'recibos' and new.pago_id ...) or       -- ← falla
--        (tg_table_name = 'visitas' and new.cliente_id ...) )     -- ← falla
--
-- PL/pgSQL PLANIFICA la expresión booleana completa apenas la ejecución llega
-- al IF (en cada INSERT/UPDATE), y al resolver `new.pago_id` / `new.cliente_id`
-- contra una fila de `pagos` (que NO tiene esas columnas) tira:
--   "record \"new\" has no field \"pago_id\""
-- → rompe TODO INSERT/UPDATE de pagos y cargos_extra (el cobro entero).
--
-- FIX: ramificar por `tg_table_name` PRIMERO y referenciar solo los campos de
-- esa tabla DENTRO de su rama. PL/pgSQL planifica cada sentencia recién cuando
-- la ejecución la alcanza, así que la rama de `recibos` (con new.pago_id) nunca
-- se planifica cuando el trigger corre sobre `pagos`. Misma lógica de validación
-- y de skip de UPDATE benigno que 0078 — solo cambia la estructura. Los triggers
-- de 0078 siguen vigentes (llaman a la función por nombre); solo se reemplaza el
-- cuerpo con CREATE OR REPLACE.

create or replace function public.validar_tenant_coherente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_padre uuid;
begin
  -- pagos.tenant_id debe == cuotas.tenant_id (por cuota_id)
  if tg_table_name = 'pagos' then
    -- UPDATE benigno (no se mueve de tenant ni de cuota): no validar.
    if tg_op = 'UPDATE'
       and new.tenant_id is not distinct from old.tenant_id
       and new.cuota_id is not distinct from old.cuota_id then
      return new;
    end if;
    select tenant_id into v_tenant_padre
      from public.cuotas where id = new.cuota_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del pago (%) no coincide con el de su cuota (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  -- cargos_extra.tenant_id debe == cuotas.tenant_id (por cuota_id)
  elsif tg_table_name = 'cargos_extra' then
    if tg_op = 'UPDATE'
       and new.tenant_id is not distinct from old.tenant_id
       and new.cuota_id is not distinct from old.cuota_id then
      return new;
    end if;
    select tenant_id into v_tenant_padre
      from public.cuotas where id = new.cuota_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del cargo (%) no coincide con el de su cuota (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  -- recibos.tenant_id debe == pagos.tenant_id (por pago_id)
  elsif tg_table_name = 'recibos' then
    if tg_op = 'UPDATE'
       and new.tenant_id is not distinct from old.tenant_id
       and new.pago_id is not distinct from old.pago_id then
      return new;
    end if;
    select tenant_id into v_tenant_padre
      from public.pagos where id = new.pago_id;
    if v_tenant_padre is not null and v_tenant_padre <> new.tenant_id then
      raise exception
        'tenant_id del recibo (%) no coincide con el de su pago (%)',
        new.tenant_id, v_tenant_padre using errcode = 'check_violation';
    end if;

  -- visitas.tenant_id debe == clientes.tenant_id (por cliente_id)
  elsif tg_table_name = 'visitas' then
    if tg_op = 'UPDATE'
       and new.tenant_id is not distinct from old.tenant_id
       and new.cliente_id is not distinct from old.cliente_id then
      return new;
    end if;
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
