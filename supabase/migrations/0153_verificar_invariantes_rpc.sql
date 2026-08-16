-- 0153 — RPC `super_admin_verificar_invariantes`: corre los 17 invariantes de
-- dinero SCOPEADOS a un tenant, desde la app (módulo Operaciones → "Verificar
-- invariantes de dinero"). Read-only, SECURITY DEFINER + gate is_super_admin()
-- (patrón 0147). Espeja supabase/tests/invariantes_dinero.sql, pero agrega
-- `AND <tabla>.tenant_id = p_tenant` en CADA check para verificar SOLO el tenant
-- en contexto (el impersonado) tras un fix, sin abrir el SQL Editor del Dashboard.
--
-- Devuelve 1 fila por invariante: (invariante, violaciones, ejemplo_ids). Si
-- TODAS dan violaciones=0, el tenant está contablemente sano. Si alguna > 0,
-- ejemplo_ids trae hasta 10 IDs ofensores. La fórmula de cada check es IDÉNTICA
-- al script de tests (no se relaja ninguna regla) — solo se scopea por tenant.

create or replace function public.super_admin_verificar_invariantes(p_tenant uuid)
returns table(invariante text, violaciones bigint, ejemplo_ids text)
language plpgsql security definer set search_path=public as $fn$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  inv1 as (
    select 'INV1: entregado = aplicado + vuelto (pagos)'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(string_agg(id::text, ', ' order by id), '')::text as ejemplo_ids
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and abs((monto_original * tasa_conversion) - (monto_cordobas + vuelto_cordobas)) > 0.50
           limit 10) t
  ),
  inv2 as (
    select 'INV2: cuota.monto_pagado = SUM(pagos aplicados)'::text,
           count(*)::bigint,
           coalesce(string_agg(cuota_id::text, ', ' order by cuota_id), '')::text
    from (select cu.id as cuota_id
            from public.cuotas cu
            left join (select cuota_id, sum(monto_cordobas) as pagado
                         from public.pagos where anulado = false group by cuota_id) p
              on p.cuota_id = cu.id
           where cu.tenant_id = p_tenant and cu.estado <> 'anulada'
             and abs(cu.monto_pagado - coalesce(p.pagado, 0)) > 0.01
           limit 10) t
  ),
  inv3 as (
    select 'INV3: estado de cuota coherente con monto_pagado'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and ((estado = 'pagada'    and monto_pagado < (monto + coalesce(cargos_neto,0)) - 0.01)
               or (estado = 'pendiente' and monto_pagado > 0.01)
               or (estado = 'parcial'   and (monto_pagado <= 0.01
                     or monto_pagado >= (monto + coalesce(cargos_neto,0)) - 0.01)))
           limit 10) t
  ),
  inv4 as (
    select 'INV4: ninguna cuota con sobrepago (monto_pagado > total)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.cuotas
           where tenant_id = p_tenant and estado <> 'anulada'
             and monto_pagado > (monto + coalesce(cargos_neto,0)) + 0.01
           limit 10) t
  ),
  inv5 as (
    select 'INV5: todo pago no anulado tiene recibo'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select p.id from public.pagos p
           where p.tenant_id = p_tenant and p.anulado = false
             and not exists (select 1 from public.recibos r where r.pago_id = p.id)
           limit 10) p
  ),
  inv6 as (
    select 'INV6: vuelto_cordobas >= 0'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and vuelto_cordobas < 0 limit 10) t
  ),
  inv7 as (
    select 'INV7: correlativo de recibo único por cobrador+prefijo'::text,
           count(*)::bigint,
           coalesce(string_agg(numero_completo, ', ' order by numero_completo), '')::text
    from (select numero_completo from public.recibos
           where tenant_id = p_tenant
           group by cobrador_id, prefijo, correlativo, numero_completo
           having count(*) > 1
           limit 10) t
  ),
  inv8 as (
    select 'INV8: contrato.cobrador_id = cliente.cobrador_id'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ct.id from public.contratos ct
            join public.clientes c on c.id = ct.cliente_id
           where ct.tenant_id = p_tenant and ct.estado = 'activo'
             and ct.cobrador_id is distinct from c.cobrador_id
           limit 10) t
  ),
  inv9 as (
    -- Solo cuotas OPERATIVAS (pendiente/parcial): el trigger 0122 congela el
    -- cobrador de las pagadas/anuladas al reasignar (auditoría) → su mismatch es
    -- esperado, no un bug. "Quién cobró" = pagos/recibos.cobrador_id (INV5/INV7).
    select 'INV9: cuota.cobrador_id = contrato.cobrador_id (operativas)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select cu.id from public.cuotas cu
            join public.contratos ct on ct.id = cu.contrato_id
           where cu.tenant_id = p_tenant and cu.contrato_id is not null
             and cu.estado in ('pendiente','parcial')
             and cu.cobrador_id is distinct from ct.cobrador_id
           limit 10) cu
  ),
  inv10 as (
    select 'INV10: tenant_id de hija == tenant_id de su padre (0082)'::text,
           count(*)::bigint,
           coalesce(string_agg(ofensor, ', ' order by ofensor), '')::text
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
       where ce.tenant_id = p_tenant and ce.cuota_id is not null and ce.tenant_id <> cu.tenant_id
      limit 10) t
  ),
  inv11 as (
    select 'INV11: contrato fijo activo tiene exactamente duracion_meses cuotas activas (#5)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant and coalesce(ct.estado, 'activo') = 'activo'
             and ct.duracion_meses is not null and ct.duracion_meses > 0
             and ((select count(*) from public.cuotas cu
                     where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                       and cu.estado <> 'anulada')
                  + (select count(*) from public.cuotas cu
                       where cu.contrato_id = ct.id and cu.tipo_cargo_manual is null
                         and cu.estado = 'anulada' and cu.motivo_anulacion = 'Suspensión temporal'))
                 <> ct.duracion_meses
           limit 10) t
  ),
  inv12 as (
    select 'INV12: recaudado por contrato = SUM(pagos no anulados de sus cuotas) (#4)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ct.id from public.contratos ct
           where ct.tenant_id = p_tenant
             and abs(coalesce((select sum(cu.monto_pagado) from public.cuotas cu
                                where cu.contrato_id = ct.id), 0)
                   - coalesce((select sum(pa.monto_cordobas) from public.pagos pa
                                join public.cuotas cu2 on cu2.id = pa.cuota_id
                               where cu2.contrato_id = ct.id and pa.anulado = false), 0)) > 0.01
           limit 10) t
  ),
  inv13 as (
    select 'INV13: cargos origen=ajuste son descuento_* con motivo no vacío'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select ce.id from public.cargos_extra ce
           where ce.tenant_id = p_tenant and ce.origen = 'ajuste'
             and (ce.tipo not in ('descuento_monto', 'descuento_porcentaje')
                  or ce.descripcion is null or btrim(ce.descripcion) = '')
           limit 10) t
  ),
  inv14 as (
    select 'INV14: cuotas.cargos_neto == SUM real de cargos_extra'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select cu.id from public.cuotas cu
           where cu.tenant_id = p_tenant
             and abs(coalesce(cu.cargos_neto, 0)
                   - coalesce((select sum(case
                         when ce.tipo in ('reconexion','otro') then ce.monto
                         when ce.tipo in ('descuento_monto','descuento_porcentaje','credito_aplicado') then -ce.monto
                         else 0 end)
                        from public.cargos_extra ce where ce.cuota_id = cu.id), 0)) > 0.01
           limit 10) t
  ),
  inv15 as (
    select 'INV15: saldo a favor del cliente nunca negativo'::text,
           count(*)::bigint,
           coalesce(string_agg(cliente_id::text, ', ' order by cliente_id), '')::text
    from (select cliente_id from public.saldos_favor
           where tenant_id = p_tenant
           group by cliente_id
           having sum(case when tipo = 'acreditado' then monto else -monto end) < -0.005
           limit 10) t
  ),
  inv16 as (
    select 'INV16: ningún pago con método de crédito (crédito no es pago)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.pagos
           where tenant_id = p_tenant and anulado = false
             and metodo not in ('efectivo','transferencia','deposito','tarjeta')
           limit 10) t
  ),
  inv17 as (
    select 'INV17: indefinido activo tiene >= 3 cuotas pendientes futuras (colchón)'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
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
                                    and cu2.estado in ('pagada', 'parcial')), '1900-01-01'::date))) < 3
           limit 10) t
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
$fn$;
