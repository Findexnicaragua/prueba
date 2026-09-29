-- 0246 — `is_super_admin()` relaja el ROL, NUNCA el TENANT.
--
-- Bug reportado por Rubén (2026-08-20, con captura): impersonando Test Tenant,
-- la bandeja /admin/cobros-a-revisar listaba huecos de talonario de Telecable
-- Mairena (SA 17-43, SA 2-4) y de Telenet (COL 20-24, COL 26-27). Test Tenant
-- no tiene ni uno: las 4 filas renderizadas eran 100% ajenas, sin decir de qué
-- empresa, y su botón "Ignorar" fallaba siempre (recibos_hueco_ignorar SÍ está
-- anclada desde 0242 — la escritura se cerró y la lectura quedó abierta).
--
-- CAUSA RAÍZ (un solo patrón, tres funciones): el gate se escribió como
--     is_super_admin() OR (tenant_id = current_tenant_id() AND is_admin_or_cobranza())
-- y el OR cortocircuita → para el super_admin el filtro de tenant NUNCA se
-- evalúa. La rama existe por una razón legítima (is_admin_or_cobranza() es
-- FALSE para el super_admin: sin ella perdería la pantalla hasta en el tenant
-- que impersona), pero relaja el TENANT cuando debía relajar el ROL.
--
-- FORMA CANÓNICA (regla nueva del proyecto, va a AGENTS.md):
--     and <tabla>.tenant_id = public.current_tenant_id()
--     and (public.is_super_admin() or public.is_admin_or_cobranza())
-- Las pantallas /admin/* y las del cobrador están SIEMPRE scopeadas al tenant
-- impersonado: el super_admin ve ahí exactamente lo que vería el admin de esa
-- empresa. Lo cross-tenant vive en /super/*, y en particular en
-- /super/diagnostico, que etiqueta cada fila con el nombre de la empresa.
--
-- NO hay ni hubo fuga entre ISPs: para todo rol que no sea super_admin la rama
-- que fuga da false. Verificado simulando 4 identidades reales (admin Telenet
-- ve 3 huecos, admin_cobranza Mairena 5, cobrador 0, admin Test Tenant 0).
-- Hay exactamente UNA cuenta super_admin en el sistema.
--
-- ⚠ A1 SIN A2+A3 ROMPE /super/diagnostico y es PEOR que el bug original:
-- super_admin_diag_talonarios() delega en recibos_huecos(), y
-- current_tenant_id() no devuelve NULL para el super_admin sin impersonar
-- (coalesce a su propia fila → tenant System, 0 recibos) → el panel pasaría a
-- decir "sin huecos, numeración continua" mientras Mairena tiene 27 recibos
-- faltantes. Un falso todo-en-orden sobre una señal de plata. Los tres van
-- juntos, en esta misma migración.

begin;

-- ═══════════ A1 — recibos_huecos(): anclada al tenant en contexto ═══════════
-- Cuerpo vigente = 0242 (NO 0237: hay que conservar el bloque `not exists` de
-- recibos_huecos_ignorados). Único cambio: las 3 líneas finales del WHERE.
create or replace function public.recibos_huecos()
returns table (
  tenant text, prefijo text, cobrador text,
  desde int, hasta int, faltan int,
  ok_antes timestamptz, ok_despues timestamptz
)
language sql stable security definer
set search_path to 'public'
as $fn$
  with r as (
    select t.id as tenant_id, t.nombre as tenant, r.prefijo, r.correlativo,
           r.created_at,
           (r.created_at::time <> '00:00:00') as real_now,
           lag(r.correlativo) over w as prev_corr,
           lag(r.created_at)  over w as prev_at,
           lag(r.cobrador_id) over w as prev_cob,
           lag(r.created_at::time <> '00:00:00') over w as prev_real
    from public.recibos r
    join public.tenants t on t.id = r.tenant_id
    window w as (partition by r.tenant_id, r.prefijo order by r.correlativo)
  )
  select r.tenant, r.prefijo, coalesce(co.nombre, '?'),
         r.prev_corr + 1, r.correlativo - 1, (r.correlativo - r.prev_corr - 1),
         r.prev_at, r.created_at
  from r left join public.cobradores co on co.id = r.prev_cob
  where r.correlativo - r.prev_corr > 1
    and r.real_now and r.prev_real
    -- Rango ignorado (descartado a mano, con registro): no se lista más.
    and not exists (
      select 1 from public.recibos_huecos_ignorados i
       where i.tenant_id = r.tenant_id and i.prefijo = r.prefijo
         and (r.prev_corr + 1) >= i.desde and (r.correlativo - 1) <= i.hasta
    )
    -- 0246: SIEMPRE el tenant en contexto; el super_admin solo relaja el ROL
    -- (is_admin_or_cobranza() es false para él). La vista cross-tenant es
    -- recibos_huecos_todos(), para /super/diagnostico.
    and r.tenant_id = public.current_tenant_id()
    and (public.is_super_admin() or public.is_admin_or_cobranza())
  order by (r.correlativo - r.prev_corr - 1) desc, r.tenant, r.prefijo;
$fn$;

-- ═══════ A2 — recibos_huecos_todos(): la vista cross-tenant del Dev ═════════
-- Misma firma de retorno que recibos_huecos() (la consola la consume igual).
-- Función APARTE y no un overload con default: PostgREST resuelve mal la
-- llamada sin argumentos cuando existe una sobrecarga, y rompería el RPC del
-- cliente.
create or replace function public.recibos_huecos_todos()
returns table (
  tenant text, prefijo text, cobrador text,
  desde int, hasta int, faltan int,
  ok_antes timestamptz, ok_despues timestamptz
)
language sql stable security definer
set search_path to 'public'
as $fn$
  with r as (
    select t.id as tenant_id, t.nombre as tenant, r.prefijo, r.correlativo,
           r.created_at,
           (r.created_at::time <> '00:00:00') as real_now,
           lag(r.correlativo) over w as prev_corr,
           lag(r.created_at)  over w as prev_at,
           lag(r.cobrador_id) over w as prev_cob,
           lag(r.created_at::time <> '00:00:00') over w as prev_real
    from public.recibos r
    join public.tenants t on t.id = r.tenant_id
    window w as (partition by r.tenant_id, r.prefijo order by r.correlativo)
  )
  select r.tenant, r.prefijo, coalesce(co.nombre, '?'),
         r.prev_corr + 1, r.correlativo - 1, (r.correlativo - r.prev_corr - 1),
         r.prev_at, r.created_at
  from r left join public.cobradores co on co.id = r.prev_cob
  where r.correlativo - r.prev_corr > 1
    and r.real_now and r.prev_real
    and not exists (
      select 1 from public.recibos_huecos_ignorados i
       where i.tenant_id = r.tenant_id and i.prefijo = r.prefijo
         and (r.prev_corr + 1) >= i.desde and (r.correlativo - 1) <= i.hasta
    )
    and public.is_super_admin()
  order by (r.correlativo - r.prev_corr - 1) desc, r.tenant, r.prefijo;
$fn$;

revoke all on function public.recibos_huecos_todos() from public, anon, service_role;
grant execute on function public.recibos_huecos_todos() to authenticated;

-- ═════ A3 — la consola del Dev pasa a la gemela global (OBLIGATORIO) ════════
-- Cuerpo vigente = 0243. Único cambio: recibos_huecos() → recibos_huecos_todos().
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
        -- 0246: la global. recibos_huecos() ahora está anclada al tenant en
        -- contexto y para el super_admin sin impersonar sería System (0 filas).
        from public.recibos_huecos_todos() h), '[]'::jsonb),
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

-- ═══ A4 — sync_rechazo_autorizado(): lista + campana + Registrar + recibo ═══
-- Gate compartido de sync_rechazos_pendientes() (la lista de la bandeja),
-- sync_rechazo_registrar() (cuerpo vigente = 0240) y el UPDATE del recibo
-- hermano. Anclado al tenant, con el ROL relajado para el super_admin.
create or replace function public.sync_rechazo_autorizado(p_tenant uuid)
returns boolean language sql stable security definer
set search_path to 'public'
as $fn$
  select (p_tenant is not null
          and p_tenant = public.current_tenant_id()
          and (public.is_super_admin() or public.is_admin_or_cobranza()))
      -- Huérfano: cuando el write se rechaza POR contexto de tenant, el
      -- connector escribe la fila con tenant_id NULL a propósito
      -- (connector.dart). Sin dueño posible → queda para el super_admin, que
      -- es el único que puede reconstruirla. Sin esta rama se volvería
      -- INVISIBLE para todos — el modo de falla que 0236/0237 nacieron para
      -- matar (incidente Derling: 10 cobros perdidos, 19 días sin saberlo).
      or (p_tenant is null and public.is_super_admin());
$fn$;

-- ═══════════════ A5 — log_cobertura(): anclada al tenant ════════════════════
-- Tercera variante del mismo antipatrón, la más difícil de ver: el CTE hacía
-- `case when is_super_admin() then null` y las 14 subconsultas lo leían como
-- "sin filtro". Hoy no la consume ninguna pantalla (0 hits en lib/), pero
-- tiene grant a authenticated y quedaría lista para mostrar 31.391 cobros
-- donde el tenant tiene 88.
create or replace function public.log_cobertura(p_dias int default 7)
returns table (concepto text, actividad bigint, con_rastro bigint)
language sql stable security definer
set search_path to 'public'
as $fn$
  with lim as (
    select now() - make_interval(days => greatest(coalesce(p_dias,7), 1)) as t0
  ),
  ten as (
    -- 0246: SIEMPRE el tenant en contexto (antes: null = todos si super_admin).
    select public.current_tenant_id() as tid,
           (public.is_super_admin() or public.is_admin_or_cobranza()) as ok
  )
  select v.concepto, v.actividad, v.con_rastro
  from lim, ten,
  lateral (
    values
      ('cobros',
       (select count(*) from public.pagos p
         where p.fecha_pago >= lim.t0
           and p.tenant_id = ten.tid),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'cuotas'
           and o.tipo_op in ('cobro','cobro_multiple','cobro_puntual','cobro_recuperado')
           and o.tenant_id = ten.tid)),
      ('anulaciones de pago',
       (select count(*) from public.pagos p
         where p.anulado_en >= lim.t0
           and p.tenant_id = ten.tid),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.tipo_op = 'anulacion_pago'
           and o.tenant_id = ten.tid)),
      ('clientes nuevos',
       (select count(*) from public.clientes c
         where c.created_at >= lim.t0
           and c.tenant_id = ten.tid),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'clientes'
           and o.accion = 'create'
           and o.tenant_id = ten.tid)),
      ('contratos nuevos',
       (select count(*) from public.contratos c
         where c.created_at >= lim.t0
           and c.tenant_id = ten.tid),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'contratos'
           and o.accion = 'create'
           and o.tenant_id = ten.tid)),
      ('tickets nuevos',
       (select count(*) from public.tickets t
         where t.ocurrido_en >= lim.t0
           and t.tenant_id = ten.tid),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'tickets'
           and o.tenant_id = ten.tid)),
      ('visitas',
       (select count(*) from public.visitas v2
         where v2.ocurrido_en >= lim.t0
           and v2.tenant_id = ten.tid),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.tipo_op like 'visita%'
           and o.tenant_id = ten.tid)),
      ('seriales de inventario',
       (select count(*) from public.inv_seriales i
         where i.created_at >= lim.t0
           and i.tenant_id = ten.tid),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'inv_seriales'
           and o.tenant_id = ten.tid))
  ) as v(concepto, actividad, con_rastro)
  where ten.ok and ten.tid is not null;
$fn$;

-- ═════════ A6 — policy super_admin de sync_rechazos, anclada ════════════════
-- NO se dropea (es la convención R10: sin super_admin_all el super_admin
-- impersonando no puede escribir — bug de op_log 0128→0131). Se ancla: el
-- "Descartar" de la bandeja es un UPDATE REST directo sin filtro de tenant, y
-- esta policy era su única barrera → podía apagar en silencio y sin deshacer
-- el aviso de un cobro perdido de OTRO ISP. (Forense: nunca ocurrió; las filas
-- ajenas resueltas llevan la marca del UPDATE masivo de 0241 §3.)
drop policy if exists sync_rechazos_super_all on public.sync_rechazos;
create policy sync_rechazos_super_all on public.sync_rechazos
  for all
  using (public.is_super_admin()
         and (tenant_id = public.current_tenant_id() or tenant_id is null))
  with check (public.is_super_admin()
              and (tenant_id = public.current_tenant_id() or tenant_id is null));

-- ── A7 DESCARTADA A PROPÓSITO ──────────────────────────────────────────────
-- El audit proponía endurecer `sync_rechazos_insert` (hoy `with check (true)`)
-- a `(tenant_id is null or tenant_id = current_tenant_id()) and cobrador_id =
-- auth.uid()`. NO se aplica: el INSERT permisivo es una decisión de diseño de
-- 0236 ("una tabla de alertas tiene que aceptar cualquier alerta; el filtro va
-- en la LECTURA"). Endurecerlo reintroduce el peor modo de falla del proyecto:
-- si la cola sube un write de la empresa A cuando el JWT ya dice B (cambio de
-- impersonación, hallazgo #4), el AVISO del cobro perdido se rechazaría en
-- silencio. El vector que cerraría es teórico (plantar una alerta falsa con
-- REST armado a mano; es escritura, no expone ni una fila ajena) y no es
-- alcanzable desde la app. Queda en el backlog con esta justificación.

-- ═══ B1-server — descartar un aviso, anclado (lo consume el build v0.36.0) ══
-- Reemplaza al UPDATE REST directo de rechazos_sync_seccion.dart. Mismo patrón
-- que recibos_hueco_ignorar (0242): RPC definer, anclada a current_tenant_id(),
-- con mensaje entendible. Defensa en profundidad sobre A6.
create or replace function public.sync_rechazo_descartar(p_id uuid)
returns jsonb
language plpgsql volatile security definer
set search_path to 'public'
as $fn$
declare
  v_tenant uuid := public.current_tenant_id();
  v_fila public.sync_rechazos%rowtype;
begin
  if v_tenant is null
     or not (public.is_super_admin() or public.is_admin_or_cobranza()) then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso para descartar avisos');
  end if;

  select * into v_fila from public.sync_rechazos where id = p_id;
  if v_fila.id is null then
    return jsonb_build_object('ok', false, 'error', 'Ese aviso ya no existe.');
  end if;
  -- Anclaje ANTES del atajo de idempotencia (lo cazó la verificación en vivo):
  -- con el orden invertido, un aviso AJENO ya resuelto contestaba "listo, ya
  -- estaba" en vez de "es de otra empresa" — confirmaba su existencia y daba
  -- por buena una acción sobre data de otro ISP.
  if not (v_fila.tenant_id = v_tenant
          or (v_fila.tenant_id is null and public.is_super_admin())) then
    return jsonb_build_object('ok', false,
      'error', 'Ese aviso es de otra empresa. Entrá a esa empresa para resolverlo.');
  end if;
  if v_fila.resuelto then
    return jsonb_build_object('ok', true, 'ya_estaba', true);
  end if;

  update public.sync_rechazos
     set resuelto = true, resuelto_en = now(), resuelto_por = auth.uid()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $fn$;

revoke all on function public.sync_rechazo_descartar(uuid) from public, anon, service_role;
grant execute on function public.sync_rechazo_descartar(uuid) to authenticated;

commit;
