-- 0241 — El permiso que SIEMPRE faltó: el colchón de indefinidos del device.
--
-- Diseño original (colchon_indefinido.dart, era v0.2x): al cobrar ADELANTADO
-- un contrato indefinido, el device crea la siguiente cuota del colchón para
-- poder seguir cobrando offline. El server NUNCA tuvo policy que permita ese
-- INSERT a un cobrador → rechazo 42501 SILENCIOSO desde el día uno (los INV17
-- "preexistentes" de cada audit eran esto). v0.35.1 lo hizo visible (snackbar
-- + sync_rechazos: 7 capturas en 2 días, 3 cobradores, 2 tenants, todos la
-- cuota de diciembre) y Telenet lo reportó como "cartel rojo".
--
-- §1 Policy QUIRÚRGICA: el cobrador solo puede insertar exactamente la cuota
--    de colchón del diseño: su tenant, contrato ACTIVO coherente con la cuota,
--    período del mes actual en adelante, pendiente, sin pago, sin cargo manual.
--    (Sin exigir asignación: ver comentario en el cuerpo — carrera de
--    reasignación con la cola offline.)
--    El trigger trg_set_cobrador_id_cuotas denormaliza cobrador_id y los
--    guards de dinero corren igual que siempre.
-- §2 Reponer una vez, server-side, los colchones que los devices no pudieron
--    subir (los contratos que INV17 viene marcando).
-- §3 Resolver los rechazos de cuotas capturados (la causa quedó cerrada).
--    Los rechazos de pagos/recibos del Test Tenant NO se tocan (demo vivo).
--
-- Backlog documentado: la fórmula del cron (0178) se queda un mes corta en el
-- caso pago-adelantado; con esta policy el mecanismo diseñado (el device) la
-- cubre. Afinar el cron = segunda red, pendiente.

begin;

-- ── §1 ───────────────────────────────────────────────────────────────────────
drop policy if exists cuotas_colchon_insert_cobrador on public.cuotas;
create policy cuotas_colchon_insert_cobrador on public.cuotas
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and estado = 'pendiente'
    and monto_pagado = 0
    and anulada_en is null
    and tipo_cargo_manual is null
    and periodo >= date_trunc('month', (now() at time zone 'America/Managua'))::date
    -- Ancla: contrato ACTIVO del MISMO tenant y coherente con la cuota.
    -- NO se exige contrato asignado al cobrador: con la cola offline, la
    -- asignación puede cambiar entre el cobro y la subida (caso real: Snay
    -- cobró a LB0139 y hoy figura sin asignar) — exigirla re-crearía el
    -- rechazo rezagado que esta policy viene a eliminar. La protección es la
    -- FORMA: pendiente + sin pago + futura + sin cargo manual = neutra hasta
    -- que un pago (con sus guards) la toque.
    and exists (
      select 1 from public.contratos ct
       where ct.id = cuotas.contrato_id
         and ct.tenant_id = public.current_tenant_id()
         and ct.cliente_id = cuotas.cliente_id
         and ct.estado = 'activo'
    )
  );

-- ── §2 ───────────────────────────────────────────────────────────────────────
do $do$
declare
  i int;
  v_insertadas int;
begin
  for i in 1..5 loop
    insert into public.cuotas (id, tenant_id, cliente_id, contrato_id, periodo,
                               fecha_vencimiento, monto, estado, monto_pagado)
    select gen_random_uuid(), ct.tenant_id, ct.cliente_id, ct.id,
           (date_trunc('month', mx.maxp) + interval '1 month')::date,
           (date_trunc('month', mx.maxp) + interval '1 month')::date
             + (least(ct.dia_pago,
                  extract(day from (date_trunc('month', mx.maxp)
                    + interval '2 month' - interval '1 day'))::int) - 1),
           ult.monto, 'pendiente', 0
    from public.contratos ct
    join lateral (select max(q.periodo) as maxp from public.cuotas q
                   where q.contrato_id = ct.id) mx on true
    join lateral (select q.monto from public.cuotas q
                   where q.contrato_id = ct.id and q.tipo_cargo_manual is null
                   order by q.periodo desc limit 1) ult on true
    where ct.estado = 'activo' and ct.duracion_meses is null
      and (select count(*) from public.cuotas cu
            where cu.contrato_id = ct.id and cu.estado = 'pendiente'
              and cu.tipo_cargo_manual is null
              and cu.periodo > greatest(
                    date_trunc('month', (now() at time zone 'America/Managua'))::date,
                    coalesce((select max(cu2.periodo) from public.cuotas cu2
                               where cu2.contrato_id = ct.id
                                 and cu2.estado in ('pagada','parcial')),
                             '1900-01-01'::date))) < 3;
    get diagnostics v_insertadas = row_count;
    exit when v_insertadas = 0;
  end loop;
end $do$;

-- ── §3 ───────────────────────────────────────────────────────────────────────
update public.sync_rechazos
   set resuelto = true, resuelto_en = now()
 where tabla = 'cuotas' and codigo = '42501' and not resuelto;

commit;
