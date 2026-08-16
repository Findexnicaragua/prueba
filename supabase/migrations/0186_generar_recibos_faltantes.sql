-- 0186 — Generar recibos faltantes (módulo Operaciones, super_admin). Crea el
-- recibo de cada pago no-anulado que quedó SIN recibo (bajas de la colisión de
-- correlativo: el pago subió, el recibo chocó el UNIQUE 23505 y el connector lo
-- descartó → INV5 violado). Es la versión "botón" del backfill manual por SQL.
--
-- Correlativo = MAX+1 por (cobrador, prefijo), ordenado por fecha_pago (mismo
-- criterio que registrarCobro). NO toca la plata: el recibo no cambia
-- cuotas.monto_pagado ni recaudado, solo agrega el comprobante que faltaba.
-- Idempotente: re-correr solo llena huérfanos nuevos (el NOT EXISTS filtra los
-- que ya tienen recibo). Corré "Verificar invariantes" después (INV5 → 0).
--
-- Patrón data-ops (0147/0154): SECURITY DEFINER + gate is_super_admin() +
-- p_tenant + preview (cuenta) + ejecutar (log en data_ops_log, sin backup — no
-- es destructivo, solo agrega filas).

-- ── PREVIEW: cuántos pagos quedaron sin recibo ─────────────────────────────
create or replace function public.super_admin_preview_recibos_faltantes(
  p_tenant uuid)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_generables int; v_sin_prefijo int;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  -- Huérfanos cuyo cobrador tiene prefijo → se les puede generar el recibo.
  select count(*) into v_generables
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
   where p.tenant_id = p_tenant and p.anulado = false
     and co.prefijo_recibo is not null and co.prefijo_recibo <> ''
     and not exists (select 1 from recibos r where r.pago_id = p.id);

  -- Huérfanos SIN prefijo de cobrador → no se pueden auto-generar (raro).
  select count(*) into v_sin_prefijo
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
   where p.tenant_id = p_tenant and p.anulado = false
     and (co.prefijo_recibo is null or co.prefijo_recibo = '')
     and not exists (select 1 from recibos r where r.pago_id = p.id);

  return jsonb_build_object(
    'generables', v_generables,
    'sin_prefijo', v_sin_prefijo);
end; $fn$;

-- ── EJECUTAR: genera los recibos faltantes + registra en data_ops_log ──────
create or replace function public.super_admin_generar_recibos_faltantes(
  p_tenant uuid, p_actor_label text default null)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare v_generados int; v_numeros jsonb;
begin
  if not public.is_super_admin() then raise exception 'No autorizado: solo super_admin'; end if;
  if p_tenant is null then raise exception 'Falta el tenant en contexto'; end if;

  with orphans as (
    select p.id as pago_id, p.tenant_id, p.cobrador_id, p.fecha_pago, p.ocurrido_en,
           co.prefijo_recibo as prefijo,
           -- Correlativo continuo por PREFIJO dentro del tenant. El prefijo es
           -- único por tenant (0092) y numero_completo es UNIQUE(tenant_id,
           -- numero_completo), así que arrancar del MAX por (tenant, prefijo)
           -- garantiza no chocar ese índice incluso si un prefijo se hubiera
           -- reasignado entre cobradores en el tiempo. created_at/ocurrido_en =
           -- fecha_pago del pago A PROPÓSITO (data del comprobante al momento
           -- del cobro, no del backfill).
           row_number() over (partition by co.prefijo_recibo
                              order by p.fecha_pago, p.id) as rn
    from pagos p
    join cobradores co on co.id = p.cobrador_id and co.tenant_id = p.tenant_id
    where p.tenant_id = p_tenant and p.anulado = false
      and co.prefijo_recibo is not null and co.prefijo_recibo <> ''
      and not exists (select 1 from recibos r where r.pago_id = p.id)
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

  if v_generados > 0 then
    insert into data_ops_log(
      tenant_id, operacion, target_label, afectados, backup_id, actor_id, actor_label)
    values (p_tenant, 'generar_recibos_faltantes',
            v_generados || ' recibo(s) faltante(s)',
            jsonb_build_object('recibos', v_generados),
            null, auth.uid(), p_actor_label);
  end if;

  return jsonb_build_object(
    'ok', true,
    'generados', v_generados,
    'numeros', v_numeros);
end; $fn$;
