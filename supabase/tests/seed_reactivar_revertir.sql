-- ===========================================================================
-- seed_reactivar_revertir.sql — Datos de prueba para REACTIVAR-en-cualquier-día
-- (2026-06-18) y REVERTIR suspensión/cancelación. Testing manual en DEV.
-- ===========================================================================
--
-- QUÉ HACE: borra y recrea 7 clientes (TEST-R*) con un contrato fijo c/u
-- (C$900/mes, 12 meses, períodos abr-2026..mar-2027) en el Test Tenant de DEV.
-- Las cuotas las genera el trigger `generar_cuotas_contrato`; el seed solo
-- inserta los `pagos` que arman cada escenario. Los contratos quedan ACTIVOS:
-- vos suspendés / reactivás / revertís EN LA APP (eso es lo que se prueba).
--
-- ⚠️  SOLO DEV. NUNCA en PRODUCCIÓN: borra todo `codigo LIKE 'TEST-R%'` del
--     tenant + su plan/geo. Seguro de re-correr. NO toca los TEST-S* del otro
--     seed (cleanup acotado a 'TEST-R%' y a plan/geo propios 'TEST-R ...').
--
-- CÓMO CORRER: pegar TODO (desde `DO $$` hasta el `;` del SELECT final) en el
-- SQL Editor del Dashboard de DEV → Run.
--
-- 🔑 REGLA DE ORO PARA QUE LOS NÚMEROS DEN: al SUSPENDER en la app, poné en el
--    date-picker del diálogo la fecha **18-jun-2026** (no la de hoy). El
--    prorrateo del mes en curso se ancla a esa fecha. Reactivá con las fechas
--    que indica cada escenario. precio/día = 900 / días-reales-del-mes
--    (junio = 900/30 = 30; mayo = 900/31 = 29.0323).
--
-- ┌───────────────────────────────────────────────────────────────────────┐
-- │ ESCENARIOS (suspendiendo el 18-jun-2026; dia_pago ≠ 1 a propósito §1c) │
-- └───────────────────────────────────────────────────────────────────────┘
--  TEST-RA15  dp15  GUARD mismo día. Pagó abr-jul (jul adelantado). Deuda 0 →
--             "Reactivar directo". Al abrir Reactivar, la fecha MÍNIMA elegible
--             es 19-jun (NO se puede elegir 18-jun = el día de suspensión).
--             Para deshacer el mismo día se usa REVERTIR, no Reactivar.
--
--  TEST-RB25  dp25  CORTE INTACTO (mismo mes, ANTES del día de pago). Pagó abr,
--             may + jun adelantado (jun = en_curso, prorrateo 714.19 cubierto
--             por el abono 900 → queda pagada 900). Reactivar **28-jun**:
--             el corte (período jun) NO colisiona con mesRNext (jul) → queda
--             INTACTO en 900; jul..mar reviven a 900. (NO debe saltar a 1800.)
--
--  TEST-RC06  dp6   SUB-CASO 4 (re-completa el corte). Pagó abr,may,jun. jul
--             (en_curso) queda prorrateado a 360 PENDIENTE (días 7→18 jun = 12
--             × 30). Deuda 360 → "Cobrar pendiente": cobrá los 360 → aparece
--             Reactivar. Reactivar **25-jun** (mismo ciclo): el corte (período
--             jul) colisiona con mesRNext (jul) → se RE-COMPLETA: monto
--             360 + 900 = **1260**, pagado 360, **saldo 900 pendiente** (el mes
--             reanudado). El recibo desglosa corte 360 + mes 900. (Sin esto se
--             SUB-cobraría el mes reanudado.)
--
--  TEST-RD06  dp6   SOBRE-COBRO CRÍTICO (gate monto<precio — bug que atajó el
--             audit). Pagó abr,may,jun + **jul ADELANTADO entero (900)**. Al
--             suspender, jul (en_curso) abono 900 ≥ prorrateo 360 → pagada 900.
--             Deuda 0 → Reactivar directo. Reactivar **25-jun** (mismo ciclo):
--             jul tiene monto 900 = precio → el gate lo EXCLUYE del re-completar
--             → **jul SIGUE 900 pagada (NO 1800)**. 🚨 Si jul salta a 1800 /
--             saldo 900 → el sobre-cobro regresó → FRENAR.
--
--  TEST-RE15  dp15  CROSS-MONTH (reactivar normal — re-test del guard nuevo).
--             Pagó abr,may,jun. jul (en_curso) prorrateo 90 PENDIENTE (días
--             16→18 jun = 3 × 30). Deuda 90 → cobrá 90 → Reactivar **10-jul**
--             (mes siguiente): mesRNext = ago → jul (corte) queda 90 pagada
--             (cubre 16-18 jun); ago..mar reviven a 900 con día 10. La pausa
--             18-jun→10-jul NO se factura. dia_pago re-anclado a 10.
--
--  TEST-RV1   dp15  REVERTIR SUSPENSIÓN (+ GUARDA). Mora: pagó solo abr. Al
--             suspender 18-jun: may,jun cumplidas (900 c/u, impagas), jul
--             en_curso prorrateo 90, ago..mar anuladas. (a) REVERTIR sin cobrar
--             nada → vuelve a ACTIVO con las cuotas EXACTAS: may,jun,jul,..,mar
--             a **900 pendiente** (jul recupera 900 ENTERO, no 90), dia_pago
--             SIGUE 15. (b) GUARDA: suspendé de nuevo → cobrá una cuota → tocá
--             Revertir → DEBE BLOQUEAR ("hubo cobros/cargos… usá Reactivar").
--
--  TEST-RV2   dp15  REVERTIR CANCELACIÓN. Al día: pagó abr,may,jun. Cancelá el
--             contrato (permanente) → jul prorrateo 90 cobrable, ago..mar
--             anuladas, estado 'cancelado'. REVERTIR cancelación sin cobrar →
--             vuelve a ACTIVO, jul a 900 pendiente, ago..mar revividas a 900,
--             se limpian cancelado_* y se re-abre la mora.
-- ===========================================================================

DO $$
DECLARE
  v_tenant   uuid := '8583a8f0-191d-4750-a07d-923c01a45300';  -- Test Tenant
  v_cobrador uuid := '79c45dce-d5a6-4568-9835-dcb89d9909db';  -- Cobrador Test
  v_plan uuid; v_depto uuid; v_muni uuid; v_com uuid; v_cli uuid; v_ct uuid;
  v_precio numeric := 900;
  -- FECHAS FIJAS (no current_date) → períodos deterministas abr-2026..mar-2027.
  v_inicio  date := DATE '2026-03-01';
  v_finfijo date := DATE '2027-03-01';
  v_p1 date := DATE '2026-04-01'; -- abr
  v_p2 date := DATE '2026-05-01'; -- may
  v_p3 date := DATE '2026-06-01'; -- jun
  v_p4 date := DATE '2026-07-01'; -- jul
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.cobradores WHERE id = v_cobrador AND tenant_id = v_tenant) THEN
    RAISE EXCEPTION 'El cobrador % no pertenece al tenant %', v_cobrador, v_tenant;
  END IF;

  -- limpieza TEST-R previos (hijos antes que padres; acotado a 'TEST-R%').
  DELETE FROM public.pagos WHERE cuota_id IN (
    SELECT cu.id FROM public.cuotas cu JOIN public.clientes c ON c.id = cu.cliente_id
    WHERE c.tenant_id = v_tenant AND c.codigo LIKE 'TEST-R%');
  DELETE FROM public.cuotas WHERE cliente_id IN (
    SELECT id FROM public.clientes WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-R%');
  DELETE FROM public.contratos WHERE cliente_id IN (
    SELECT id FROM public.clientes WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-R%');
  DELETE FROM public.clientes      WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-R%';
  DELETE FROM public.planes        WHERE tenant_id = v_tenant AND nombre = 'TEST-R Plan';
  DELETE FROM public.comunidades   WHERE tenant_id = v_tenant AND nombre = 'TEST-R Barrio';
  DELETE FROM public.municipios    WHERE tenant_id = v_tenant AND nombre = 'TEST-R Municipio';
  DELETE FROM public.departamentos WHERE tenant_id = v_tenant AND nombre = 'TEST-R Depto';

  -- plan + geo propios
  v_plan := gen_random_uuid();
  INSERT INTO public.planes (id, tenant_id, nombre, tipo, precio_mensual, activo)
    VALUES (v_plan, v_tenant, 'TEST-R Plan', 'internet', v_precio, true);
  v_depto := gen_random_uuid();
  INSERT INTO public.departamentos (id, tenant_id, nombre) VALUES (v_depto, v_tenant, 'TEST-R Depto');
  v_muni := gen_random_uuid();
  INSERT INTO public.municipios (id, tenant_id, departamento_id, nombre) VALUES (v_muni, v_tenant, v_depto, 'TEST-R Municipio');
  v_com := gen_random_uuid();
  INSERT INTO public.comunidades (id, tenant_id, municipio_id, nombre) VALUES (v_com, v_tenant, v_muni, 'TEST-R Barrio');

  -- ── TEST-RA15: dp15, pagó abr-jul (jul adelantado) → deuda 0 (guard) ─────
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-RA15', 'TEST RA dp15 guard mismo dia', '88881001', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3, v_p4);

  -- ── TEST-RB25: dp25, pagó abr,may + jun adelantado (corte intacto) ───────
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-RB25', 'TEST RB dp25 corte intacto', '88881002', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 25, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3);

  -- ── TEST-RC06: dp6, pagó abr,may,jun. jul prorrateo 360 pendiente (subcaso 4) ──
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-RC06', 'TEST RC dp6 subcaso4 recompleta', '88881003', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 6, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3);

  -- ── TEST-RD06: dp6, pagó abr,may,jun + jul ADELANTADO entero (sobre-cobro) ──
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-RD06', 'TEST RD dp6 sobre-cobro gate', '88881004', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 6, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3, v_p4);

  -- ── TEST-RE15: dp15, pagó abr,may,jun. jul prorrateo 90 pendiente (cross-month) ──
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-RE15', 'TEST RE dp15 cross-month', '88881005', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3);

  -- ── TEST-RV1: dp15, mora (pagó solo abr) → revertir suspensión + guarda ──
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-RV1', 'TEST RV1 dp15 revertir suspension', '88881006', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo = v_p1;

  -- ── TEST-RV2: dp15, al día (pagó abr,may,jun) → revertir cancelación ─────
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-RV2', 'TEST RV2 dp15 revertir cancelacion', '88881007', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3);

  -- settings: habilita pago parcial / adelantado / cambio de fecha en el tenant TEST.
  UPDATE public.settings SET valor = 'true', updated_at = now()
    WHERE tenant_id = v_tenant
      AND clave IN ('cobranza.pago_parcial','cobranza.pago_adelantado','cobranza.cambio_fecha_habilitado');
  UPDATE public.cobradores SET puede_cambiar_fecha = true WHERE id = v_cobrador;

  RAISE NOTICE 'Seed reactivar/revertir OK: 7 contratos TEST-R* (suspendé/cancelá con fecha 18-jun-2026).';
END $$;

-- VERIFICACIÓN: estado PRE-acción por cuota (todas a monto 900; el prorrateo se
-- aplica al SUSPENDER/CANCELAR en la app, no acá). Los pagos ya marcan pagadas.
SELECT c.codigo, ct.dia_pago, cu.periodo, cu.fecha_vencimiento, cu.estado,
       cu.monto, cu.monto_pagado,
       (cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado) AS saldo
FROM public.clientes c
JOIN public.contratos ct ON ct.cliente_id = c.id
JOIN public.cuotas    cu ON cu.contrato_id = ct.id
WHERE c.codigo LIKE 'TEST-R%'
ORDER BY c.codigo, cu.periodo;
