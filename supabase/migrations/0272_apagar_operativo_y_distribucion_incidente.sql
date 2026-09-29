-- 0272 — INCIDENTE: se apagan "Estado actual" y "Distribución de cuotas"
--
-- ⚠️ Esto REVIERTE la `0266`, corrida hoy mismo unas horas antes.
--
-- ── Por qué ────────────────────────────────────────────────────────────────
--
-- Usuarios de Telecable Mairena y Telenet reportaron el Resumen **lento o
-- completamente en blanco** poco después del release de la v0.41.0. Dos cosas
-- pasaron casi al mismo tiempo:
--
--   1. La v0.41.0 les llevó el Resumen NUEVO por primera vez. v0.37.1 tenía
--      5 archivos de dashboard; v0.41.0 tiene 16. Se reconstruyó entero.
--   2. La `0266` encendió `operativo` y `distribucion` para las dos empresas
--      — dos tarjetas que **nunca habían corrido contra sus datos**.
--
-- No hay causa confirmada. Esto NO es el arreglo: es partir el problema al
-- medio con la palanca más rápida que existe. Si el blanco desaparece, la
-- causa está en una de esas dos tarjetas contra el volumen real de Mairena
-- (4.426 contratos activos, 51.458 cuotas). Si no desaparece, se descarta esa
-- mitad en minutos en vez de en una sesión de bisección a ciegas.
--
-- Llega por sync en segundos y no requiere publicar nada.
--
-- ── Lo que NO se toca ──────────────────────────────────────────────────────
--
-- El **Test Tenant** queda como está: tenía las dos tarjetas encendidas A MANO
-- desde el 2026-09-01, mucho antes de la `0266`, y es donde hay que poder
-- seguir reproduciendo el problema. Además su `dashboard.tarjetas` está
-- doble-codificado (bug viejo, ya tolerado por el lector), así que el
-- manipulado jsonb de abajo lo rompería — por eso el filtro `valor LIKE '[%'`.
--
-- ── Para volver a encenderlas ──────────────────────────────────────────────
--
-- Cuando se identifique y arregle la causa, se vuelve a correr la `0266`. Es
-- idempotente respecto de esto: pone las dos en `true`.

begin;

do $$
declare v_antes text;
begin
  select string_agg(t.nombre, ', ' order by t.nombre) into v_antes
    from public.settings s
    join public.tenants t on t.id = s.tenant_id
   where s.clave = 'dashboard.tarjetas'
     and s.valor like '[%'
     and s.valor::jsonb @> '[{"id":"operativo","on":true}]';
  raise notice '0272 · tenants con operativo encendido ANTES: %',
    coalesce(v_antes, '(ninguno)');
end $$;

-- Se reescribe el array poniendo `on:false` SOLO en esas dos tarjetas y
-- conservando el orden y el resto tal cual. `jsonb_set` sobre el elemento no
-- sirve: la posición varía por tenant.
with objetivo as (
  select s.tenant_id, s.valor::jsonb as arr
    from public.settings s
    join public.tenants t on t.id = s.tenant_id
   where s.clave = 'dashboard.tarjetas'
     and s.valor like '[%'                       -- excluye el doble-codificado
     and t.nombre in ('Telecable Mairena', 'Telenet')
),
piezas as (
  select o.tenant_id, e.ord,
         case when e.valor->>'id' in ('operativo', 'distribucion')
              then jsonb_set(e.valor, '{on}', 'false'::jsonb)
              else e.valor end as elem
    from objetivo o,
         lateral jsonb_array_elements(o.arr) with ordinality e(valor, ord)
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
   and s.clave = 'dashboard.tarjetas';

do $$
declare r record; v_malos int := 0;
begin
  for r in
    select t.nombre,
           (s.valor::jsonb @> '[{"id":"operativo","on":true}]') as op_on,
           (s.valor::jsonb @> '[{"id":"distribucion","on":true}]') as dist_on,
           jsonb_array_length(s.valor::jsonb) as bloques
      from public.settings s
      join public.tenants t on t.id = s.tenant_id
     where s.clave = 'dashboard.tarjetas'
       and s.valor like '[%'
       and t.nombre in ('Telecable Mairena', 'Telenet')
  loop
    raise notice '0272 · % → operativo=% distribucion=% (tarjetas=%)',
      r.nombre, r.op_on, r.dist_on, r.bloques;
    -- Que sigan estando las 11 tarjetas: apagar no es borrar.
    if r.op_on or r.dist_on or r.bloques <> 11 then v_malos := v_malos + 1; end if;
  end loop;

  if v_malos > 0 then
    raise exception '0272 ABORTA: % tenants quedaron mal', v_malos;
  end if;
end $$;

commit;
