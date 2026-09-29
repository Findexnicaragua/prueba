-- 0266 — "Estado actual" y "Distribución de cuotas" vuelven ENCENDIDAS
--
-- ⚠️ Esta migración NUNCA SE CORRIÓ. Se AMPLIÓ el 2026-09-02 en vez de apilarle
-- una 0269 encima: dos migraciones tocando el mismo array, una prendiendo
-- `operativo` y la otra `distribucion`, se leen como si pelearan. Como no se
-- ejecutó en ningún tenant, extenderla es seguro y deja UNA sola verdad.
-- (El Test Tenant se prendió A MANO el 2026-09-01, no por acá.)
--
-- ── Lo que pidió Rubén, en dos tiempos ──────────────────────────────────────
--
-- 2026-09-01: *"todo lo que sale actualmente en el dashboard actual tiene que
-- ser optimizado y aparecer en el dashboard nuevo"*. La tarjeta se rehízo
-- (`estado_actual_card.dart`) y de paso se comió a "Distribución de cuotas":
-- eran la misma partición contada dos veces —"Cuotas por cobrar" es
-- EXACTAMENTE al día + en gracia + vencidas— y "En mora" salía repetido en las
-- dos. Verificado contra producción antes de fusionar (Mairena):
-- 20.217 + 797 + 2.596 = 23.610 cuotas y
-- 18.910.031 + 692.255 + 2.018.102 = 21.620.388 C$, al peso.
--
-- 2026-09-02: el dueño pidió las DOS, separadas, en el estilo que tienen hoy en
-- producción: *"Proyección de cobros, Recuperación por cobrador y comunidad,
-- Estado actual y Distribución de cuotas tienen que regresar al estilo anterior
-- y habilitadas"*.
--
-- 🔴 El solapamiento NO se arregló: se ACEPTÓ. Se le mostró con sus propios
-- números de Mairena (20.065 + 746 + 2.563 = 23.374 = "Cuotas por cobrar", y
-- "En mora" 2.563 = "Vencidas") y eligió las dos igual, porque "Distribución"
-- aporta el corte al día/en gracia y el conteo de "Pagadas", que "Estado
-- actual" no tiene. Si mañana alguien lee que los números se repiten y quiere
-- "arreglarlo": está así a propósito y con el dueño enterado.
--
-- ══════════════════════════════════════════════════════════════════════════
-- 🔴 CUÁNDO CORRERLA: **con el release del Resumen nuevo, NO antes.**
-- ══════════════════════════════════════════════════════════════════════════
-- La app instalada hoy (v0.37.1) tiene el Resumen VIEJO, donde `operativo`
-- dibuja la grilla de KPIs sueltos. Correr esto ahora le haría aparecer esa
-- grilla vieja a Mairena y a Telenet, que no la pidieron. El setting y el
-- código tienen que viajar juntos.
--
-- (Para probar, el Test Tenant se encendió a mano el 2026-09-01 — ver
-- BITACORA. Es el único tenant donde hacerlo es inocuo.)

begin;

-- ── 1. Tenants NUEVOS ───────────────────────────────────────────────────────
-- Se reemplaza el CUERPO de la misma función de 0263, no se crea una nueva: así
-- `tenants_seed_settings_trg` queda intacto. Reescribir ese trigger es
-- exactamente donde se perdieron 5 `perform` en 0151 (ver la lección en 0263).
-- El nombre sigue diciendo `_0263` a propósito: renombrarlo obligaría a tocar
-- el trigger.
create or replace function public.seed_settings_dashboard_orden_0263(p_tenant uuid)
returns void language plpgsql as $fn$
begin
  insert into public.settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  select p_tenant, v.clave, v.valor, v.tipo, v.categoria, v.descripcion, v.editable_por
  from (values
    ('dashboard.tarjetas',
     '[{"id":"caja","on":true},
       {"id":"cobertura","on":true},
       {"id":"mora_ciclo","on":true},
       {"id":"proyeccion","on":true},
       {"id":"mora_zona","on":true},
       {"id":"quien_cobro","on":true},
       {"id":"recaudo_mora","on":false},
       {"id":"consultar_periodo","on":false},
       {"id":"sparkline","on":false},
       {"id":"operativo","on":true},
       {"id":"distribucion","on":true}]'::jsonb,
     'json', 'dashboard',
     'Orden y encendido de las tarjetas del Resumen. Se edita en Ajustes → Avanzado → Tarjetas del Resumen.',
     'super_admin')
  ) as v(clave, valor, tipo, categoria, descripcion, editable_por)
  where not exists (
    select 1 from public.settings s where s.tenant_id = p_tenant and s.clave = v.clave
  );
end;
$fn$;

-- ── 2. Tenants que YA tienen su ajuste guardado ─────────────────────────────
-- Se tocan DOS cosas y nada más: el `on` de `operativo` y el de `distribucion`.
-- El orden que el tenant haya elegido y el resto de los flags quedan como están
-- — un backfill que sobreescriba la lista entera le pisa la configuración a
-- quien la movió.
--
-- `settings.valor` es TEXT (no jsonb), y ADENTRO conviven dos formas:
--   · array          → lo que escribe el seed SQL
--   · string de JSON → lo que escribía la pantalla de tarjetas hasta el
--                      2026-09-01 (doble codificación; ver `ordenTarjetasCrudo`)
-- Las dos se aceptan y cada una se devuelve EN SU MISMA FORMA: normalizar acá
-- arreglaría una y rompería la otra si algún cliente viejo sigue leyendo.
with base as (
  select s.id,
         s.valor as crudo,
         case when jsonb_typeof(s.valor::jsonb) = 'array'
              then s.valor::jsonb
              else (s.valor::jsonb #>> '{}')::jsonb
         end as arr,
         jsonb_typeof(s.valor::jsonb) as forma
    from public.settings s
   where s.clave = 'dashboard.tarjetas'
),
nueva as (
  select b.id, b.forma,
         (select jsonb_agg(
                   case when e->>'id' in ('operativo', 'distribucion')
                        then jsonb_set(e, '{on}', 'true'::jsonb)
                        else e end
                   order by ord)
            from jsonb_array_elements(b.arr) with ordinality as t(e, ord)) as arr
    from base b
   where jsonb_typeof(b.arr) = 'array'
)
update public.settings s
   set valor = case when n.forma = 'array'
                    then n.arr::text
                    -- Se devuelve envuelto como estaba: `to_jsonb(text)`
                    -- produce el string JSON con sus comillas.
                    else to_jsonb(n.arr::text)::text
               end,
       updated_at = now()
  from nueva n
 where s.id = n.id
   -- Sin esto, un re-corrido estampa `updated_at` en filas que no cambian.
   and s.valor is distinct from (case when n.forma = 'array'
                                      then n.arr::text
                                      else to_jsonb(n.arr::text)::text end);

commit;

-- ── Verificación POR CONTENIDO (no "existe": que diga lo que tiene que decir)
-- Las tres columnas tienen que dar `true`.
--
-- select
--   (select (valor::jsonb -> 9 ->> 'on')::boolean
--      from pg_get_functiondef(
--             'public.seed_settings_dashboard_orden_0263(uuid)'::regprocedure) f,
--           lateral (select substring(f from '\[\{"id":"caja".*?\}\]') as valor) x
--   ) as seed_nuevo_ok,
--   (select bool_and(
--       (select count(*) from jsonb_array_elements(
--                        case when jsonb_typeof(s.valor::jsonb)='array'
--                             then s.valor::jsonb
--                             else (s.valor::jsonb #>> '{}')::jsonb end) e
--                where e->>'id' in ('operativo','distribucion')
--                  and (e->>'on')::boolean) = 2)
--      from public.settings s where s.clave='dashboard.tarjetas') as tenants_ok,
--   (select bool_and(
--       jsonb_array_length(
--         case when jsonb_typeof(s.valor::jsonb)='array'
--              then s.valor::jsonb
--              else (s.valor::jsonb #>> '{}')::jsonb end) = 11)
--      from public.settings s where s.clave='dashboard.tarjetas') as sin_perder_tarjetas;
