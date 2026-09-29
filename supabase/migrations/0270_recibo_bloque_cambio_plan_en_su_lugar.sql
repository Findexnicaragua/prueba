-- 0270 — el bloque "Cambio de plan" del recibo va DESPUÉS de Servicio, no al final
--
-- ── El problema ─────────────────────────────────────────────────────────────
--
-- El catálogo (`lib/data/models/recibo_layout.dart`) ubica `cambio_plan` entre
-- `servicio` y `cuota`/`totales`, que es donde tiene sentido: el cliente lee de qué
-- plan a qué plan pasó ANTES de leer cuánto paga.
--
-- Pero `ReciboLayout.fromRaw` (:380-398) completa los bloques faltantes **al final
-- de su zona**, y lo dice en su propio comentario: *"en los tenants que ya tienen
-- layout guardado va a aparecer al FINAL de su zona, no en la posición del
-- catálogo"*. Es una decisión deliberada y con test —el orden que el tenant guardó
-- manda— pero deja al bloque nuevo cayendo después de `totales`, `letras`, `metodo`
-- y `mora`.
--
-- Resultado impreso, en los TRES tenants: el cliente lee MONTO C$846,67, después el
-- detalle de mora, y recién ahí aparece un segundo total en negrita —"Total del mes
-- 846,67"— que parece un cobro adicional. El bloque se agregó justamente para que un
-- cargo que el cliente no puede deducir no termine en un reclamo, y llegaba después
-- de la pregunta.
--
-- Audit 2026-09-03. Verificado en producción ANTES de escribir esto: los tres
-- tenants tienen `recibo.layout` guardado con **13 bloques** (el catálogo tiene 14),
-- los tres traen `servicio`, y ninguno trae `cambio_plan`.
--
-- ── Por qué se arregla acá y no en el código ────────────────────────────────
--
-- Rubén pidió explícitamente NO tocar la generación del recibo
-- (*"eso ya se ha batallado demasiado"*), y tiene razón: cambiar la regla de
-- `fromRaw` movería de lugar CUALQUIER bloque futuro en todos los tenants, que es
-- justo lo que esa regla evita. Lo que está mal no es la regla: es que estos tres
-- layouts no nombran un bloque que ya existe. Se arregla el DATO.
--
-- Idempotente: si el tenant ya lo tiene (o lo movió a mano desde el editor), no se
-- toca. Un admin que después lo reubique gana sobre esto.

begin;

do $$
declare v_pendientes int;
begin
  select count(*) into v_pendientes
    from public.settings s
   where s.clave = 'recibo.layout'
     and not (s.valor::jsonb @> '[{"id":"cambio_plan"}]');
  raise notice '0270 · layouts a reordenar: %', v_pendientes;
end $$;

with objetivo as (
  select s.tenant_id, s.valor::jsonb as arr
    from public.settings s
   where s.clave = 'recibo.layout'
     -- Idempotencia: sólo los que NO lo nombran todavía.
     and not (s.valor::jsonb @> '[{"id":"cambio_plan"}]')
     -- Sin `servicio` no hay ancla; se deja como está (cae al final, como hoy)
     -- en vez de meterlo en un lugar arbitrario.
     and s.valor::jsonb @> '[{"id":"servicio"}]'
),
piezas as (
  -- Todos los bloques que ya tenía, con su posición original…
  select o.tenant_id, e.valor as elem, e.ord::numeric as ord
    from objetivo o,
         lateral jsonb_array_elements(o.arr) with ordinality e(valor, ord)
  union all
  -- …más el nuevo, media posición DESPUÉS de `servicio`.
  -- `visible: true` espeja `visibleDefault` del catálogo (a diferencia de
  -- `cuota`, que nace apagado): sólo se dibuja cuando esa cuota REALMENTE viene
  -- de un cambio de plan, así que en un recibo normal no ocupa una línea.
  select o.tenant_id,
         '{"id":"cambio_plan","visible":true,"size":"normal","espacioAntes":"normal"}'::jsonb,
         e.ord::numeric + 0.5
    from objetivo o,
         lateral jsonb_array_elements(o.arr) with ordinality e(valor, ord)
   where e.valor->>'id' = 'servicio'
),
nuevo as (
  select tenant_id, jsonb_agg(elem order by ord) as arr
    from piezas group by tenant_id
)
update public.settings s
   set valor = n.arr::text,
       updated_at = now()
  from nuevo n
 where s.tenant_id = n.tenant_id
   and s.clave = 'recibo.layout';

-- Verificación DENTRO de la transacción.
do $$
declare r record; v_malos int := 0;
begin
  for r in
    select t.nombre,
           (s.valor::jsonb @> '[{"id":"cambio_plan"}]') as tiene,
           jsonb_array_length(s.valor::jsonb) as bloques,
           (select min(o) from jsonb_array_elements(s.valor::jsonb)
                 with ordinality e(v, o) where v->>'id' = 'servicio') as pos_servicio,
           (select min(o) from jsonb_array_elements(s.valor::jsonb)
                 with ordinality e(v, o) where v->>'id' = 'cambio_plan') as pos_cambio,
           (select min(o) from jsonb_array_elements(s.valor::jsonb)
                 with ordinality e(v, o) where v->>'id' = 'totales') as pos_totales
      from public.settings s join public.tenants t on t.id = s.tenant_id
     where s.clave = 'recibo.layout'
  loop
    raise notice '0270 · % → bloques=% servicio=% cambio_plan=% totales=%',
      r.nombre, r.bloques, r.pos_servicio, r.pos_cambio, r.pos_totales;

    -- Lo que importa: que quede DESPUÉS de servicio y ANTES del total.
    if r.tiene and not (r.pos_cambio > r.pos_servicio
                        and (r.pos_totales is null or r.pos_cambio < r.pos_totales)) then
      v_malos := v_malos + 1;
    end if;
  end loop;

  if v_malos > 0 then
    raise exception '0270 ABORTA: % layouts quedaron con el bloque fuera de lugar', v_malos;
  end if;
end $$;

commit;
