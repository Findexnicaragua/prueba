-- 0238 — log_cobertura(): el guardián del módulo de logs.
--
-- Nace del audit 2026-08-18: los huecos del op_log se descubrían por
-- sensación ("siento que no registra"), no por datos. Esta función compara,
-- por concepto, la ACTIVIDAD real de las tablas base contra las filas de
-- op_log de la misma ventana. actividad > con_rastro = hay silencio.
--
-- OJO al leerla: en cobros, con_rastro suele ser MAYOR que actividad (un
-- cobro escribe filas por cada objeto afectado). El silencio es SOLO la
-- dirección contraria: actividad alta con rastro en cero o muy por debajo.
--
-- Gate igual que recibos_huecos: super_admin ve global; admin/cobranza su
-- tenant; el resto, nada.

begin;

create or replace function public.log_cobertura(p_dias int default 7)
returns table (concepto text, actividad bigint, con_rastro bigint)
language sql stable security definer
set search_path to 'public'
as $fn$
  with lim as (
    select now() - make_interval(days => greatest(coalesce(p_dias,7), 1)) as t0
  ),
  ten as (
    select case when public.is_super_admin() then null
                else public.current_tenant_id() end as tid,
           (public.is_super_admin() or public.is_admin_or_cobranza()) as ok
  )
  select v.concepto, v.actividad, v.con_rastro
  from lim, ten,
  lateral (
    values
      ('cobros',
       (select count(*) from public.pagos p
         where p.fecha_pago >= lim.t0
           and (ten.tid is null or p.tenant_id = ten.tid)),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'cuotas'
           and o.tipo_op in ('cobro','cobro_multiple','cobro_puntual','cobro_recuperado')
           and (ten.tid is null or o.tenant_id = ten.tid))),
      ('anulaciones de pago',
       (select count(*) from public.pagos p
         where p.anulado_en >= lim.t0
           and (ten.tid is null or p.tenant_id = ten.tid)),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.tipo_op = 'anulacion_pago'
           and (ten.tid is null or o.tenant_id = ten.tid))),
      ('clientes nuevos',
       (select count(*) from public.clientes c
         where c.created_at >= lim.t0
           and (ten.tid is null or c.tenant_id = ten.tid)),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'clientes'
           and o.accion = 'create'
           and (ten.tid is null or o.tenant_id = ten.tid))),
      ('contratos nuevos',
       (select count(*) from public.contratos c
         where c.created_at >= lim.t0
           and (ten.tid is null or c.tenant_id = ten.tid)),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'contratos'
           and o.accion = 'create'
           and (ten.tid is null or o.tenant_id = ten.tid))),
      ('tickets nuevos',
       (select count(*) from public.tickets t
         where t.ocurrido_en >= lim.t0
           and (ten.tid is null or t.tenant_id = ten.tid)),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'tickets'
           and (ten.tid is null or o.tenant_id = ten.tid))),
      ('visitas',
       (select count(*) from public.visitas v2
         where v2.ocurrido_en >= lim.t0
           and (ten.tid is null or v2.tenant_id = ten.tid)),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.tipo_op like 'visita%'
           and (ten.tid is null or o.tenant_id = ten.tid))),
      ('seriales de inventario',
       (select count(*) from public.inv_seriales i
         where i.created_at >= lim.t0
           and (ten.tid is null or i.tenant_id = ten.tid)),
       (select count(*) from public.op_log o
         where o.ocurrido_en >= lim.t0 and o.entidad = 'inv_seriales'
           and (ten.tid is null or o.tenant_id = ten.tid)))
  ) as v(concepto, actividad, con_rastro)
  where ten.ok;
$fn$;

revoke all on function public.log_cobertura(int) from public;
grant execute on function public.log_cobertura(int) to authenticated;

comment on function public.log_cobertura(int) is
  'Actividad real vs rastro en op_log por concepto, ultimos N dias. '
  'actividad >> con_rastro = una emision esta rota o rechazada (0238).';

commit;
