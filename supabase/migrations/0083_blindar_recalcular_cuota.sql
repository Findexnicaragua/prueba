-- 0083 — Blindaje preventivo de recalcular_cuota_desde_pagos (lección de 0078).
--
-- La función es polimórfica: se engancha a `pagos` (0012) y a `cargos_extra`
-- (0018), y referencia `new.cuota_id` / `new.ocurrido_en` en sentencias
-- COMPARTIDAS (no ramificadas por tabla) — el MISMO antipatrón que rompió todo
-- INSERT de pagos en 0078 (PL/pgSQL planifica cada sentencia al alcanzarla y
-- resuelve los campos contra el rowtype de la tabla que dispara; si el campo no
-- existe → "record \"new\" has no field ...").
--
-- HOY no rompe porque ambas tablas tienen `cuota_id` + `ocurrido_en`. Pero es
-- frágil exactamente igual y toca el flujo de dinero: si esta función se
-- enganchara a una tabla SIN esas columnas, se caería TODO INSERT de esa tabla.
--
-- FIX (defensivo, sin cambiar comportamiento): un guard temprano por
-- `tg_table_name` ANTES de tocar cualquier `new.<campo>`. Como PL/pgSQL es lazy
-- (planifica la sentencia recién al alcanzarla), una tabla desconocida retorna
-- no-op sin llegar nunca al acceso a `new.cuota_id`. Las 2 tablas conocidas
-- operan idéntico que antes — monto_pagado/estado/ocurrido_en sin cambios, las
-- invariantes de dinero intactas. Idempotente (CREATE OR REPLACE). Solo función
-- server-side: NO toca schema.dart, db.dart ni sync rules.

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
  -- Guard polimórfico (lección de 0078): operar SOLO sobre las 2 tablas
  -- conocidas, que tienen cuota_id + ocurrido_en. Cualquier otra tabla es un
  -- no-op seguro — el acceso a new.cuota_id queda después de este guard y nunca
  -- se alcanza, así que PL/pgSQL no lo planifica ni falla.
  if tg_table_name not in ('pagos', 'cargos_extra') then
    return coalesce(new, old);
  end if;

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

  update public.cuotas
     set monto_pagado = v_total_pagado,
         estado = v_nuevo_estado,
         ocurrido_en = coalesce(new.ocurrido_en, old.ocurrido_en, now())
   where id = v_cuota_id;

  return coalesce(new, old);
end;
$$;

COMMIT;
