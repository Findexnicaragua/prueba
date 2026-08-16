-- 0214 — Guard de sobrepago: el servidor deja de aceptar en silencio un cobro
-- que deja la cuota por encima de su total (INV4).
--
-- POR QUÉ
-- El 26/07/2026 entraron 72 pagos que dejaron 36 cuotas sobrepagadas
-- (C$30.003, 9 clientes): dos usuarios cargando el mismo histórico. 33 de esos
-- casos son copia EXACTA (misma cuota, mismo monto, mismo día) y 3 son un pago
-- real imputado al mes equivocado. Nadie se enteró hasta que se corrió el
-- chequeo a mano — eso es lo que este guard viene a cerrar.
--
-- POR QUÉ ANULA Y NO RECHAZA
-- `raise exception` funcionaría: `connector.dart` clasifica P0001 como error
-- permanente, lo saltea y NO traba la cola. Pero el pago quedaría solo en el
-- device (divergente del server) con un recibo ya impreso que no respalda
-- nada. Anulándolo, la fila existe de los dos lados, el cobrador ve en su
-- propia app que quedó anulada, y `recalcular_cuota_desde_pagos` no la suma
-- (ya filtra por anulado = false) → la cuota cuadra sola.
--
-- QUÉ **NO** HACE
-- Si el pago excede pero NO es copia exacta (otro monto u otra fecha), entra
-- igual. Puede ser plata real imputada al mes equivocado y la app no tiene
-- forma de saber cuál de los dos es el bueno: lo decide una persona. Esos
-- casos se listan solos con la consulta del pie (pantalla "Cobros a revisar").

BEGIN;

-- `pagos_anulacion_coherencia` exigía `anulado_por IS NOT NULL` para toda
-- anulación. Acá no hay persona que haya anulado: lo hizo el server. Poner al
-- cobrador del pago sería MENTIR en el rastro — un reporte de anulaciones lo
-- mostraría como si él lo hubiera anulado.
--
-- Se abre el carve-out EXACTO para el caso del sistema (actor nulo + motivo
-- automático) y se deja la exigencia intacta para las anulaciones humanas: una
-- anulación hecha por un usuario sigue necesitando sí o sí quién, cuándo y por
-- qué. El prefijo del motivo lo escribe el trigger de abajo, nadie más.
alter table public.pagos drop constraint if exists pagos_anulacion_coherencia;
alter table public.pagos add constraint pagos_anulacion_coherencia
  check (
    anulado = false
    or (anulado_en is not null
        and motivo_anulacion is not null
        and (anulado_por is not null
             or motivo_anulacion like 'Duplicado automático:%'))
  );

create or replace function public.pagos_guard_sobrepago_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
-- `fecha_pago` guarda el WALL-CLOCK local como si fuera UTC (convención de
-- AGENTS §1b: su `date()` sostiene el bucketing). Con la sesión en UTC,
-- `::date` devuelve el día que el usuario eligió; convertir a
-- 'America/Managua' correría un día para atrás todo pago retroactivo
-- (verificado: 2026-01-12 00:00+00 → 2026-01-11). Se fija acá para no
-- depender del TimeZone de la sesión que dispare el trigger.
set timezone = 'UTC'
as $$
declare
  v_total_a_cobrar numeric(10,2);
  v_ya_pagado      numeric(10,2);
  v_gemelo         uuid;
begin
  -- Un pago que ya llega anulado no suma a la cuota: no hay nada que evaluar.
  if new.anulado then
    return new;
  end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(new.cuota_id);
  if v_total_a_cobrar is null then
    return new;  -- cuota inexistente: que lo rechace la FK, no este guard
  end if;

  -- OJO — `p.id <> new.id` NO es decorativo: el upload de PowerSync es un
  -- UPSERT (`connector.dart`, UpdateType.put → `table.upsert`), así que un
  -- reintento del MISMO pago vuelve a disparar este BEFORE INSERT con la fila
  -- ya commiteada. Sin excluirse a sí mismo, el reintento se leería como
  -- duplicado de sí mismo y se auto-anularía.
  select coalesce(sum(p.monto_cordobas), 0)
    into v_ya_pagado
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false
     and p.id <> new.id;

  -- No excede → el 99,9% de los cobros. El guard no toca nada.
  -- Tolerancia de 1 centavo, igual que INV4 en invariantes_dinero.sql.
  if v_ya_pagado + new.monto_cordobas <= v_total_a_cobrar + 0.01 then
    return new;
  end if;

  -- Excede. ¿Ya hay un pago IDÉNTICO en esta cuota? Se compara en centavos
  -- enteros para no arrastrar el redondeo de numeric.
  --
  -- Que el monto sea igual NO alcanza por sí solo: dos parciales de 500 sobre
  -- una cuota de 1000 son legítimos y no llegan acá justamente porque no
  -- exceden. Llegar acá con monto y día iguales solo pasa si el cobro se
  -- cargó dos veces.
  select p.id
    into v_gemelo
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false
     and p.id <> new.id
     and round(p.monto_cordobas * 100) = round(new.monto_cordobas * 100)
     and p.fecha_pago::date = new.fecha_pago::date
   order by p.fecha_pago
   limit 1;

  if v_gemelo is null then
    return new;  -- excede pero no es copia: lo resuelve una persona
  end if;

  new.anulado          := true;
  new.anulado_en       := now();
  new.anulado_por      := null;  -- lo anuló el servidor, no un usuario
  new.motivo_anulacion := coalesce(
    new.motivo_anulacion,
    'Duplicado automático: ya existe un pago idéntico en esta cuota ('
      || v_gemelo || ')');
  return new;
end $$;

drop trigger if exists trg_pagos_guard_sobrepago on public.pagos;
create trigger trg_pagos_guard_sobrepago
  before insert on public.pagos
  for each row execute function public.pagos_guard_sobrepago_trg();

-- Descuentos huérfanos de un pago auto-anulado.
--
-- `trg_pagos_revertir_descuentos` limpia los `cargos_extra` de descuento
-- cuando un pago pasa de vivo a anulado, pero es AFTER UPDATE OF anulado: no
-- dispara si el pago nace anulado. Y los cargos del cobro suben DESPUÉS del
-- pago en el mismo batch, así que tampoco están todavía cuando corre el guard.
-- Sin esto, un cobro duplicado CON descuento quedaría anulado pero con su
-- descuento aplicado, bajando `cuota_total_a_cobrar` sin pago que lo sostenga.
create or replace function public.cargos_descuento_de_pago_anulado_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.pago_id is null
     or new.tipo not in ('descuento_monto', 'descuento_porcentaje') then
    return new;
  end if;
  -- Mismo alcance que pagos_revertir_descuentos_trg: descuentos atados a un
  -- pago que ya no cuenta. Descartar la fila (return null) deja al server sin
  -- ella y PowerSync converge borrándola del device.
  if exists (select 1 from public.pagos p
              where p.id = new.pago_id and p.anulado = true) then
    return null;
  end if;
  return new;
end $$;

drop trigger if exists trg_cargos_descuento_pago_anulado on public.cargos_extra;
create trigger trg_cargos_descuento_pago_anulado
  before insert on public.cargos_extra
  for each row execute function public.cargos_descuento_de_pago_anulado_trg();

COMMIT;

-- Verificación post-deploy (correr a mano):
--
--   -- 1) Los dos triggers existen:
--   select tgname from pg_trigger
--    where tgname in ('trg_pagos_guard_sobrepago',
--                     'trg_cargos_descuento_pago_anulado');        -- 2 filas
--
--   -- 2) El guard fija la sesión en UTC (si no, los pagos retroactivos
--   --    se comparan contra el día equivocado):
--   select proconfig from pg_proc
--    where proname = 'pagos_guard_sobrepago_trg';   -- incluye TimeZone=UTC
--
--   -- 3) Cobros a revisar — excede el total y NADIE lo anuló solo (o sea,
--   --    no era copia exacta). Es la consulta que alimenta la pantalla.
--   select cl.nombre, cu.periodo::date, cu.monto_pagado,
--          public.cuota_total_a_cobrar(cu.id) as total
--     from public.cuotas cu
--     join public.contratos ct on ct.id = cu.contrato_id
--     join public.clientes  cl on cl.id = ct.cliente_id
--    where cu.estado <> 'anulada'
--      and cu.monto_pagado > public.cuota_total_a_cobrar(cu.id) + 0.01
--    order by cl.nombre, cu.periodo;
--
--   -- 4) Lo que el guard anuló solo (auditoría de falsos positivos):
--   select count(*) from public.pagos
--    where anulado = true and anulado_por is null
--      and motivo_anulacion like 'Duplicado autom%';
