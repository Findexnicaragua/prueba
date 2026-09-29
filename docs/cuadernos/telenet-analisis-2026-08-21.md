## VEREDICTO EN 3 LINEAS

Se puede ejecutar HOY el 37% de la plata del cuaderno — C$59.595,51 en 70 cuotas de 27 contratos — donde la duplicación está probada contra la base y no hace falta preguntarle nada a nadie; la regla dura de Mairena ni se roza, porque en los 47 contratos NO hay una sola cuota pendiente con plata cobrada encima (cero, verificado hoy).

Los otros C$102.860,31 NO se tocan: la lectura "contrato mal cargado = deuda ficticia" se cae en 20 filas donde hay meses que ningún otro contrato facturó, o donde el propio Telenet escribió al cancelar que el cliente pidió la baja o el cambio de plan (o sea, servicio prestado).

Y hay tres cosas que el cuaderno ni siquiera contempla y que hay que resolver aparte: C$23.185 de pagos duplicados que están inflando la caja (uno de esos clientes ni figura en el cuaderno), los 6 clientes desactivados con deuda que dicen "cobrala" pero el guard lo prohíbe, y 29 contratos nuevos por C$90.437,69 que entraron al mismo problema entre el 12 y el 18 de agosto.

---

## LO QUE SE PUEDE EJECUTAR YA — por lote

Punto de partida verificado hoy contra vxxz (solo lectura): los 47 códigos resuelven 1:1 contra 47 contratos reales, los 47 tienen exactamente el estado que dice el cuaderno, y la deuda viva es **C$162.455,82 en 193 cuotas** — NO los C$169.306,82 del Excel (el 2026-08-12 corrió la reparación de la 0234 y anuló 8 cuotas por C$6.851 en las filas 2, 42 y 43). **Nada se ejecuta con los montos del archivo: se recalcula contra la base en el momento.**

Control previo que ya pasó: `count(*) where estado in ('pendiente','parcial') and monto_pagado > 0` sobre los 47 contratos = **0**. Las 104 cuotas con plata (C$112.551) están todas en estado `pagada` con saldo 0,00 y quedan fuera de cualquier WHERE por construcción.

---

### LOTE A — Contrato re-tipeado (duplicado de carga probado)

**Criterio (las tres a la vez, ninguna es opinión):** (1) el cliente tiene un contrato hermano ACTIVO cuya `fecha_inicio` es **igual o anterior** a la del contrato del cuaderno — o sea es el mismo servicio cargado dos veces, no un reemplazo posterior; (2) el **100%** de las cuotas pendientes tiene contraparte viva en ese hermano, con solape de ventana de servicio ≥ 24 días (cero cuotas huérfanas); (3) cero cuotas con `monto_pagado > 0`.

**9 contratos · 29 cuotas · C$27.290,52**

| # | Cliente | Contrato | Hermano activo | Deuda | Evidencia |
|---|---|---|---|---|---|
| 2 | MV0049 | 119 | 0119 (mismo ini 2026-01-02) | 8.974,00 | 7/7 meses YA PAGADOS en 0119 |
| 4 | PM0023 | 0432 | 0433 (mismo ini 2026-01-25) | 11.538,00 | 9/9 cubiertos, 6 ya pagados |
| 15 | VZ0078 | 642 | 0642 (mismo ini 2026-01-14) | 2.970,99 | 6/6 YA PAGADOS |
| 22 | VZ0006 | 702 | 00702 (mismo ini 2026-01-13) | 1.057,31 | 1/1 YA PAGADO |
| 27 | NA0053 | 0603 | 00603 (ini 2 días antes) | 761,23 | 2/2 cubiertos |
| 30 | VZ0106 | 378 | 00378 (ini más viejo) | 696,41 | 1/1 YA PAGADO |
| 32 | MV0084 | 0625 | 00625 (mismo ini 2026-06-12) | 614,19 | 1/1 cubierto |
| 35 | QH0084 | 0668 | 00668 (mismo ini 2026-07-11) | 430,26 | 1/1 YA PAGADO |
| 38 | SP0099 | 0092 | 00092 (ini más viejo) | 248,13 | 1/1 YA PAGADO |

---

### LOTE B — Cola de contrato terminal (servicio que no se va a prestar)

**Criterio:** cuotas **COMPLETAS** (monto = precio del plan, no prorrateadas) con **`fecha_vencimiento > CURRENT_DATE`** en contratos que ya están dados de baja. Es exactamente lo que el trigger 0234 hace al cancelar; estos 6 contratos quedaron afuera porque tienen `cancelado_en IS NULL` y el backfill de la 0234 filtra `WHERE b.fecha IS NOT NULL AND b.por IS NOT NULL`.

Ojo con el porqué del NULL, que es el hallazgo más importante para la ejecución: **estos contratos nunca pasaron por el flujo de cancelación.** El op_log muestra que Telenet los marcó `activo → completado`, y fue la migración **0221(b1)** la que les cambió la etiqueta a `cancelado`. No tienen `cancelado_en`, `cancelado_por`, `motivo_cancelacion` ni `cancelacion_deuda_snapshot`.

**Este lote NO toca la deuda pasada de esos contratos** (esa va a preguntas, punto 1). Solo mata la cola futura.

**6 contratos · 19 cuotas · C$17.511,00**

| # | Cliente | Contrato | Cuotas futuras | Monto | Hasta |
|---|---|---|---|---|---|
| 1 | SP0023 | 488 | 3 | 3.846,00 | 2026-10-26 |
| 3 | SP0027 | 487 | 3 | 3.846,00 | 2026-10-26 |
| 5 | SP0014 | 280 | 2 | 2.564,00 | 2026-10-16 |
| 6 | VQ0039 | 272 | 4 | 3.664,00 | 2026-12-03 |
| 7 | SP0024 | 00255 | 5 | 2.565,00 | **2027-01-12** |
| 13 | SP0024 | 0523 | 2 | 1.026,00 | 2026-10-12 |

(PM0023/0432 también es de este grupo, pero entra completo en el lote A, así que no se cuenta dos veces.)

---

### LOTE C — El mes ya está pagado bajo el contrato vigente

**Criterio:** el 100% de las cuotas pendientes solapa (≥ 26 días) con una cuota **PAGADA** de un contrato ACTIVO del mismo cliente. Cobrar acá es cobrarle dos veces el mismo mes de servicio a alguien que ya pagó.

**3 contratos · 5 cuotas · C$2.854,07**

| # | Cliente | Contrato | Hermano | Deuda |
|---|---|---|---|---|
| 20 | VZ0087 | 766 | 0345 activo, mes PAGADO | 1.157,94 |
| 23 | SG0042 | 0612 | 00612 activo, 2 meses PAGADOS | 1.034,19 |
| 31 | LP0012 | 0296 | 00296 activo, 2 meses PAGADOS | 661,94 |

---

### LOTE D — Línea duplicada: el mes se factura dos veces, se cobra una

**Criterio:** el 100% de las cuotas solapa (≥ 27 días) con una cuota **PENDIENTE** de un contrato ACTIVO del mismo cliente. El mes está facturado en los dos; se mata el del contrato dado de baja y **queda viva la del contrato vigente** (no se pierde plata cobrable, se deja de reclamar dos veces).

**9 contratos · 17 cuotas · C$11.939,92**

| # | Cliente | Contrato | Hermano activo | Deuda |
|---|---|---|---|---|
| 14 | MV0148 | 817 | 00817 | 3.473,81 |
| 16 | QH0063 | 228 | 00228 | 1.860,97 |
| 18 | SG0008 | 00002 | 0078 | 1.860,65 |
| 21 | AS0027 | 0590 | 00590 | 1.075,23 |
| 24 | EM0008 | 809 | 00809 | 943,26 |
| 26 | FS0008 | 87 | 00087 | 851,61 |
| 28 | LQ0044 | 0572 | 00572 | 728,13 |
| 29 | QH0074 | 0374 | 00374 | 703,03 |
| 34 | PÑ0064 | 00377 | 000377 | 443,23 |

Advertencia honesta sobre este lote: en 5 de estas 9 el `motivo_cancelacion` que escribió Telenet dice "Solicitud del cliente — migra / da de baja / cambio de megas". Es decir, hubo migración real de servicio. Igual entran, porque la aritmética manda: el mes está facturado completo en el contrato vigente, así que la línea vieja es duplicado. Pero si Rubén prefiere máxima prudencia, **este es el lote que se saca primero** (queda C$47.655,59 ejecutable).

---

### EL SQL DEL PLAN (esto es lo que se correría — NO se corrió)

Todo en **UNA sola transacción**, con `now()` congelado, copiando el molde de Mairena y arreglando sus tres defectos (op_log dentro de la transacción, `data_ops_log` poblado, snapshot ANTES de anular).

```sql
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
                    actor, actor_id, actor_label, ocurrido_en, diff, created_at)
select gen_random_uuid(), 'ca3b04ca-fd68-4208-8f01-b8f681dcf578', op.op_id,
       'anulacion_cuota', 'cuotas', c.cuota_id, 'update',
       'system_admin', null, 'System Admin', op.ts,
       jsonb_build_object(
         'campos', jsonb_build_array(jsonb_build_object(
            'campo','estado','antes',c.estado_antes,'despues','anulada')),
         'resumen', jsonb_build_object('motivo', c.motivo,
            'origen','Cuaderno de decisiones de Telenet (08/2026)')),
       op.ts
from _cuo c cross join op;

with op as (select gen_random_uuid() op_id, now() ts)
insert into op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id, accion,
                    actor, actor_id, actor_label, ocurrido_en, diff, created_at)
select gen_random_uuid(), 'ca3b04ca-fd68-4208-8f01-b8f681dcf578', op.op_id,
       'limpieza_deuda', 'contratos', c.contrato_id, 'update',
       'system_admin', null, 'System Admin', op.ts,
       jsonb_build_object('campos', jsonb_build_array(),
         'resumen', jsonb_build_object('lote', c.lote,
            'motivo','Cuaderno de decisiones de Telenet 08/2026',
            'cuotas_anuladas', count(*), 'monto_anulado', sum(c.saldo))),
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
```

**Verificación posterior (obligatoria):**
```sql
-- a) el trio quedo completo en las 70
select count(*) from cuotas where motivo_anulacion like 'Limpieza cuaderno Telenet 08/2026%'
  and (anulada_en is null or anulada_por is null);           -- debe dar 0
-- b) no se toco plata
select count(*) from cuotas where motivo_anulacion like 'Limpieza cuaderno Telenet 08/2026%'
  and coalesce(monto_pagado,0) > 0;                          -- debe dar 0
-- c) triple registro
select (select count(*) from data_op_backups where operacion='limpieza_cuaderno_telenet_2026_08'),
       (select count(*) from data_ops_log   where operacion='limpieza_cuaderno_telenet_2026_08'),
       (select count(*) from op_log where tipo_op='anulacion_cuota' and ocurrido_en::date = current_date);
-- d) invariantes
-- supabase db query --linked -f supabase/tests/invariantes_dinero.sql
--    esperado: INV19 sigue en 6 (este lote no lo toca), todo lo demas en 0.
```

---

## LO QUE HAY QUE PREGUNTARLE A TELENET ANTES DE TOCAR

Preguntas listas para reenviar tal cual, cada una con el dato en la mano para que las contesten sin abrir el sistema.

**1. Los 6 contratos de "mala fecha": ¿desde cuándo tuvo servicio el cliente, de verdad?** (C$39.124,00 en juego)
> "Estos 6 contratos los dieron de baja porque la fecha estaba mal cargada, y el contrato correcto arranca meses después. Necesitamos que nos confirmen la fecha REAL en que se le instaló el servicio a cada uno:
> • Brandon Francisco Samb (SP0023) — el sistema dice que arrancó el 25/12/2025 y el contrato bueno arranca el 25/05/2026. ¿Le dieron servicio de enero a mayo 2026? Son C$6.410.
> • María Soledad Vargas (SP0027) — viejo desde 25/01/2026, bueno desde 25/05/2026. ¿Febrero a mayo? C$5.128.
> • Heydi Gabriela Martínez (SP0014) — viejo desde 16/01/2026, bueno desde 16/06/2026. ¿Febrero a junio? C$6.410.
> • María Luisa Reyes Ruíz (SP0024) — tiene TRES contratos (00255 desde 12/01, 0523 desde 12/03, 5524 desde 12/04). ¿Cuál fue la fecha real de instalación? Hay C$2.565 de febrero a abril sin cubrir.
> • Miryam del Carmen Rome (VQ0039) — el mes de enero 2026 (C$916) no lo factura ningún otro contrato.
> Si nos dicen que el servicio arrancó cuando arranca el contrato bueno, esos meses nunca existieron y los anulamos. Si arrancó antes, la deuda es real y se cobra."

**2. Los 6 clientes cortados que están DESACTIVADOS: ¿se cobra o se perdona?** (C$26.181,03)
> "Estos 6 están desactivados en el sistema y ustedes escribieron 'cliente cortado', o sea que la deuda es real. El problema es que un cliente desactivado no le aparece a ningún cobrador: la deuda existe pero es invisible. Hay que elegir una de dos, por cliente:
> (a) LO SEGUIMOS COBRANDO → lo reactivamos, el contrato queda cortado y la deuda vuelve a la lista de cobro; o
> (b) LA DAMOS POR PERDIDA → la anulamos con motivo y el cliente queda desactivado.
> • Juan José Castro López (MV0167) — C$10.863,88
> • José Daniel Martínez (MV0097) — C$4.816,39
> • Angela María Montiel (VQ0014) — C$3.961,45
> • Yoely Mercedes García (QH0073) — C$3.078,00
> • Cruz del Socorro López (MV0045) — C$1.889,83
> • Douglas José Navarrete (VZ0042) — C$1.571,48"

**3. Juan José Castro López (MV0167): ¿tenía UNO o DOS servicios?** (decide C$3.664)
> "A Juan José le facturamos abril, mayo, junio y julio de 2026 en DOS contratos a la vez: el 0488 (Combo 20M + Catv, C$1.282/mes) y el 00488 (Internet 20MB, C$916/mes). Ustedes marcaron los dos como 'cliente cortado'. Pero la nota que dejaron el 6 de julio al suspender el 00488 dice 'quedó pendiente con 3 meses abril, mayo…', o sea habla de UN solo servicio. ¿Tenía las dos líneas o una es duplicado de carga? Si es duplicado, C$3.664 de esa deuda no existen."

**4. Marcela Elizabeth Videa (QH0066): tiene TRES contratos y las dos decisiones se contradicen** (C$7.516,93 + C$5.128 fuera del cuaderno)
> "Marcela tiene tres contratos cargados: el 561 (Combo 20M+Catv, desde 07/01/2026, SUSPENDIDO, nunca pagó un peso, debe C$7.392,87), el 00561 (Internet 40MB, cancelado el 10/08, pagó 2 meses, debe C$124,06) y el 0561 (Internet 40MB, ACTIVO, creado el 10/08 con fecha retroactiva al 03/07, debe C$5.128 y nunca pagó nada).
> Necesitamos tres respuestas: (a) el Combo del contrato 561 entre febrero y junio, ¿le prestaron el servicio o fue un alta que nunca se instaló? (b) ustedes escribieron 'cliente cambió a combo', pero el sistema dice lo contrario — que se fue del combo y subió a 40M de internet. ¿Cuál es? (c) el contrato 0561 activo con C$5.128 sin ningún pago, ¿qué es? Ese ni siquiera está en la planilla que nos mandaron."

**5. Ruth Esther Valdizón (LQ0072): ¿le dieron servicio en agosto?** (C$380,61 + C$330,84)
> "Ruth tiene el contrato 0686 cancelado (debe agosto, C$380,61) y el 0717 suspendido desde el 12/08 con la nota 'cliente da de baja por falla en el servicio' (debe septiembre, C$330,84). El contrato nuevo NO factura agosto: si anulamos el viejo, agosto no lo cobra nadie. ¿Tuvo servicio en agosto? ¿Y sigue siendo cliente? Hoy figura activa, sin ningún contrato activo y sin un solo pago en toda su historia."

**6. Cuatro clientes con un mes de transición que nadie factura** (C$2.821,00)
> "En estos cuatro, el contrato nuevo arranca un mes después de que se cerró el viejo, así que queda un mes de servicio que ningún contrato cubre. ¿Se lo prestaron o no?
> • Gioconda Carolina Carvajal (VZ0120) — julio 2026, C$1.282 (venía pagando el contrato viejo desde febrero)
> • José Luis Ortíz (MV0058) — julio 2026, C$513
> • Ubelda de los Ángeles (GG0003) — agosto 2026, C$1.282
> • Ervin Francisco Acuña (LP0003) — julio 2026, C$449,14"

**7. Siete clientes con la misma cobranza cargada DOS VECES** (C$23.185 en la caja que puede no existir)
> "Encontramos que en estos clientes el mismo mes está cobrado en dos contratos distintos. Necesitamos saber cuánto cobraron realmente cada mes:
> • Delia Marina Juárez (VZ0006) — de febrero a junio, C$916 + C$1.282 cada mes. ¿Cobraron C$916 o C$1.282?
> • Darling de los Ángeles (VZ0106) — de febrero a junio, C$1.482 + C$1.648 cada mes.
> • **Pedro/PT0004** — de febrero a julio, C$513 + C$1.282 cada mes. **Este cliente NO está en la planilla que nos mandaron.**
> • Jorddy Jerioth Vilchez (MV0084) — 18/07, C$2.014 + C$2.380.
> • Blanca Adriana Pineda (MV0148) — mayo, C$513 + C$1.282.
> • Gladys Victoria Salinas (QH0074) — julio, C$916 + C$1.282.
> • Eloida Dalila Hernández (NA0053) — junio, C$513 + C$1.282.
> Esto NO se arregla anulando cuotas: hay que revertir el pago sobrante, y si el cliente pagó de más le corresponde crédito. Nada de esto se toca sin su respuesta."

**8. Marina Lisseth Benavides (VQ0038) y Augusto César García (VQ0031): el 12 de julio, ¿qué se cortó?** (~C$532 sobrefacturados)
> "Ustedes escribieron 'cliente cortado desde 12 de julio desde sistema, no se tiene fecha en que se le cortó el servicio ni que le retiró el equipo'. Necesitamos saber si el 12 de julio se le cortó el SERVICIO o solo se lo dio de baja en el sistema. Si el servicio se cortó ese día, hay cuotas posteriores que están cobrando servicio que no se prestó: VQ0038 tiene C$325,03 con vencimiento 29/08 y VQ0031 tiene C$206,84 con vencimiento 02/09."

**9. Taniuska Liseloth Méndez (VQ0003): está marcada como 'cliente cortado' pero pagó hasta el 7 de agosto**
> "Taniuska pagó 7 meses seguidos sin faltar uno (C$6.412) y su último pago fue el 07/08/2026. El contrato se canceló el 10/08 con el motivo que ustedes escribieron: 'Cliente solicita baja del servicio porque estudia en León'. No es una morosa cortada, es una buena pagadora que pidió la baja. Quedan C$354,58 de los últimos 12 días de servicio. ¿Se los cobran o se los condonan como cortesía de baja?"

**10. Hay 29 casos NUEVOS que entraron al mismo problema después de que les mandamos la planilla** (C$90.437,69)
> "Entre el 12 y el 18 de agosto ustedes hicieron una campaña de cortes (27 suspensiones y 3 cancelaciones). Eso hizo que 29 contratos más quedaran en la misma situación que los 47 de la planilla: hoy son 76 contratos por C$252.893,51. El más grande es Ronald/RL0014 contrato 400, con C$14.556,90 y vencimiento más viejo del 07/10/2025 — más grande que cualquier fila de la planilla. Les mandamos la lista actualizada para que la completen igual que la primera."

---

## LO QUE NO SE TOCA (y por qué)

**1. Ninguna cuota con plata cobrada.** Hay 104 cuotas pagadas en los 47 contratos por C$112.551,00. Están todas en estado `pagada` con saldo 0,00 y quedan fuera del WHERE por construcción (`monto_pagado = 0`). Además hay 0 cuotas en estado `parcial` en todo el universo consultado, que es el caso peligroso (anular una parcial escondería el saldo restante y dejaría un pago colgando). El riesgo que motivó la regla de Mairena directamente no existe acá.

**2. La tabla `pagos`.** Ni un solo UPDATE. Los C$23.185 de pagos duplicados son un expediente aparte, con su propia aprobación, y con un orden que importa: **primero se revierte el pago sobrante, después se decide la cuota.** Si se hace al revés, cada reversión resucita una cuota pendiente sobre un contrato ya cerrado y obliga a una segunda ronda de anulaciones.

**3. Las 10 filas de "CLIENTE CORTADO" (C$34.395,48).** Ningún contrato hermano cubre esos meses — verificado cuota por cuota, cero cobertura en las 10. Es deuda que corresponde a servicio prestado y el propio ISP la declara real. Anularla sería regalarla. (La única excepción a revisar es el par MV0167, pregunta 3.)

**4. La deuda PASADA de los 6 contratos "completado→cancelado" (C$39.124,00).** El lote B solo mata la cola futura. Los meses previos al arranque del contrato bueno son justamente los que ningún otro contrato factura, y no hay forma de probar desde la base si el servicio existió. Van a la pregunta 1.

**5. Las cuotas PRORRATEADAS de cola.** Cuando un contrato se da de baja, el sistema deja viva una última cuota prorrateada hasta el día del corte (C$325,03 / C$578,97 / C$212,65 / C$118,19…). Esa cuota NO es duplicado: es el empalme que cubre los días efectivamente prestados. Por eso el lote B filtra `cu.monto >= precio_mensual` — solo mata las cuotas COMPLETAS de vencimiento futuro.

**6. Las 9 filas donde el motivo grabado contradice la decisión escrita** (VZ0120, GG0003, AS0027, LQ0044, VQ0003, QH0066, LQ0072, MV0058, LP0003 en distintos grados). Telenet escribió "malo el paquete" (= error de carga) pero al cancelar el contrato habían escrito "Solicitud del cliente — cliente da de baja el cable y sube a 40M", "migra de catv a combo", "cliente tiene dañado el TV". El motivo contemporáneo le gana al texto libre de diez días después. Las que igual entran al lote D lo hacen solo porque el mes está facturado completo en el contrato vigente — no por el texto.

**7. Los 29 contratos nuevos (C$90.437,69).** No tienen decisión de nadie.

**8. `contratos.cancelado_en` / `cancelado_por` de los 6 del lote B.** No se rellenan. Esos contratos nunca se cancelaron: Telenet los marcó `completado` y la migración 0221 les cambió la etiqueta. Escribir una fecha y un autor de cancelación que no existieron ensucia el rastro en vez de arreglarlo. Sí se les pone el snapshot de deuda, que es la foto que hoy les falta.

---

## PLATA EN JUEGO

| Concepto | Cuotas | Monto | Estado |
|---|---:|---:|---|
| **SE ANULA — duplicación probada** (lotes A + C + D) | 51 | **C$42.084,51** | Ejecutable ya |
| **SE ANULA — servicio que no se va a prestar** (lote B, cola futura) | 19 | **C$17.511,00** | Ejecutable ya |
| **TOTAL EJECUTABLE** | **70** | **C$59.595,51** | 37% del cuaderno |
| | | | |
| Congelado — meses sin cobertura, "mala fecha" (pregunta 1) | 60 | C$39.124,00 | Espera respuesta |
| Congelado — cliente cortado, deuda real (pregunta 2, 8, 9) | 36 | C$34.395,48 | Espera respuesta |
| Congelado — casos enredados y mes de transición (preg. 4, 5, 6) | 27 | C$29.340,83 | Espera respuesta |
| **TOTAL CONGELADO** | **123** | **C$102.860,31** | 63% del cuaderno |
| | | | |
| **DEUDA DEL CUADERNO HOY** | **193** | **C$162.455,82** | (el Excel decía C$169.306,82) |

**Lo que queda COBRABLE después de ejecutar:** C$102.860,31 del cuaderno + C$90.437,69 de los 29 contratos nuevos = **C$193.298,00**. Además, los contratos VIGENTES de esos mismos 44 clientes siguen debiendo C$135.147,84 aparte, que no se toca en ningún escenario. O sea: esta limpieza no deja al ISP sin nada que cobrar, ni de cerca.

**Plata que NO es del cuaderno y hay que mirar aparte:**

| Concepto | Monto | Nota |
|---|---:|---|
| Pagos duplicados, lado del contrato cancelado | C$23.185 | 7 clientes / 20 meses |
| Pagos duplicados, lado del contrato activo | C$24.407 | una de las dos mitades es fantasma |
| Impacto en `recaudado_caja` del tenant | 0,44% | sobre C$5.307.986 de pagos no anulados |
| Contratos nuevos sin decisión (12–18 ago) | C$90.437,69 | 29 contratos |

---

## RIESGOS DE ESTA EJECUCION

**1. El rollback no existe — hay que escribirlo antes.** El RPC `super_admin_restaurar_backup` (0155) NO puede deshacer esto: recorre las claves `'cliente','contratos','cuotas'` y hace `insert … on conflict do nothing`. Sirve para deshacer un BORRADO, no un UPDATE. Acá las cuotas nunca se borran, solo cambian de estado, así que el restore devolvería 0 filas y diría "ok". **Precedente empírico:** en Mairena ya hubo que revertir a mano al menos una cuota (el caso SS0036) — hoy la base tiene 447 anuladas contra 448 filas de op_log, y esa cuota volvió a `pendiente` sin script y sin registro. Antes de tocar Telenet: escribir el `.sql` de rollback (restaurar `estado` desde el snapshot, no un `'pendiente'` hardcodeado; limpiar `anulada_en/por/motivo`; limpiar `cancelacion_deuda_snapshot` en los 6 del lote B), probarlo en Test Tenant, y commitearlo en `docs/cuadernos/`.

**2. La trampa que ya mordió una vez: filtrar por `cancelado_en`.** Los 6 contratos del lote B (C$68.173 de deuda total, 40% del cuaderno) tienen `cancelado_en IS NULL`. La reparación del 2026-08-12 usó `WHERE b.fecha IS NOT NULL AND b.por IS NOT NULL` y los salteó en silencio. Si el script de ejecución hereda ese filtro, se ejecuta el lote, se le informa a Telenet que está hecho, y el 40% del problema sigue vivo. **Por eso el script va por lista explícita de UUID, nunca por predicado de estado.**

**3. Matchear por `codigo` toca el contrato equivocado.** En Telenet los códigos se distinguen SOLO por ceros a la izquierda: `561` / `00561` / `0561` son tres contratos distintos del mismo cliente, con tres planes distintos. Igual `0488`/`00488`, `00255`/`0523`/`5524`, `00377`/`000377`, `119`/`0119`. Un `WHERE codigo = '561'` anula la plata de otro contrato y ni Postgres ni SQLite avisan nada. **Todo va por UUID, y el listado que se le muestre a Rubén para aprobar lleva el UUID corto al lado del código.**

**4. Guards que pueden saltar y hacer rollback de TODO:**
- `cuotas_anulacion_coherencia` (CHECK, verificado hoy en prod): si falta `anulada_en`, `anulada_por` o `motivo_anulacion`, la fila entera se rechaza y con ella la transacción. El script los pone los tres.
- `clientes_guard_desactivar_con_deuda_trg` (0220): cuenta TODAS las cuotas del CLIENTE, sin filtrar por contrato. **Este script no desactiva a nadie** — los 27 clientes de A/B/C/D están activos y sus contratos vigentes siguen debiendo. Si en el futuro se desactiva a alguno de los 6 cortados, primero se anula toda su deuda (en todos sus contratos) y recién después se desactiva.
- `z_contratos_anular_cuotas_futuras` (0234): se dispara si se toca `cancelado_por`. Con `cancelado_por` en NULL el trigger sale en silencio. Como el script NO rellena `cancelado_por`, no corre — que es lo que queremos, porque si corriera anularía cuotas con motivo ajeno ("Cancelación de contrato (red del server)") y **sin emitir op_log**.
- `pagos_anulacion_coherencia` (0012/0214): irrelevante acá porque no se toca `pagos`.

**5. Lo que salió mal en Mairena y no hay que repetir:** el `op_log` por cuota se olvidó dentro de la transacción y se backfilleó 4 horas después (448 filas con `created_at` 23:00 contra la anulación de las 18:52) — durante esas horas el historial de cada cuota no mostraba nada. Y `data_ops_log` quedó en CERO: la operación de datos más grande del proyecto no figura en el Historial del panel Dev, y como el botón "Restaurar" se dibuja desde `data_ops_log.backup_id`, los 110 respaldos de Mairena son huérfanos, invisibles desde la app. El script de arriba emite las dos familias de op_log dentro de la misma transacción, con `op_id` compartido por intención, y escribe `data_ops_log`.

**6. La ventana entre aprobación y ejecución.** El cuaderno ya se movió C$6.851 en diez días y el universo pasó de 47 a 76 contratos. Cualquier demora entre que Rubén aprueba y se ejecuta puede mover los números otra vez. El script tiene un GATE que recalcula y avisa el total antes de escribir: **si no da 70 cuotas / C$59.595,51, hay que parar y volver a mirar.**

**7. Cómo se verifica después.** Las cuatro queries del bloque de verificación de arriba, más `supabase db query --linked -f supabase/tests/invariantes_dinero.sql`. Esperado: todos los invariantes en 0 salvo **INV19, que debe seguir en 6** (los 6 clientes desactivados con deuda). Si INV19 baja, el script tocó algo que no debía. Si sube, peor.

**8. Corrección para el registro:** los números publicados de Mairena en `BITACORA.md` están mal por 1 cuota y C$513,44. La base dice **447 cuotas / C$363.501,19**, no 448 / C$364.014 (la diferencia sale de contar filas de `op_log`, que incluyen la cuota revivida del caso SS0036). Regla para el reporte de Telenet: los totales se sacan de `cuotas`, nunca de `op_log`.