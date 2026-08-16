-- 0203 — El reparador de recibos deja de ser todo-o-nada
--
-- Síntoma reportado: "analizar y generar los recibos da timeout y no corrige
-- nada". El rol `authenticated` tiene `statement_timeout = 8s`, y 0186 inserta
-- TODOS los faltantes en una sola sentencia. Si se pasa del límite —cosa que
-- pasa por espera de locks cuando los devices están sincronizando cobros sobre
-- la misma tabla, no por lentitud: las consultas miden 575ms y 47ms— Postgres
-- aborta y REVIERTE la sentencia entera: no genera ni uno. Por eso corría,
-- tardaba, fallaba y todo quedaba igual.
--
-- Cambios:
--   1. `p_limite` (default 200): procesa de a tandas. Cada corrida COMMITEA lo
--      suyo, así que lo hecho queda hecho aunque la siguiente se corte.
--   2. Devuelve `restantes` para que la UI sepa si hay que volver a correr.
--   3. Índice sobre `recibos(pago_id)` — el que había es PARCIAL
--      (`WHERE anulado = false`) y el `NOT EXISTS` no lo puede usar, así que
--      recorría la tabla entera. Hoy son 17.400 filas y crece todos los días.
--
-- La causa RAÍZ (el correlativo se calcula en el device y colisiona) se ataca
-- del lado del cliente: un choque ahora reintenta con el próximo número en vez
-- de descartar el recibo. Esto es la red para lo ya acumulado.

BEGIN;

-- Índice usable por el NOT EXISTS (el existente es parcial y no aplica).
CREATE INDEX IF NOT EXISTS recibos_pago_id_idx ON public.recibos (pago_id);

-- OJO: agregar un parámetro NO reemplaza la función, crea una SOBRECARGA — y
-- PostgREST podría seguir resolviendo a la vieja (que es la todo-o-nada). Se
-- dropea explícitamente la firma de 2 argumentos.
DROP FUNCTION IF EXISTS public.super_admin_generar_recibos_faltantes(uuid, text);

CREATE OR REPLACE FUNCTION public.super_admin_generar_recibos_faltantes(
  p_tenant uuid, p_actor_label text default null, p_limite int default 200)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_generados int; v_numeros jsonb; v_restantes int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;
  if p_limite is null or p_limite < 1 then p_limite := 200; end if;

  with orphans as (
    select p.id as pago_id, p.tenant_id, p.cobrador_id, p.fecha_pago, p.ocurrido_en,
           co.prefijo_recibo as prefijo,
           row_number() over (partition by co.prefijo_recibo
                              order by p.fecha_pago, p.id) as rn
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
    where p.tenant_id = p_tenant and p.anulado = false
      and co.prefijo_recibo is not null and co.prefijo_recibo <> ''
      and not exists (select 1 from recibos r where r.pago_id = p.id)
    -- La TANDA: los más viejos primero, para que el correlativo siga el orden
    -- cronológico de los cobros.
    order by p.fecha_pago, p.id
    limit p_limite
  ),
  maxes as (
    select d.prefijo,
           coalesce(max(r.correlativo), 0) as maxc
    from (select distinct prefijo from orphans) d
    left join recibos r on r.tenant_id = p_tenant and r.prefijo = d.prefijo
    group by d.prefijo
  ),
  ins as (
    insert into recibos (
      id, tenant_id, pago_id, cobrador_id, prefijo, correlativo, numero_completo,
      reimpresiones, anulado, created_at, client_local_id, ocurrido_en)
    select gen_random_uuid(), o.tenant_id, o.pago_id, o.cobrador_id, o.prefijo,
           m.maxc + o.rn,
           o.prefijo || '-' || lpad((m.maxc + o.rn)::text, 5, '0'),
           0, false, o.fecha_pago, gen_random_uuid(),
           coalesce(o.ocurrido_en, o.fecha_pago)
    from orphans o
    join maxes m on m.prefijo = o.prefijo
    returning numero_completo)
  select count(*)::int,
         coalesce(jsonb_agg(numero_completo order by numero_completo), '[]'::jsonb)
    into v_generados, v_numeros
  from ins;

  -- Cuántos quedan DESPUÉS de esta tanda: la UI lo usa para ofrecer otra vuelta.
  select count(*)::int into v_restantes
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
   where p.tenant_id = p_tenant and p.anulado = false
     and co.prefijo_recibo is not null and co.prefijo_recibo <> ''
     and not exists (select 1 from recibos r where r.pago_id = p.id);

  if v_generados > 0 then
    insert into data_ops_log(
      tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'generar_recibos_faltantes',
            v_generados || ' recibo(s) faltante(s)',
            jsonb_build_object('recibos', v_generados, 'restantes', v_restantes),
            null, auth.uid(), p_actor_label);
  end if;

  return jsonb_build_object(
    'ok', true,
    'generados', v_generados,
    'restantes', v_restantes,
    'numeros', v_numeros);
end; $fn$;

COMMIT;
