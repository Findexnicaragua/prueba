-- 0156 — RPC `super_admin_verificar_invariantes_inventario`: chequeos de
-- integridad ESTRUCTURAL del inventario (seriales + ledger de movimientos),
-- scopeados a un tenant, desde el módulo Operaciones. Read-only, SECURITY
-- DEFINER + gate is_super_admin() (mismo patrón que 0153 para dinero). Es el
-- hermano de la verificación de dinero: el inventario NO tenía red de seguridad.
--
-- Devuelve 1 fila por invariante: (invariante, violaciones, ejemplo_ids). Si
-- TODAS dan violaciones=0, el stock está estructuralmente sano. ejemplo_ids trae
-- hasta 10 IDs ofensores.
--
-- Recordatorio del modelo: el stock se DERIVA (serializado = COUNT en_stock;
-- granel = Σdestino − Σorigen del ledger append-only inv_movimientos). Estos
-- chequeos validan la COHERENCIA de seriales y movimientos, no recalculan stock.
-- Estados del serial: en_stock | instalado | danado | retirado | baja (terminal).

create or replace function public.super_admin_verificar_invariantes_inventario(p_tenant uuid)
returns table(invariante text, violaciones bigint, ejemplo_ids text)
language plpgsql security definer set search_path=public as $fn$
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  return query
  with
  invi1 as (
    select 'INVI1: serial en_stock tiene ubicación'::text as invariante,
           count(*)::bigint as violaciones,
           coalesce(string_agg(id::text, ', ' order by id), '')::text as ejemplo_ids
    from (select id from public.inv_seriales
           where tenant_id = p_tenant and estado = 'en_stock' and ubicacion_id is null
           limit 10) t
  ),
  invi2 as (
    select 'INVI2: serial instalado tiene cliente'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.inv_seriales
           where tenant_id = p_tenant and estado = 'instalado' and cliente_id is null
           limit 10) t
  ),
  invi3 as (
    -- 'baja' es terminal (equipo fuera de circulación) → no debe seguir "en" un
    -- cliente. La op "Dar de baja" (módulo Operaciones) limpia cliente_id.
    select 'INVI3: serial dado de baja no conserva cliente'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.inv_seriales
           where tenant_id = p_tenant and estado = 'baja' and cliente_id is not null
           limit 10) t
  ),
  invi4 as (
    select 'INVI4: serial pertenece a un producto serializado'::text,
           count(*)::bigint,
           coalesce(string_agg(s.id::text, ', ' order by s.id), '')::text
    from (select s.id from public.inv_seriales s
            join public.inv_productos p on p.id = s.producto_id
           where s.tenant_id = p_tenant and p.es_serializado = false
           limit 10) s
  ),
  invi5 as (
    select 'INVI5: tenant_id de hija == tenant_id de su padre'::text,
           count(*)::bigint,
           coalesce(string_agg(ofensor, ', ' order by ofensor), '')::text
    from (
      select 'serial:' || s.id::text as ofensor
        from public.inv_seriales s join public.inv_productos p on p.id = s.producto_id
       where s.tenant_id = p_tenant and s.tenant_id <> p.tenant_id
      union all
      select 'mov:' || m.id::text
        from public.inv_movimientos m join public.inv_productos p on p.id = m.producto_id
       where m.tenant_id = p_tenant and m.tenant_id <> p.tenant_id
      union all
      select 'mov-serial:' || m.id::text
        from public.inv_movimientos m join public.inv_seriales s on s.id = m.serial_id
       where m.tenant_id = p_tenant and m.serial_id is not null and m.tenant_id <> s.tenant_id
      limit 10) t
  ),
  invi6 as (
    select 'INVI6: movimiento con serial coincide en producto'::text,
           count(*)::bigint,
           coalesce(string_agg(m.id::text, ', ' order by m.id), '')::text
    from (select m.id from public.inv_movimientos m
            join public.inv_seriales s on s.id = m.serial_id
           where m.tenant_id = p_tenant and m.serial_id is not null
             and m.producto_id <> s.producto_id
           limit 10) m
  ),
  invi7 as (
    select 'INVI7: todo movimiento tiene cantidad positiva'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.inv_movimientos
           where tenant_id = p_tenant and cantidad <= 0
           limit 10) t
  ),
  invi8 as (
    -- Transferencia = mueve de un lado a otro: exige origen y destino, distintos.
    select 'INVI8: transferencia tiene origen y destino distintos'::text,
           count(*)::bigint,
           coalesce(string_agg(id::text, ', ' order by id), '')::text
    from (select id from public.inv_movimientos
           where tenant_id = p_tenant and tipo = 'transferencia'
             and (ubicacion_origen_id is null or ubicacion_destino_id is null
                  or ubicacion_origen_id = ubicacion_destino_id)
           limit 10) t
  )
  select * from invi1
  union all select * from invi2
  union all select * from invi3
  union all select * from invi4
  union all select * from invi5
  union all select * from invi6
  union all select * from invi7
  union all select * from invi8
  order by invariante;
end;
$fn$;
