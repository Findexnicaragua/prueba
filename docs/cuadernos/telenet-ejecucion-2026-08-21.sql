-- ============================================================================
-- LIMPIEZA CUADERNO TELENET 08/2026 — LOTES A/B/C/D
-- SOLO LECTURA HASTA ACA: este script NO se ejecutó. Requiere aprobación.
-- Antes de correrlo: guardar en el repo el .sql de ROLLBACK (ver RIESGOS).
-- ============================================================================
begin;

-- 0) Contexto. Los contratos se resuelven por UUID EXPLICITO, nunca por codigo:
--    en Telenet los codigos se distinguen SOLO por ceros a la izquierda
--    (561 / 00561 / 0561 son TRES contratos distintos del mismo cliente).
create temp table _plan(lote text, ctr uuid) on commit drop;
insert into _plan values
 -- LOTE A (contrato re-tipeado)
 ('A','33f4a15a-83e7-474d-9945-a62c78b7e14f'), -- MV0049/119
 ('A','7745f6b9-e827-4aa8-a027-79b36f0cd4c4'), -- PM0023/0432
 ('A','5dcee66d-124b-46f7-879a-fdf36d21e261'), -- VZ0078/642
 ('A','20f87dd0-9e51-4a0c-8e88-6eeb2355ee7d'), -- VZ0006/702
 ('A','3ecbc365-60ec-423a-b7c9-a21c45da196a'), -- NA0053/0603
 ('A','5c95b494-1071-42c4-982a-d8d64052113c'), -- VZ0106/378
 ('A','59049093-4497-4b6c-bf8e-cb750f63007a'), -- MV0084/0625
 ('A','cce7b2f4-62e6-42c6-b4bd-27e3de06ee5a'), -- QH0084/0668
 ('A','20ec2414-eb94-4fc9-85e9-5389416929d4'), -- SP0099/0092
 -- LOTE B (cola futura de contrato terminal)
 ('B','0f73a92b-f6cb-45da-b14c-a8320144eeb3'), -- SP0023/488
 ('B','834eaf28-0339-4a4d-a43b-1c785eaf8609'), -- SP0027/487
 ('B','e6a2bed1-cea6-43fe-9f9b-5cff4e54120b'), -- SP0014/280
 ('B','79f060a5-d971-4f24-98af-3b2a92182d55'), -- VQ0039/272
 ('B','9937ba12-d613-4b9f-b109-bd2733805d83'), -- SP0024/00255
 ('B','fc756e1a-d991-4930-bd79-5792f8966f9d'), -- SP0024/0523
 -- LOTE C (mes ya pagado en el contrato vigente)
 ('C','7f3c83a4-c38f-4ab8-92b7-14a241b71d6c'), -- VZ0087/766
 ('C','21418d6d-ac58-4557-b7b5-c9b418a4cc88'), -- SG0042/0612
 ('C','19c4cbae-e074-4e79-ad2b-75c9a8e15f49'), -- LP0012/0296
 -- LOTE D (linea duplicada, hermano pendiente)
 ('D','d0421d70-efa0-4111-9b7a-7aed8215a175'), -- MV0148/817
 ('D','d62cc9ec-5587-4e7b-9b45-39838b8cb731'), -- QH0063/228
 ('D','8a21988d-f3c6-4195-acc0-ac99046a370b'), -- SG0008/00002
 ('D','9f5a28a7-1542-4596-85ad-826f7cb04c47'), -- AS0027/0590
 ('D','f3fc75ed-ea72-4f41-972d-b1ca6c36cee7'), -- EM0008/809
 ('D','e3fe8749-1525-4f8f-94cb-bebfa3a338f8'), -- FS0008/87
 ('D','806d25c5-d983-4ce6-9bbd-402d2dfb2578'), -- LQ0044/0572
 ('D','7e70f6a5-5be4-47c1-b660-af0cb8e71604'), -- QH0074/0374
 ('D','e9320531-9d41-471a-82e1-f25240b6c589'); -- PÑ0064/00377

-- 1) SELECCION DE CUOTAS. El filtro monto_pagado=0 va SIEMPRE, aunque hoy
--    sepamos que ninguna tiene plata: es la red, no el diagnostico.
create temp table _cuo on commit drop as
select p.lote, cu.id cuota_id, cu.contrato_id, cu.cliente_id, cu.estado estado_antes,
       cu.periodo, cu.fecha_vencimiento,
       (cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado) saldo,
       case p.lote
         when 'A' then 'Limpieza cuaderno Telenet 08/2026: contrato duplicado por error de carga; el servicio se factura en el contrato vigente del cliente (decision ISP)'
         when 'B' then 'Limpieza cuaderno Telenet 08/2026: cuota de vencimiento futuro sobre contrato ya dado de baja - servicio no prestado'
         when 'C' then 'Limpieza cuaderno Telenet 08/2026: mes ya cobrado en el contrato vigente del cliente - doble facturacion'
         when 'D' then 'Limpieza cuaderno Telenet 08/2026: mes facturado en dos contratos; se conserva el del contrato vigente (decision ISP)'
       end motivo
from _plan p
join cuotas cu on cu.contrato_id = p.ctr
join planes pl on pl.id = (select plan_id from contratos c where c.id = p.ctr)
where cu.tenant_id = 'ca3b04ca-fd68-4208-8f01-b8f681dcf578'
  and cu.estado in ('pendiente','parcial')
  and coalesce(cu.monto_pagado,0) = 0          -- REGLA DURA: jamas plata cobrada
  and cu.tipo_cargo_manual is null              -- los cargos manuales no se tocan
  and (cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado) > 0.005
  and ( p.lote <> 'B'
        or (cu.fecha_vencimiento > current_date and cu.monto >= pl.precio_mensual - 0.01) );

-- GATE: si el conteo no da 70 / C$59.595,51 (recalculado hoy), ABORTAR.
do $$ declare n int; m numeric; begin
  select count(*), sum(saldo) into n, m from _cuo;
  raise notice 'SELECCION: % cuotas / C$%', n, m;
  if n = 0 then raise exception 'seleccion vacia'; end if;
  -- Gate duro: el plan se calculo sobre 70 cuotas. Un desvio grande significa
  -- que la base cambio desde el analisis (pagos nuevos, cortes nuevos) y hay
  -- que volver a analizar, no ejecutar a ciegas.
  if n < 60 or n > 80 then
    raise exception 'ABORTA: la seleccion dio % cuotas (esperado ~70). La base cambio desde el analisis.', n;
  end if;
end $$;

-- 2) BACKUP (una fila por contrato, con los uuid adentro para que el rollback
--    sea mecanico — el snapshot de Mairena NO los tenia y por eso alla el undo
--    fue arqueologia).
insert into data_op_backups (id, tenant_id, operacion, target_label, snapshot, created_at)
select gen_random_uuid(), 'ca3b04ca-fd68-4208-8f01-b8f681dcf578',
       'limpieza_cuaderno_telenet_2026_08',
       cl.codigo || ' / contrato ' || co.codigo,
       jsonb_build_object(
         'lote', c.lote,
         'cliente_id', cl.id, 'cliente_codigo', cl.codigo, 'cliente_activo_antes', cl.activo,
         'contrato_id', co.id, 'contrato_codigo', co.codigo, 'contrato_estado_antes', co.estado,
         'cuotas_pendientes_antes', jsonb_agg(jsonb_build_object(
            'id', c.cuota_id, 'estado', c.estado_antes, 'periodo', c.periodo,
            'vence', c.fecha_vencimiento, 'saldo', c.saldo))),
       now()
from _cuo c
join contratos co on co.id = c.contrato_id
join clientes  cl on cl.id = c.cliente_id
group by c.lote, cl.id, cl.codigo, cl.activo, co.id, co.codigo, co.estado;

-- 3) FOTO DE LA DEUDA en el contrato, ANTES de anular. En Mairena esto se hizo
--    DESPUES y 34 de 57 contratos quedaron con snapshot en total 0.
--    Solo para los 6 del lote B, que hoy tienen cancelacion_deuda_snapshot NULL.
update contratos co
set cancelacion_deuda_snapshot = (
  select jsonb_build_object(
    'generado_en', now(), 'origen', 'limpieza_cuaderno_telenet_2026_08',
    'dia_pago', co.dia_pago,
    'total', sum(cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado),
    'cuotas', jsonb_agg(jsonb_build_object('periodo', cu.periodo,
                'vence', cu.fecha_vencimiento,
                'saldo', cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado)))::text
  from cuotas cu where cu.contrato_id = co.id and cu.estado in ('pendiente','parcial')
    and (cu.monto + coalesce(cu.cargos_neto,0) - cu.monto_pagado) > 0.005)
where co.id in (select ctr from _plan where lote = 'B')
  and co.cancelacion_deuda_snapshot is null;
-- NO se rellenan cancelado_en / cancelado_por: esos contratos NUNCA se cancelaron
-- (fueron marcados 'completado' por el ISP y renombrados por la migracion 0221).
-- Inventar una fecha y un autor de cancelacion seria falsear el rastro.

-- 4) ANULACION. Trio completo obligatorio (CHECK cuotas_anulacion_coherencia:
--    estado='anulada' -> anulada_en IS NOT NULL AND anulada_por IS NOT NULL
--    AND motivo_anulacion IS NOT NULL). Si falta uno, revienta la transaccion entera.
update cuotas cu
set estado           = 'anulada',
    anulada_en       = now(),
    anulada_por      = '92f4d735-e6ee-4da5-9ff1-0647ce44b4b5',  -- Ruben, super_admin (el mismo de Mairena)
    motivo_anulacion = c.motivo
from _cuo c
where cu.id = c.cuota_id
  and cu.estado in ('pendiente','parcial')       -- idempotente
  and coalesce(cu.monto_pagado,0) = 0;           -- la red, otra vez

-- 5) op_log: UNA FILA POR OBJETO, DENTRO de la transaccion, compartiendo op_id
--    por intencion. En Mairena esto se olvido y se backfilleo 4 horas despues.
with op as (select gen_random_uuid() op_id, now() ts)
insert into op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id, accion,
                    actor_id, actor_label, ocurrido_en, diff, created_at)
select gen_random_uuid(), 'ca3b04ca-fd68-4208-8f01-b8f681dcf578', op.op_id,
       'anulacion_cuota', 'cuotas', c.cuota_id, 'update',
       null, 'System Admin', op.ts,
       jsonb_build_object(
         'campos', jsonb_build_array(jsonb_build_object(
            'campo','estado','antes',c.estado_antes,'despues','anulada')),
         'resumen', jsonb_build_object('motivo', c.motivo,
            'origen','Cuaderno de decisiones de Telenet (08/2026)'))::text,
       op.ts
from _cuo c cross join op;

with op as (select gen_random_uuid() op_id, now() ts)
insert into op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id, accion,
                    actor_id, actor_label, ocurrido_en, diff, created_at)
select gen_random_uuid(), 'ca3b04ca-fd68-4208-8f01-b8f681dcf578', op.op_id,
       'limpieza_deuda', 'contratos', c.contrato_id, 'update',
       null, 'System Admin', op.ts,
       jsonb_build_object('campos', jsonb_build_array(),
         'resumen', jsonb_build_object('lote', c.lote,
            'motivo','Cuaderno de decisiones de Telenet 08/2026',
            'cuotas_anuladas', count(*), 'monto_anulado', sum(c.saldo)))::text,
       op.ts
from _cuo c cross join op
group by c.contrato_id, c.lote, op.op_id, op.ts;

-- 6) data_ops_log — el "Historial de operaciones" del panel Dev.
--    En Mairena quedo VACIO: la operacion de datos mas grande del proyecto
--    no figura en ningun lado de la app.
insert into data_ops_log (id, tenant_id, operacion, target_label, afectados,
                          actor_id, actor_label, created_at)
select gen_random_uuid(), 'ca3b04ca-fd68-4208-8f01-b8f681dcf578',
       'limpieza_cuaderno_telenet_2026_08',
       'Telenet — cuaderno 08/2026, lotes A/B/C/D',
       jsonb_build_object('contratos', count(distinct contrato_id),
                          'cuotas', count(*), 'total', sum(saldo),
                          'lotes', jsonb_agg(distinct lote)),
       '92f4d735-e6ee-4da5-9ff1-0647ce44b4b5', 'Ruben Maltez (super_admin)', now()
from _cuo;

-- NADA de desactivar clientes en esta corrida: los 27 clientes de A/B/C/D estan
-- ACTIVOS y sus contratos vigentes siguen debiendo plata. El guard 0220
-- (clientes_guard_desactivar_con_deuda_trg) haria rollback de TODO.
-- NADA de tocar la tabla `pagos`. Eso es un expediente aparte.

commit;
