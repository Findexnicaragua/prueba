-- 0264 — El duplicado IDÉNTICO también lo decide una persona
--
-- QUE: la rama del "gemelo exacto" del guard de sobrepago deja de ANULAR sola
-- y pasa a mandar el cobro a CUARENTENA (`en_revision`), igual que la otra
-- rama. Todo duplicado espera decisión del admin.
--
-- REGLA (dueño, 2026-08-29): dos cobros con el mismo monto y el mismo día NO
-- son intercambiables. Cada uno tiene su RECIBO, con su correlativo y su
-- cobrador, y el cliente tiene UNO de los dos en la mano. Además el monto
-- puede coincidir y el recibo no: cambia el vuelto, o uno pagó en dólares.
-- Elegir por el cliente es elegir cuál comprobante queda sin respaldo.
--
-- POR QUE EXISTIA LA RAMA QUE SE SACA: 0214 la agregó para no molestar al
-- admin con lo "obviamente" duplicado. Lo obvio resultó no serlo: en
-- producción se resolvieron así 14 cobros sin que nadie los viera. Se quedan
-- como están (decisión del dueño: lo resuelto, resuelto; la regla nueva rige
-- de acá en adelante).
--
-- QUE NO CAMBIA, y es la razón de que esto sea barato:
--   · El predicado canónico de "pago que cuenta" (anulado=false AND
--     en_revision=false) ya está en las 21 superficies de reportería —caja,
--     arqueo, dashboard, cobertura, mora, Excel—. Un cobro en cuarentena YA
--     no cuenta en ninguna. No hay una sola query que tocar.
--   · El guard de UPDATE (`pagos_guard_sobrepago_update_trg`) no tiene rama de
--     gemelo: ya manda todo a cuarentena. No se toca.
--   · INV18 ("anulación sin actor solo si la hizo el guard") y el CHECK
--     `pagos_anulacion_coherencia` siguen valiendo para los 14 históricos, que
--     conservan su motivo. Hacia adelante el guard deja de anular, así que el
--     invariante queda MÁS estricto, no roto.
--
-- SE VA EL op_log AUTOMÁTICO de esta rama, a propósito: lo escribía porque la
-- anulación era invisible (audit 2026-08-19) y había que dejar rastro de una
-- decisión que tomaba la máquina. Ahora no hay decisión automática que
-- registrar — el cobro queda VISIBLE en la bandeja, y cuando el admin elija,
-- `elegirCobroVerdadero` registra quién decidió y qué. Escribir "detecté un
-- duplicado" en el historial de cada cuota sería ruido sobre algo que ya se ve.

begin;

-- Cuerpo partido de la definición VIGENTE traída de la base (no del archivo de
-- 0240, que pudo quedar atrás) — lección 0151→0152.
create or replace function public.pagos_guard_sobrepago_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_total_a_cobrar numeric(10,2);
  v_ya_pagado      numeric(10,2);
  v_gemelo         uuid;
begin
  if new.anulado then return new; end if;

  v_total_a_cobrar := public.cuota_total_a_cobrar(new.cuota_id);
  if v_total_a_cobrar is null then return new; end if;

  -- Excluye anulados Y en_revision (predicado canónico). El `p.id <> new.id`
  -- es por el UPSERT de PowerSync (reintento del mismo pago): sin él, un
  -- re-put se contaría a sí mismo y se mandaría a cuarentena solo.
  select coalesce(sum(p.monto_cordobas), 0)
    into v_ya_pagado
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false and p.en_revision = false
     and p.id <> new.id;

  if v_ya_pagado + new.monto_cordobas <= v_total_a_cobrar + 0.01 then
    return new;  -- no excede: el 99,9%.
  end if;

  -- Excede. ¿Hay una copia EXACTA (mismo monto + mismo día)?
  -- Ya NO se anula sola: se distingue solo para decirle al admin QUÉ mirar.
  select p.id into v_gemelo
    from public.pagos p
   where p.cuota_id = new.cuota_id
     and p.anulado = false and p.en_revision = false
     and p.id <> new.id
     and round(p.monto_cordobas * 100) = round(new.monto_cordobas * 100)
     and p.fecha_pago::date = new.fecha_pago::date
   order by p.fecha_pago limit 1;

  new.en_revision := true;
  new.revision_motivo := coalesce(
    new.revision_motivo,
    case when v_gemelo is not null
      then 'Cobro idéntico: mismo monto y mismo día que otro cobro de esta '
        || 'cuota. Preguntá al cliente qué recibo tiene y elegí ése.'
      else 'Sobrepago: excede el total de la cuota. Requiere decidir cuál '
        || 'cobro es el verdadero.'
    end);
  return new;
end;
$fn$;

commit;

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICACIÓN POR CONTENIDO (no "existe": qué DICE) — lección 0192
-- ═══════════════════════════════════════════════════════════════════════════
-- Esperado: los tres en `true`.
select
  -- 1. La rama que anulaba ya no está.
  (pg_get_functiondef(oid) not like '%new.anulado          := true%')
    as ya_no_anula,
  -- 2. Manda a cuarentena.
  (pg_get_functiondef(oid) like '%new.en_revision := true%')
    as manda_a_cuarentena,
  -- 3. Sigue distinguiendo el gemelo para orientar al admin.
  (pg_get_functiondef(oid) like '%Cobro id%ntico%')
    as explica_el_gemelo
from pg_proc where proname = 'pagos_guard_sobrepago_trg';
