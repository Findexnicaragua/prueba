-- ===========================================================================
-- seed_escenarios_suspension.sql — Datos de prueba para validar la SUSPENSIÓN
-- con prorrateo anclado al CICLO DEL DÍA_PAGO (testing manual en DEV).
-- v2 (2026-06-16): rediseñado tras el fix del bug de anclaje. Incluye dos
-- día_pago (15 y 6) para demostrar que el prorrateo del mes en curso usa la
-- ventana de servicio real, no el mes calendario.
-- ===========================================================================
--
-- QUÉ HACE: borra y recrea 6 clientes (TEST-S1..S6) con un contrato fijo c/u
-- (C$900/mes, 12 meses, instalado hace 3 meses) en el Test Tenant de DEV.
-- Las cuotas las genera el trigger `generar_cuotas_contrato`; el seed solo
-- inserta los `pagos` que arman cada escenario.
--
-- ⚠️  SOLO DEV. NUNCA en PRODUCCIÓN: borra todo `codigo LIKE 'TEST-%'` del
--     tenant y reescribe settings. Seguro de re-correr (los hijos —recibos,
--     cargos_extra, contrato_suspensiones— son ON DELETE CASCADE).
--
-- CÓMO CORRER: pegar TODO (desde `DO $$` hasta el `;` del SELECT final) en el
-- SQL Editor del Dashboard de DEV → Run. NO un bloque suelto.
--
-- MODELO (facturación vencida): una cuota de período P con día_pago D cubre
-- servicio (venc anterior, su propio venc] = ((P-1mes)+D, P+D]. Al SUSPENDER:
--   · período CUMPLIDO (su venc ya pasó)      → se cobra ENTERO (deuda real).
--   · período EN CURSO (su ventana contiene hoy) → se prorratea a los días
--     consumidos del ciclo (inicio del ciclo → hoy), con clamp al pago.
--   · período FUTURO (servicio no empezó)     → se anula (no se cobra).
--
-- ESCENARIOS — esperados al SUSPENDER HOY (16-jun-2026). El prorrateo del mes
-- en curso = (día de hoy − día de inicio del ciclo) días × (900/díasMes). Si
-- suspendés otro día, ese prorrateo cambia (lo demás no).
--   S1 día_pago 15 · mora (pagó solo la 1ª)  → Abril 900 + Mayo 900 + Junio(1 día)30  = 1.830 · Cobrar
--   S2 día_pago 15 · parcial 200 en Mayo     → Mayo 700 + Junio 30                    =   730 · Cobrar
--   S3 día_pago 15 · adelanto 50 en Junio    → Junio en curso (prorrateo 30) saldado  =     0 · Reactivar directo
--   S4 día_pago 15 · al día                  → Junio (1 día) 30                        =    30 · Cobrar
--   S5 día_pago  6 · mora (pagó solo la 1ª)  → Abril 900 + Mayo 900 + Junio(10 días)300= 2.100 · Cobrar
--   S6 día_pago  6 · al día                  → Junio (10 días) 300                     =   300 · Cobrar
-- (S5/S6 con día_pago 6: el ciclo en curso es 6-jun→6-jul, ya van 10 días = 300.
--  S1..S4 con día_pago 15: el ciclo es 15-jun→15-jul, va 1 día = 30. Esa diferencia
--  ES la prueba de que el prorrateo se ancla al día_pago, no al mes calendario.)
-- ===========================================================================

DO $$
DECLARE
  v_tenant   uuid := '8583a8f0-191d-4750-a07d-923c01a45300';  -- Test Tenant
  v_cobrador uuid := '79c45dce-d5a6-4568-9835-dcb89d9909db';  -- Cobrador Test
  v_plan uuid; v_depto uuid; v_muni uuid; v_com uuid; v_cli uuid; v_ct uuid;
  v_precio numeric := 900;
  v_inicio date := (current_date - interval '3 months')::date;
  v_finfijo date := (current_date - interval '3 months' + interval '12 months')::date;
  -- Períodos de las primeras cuotas (= 1er día del mes de VENCIMIENTO).
  v_p1 date := (date_trunc('month', current_date - interval '3 months') + interval '1 month')::date; -- ~abr
  v_p2 date := (date_trunc('month', current_date - interval '3 months') + interval '2 months')::date; -- ~may
  v_p3 date := (date_trunc('month', current_date - interval '3 months') + interval '3 months')::date; -- ~jun
  v_p4 date := (date_trunc('month', current_date - interval '3 months') + interval '4 months')::date; -- ~jul
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.cobradores WHERE id = v_cobrador AND tenant_id = v_tenant) THEN
    RAISE EXCEPTION 'El cobrador % no pertenece al tenant %', v_cobrador, v_tenant;
  END IF;

  -- limpieza TEST previos (hijos antes que padres; cuotas.cliente_id es RESTRICT).
  DELETE FROM public.pagos WHERE cuota_id IN (
    SELECT cu.id FROM public.cuotas cu JOIN public.clientes c ON c.id = cu.cliente_id
    WHERE c.tenant_id = v_tenant AND c.codigo LIKE 'TEST-%');
  DELETE FROM public.cuotas WHERE cliente_id IN (
    SELECT id FROM public.clientes WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-%');
  DELETE FROM public.contratos WHERE cliente_id IN (
    SELECT id FROM public.clientes WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-%');
  DELETE FROM public.clientes      WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-%';
  DELETE FROM public.planes        WHERE tenant_id = v_tenant AND nombre = 'TEST Plan 5MB';
  DELETE FROM public.comunidades   WHERE tenant_id = v_tenant AND nombre = 'TEST Barrio';
  DELETE FROM public.municipios    WHERE tenant_id = v_tenant AND nombre = 'TEST Municipio';
  DELETE FROM public.departamentos WHERE tenant_id = v_tenant AND nombre = 'TEST Depto';

  -- plan + geo
  v_plan := gen_random_uuid();
  INSERT INTO public.planes (id, tenant_id, nombre, tipo, precio_mensual, activo)
    VALUES (v_plan, v_tenant, 'TEST Plan 5MB', 'internet', v_precio, true);
  v_depto := gen_random_uuid();
  INSERT INTO public.departamentos (id, tenant_id, nombre) VALUES (v_depto, v_tenant, 'TEST Depto');
  v_muni := gen_random_uuid();
  INSERT INTO public.municipios (id, tenant_id, departamento_id, nombre) VALUES (v_muni, v_tenant, v_depto, 'TEST Municipio');
  v_com := gen_random_uuid();
  INSERT INTO public.comunidades (id, tenant_id, municipio_id, nombre) VALUES (v_com, v_tenant, v_muni, 'TEST Barrio');

  -- ── S1: día_pago 15, MORA (paga solo la más vieja) ──────────────────────
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-S1', 'TEST S1 dp15 mora', '88880001', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo = v_p1;

  -- ── S2: día_pago 15, PARCIAL 200 en Mayo (último cumplido) ───────────────
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-S2', 'TEST S2 dp15 parcial', '88880002', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2);
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, 200, 0, 'NIO', 200, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo = v_p3;

  -- ── S3: día_pago 15, adelanto 50 en el mes en curso → saldado (Reactivar directo) ──
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-S3', 'TEST S3 dp15 reactivar directo', '88880003', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3);
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, 50, 0, 'NIO', 50, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo = v_p4;

  -- ── S4: día_pago 15, AL DÍA (pagó hasta el último cumplido) ──────────────
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-S4', 'TEST S4 dp15 al dia', '88880004', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3);

  -- ── S5: día_pago 6, MORA (paga solo la más vieja) — anclaje distinto ─────
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-S5', 'TEST S5 dp6 mora', '88880005', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 6, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo = v_p1;

  -- ── S6: día_pago 6, AL DÍA — el mes en curso prorratea 10 días (≠ S4) ────
  v_cli := gen_random_uuid();
  INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
    VALUES (v_cli, v_tenant, v_cobrador, v_com, 'TEST-S6', 'TEST S6 dp6 al dia', '88880006', true);
  v_ct := gen_random_uuid();
  INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
    VALUES (v_ct, v_tenant, v_cli, v_plan, 6, v_inicio, v_finfijo, 12, 'activo');
  INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
    SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
    FROM public.cuotas cu WHERE cu.contrato_id = v_ct AND cu.periodo IN (v_p1, v_p2, v_p3);

  -- settings: habilita pago parcial / adelantado / cambio de fecha en el tenant TEST.
  UPDATE public.settings SET valor = 'true', updated_at = now()
    WHERE tenant_id = v_tenant
      AND clave IN ('cobranza.pago_parcial','cobranza.pago_adelantado','cobranza.cambio_fecha_habilitado');
  UPDATE public.cobradores SET puede_cambiar_fecha = true WHERE id = v_cobrador;

  RAISE NOTICE 'Seed v2 OK: 6 contratos TEST (día_pago 15 y 6) para validar el prorrateo anclado al ciclo.';
END $$;

-- VERIFICACIÓN: saldo PRE-suspensión por cuota (todas a monto 900; el prorrateo
-- se aplica al SUSPENDER en la app, no acá).
SELECT c.codigo, ct.dia_pago, cu.periodo, cu.fecha_vencimiento, cu.estado,
       cu.monto, cu.monto_pagado,
       (cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado) AS saldo
FROM public.clientes c
JOIN public.contratos ct ON ct.cliente_id = c.id
JOIN public.cuotas    cu ON cu.contrato_id = ct.id
WHERE c.codigo LIKE 'TEST-%'
ORDER BY c.codigo, cu.periodo;
