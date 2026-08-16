-- 0075: recalcular_cuota_desde_pagos propaga ocurrido_en (device time).
--
-- PROBLEMA (Change Log / historial de cobro):
-- Al registrar un cobro, el trigger server-side recalcular_cuota_desde_pagos
-- (0012/0018) recalcula cuotas.monto_pagado + estado, pero NO seteaba
-- ocurrido_en. Esa funcion es anterior a la 0069 (que introdujo el device
-- time). Como la columna cuotas.ocurrido_en venia en NULL (la generacion
-- mensual tampoco la setea), el audit_log de ESE cambio — el real:
-- pendiente->pagada — caia al COALESCE(p_ocurrido_en, now()) de
-- audit_registrar, quedando con la HORA DE SYNC del server en vez de la hora
-- real del cobro. El cliente ademas hace su propio UPDATE de la cuota con el
-- device time correcto, pero llega despues del trigger y queda no-op.
--
-- CONSECUENCIA observada (confirmada con audit_log real de un cobro
-- multi-cuota):
--   * La 2da cuota del cobro tenia su cambio real (pendiente->pagada) con
--     ocurrido_en = server time, a >3s del device time del pago. El
--     HistorialCuotaWidget agrupa pago<->cuota por una ventana de 3s sobre
--     ocurrido_en, asi que ese cambio NO se agrupaba con el pago y aparecia
--     "pendiente->pagada" colgando suelto, desconectado del cobro.
--   * En cobros offline sincronizados tarde, el historial mostraba la hora de
--     sync, no la del cobro — exactamente lo que la 0069 buscaba evitar.
--
-- FIX:
-- El UPDATE de la cuota propaga ocurrido_en desde la fila que disparo el
-- trigger (el pago en pagos, o el cargo en cargos_extra) via
-- coalesce(new.ocurrido_en, old.ocurrido_en, now()) — mismo patron que el
-- coalesce(new.cuota_id, old.cuota_id) que la funcion ya usaba. Asi el cambio
-- canonico de la cuota lleva el device time del cobro y se alinea con el pago.
--
-- NO cambia la logica de monto_pagado/estado: solo agrega ocurrido_en al SET.
-- Las invariantes de dinero quedan intactas (monto_pagado sigue siendo
-- SUM(pagos no anulados); estado se deriva igual). Idempotente
-- (CREATE OR REPLACE). Solo funcion server-side: NO toca schema.dart, db.dart
-- ni sync rules.
--
-- Se aplica el MISMO fix a cargos_extra_actualizar_neto_trg (0023), que
-- actualiza cuotas.cargos_neto cuando se inserta/edita/borra un cargo extra
-- (ej. reconexion durante el cobro) y tampoco propagaba ocurrido_en — mismo
-- sintoma de desalineacion en el historial del cobro-con-cargo.

BEGIN;

create or replace function public.recalcular_cuota_desde_pagos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
  v_total_pagado numeric(10,2);
  v_total_a_cobrar numeric(10,2);
  v_estado_actual text;
  v_nuevo_estado text;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);

  select coalesce(sum(monto_cordobas), 0)
    into v_total_pagado
    from public.pagos
   where cuota_id = v_cuota_id and anulado = false;

  select estado into v_estado_actual from public.cuotas where id = v_cuota_id;
  if v_estado_actual = 'anulada' then
    return coalesce(new, old);
  end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(v_cuota_id);

  if v_total_pagado <= 0 then
    v_nuevo_estado := 'pendiente';
  elsif v_total_pagado < v_total_a_cobrar then
    v_nuevo_estado := 'parcial';
  else
    v_nuevo_estado := 'pagada';
  end if;

  -- ocurrido_en: propagar el device time del pago/cargo que disparo el
  -- trigger. coalesce con old (caso DELETE) y now() (fallback, ej. la fila
  -- disparadora no traia device time). Mismo patron que coalesce(new.cuota_id,
  -- old.cuota_id) de arriba.
  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado,
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

-- Mismo fix para el trigger de cargos_neto: propagar el device time del
-- cargo_extra que disparo el recalculo. Sin esto, el cobro con cargo de
-- reconexion deja el cambio de cargos_neto de la cuota con hora de sync.
create or replace function public.cargos_extra_actualizar_neto_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cuota_id uuid;
begin
  v_cuota_id := coalesce(new.cuota_id, old.cuota_id);
  update public.cuotas
     set cargos_neto = public.calcular_cargos_neto(v_cuota_id),
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;
  return coalesce(new, old);
end;
$$;

COMMIT;
