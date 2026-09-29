-- 0273 — `pagos.fecha_cobro`: el DÍA del cobro, como fecha y no como instante
--
-- ── Para qué ───────────────────────────────────────────────────────────────
--
-- Todas las consultas del Resumen filtran el ciclo así:
--
--     WHERE date(p.fecha_pago) >= ? AND date(p.fecha_pago) <= ?
--
-- El índice está sobre `fecha_pago` tal como se guarda, pero la consulta
-- pregunta por `date(fecha_pago)` — otro valor, calculado al vuelo. SQLite no
-- puede usar el índice y **recorre las 34.010 filas** una por una. Medido en
-- una base local con los datos de Mairena: 76 ms contra 24 ms preguntando de
-- una forma que el índice sí pueda resolver.
--
-- La salida obvia —sacar el `date()`— **pierde plata**: un cobro del 14 a las
-- 16:30 está guardado como `2026-09-14 16:30:00`, que comparado como texto es
-- MAYOR que `2026-09-14`, así que un `fecha_pago <= '…-14'` lo deja afuera del
-- ciclo. En producción son **192 pagos por C$152.143 en Telecable Mairena** y
-- 21 por C$23.554 en Telenet: cobros reales, con su recibo en mano del cliente.
--
-- Decisión del dueño (2026-09-03): *"el periodo es por dia, que una cuota se
-- pague a las 6 pm da igual… el time solo es util a la hora de imprimir el
-- recibo"*. Entonces se guarda el día aparte, como `date`, y las consultas
-- comparan fecha contra fecha. Sin funciones de por medio no hay nada que
-- recortar, no hay borde que cuidar y el índice entra solo.
--
-- ── LA ZONA HORARIA (lo que hay que leer antes de tocar esto) ──────────────
--
-- `fecha_pago` es `timestamptz`, pero guarda el **wall-clock local de
-- Nicaragua etiquetado como UTC** — convención vieja del proyecto, ya
-- documentada en 0096 y 0214. Por eso el día correcto se saca con
-- `AT TIME ZONE 'UTC'` y **NUNCA** con `AT TIME ZONE 'America/Managua'`.
--
-- No es una sutileza teórica: medido sobre las 34.010 filas de producción,
-- convertir a Managua movería **26.178 pagos (el 77%) al día anterior**,
-- porque el grueso está guardado a las 00:00:00 y restarle 6 horas los tira al
-- día de antes. Con UTC la diferencia es CERO — o sea, coincide exactamente
-- con el día que la app viene calculando hoy con `date()`.
--
-- ── Por qué el backfill es seguro ──────────────────────────────────────────
--
-- `pagos` tiene 9 triggers. Los que recalculan cuotas están todos acotados con
-- `UPDATE OF monto_cordobas, cuota_id, anulado, en_revision`, así que tocar
-- SOLO `fecha_cobro` no dispara ninguno. De los dos que corren en cualquier
-- UPDATE, `pagos_guard_cobrador_trg` sale de entrada si el rol no es cobrador
-- y `validar_tenant_coherente` sale de entrada si no cambian `tenant_id` ni
-- `cuota_id` — que es justo este caso. Verificado leyendo los nueve.
--
-- ── Quién la llena ─────────────────────────────────────────────────────────
--
-- El trigger de acá abajo, SIEMPRE, pisando lo que venga. Y **además el
-- cliente la escribe en su INSERT**: los triggers de Postgres no corren en el
-- SQLite del dispositivo, así que un cobro hecho offline no la tendría hasta
-- volver del servidor — y en esa ventana desaparecería del Resumen. Es la
-- regla de denormalización que el checklist del proyecto ya tiene escrita.
-- Si el cliente manda cualquier cosa, el trigger la corrige: server gana.

begin;

alter table public.pagos
  add column if not exists fecha_cobro date;

comment on column public.pagos.fecha_cobro is
  'El DIA del cobro, derivado de fecha_pago con AT TIME ZONE ''UTC'' (ver 0273). '
  'Existe para que las consultas del dashboard filtren por fecha sin envolver la '
  'columna en date(), que anula el indice. NO se muestra en ninguna pantalla: el '
  'recibo y el arqueo siguen usando fecha_pago con su hora.';

-- ── El trigger, antes del backfill: así cualquier fila que entre mientras
--    corre la migración ya nace con su fecha puesta.
create or replace function public.pagos_fecha_cobro_trg()
returns trigger
language plpgsql
as $$
begin
  -- SIEMPRE derivada, nunca lo que mande el cliente. Es la regla "server gana":
  -- el cliente la escribe para poder verse a sí mismo offline, pero la verdad
  -- la fija acá.
  new.fecha_cobro := (new.fecha_pago at time zone 'UTC')::date;
  return new;
end $$;

drop trigger if exists aa_pagos_fecha_cobro on public.pagos;
create trigger aa_pagos_fecha_cobro
  before insert or update of fecha_pago on public.pagos
  for each row execute function public.pagos_fecha_cobro_trg();

-- ── Backfill de las 34.010 filas ───────────────────────────────────────────
update public.pagos
   set fecha_cobro = (fecha_pago at time zone 'UTC')::date
 where fecha_cobro is null
    or fecha_cobro is distinct from (fecha_pago at time zone 'UTC')::date;

-- ── El índice que todo esto vino a hacer usable ────────────────────────────
create index if not exists pagos_tenant_fecha_cobro_idx
  on public.pagos (tenant_id, fecha_cobro);

-- ── VERIFICACIÓN: que la columna nueva diga EXACTAMENTE lo mismo que la
--    cuenta vieja. Si difiere una sola fila, la migración aborta: sería plata
--    apareciendo o desapareciendo de un día.
do $$
declare
  v_null   bigint;
  v_difiere bigint;
  v_total  bigint;
begin
  select count(*) into v_total from public.pagos;

  select count(*) into v_null
    from public.pagos where fecha_cobro is null;

  -- `date(fecha_pago)` es lo que la app calcula hoy. La columna nueva tiene
  -- que coincidir fila por fila, o cambiamos el significado de un ciclo.
  select count(*) into v_difiere
    from public.pagos
   where fecha_cobro is distinct from (fecha_pago at time zone 'UTC')::date;

  raise notice '0273 · pagos=% · sin fecha_cobro=% · que difieren de la cuenta vieja=%',
    v_total, v_null, v_difiere;

  if v_null > 0 then
    raise exception '0273 ABORTA: % pagos quedaron sin fecha_cobro', v_null;
  end if;
  if v_difiere > 0 then
    raise exception '0273 ABORTA: % pagos no coinciden con date(fecha_pago)', v_difiere;
  end if;
end $$;

-- ── Y que la PLATA por ciclo no se haya movido ─────────────────────────────
--    Se compara el total de cada mes calculado de las dos maneras. Es la
--    prueba de que el Resumen va a mostrar los mismos números.
do $$
declare r record; v_malos int := 0;
begin
  for r in
    select to_char((fecha_pago at time zone 'UTC'), 'YYYY-MM') as mes,
           round(sum(monto_cordobas) filter (
             where date(fecha_pago) between
                   date_trunc('month', fecha_pago at time zone 'UTC')::date
               and (date_trunc('month', fecha_pago at time zone 'UTC')
                    + interval '1 month - 1 day')::date)::numeric, 2) as vieja,
           round(sum(monto_cordobas) filter (
             where fecha_cobro between
                   date_trunc('month', fecha_pago at time zone 'UTC')::date
               and (date_trunc('month', fecha_pago at time zone 'UTC')
                    + interval '1 month - 1 day')::date)::numeric, 2) as nueva
      from public.pagos
     where anulado = false and en_revision = false
     group by 1 order by 1 desc limit 6
  loop
    if r.vieja is distinct from r.nueva then
      raise notice '0273 · MES % : vieja=% nueva=%  <<< DIFIERE', r.mes, r.vieja, r.nueva;
      v_malos := v_malos + 1;
    else
      raise notice '0273 · mes % : % (igual por los dos caminos)', r.mes, r.vieja;
    end if;
  end loop;

  if v_malos > 0 then
    raise exception '0273 ABORTA: % meses con plata distinta', v_malos;
  end if;
end $$;

commit;
