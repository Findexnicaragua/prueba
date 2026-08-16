-- =========================================================================
-- 0213 — La verificación de invariantes moría por timeout (y mentía el conteo)
--
-- REPORTADO: "canceling statement due to statement timeout" al verificar los
-- invariantes de dinero de Telecable Mairena (4.372 contratos, 41.804 cuotas,
-- 19.415 pagos).
--
-- CAUSA 1 — FALTABA UN ÍNDICE. El plan real de INV12 mostraba:
--     Seq Scan on pagos  (rows=19415 loops=4372)
-- o sea: la tabla ENTERA de pagos escaneada UNA VEZ POR CONTRATO — 85 millones
-- de filas leídas. 27.417 ms para un solo chequeo, contra un statement_timeout
-- de 8 s. `pagos` tenia indice (tenant_id, cuota_id), pero las subconsultas
-- buscan por cuota_id SOLO, y en un índice compuesto sin la primera columna
-- no hay búsqueda dirigida. Con el índice: **27.417 ms → 173 ms** (158x).
--
-- CAUSA 2 -- EL CONTEO MENTIA. Cada chequeo hacia count(*) sobre un subselect
-- con LIMIT 10, asi que el número TOPABA en 10. Medido en Mairena: INV2 tiene
-- **33 violaciones reales y la pantalla mostraba 10**. Y como el propio consejo
-- de la UI es "corregí INV2 primero", el operador arreglaba 10, re-verificaba,
-- volvia a leer 10 y concluia que la correccion no servia. Ahora violaciones
-- es el conteo REAL y ejemplo_ids sigue trayendo 10 (que es su propósito:
-- ejemplos, no inventario).
--
-- Contar sin el LIMIT ya no cuesta nada gracias al índice: medido, 174 ms el
-- chequeo más pesado y 8 ms el segundo.
--
-- El cuerpo sale de la definicion VIVA (pg_get_functiondef), no de la
-- migración que la creó — regla del proyecto. Los ÚNICOS cambios son sacar los
-- 17 LIMIT 10 y recortar los 17 agregadores a 10 ejemplos.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. El índice que faltaba. Sirve a TODA búsqueda de pagos por cuota, no solo
--    a esta verificación (es un patrón central del dominio).
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS pagos_cuota_id_idx ON public.pagos (cuota_id);

-- -------------------------------------------------------------------------
-- 2. Conteo real + 10 ejemplos.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.super_admin_verificar_invariantes(p_tenant uuid)
 RETURNS TABLE(invariante text, violaciones bigint, ejemplo_ids text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  inv1 as (
    select 'INV1: entregado = aplicado + vuelto (pagos)'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text as ejemplo_ids
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and abs((monto_original * tasa_conversion) - (monto_cordobas + vuelto_cordobas)) > 0.50) t
  ),
  inv2 as (
    select 'INV2: cuota.monto_pagado = SUM(pagos aplicados)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(cuota_id::text order by cuota_id))[1:10], ', '), '')::text
    from (select cu.id as cuota_id
            from public.cuotas cu
            left join (select cuota_id, sum(monto_cordobas) as pagado
                         from public.pagos where anulado = false group by cuota_id) p
              on p.cuota_id = cu.id
           where cu.tenant_id = p_tenant and cu.estado <> 'anulada'
             and abs(cu.monto_pagado - coalesce(p.pagado, 0)) > 0.01) t
  ),
  inv3 as (
    select 'INV3: estado de cuota coherente con monto_pagado'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and ((estado = 'pagada'    and monto_pagado < (monto + coalesce(cargos_neto,0)) - 0.01)
               or (estado = 'pendiente' and monto_pagado > 0.01)
               or (estado = 'parcial'   and (monto_pagado <= 0.01
                     or monto_pagado >= (monto + coalesce(cargos_neto,0)) - 0.01)))) t
  ),
  inv4 as (
    select 'INV4: ninguna cuota con sobrepago (monto_pagado > total)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and monto_pagado > (monto + coalesce(cargos_neto,0)) + 0.01) t
  ),
  inv5 as (
    select 'INV5: todo pago no anulado tiene recibo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select p.id from public.pagos p
           where p.tenant_id = p_tenant and p.anulado = false
             and not exists (select 1 from public.recibos r where r.pago_id = p.id)) p
  ),
  inv6 as (
    select 'INV6: vuelto_cordobas >= 0'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and vuelto_cordobas < 0) t
  ),
  inv7 as (
    select 'INV7: correlativo de recibo Ãºnico por cobrador+prefijo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(numero_completo order by numero_completo))[1:10], ', '), '')::text
    from (select numero_completo from public.recibos
           where tenant_id = p_tenant
           group by cobrador_id, prefijo, correlativo, numero_completo
           having count(*) > 1) t
  ),
  inv8 as (
    select 'INV8: contrato.cobrador_id = cliente.cobrador_id'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
            join public.clientes c on c.id = ct.cliente_id
           where ct.tenant_id = p_tenant and ct.estado = 'activo'
             and ct.cobrador_id is distinct from c.cobrador_id) t
  ),
  inv9 as (
    -- Solo cuotas OPERATIVAS (pendiente/parcial): el trigger 0122 congela el
    -- cobrador de las pagadas/anuladas al reasignar (auditorÃ­a) â†’ su mismatch es
    -- esperado, no un bug. "QuiÃ©n cobrÃ³" = pagos/recibos.cobrador_id (INV5/INV7).
    select 'INV9: cuota.cobrador_id = contrato.cobrador_id (operativas)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id from public.cuotas cu
            join public.contratos ct on ct.id = cu.contrato_id
           where cu.tenant_id = p_tenant and cu.contrato_id is not null
             and cu.estado in ('pendiente','parcial')
             and cu.cobrador_id is distinct from ct.cobrador_id) cu
  ),
  inv10 as (
    select 'INV10: tenant_id de hija == tenant_id de su padre (0082)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(ofensor order by ofensor))[1:10], ', '), '')::text
    from (
      select 'pago:' || p.id::text as ofensor
        from public.pagos p join public.cuotas cu on cu.id = p.cuota_id
       where p.tenant_id = p_tenant and p.cuota_id is not null and p.tenant_id <> cu.tenant_id
      union all
      select 'recibo:' || r.id::text
        from public.recibos r join public.pagos p on p.id = r.pago_id
       where r.tenant_id = p_tenant and r.pago_id is not null and r.tenant_id <> p.tenant_id
      union all
      select 'cargo:' || ce.id::text
        from public.cargos_extra ce join public.cuotas cu on cu.id = ce.cuota_id
       where ce.tenant_id = p_tenant and ce.cuota_id is not null and ce.tenant_id <> cu.tenant_id) t
  ),
  inv11 as (
    select 'INV11: contrato fijo activo tiene exactamente duracion_meses cuotas activas (#5)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is not null and ct.duracion_meses > 0
             and ((select count(*) from public.cuotas cu
                     where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                       and cu.estado <> 'anulada')
                  + (select count(*) from public.cuotas cu
                       where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                         and cu.estado = 'anulada' and cu.motivo_anulacion = 'SuspensiÃ³n temporal'))
                 <> ct.duracion_meses) t
  ),
  inv12 as (
    select 'INV12: recaudado por contrato = SUM(pagos no anulados de sus cuotas) (#4)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant
             and abs(coalesce((select sum(cu.monto_pagado) from public.cuotas cu
                                where cu.contrato_id = ct.id), 0)
                   - coalesce((select sum(pa.monto_cordobas) from public.pagos pa
                                join public.cuotas cu2 on cu2.id = pa.cuota_id
                               where cu2.contrato_id = ct.id and pa.anulado = false), 0)) > 0.01) t
  ),
  inv13 as (
    select 'INV13: cargos origen=ajuste son descuento_* con motivo no vacÃ­o'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ce.id from public.cargos_extra ce
           where ce.tenant_id = p_tenant and ce.origen = 'ajuste'
             and (ce.tipo not in ('descuento_monto', 'descuento_porcentaje')
                  or ce.descripcion is null or btrim(ce.descripcion) = '')) t
  ),
  inv14 as (
    select 'INV14: cuotas.cargos_neto == SUM real de cargos_extra'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select cu.id from public.cuotas cu
           where cu.tenant_id = p_tenant
             and abs(coalesce(cu.cargos_neto, 0)
                   - coalesce((select sum(case
                         when ce.tipo in ('reconexion','otro') then ce.monto
                         when ce.tipo in ('descuento_monto','descuento_porcentaje','credito_aplicado') then -ce.monto
                         else 0 end)
                        from public.cargos_extra ce where ce.cuota_id = cu.id), 0)) > 0.01) t
  ),
  inv15 as (
    select 'INV15: saldo a favor del cliente nunca negativo'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(cliente_id::text order by cliente_id))[1:10], ', '), '')::text
    from (select cliente_id from public.saldos_favor
           where tenant_id = p_tenant
           group by cliente_id
           having sum(case when tipo = 'acreditado' then monto else -monto end) < -0.005) t
  ),
  inv16 as (
    select 'INV16: ningÃºn pago con mÃ©todo de crÃ©dito (crÃ©dito no es pago)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and metodo not in ('efectivo','transferencia','deposito','tarjeta')) t
  ),
  inv17 as (
    select 'INV17: indefinido activo tiene >= 3 cuotas pendientes futuras (colchÃ³n)'::text,
           count(*)::bigint,
           coalesce(array_to_string((array_agg(id::text order by id))[1:10], ', '), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is null
             and (select count(*) from public.cuotas cu
                   where cu.contrato_id = ct.id and cu.estado = 'pendiente'
                     and cu.tipo_cargo_manual is null
                     and cu.periodo > greatest(
                       date_trunc('month', (now() at time zone 'America/Managua'))::date,
                       coalesce((select max(cu2.periodo) from public.cuotas cu2
                                  where cu2.contrato_id = ct.id
                                    and cu2.estado in ('pagada', 'parcial')), '1900-01-01'::date))) < 3) t
  )
  select * from inv1
  union all select * from inv2
  union all select * from inv3
  union all select * from inv4
  union all select * from inv5
  union all select * from inv6
  union all select * from inv7
  union all select * from inv8
  union all select * from inv9
  union all select * from inv10
  union all select * from inv11
  union all select * from inv12
  union all select * from inv13
  union all select * from inv14
  union all select * from inv15
  union all select * from inv16
  union all select * from inv17
  order by invariante;
end;
$function$
;

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'el indice de pagos por cuota existe' AS chequeo, COUNT(*) = 1 AS ok
  FROM pg_indexes
 WHERE schemaname='public' AND indexname='pagos_cuota_id_idx'
UNION ALL
SELECT 'la funcion ya NO topa el conteo en 10',
       pg_get_functiondef(oid) NOT ILIKE '%limit 10%'
  FROM pg_proc WHERE proname='super_admin_verificar_invariantes'
UNION ALL
SELECT 'sigue devolviendo 10 ejemplos',
       pg_get_functiondef(oid) LIKE '%[1:10]%'
  FROM pg_proc WHERE proname='super_admin_verificar_invariantes'
UNION ALL
SELECT 'no se perdio ningun invariante (los 17)',
       (length(pg_get_functiondef(oid)) - length(replace(pg_get_functiondef(oid), 'INV', ''))) / 3 >= 17
  FROM pg_proc WHERE proname='super_admin_verificar_invariantes';
