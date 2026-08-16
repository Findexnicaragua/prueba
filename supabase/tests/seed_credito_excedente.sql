-- ===========================================================================
-- seed_credito_excedente.sql — Datos de prueba para el CRÉDITO POR EXCEDENTE
-- (0127): acreditar / devolver / condonar el pago por adelantado al suspender
-- o cancelar. Testing manual en DEV. Requiere setting cobranza.credito_excedente
-- = true (default ON) + app con schema v32 + sync rules con saldos_favor.
-- ===========================================================================
--
-- QUÉ HACE: crea 3 clientes TEST-CE1..CE3 con un contrato fijo c/u
-- (C$900/mes, día_pago 15, períodos abr-2026..mar-2027) que pagaron POR
-- ADELANTADO hasta septiembre. Las cuotas las genera el trigger; el seed solo
-- inserta los `pagos`. Los 3 quedan ACTIVOS: vos suspendés/cancelás EN LA APP.
--
-- ⚠️  SOLO DEV. Seguro de re-correr (cleanup acotado a 'TEST-CE%' + su plan/geo).
--     No toca TEST-S* ni TEST-R* de los otros seeds.
--
-- CÓMO CORRER: pegar TODO en el SQL Editor de DEV → Run.
--
-- 🔑 SUSPENDÉ / CANCELÁ con fecha **18-jun-2026** para que los números den.
--    Pagaron abr-sep. Al suspender/cancelar el 18-jun:
--      · abr, may, jun → CUMPLIDO (servicio dado) → deuda 0, sin excedente.
--      · jul → EN CURSO (15-jun→15-jul): servido 16-18 jun = 3 días × 30 = 90;
--        pagó 900 → EXCEDENTE 810.
--      · ago, sep → FUTURO (no empezó): pagó 900 c/u → EXCEDENTE 900 + 900.
--      · oct..mar → futuro SIN pagar → se anulan (ni deuda ni excedente).
--    → Deuda a la fecha = 0 · **A favor del cliente = 810 + 900 + 900 = C$2.610**
--
-- ESCENARIOS (mismo setup, distinta decisión):
--   TEST-CE1 · ACREDITAR: suspendé → "A favor C$2.610" → Acreditar. Reactivá
--             (directo, deuda 0). En el detalle del CLIENTE: chip "Saldo a favor
--             C$2.610" → Aplicar → cubre la cuota más vieja (queda en C$0, no
--             entra plata, el recaudado no sube). Repetí hasta agotar el saldo.
--   TEST-CE2 · DEVOLVER: suspendé → "A favor C$2.610" → Devolver. El arqueo del
--             día (reporte) RESTA C$2.610 de la caja de ese cobrador (línea
--             "(−) Devoluciones de saldo a favor"). El saldo a favor queda en 0.
--   TEST-CE3 · CONDONAR (vía cancelación): CANCELÁ el contrato → "A favor
--             C$2.610" → Condonar. El contrato queda cancelado, la plata se
--             queda en caja (recaudado NO baja) y queda registrado/auditado.
--             El saldo a favor queda en 0.
--
-- VERIFICAR (cualquier momento) el libro del crédito de un cliente:
--   SELECT tipo, monto, motivo, fecha_devolucion FROM saldos_favor sf
--     JOIN clientes c ON c.id = sf.cliente_id WHERE c.codigo = 'TEST-CE1'
--     ORDER BY sf.created_at;
--   -- disponible = SUM(+acreditado) − SUM(aplicado+devuelto+condonado+revertido)
-- ===========================================================================

DO $$
DECLARE
  v_tenant   uuid := '8583a8f0-191d-4750-a07d-923c01a45300';  -- Test Tenant
  v_cobrador uuid := '79c45dce-d5a6-4568-9835-dcb89d9909db';  -- Cobrador Test
  v_plan uuid; v_depto uuid; v_muni uuid; v_com uuid; v_cli uuid; v_ct uuid;
  v_precio numeric := 900;
  v_inicio  date := DATE '2026-03-01';
  v_finfijo date := DATE '2027-03-01';
  -- Períodos pagados por adelantado: abr → sep (6 meses).
  v_pagados date[] := ARRAY[
    DATE '2026-04-01', DATE '2026-05-01', DATE '2026-06-01',
    DATE '2026-07-01', DATE '2026-08-01', DATE '2026-09-01'];
  v_codigos text[] := ARRAY['TEST-CE1','TEST-CE2','TEST-CE3'];
  v_nombres text[] := ARRAY[
    'Marta Gómez (CE1·acreditar)', 'Carlos Ruiz (CE2·devolver)',
    'Ana López (CE3·condonar)'];
  v_tels text[] := ARRAY['88882001','88882002','88882003'];
  i int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.cobradores WHERE id = v_cobrador AND tenant_id = v_tenant) THEN
    RAISE EXCEPTION 'El cobrador % no pertenece al tenant %', v_cobrador, v_tenant;
  END IF;

  -- limpieza TEST-CE previos (hijos antes que padres; acotado a 'TEST-CE%').
  DELETE FROM public.saldos_favor WHERE cliente_id IN (
    SELECT id FROM public.clientes WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-CE%');
  DELETE FROM public.pagos WHERE cuota_id IN (
    SELECT cu.id FROM public.cuotas cu JOIN public.clientes c ON c.id = cu.cliente_id
    WHERE c.tenant_id = v_tenant AND c.codigo LIKE 'TEST-CE%');
  DELETE FROM public.cargos_extra WHERE cuota_id IN (
    SELECT cu.id FROM public.cuotas cu JOIN public.clientes c ON c.id = cu.cliente_id
    WHERE c.tenant_id = v_tenant AND c.codigo LIKE 'TEST-CE%');
  DELETE FROM public.cuotas WHERE cliente_id IN (
    SELECT id FROM public.clientes WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-CE%');
  DELETE FROM public.contratos WHERE cliente_id IN (
    SELECT id FROM public.clientes WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-CE%');
  DELETE FROM public.clientes      WHERE tenant_id = v_tenant AND codigo LIKE 'TEST-CE%';
  DELETE FROM public.planes        WHERE tenant_id = v_tenant AND nombre = 'TEST-CE Plan';
  DELETE FROM public.comunidades   WHERE tenant_id = v_tenant AND nombre = 'TEST-CE Barrio';
  DELETE FROM public.municipios    WHERE tenant_id = v_tenant AND nombre = 'TEST-CE Municipio';
  DELETE FROM public.departamentos WHERE tenant_id = v_tenant AND nombre = 'TEST-CE Depto';

  -- plan + geo propios
  v_plan := gen_random_uuid();
  INSERT INTO public.planes (id, tenant_id, nombre, tipo, precio_mensual, activo)
    VALUES (v_plan, v_tenant, 'TEST-CE Plan', 'internet', v_precio, true);
  v_depto := gen_random_uuid();
  INSERT INTO public.departamentos (id, tenant_id, nombre) VALUES (v_depto, v_tenant, 'TEST-CE Depto');
  v_muni := gen_random_uuid();
  INSERT INTO public.municipios (id, tenant_id, departamento_id, nombre) VALUES (v_muni, v_tenant, v_depto, 'TEST-CE Municipio');
  v_com := gen_random_uuid();
  INSERT INTO public.comunidades (id, tenant_id, municipio_id, nombre) VALUES (v_com, v_tenant, v_muni, 'TEST-CE Barrio');

  -- 3 clientes/contratos idénticos (día_pago 15, pagaron abr-sep por adelantado).
  FOR i IN 1..3 LOOP
    v_cli := gen_random_uuid();
    INSERT INTO public.clientes (id, tenant_id, cobrador_id, comunidad_id, codigo, nombre, telefono, activo)
      VALUES (v_cli, v_tenant, v_cobrador, v_com, v_codigos[i], v_nombres[i], v_tels[i], true);
    v_ct := gen_random_uuid();
    INSERT INTO public.contratos (id, tenant_id, cliente_id, plan_id, dia_pago, fecha_inicio, fecha_fin, duracion_meses, estado)
      VALUES (v_ct, v_tenant, v_cli, v_plan, 15, v_inicio, v_finfijo, 12, 'activo');
    INSERT INTO public.pagos (id, tenant_id, cuota_id, cobrador_id, monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion, metodo, fecha_pago, anulado, ocurrido_en)
      SELECT gen_random_uuid(), v_tenant, cu.id, v_cobrador, v_precio, 0, 'NIO', v_precio, 1, 'efectivo', now(), false, now()
      FROM public.cuotas cu
      WHERE cu.contrato_id = v_ct AND cu.periodo = ANY(v_pagados);
  END LOOP;

  -- settings: asegura que el crédito por excedente y el adelantado estén ON.
  UPDATE public.settings SET valor = 'true', updated_at = now()
    WHERE tenant_id = v_tenant
      AND clave IN ('cobranza.credito_excedente','cobranza.pago_adelantado','cobranza.pago_parcial');

  RAISE NOTICE 'Seed crédito por excedente OK: TEST-CE1..CE3 (suspendé/cancelá con fecha 18-jun-2026; A favor = C$2610 c/u).';
END $$;

-- VERIFICACIÓN: cuotas pagadas por adelantado (abr-sep = 900/900; resto 900/0).
SELECT c.codigo, cu.periodo, cu.estado, cu.monto, cu.monto_pagado
FROM public.clientes c
JOIN public.contratos ct ON ct.cliente_id = c.id
JOIN public.cuotas    cu ON cu.contrato_id = ct.id
WHERE c.codigo LIKE 'TEST-CE%'
ORDER BY c.codigo, cu.periodo;
