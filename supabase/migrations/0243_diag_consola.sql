-- 0243 — Consola de diagnóstico del Dev (solo lectura, cross-tenant).
--
-- 4 RPCs SECURITY DEFINER gateados a is_super_admin() que alimentan la pantalla
-- /super/diagnostico (v0.36.0): buscador global de clientes, radiografía
-- completa de un cliente, salud de talonarios y fantasmas de sync. La ficha de
-- invariantes de dinero REUSA super_admin_verificar_invariantes (0153/0219) con
-- un selector de tenant — acá no se duplica.
--
-- Nada de esto sincroniza a devices (la pantalla es online-only, patrón panel
-- super) ni escribe una sola fila: los 4 son STABLE de lectura pura.

begin;

-- ── 1. Buscador global de clientes (todas las empresas) ─────────────────────
-- Tokens: cada palabra del query debe aparecer (en cualquier orden) en
-- codigo+nombre, con AMBOS lados plegados a ASCII (á→a, ñ→n) — espejo server
-- de foldBusqueda/coincideTokens del cliente (reglas #1d y #10 del AGENTS).
create or replace function public.super_admin_diag_buscar(p_q text)
returns jsonb
language plpgsql stable security definer set search_path=public as $fn$
declare
  v_tokens text[];
begin
  if not public.is_super_admin() then
    raise exception 'No autorizado: solo super_admin';
  end if;
  v_tokens := regexp_split_to_array(
      trim(translate(lower(coalesce(p_q, '')), 'áéíóúüñ', 'aeiouun')), '\s+');
  if v_tokens is null or v_tokens = '{}' or (array_length(v_tokens,1) = 1 and v_tokens[1] = '') then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', s.id, 'tenant_id', s.tenant_id, 'tenant', s.tenant,
        'codigo', s.codigo, 'nombre', s.nombre, 'activo', s.activo,
        'telefono', s.telefono, 'vencimiento_mas_viejo', s.vencimiento_mas_viejo))
    from (
      select c.id, c.tenant_id, t.nombre as tenant, c.codigo, c.nombre,
             c.activo, c.telefono, c.vencimiento_mas_viejo
        from public.clientes c
        join public.tenants t on t.id = c.tenant_id
       where (select bool_and(
                translate(lower(coalesce(c.codigo,'') || ' ' || c.nombre),
                          'áéíóúüñ', 'aeiouun') like '%' || tok || '%')
                from unnest(v_tokens) tok)
       order by c.nombre
       limit 20
    ) s), '[]'::jsonb);
end $fn$;

revoke all on function public.super_admin_diag_buscar(text) from public;
grant execute on function public.super_admin_diag_buscar(text) to authenticated;

-- ── 2. Radiografía completa de un cliente ───────────────────────────────────
-- Devuelve en UN jsonb todo lo que el Dev necesita para diagnosticar un caso:
-- ficha, contratos, últimas 36 cuotas, últimos 30 pagos (con recibo), señales
-- (cuarentenas, rechazos de sync, anuladas recientes, deuda viva) y los últimos
-- 25 eventos de op_log del cliente y sus entidades. El VEREDICTO en prosa lo
-- arma la UI a partir de `senales` (mantener la heurística en Dart la hace
-- ajustable sin migración).
create or replace function public.super_admin_diag_cliente(p_cliente uuid)
returns jsonb
language plpgsql stable security definer set search_path=public as $fn$
declare
  v_tenant uuid;
  v_hoy date := (now() at time zone 'America/Managua')::date;
begin
  if not public.is_super_admin() then
    raise exception 'No autorizado: solo super_admin';
  end if;
  select c.tenant_id into v_tenant from public.clientes c where c.id = p_cliente;
  if v_tenant is null then
    raise exception 'Cliente no encontrado';
  end if;

  return jsonb_build_object(
    'cliente', (
      select jsonb_build_object(
          'id', c.id, 'codigo', c.codigo, 'nombre', c.nombre, 'activo', c.activo,
          'telefono', c.telefono, 'direccion', c.direccion,
          'tenant_id', c.tenant_id, 'tenant', t.nombre,
          'vencimiento_mas_viejo', c.vencimiento_mas_viejo,
          'cobrador_asignado', (select co.nombre from public.cobradores co
                                 where co.id = c.cobrador_id),
          'creado', c.created_at::date)
        from public.clientes c
        join public.tenants t on t.id = c.tenant_id
       where c.id = p_cliente),
    'contratos', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', ct.id, 'codigo', ct.codigo, 'estado', ct.estado,
          'plan', pl.nombre, 'precio_mensual', pl.precio_mensual,
          'dia_pago', ct.dia_pago, 'fecha_inicio', ct.fecha_inicio,
          'duracion_meses', ct.duracion_meses,
          'cancelado_en', ct.cancelado_en::date,
          'motivo_cancelacion', ct.motivo_cancelacion,
          'tiene_snapshot', (ct.cancelacion_deuda_snapshot is not null))
        order by ct.created_at desc)
        from public.contratos ct
        left join public.planes pl on pl.id = ct.plan_id
       where ct.cliente_id = p_cliente), '[]'::jsonb),
    'cuotas', coalesce((
      select jsonb_agg(s.x order by s.periodo desc, s.venc desc)
        from (
          select cu.periodo, cu.fecha_vencimiento as venc, jsonb_build_object(
              'id', cu.id, 'periodo', cu.periodo,
              'fecha_vencimiento', cu.fecha_vencimiento,
              'monto', cu.monto, 'cargos_neto', cu.cargos_neto,
              'monto_pagado', cu.monto_pagado, 'estado', cu.estado,
              'saldo', greatest(cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado, 0),
              'motivo_anulacion', cu.motivo_anulacion,
              'anulada_en', cu.anulada_en::date,
              'descripcion', cu.descripcion,
              'es_cargo_manual', (cu.tipo_cargo_manual is not null),
              'contrato_codigo', ct.codigo) as x
            from public.cuotas cu
            left join public.contratos ct on ct.id = cu.contrato_id
           where cu.cliente_id = p_cliente
           order by cu.periodo desc, cu.fecha_vencimiento desc
           limit 36
        ) s), '[]'::jsonb),
    'cuotas_total', (select count(*) from public.cuotas where cliente_id = p_cliente),
    'pagos', coalesce((
      select jsonb_agg(s.x order by s.f desc)
        from (
          select p.fecha_pago as f, jsonb_build_object(
              'id', p.id, 'fecha_pago', p.fecha_pago::date,
              'monto', p.monto_cordobas, 'metodo', p.metodo,
              'anulado', p.anulado, 'motivo_anulacion', p.motivo_anulacion,
              'en_revision', p.en_revision, 'revision_motivo', p.revision_motivo,
              'cobrador', co.nombre, 'referencia', p.referencia,
              'recibo', (select r.numero_completo from public.recibos r
                          where r.pago_id = p.id
                          order by r.anulado, r.created_at limit 1)) as x
            from public.pagos p
            join public.cuotas cu on cu.id = p.cuota_id
            left join public.cobradores co on co.id = p.cobrador_id
           where cu.cliente_id = p_cliente
           order by p.fecha_pago desc
           limit 30
        ) s), '[]'::jsonb),
    'historial', coalesce((
      select jsonb_agg(s.x order by s.o desc)
        from (
          select o.ocurrido_en as o, jsonb_build_object(
              'tipo_op', o.tipo_op, 'entidad', o.entidad, 'accion', o.accion,
              'actor', o.actor_label, 'ocurrido_en', o.ocurrido_en,
              -- diff vive como TEXT en la DB (saga doble-encoding, cf. 0126):
              -- se parsea acá; un legacy string-escalar cae al {} por coalesce.
              'resumen', coalesce(o.diff::jsonb->'resumen', '{}'::jsonb)) as x
            from public.op_log o
           where o.tenant_id = v_tenant
             and o.entidad_id in (
                   select p_cliente
                   union select ct.id from public.contratos ct where ct.cliente_id = p_cliente
                   union select cu.id from public.cuotas cu where cu.cliente_id = p_cliente
                   union select p.id from public.pagos p
                          join public.cuotas cu2 on cu2.id = p.cuota_id
                         where cu2.cliente_id = p_cliente)
           order by o.ocurrido_en desc
           limit 25
        ) s), '[]'::jsonb),
    'senales', jsonb_build_object(
      'cuarentenas', (
        select count(*) from public.pagos p
          join public.cuotas cu on cu.id = p.cuota_id
         where cu.cliente_id = p_cliente and p.en_revision and not p.anulado),
      'rechazos_pendientes', (
        select count(*) from public.sync_rechazos r
         where r.tenant_id = v_tenant and not r.resuelto
           and r.registro_id in (
                 select cu.id::text from public.cuotas cu where cu.cliente_id = p_cliente
                 union select p.id::text from public.pagos p
                        join public.cuotas cu2 on cu2.id = p.cuota_id
                       where cu2.cliente_id = p_cliente
                 union select rc.id::text from public.recibos rc
                        join public.pagos p2 on p2.id = rc.pago_id
                        join public.cuotas cu3 on cu3.id = p2.cuota_id
                       where cu3.cliente_id = p_cliente)),
      'vencidas_sin_pago', (
        select count(*) from public.cuotas cu
          left join public.contratos ct on ct.id = cu.contrato_id
         where cu.cliente_id = p_cliente and cu.estado = 'pendiente'
           and cu.fecha_vencimiento < v_hoy
           and coalesce(ct.estado, 'activo') = 'activo'),
      'anuladas_30d', (
        select count(*) from public.cuotas cu
         where cu.cliente_id = p_cliente and cu.estado = 'anulada'
           and cu.anulada_en > now() - interval '30 days'),
      'deuda_viva', (
        select coalesce(sum(greatest(cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado, 0)), 0)
          from public.cuotas cu
          left join public.contratos ct on ct.id = cu.contrato_id
         where cu.cliente_id = p_cliente and cu.estado in ('pendiente','parcial')
           and coalesce(ct.estado, 'activo') = 'activo'),
      'ultimo_pago', (
        select max(p.fecha_pago)::date from public.pagos p
          join public.cuotas cu on cu.id = p.cuota_id
         where cu.cliente_id = p_cliente and not p.anulado)));
end $fn$;

revoke all on function public.super_admin_diag_cliente(uuid) from public;
grant execute on function public.super_admin_diag_cliente(uuid) to authenticated;

-- ── 3. Salud de talonarios (todas las empresas) ─────────────────────────────
-- Por serie (tenant × prefijo): máximo emitido, total, anulados, dueños del
-- prefijo y último recibo. Aparte: los huecos VIGENTES (recibos_huecos() ya
-- excluye ignorados) y el registro de los ignorados (quién y cuándo).
create or replace function public.super_admin_diag_talonarios()
returns jsonb
language plpgsql stable security definer set search_path=public as $fn$
begin
  if not public.is_super_admin() then
    raise exception 'No autorizado: solo super_admin';
  end if;

  return jsonb_build_object(
    'series', coalesce((
      select jsonb_agg(jsonb_build_object(
          'tenant', s.tenant, 'prefijo', s.prefijo,
          'max_correlativo', s.max_corr, 'total', s.total,
          'anulados', s.anulados, 'ultimo', s.ultimo, 'duenos', s.duenos)
        order by s.tenant, s.prefijo)
        from (
          select t.nombre as tenant, r.tenant_id, r.prefijo,
                 max(r.correlativo) as max_corr, count(*) as total,
                 count(*) filter (where r.anulado) as anulados,
                 max(r.created_at)::date as ultimo,
                 (select string_agg(distinct co.nombre, ', ')
                    from public.cobradores co
                   where co.tenant_id = r.tenant_id
                     and co.prefijo_recibo = r.prefijo) as duenos
            from public.recibos r
            join public.tenants t on t.id = r.tenant_id
           group by t.nombre, r.tenant_id, r.prefijo
        ) s), '[]'::jsonb),
    'huecos', coalesce((
      select jsonb_agg(jsonb_build_object(
          'tenant', h.tenant, 'prefijo', h.prefijo, 'cobrador', h.cobrador,
          'desde', h.desde, 'hasta', h.hasta, 'faltan', h.faltan))
        from public.recibos_huecos() h), '[]'::jsonb),
    'ignorados', coalesce((
      select jsonb_agg(jsonb_build_object(
          'tenant', t.nombre, 'prefijo', i.prefijo, 'desde', i.desde,
          'hasta', i.hasta, 'motivo', i.motivo,
          'por', (select co.nombre from public.cobradores co where co.id = i.ignorado_por),
          'cuando', i.ignorado_en::date)
        order by i.ignorado_en desc)
        from public.recibos_huecos_ignorados i
        join public.tenants t on t.id = i.tenant_id), '[]'::jsonb));
end $fn$;

revoke all on function public.super_admin_diag_talonarios() from public;
grant execute on function public.super_admin_diag_talonarios() to authenticated;

-- ── 4. Fantasmas de sync (todas las empresas) ───────────────────────────────
-- Lo que "no debería estar pasando": cuotas vivas nacidas DESPUÉS de cancelado
-- su contrato (con la firma horaria para distinguir cron de device — el cron de
-- cuotas corre 06:05 UTC), rechazos de sync de los últimos 14 días por empresa,
-- cuarentenas abiertas y pagos sin recibo.
create or replace function public.super_admin_diag_fantasmas()
returns jsonb
language plpgsql stable security definer set search_path=public as $fn$
begin
  if not public.is_super_admin() then
    raise exception 'No autorizado: solo super_admin';
  end if;

  return jsonb_build_object(
    'cuotas_fantasma', coalesce((
      select jsonb_agg(s.x order by s.c desc)
        from (
          select cu.created_at as c, jsonb_build_object(
              'tenant', t.nombre, 'cliente', coalesce(cl.codigo || ' — ', '') || cl.nombre,
              'contrato', ct.codigo, 'periodo', cu.periodo, 'estado', cu.estado,
              'creada', cu.created_at,
              'firma', case when cu.created_at::time between time '06:00' and time '06:20'
                            then 'cron' else 'device' end,
              'contrato_cancelado_en', ct.cancelado_en::date) as x
            from public.cuotas cu
            join public.contratos ct on ct.id = cu.contrato_id
            join public.clientes cl on cl.id = cu.cliente_id
            join public.tenants t on t.id = cu.tenant_id
           where ct.estado = 'cancelado' and ct.cancelado_en is not null
             and cu.created_at > ct.cancelado_en
             and cu.estado in ('pendiente','parcial')
           order by cu.created_at desc
           limit 30
        ) s), '[]'::jsonb),
    'rechazos_14d', coalesce((
      select jsonb_agg(jsonb_build_object(
          'tenant', s.tenant, 'dia', s.dia, 'total', s.total,
          'sin_resolver', s.sin_resolver)
        order by s.dia desc, s.tenant)
        from (
          select coalesce(t.nombre, '?') as tenant, r.created_at::date as dia,
                 count(*) as total,
                 count(*) filter (where not r.resuelto) as sin_resolver
            from public.sync_rechazos r
            left join public.tenants t on t.id = r.tenant_id
           where r.created_at > now() - interval '14 days'
           group by t.nombre, r.created_at::date
        ) s), '[]'::jsonb),
    'cuarentenas', coalesce((
      select jsonb_agg(jsonb_build_object('tenant', t.nombre, 'abiertas', s.n))
        from (
          select p.tenant_id, count(*) as n
            from public.pagos p
           where p.en_revision and not p.anulado
           group by p.tenant_id
        ) s join public.tenants t on t.id = s.tenant_id), '[]'::jsonb),
    'pagos_sin_recibo', coalesce((
      select jsonb_agg(jsonb_build_object('tenant', t.nombre, 'pagos', s.n))
        from (
          select p.tenant_id, count(*) as n
            from public.pagos p
           where not p.anulado
             and not exists (select 1 from public.recibos r where r.pago_id = p.id)
           group by p.tenant_id
        ) s join public.tenants t on t.id = s.tenant_id), '[]'::jsonb));
end $fn$;

revoke all on function public.super_admin_diag_fantasmas() from public;
grant execute on function public.super_admin_diag_fantasmas() to authenticated;

commit;
