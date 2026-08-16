-- 0217 — Fix F5 (auditoría 2026-08-02): el corrector de invariantes recalculaba
-- cargos_neto SIN signo.
--
-- `super_admin_corregir_invariantes` (0189) hacía en su bloque INV14:
--   SET cargos_neto = SUM(ce.monto)
-- que suma TODOS los cargos_extra como positivos. Pero `cargos_neto` es NETO:
-- reconexión/otro SUMAN, descuento_monto/descuento_porcentaje/credito_aplicado
-- RESTAN (ver `calcular_cargos_neto`, 0023). En un tenant con descuentos o
-- crédito aplicado, correr el corrector INFLABA cargos_neto → corrompía el total
-- a cobrar y el saldo (INV14). Hoy sin daño (INV14=0) pero es un footgun.
--
-- FIX: usar `calcular_cargos_neto(q.id)` (el mismo helper con signo que usa el
-- trigger 0216). CREATE OR REPLACE idempotente; se parte de la definición VIGENTE
-- en prod y se cambia SOLO el bloque INV14 (regla del proyecto). Los bloques
-- INV2/INV3/INV17 quedan verbatim.

BEGIN;

CREATE OR REPLACE FUNCTION public.super_admin_corregir_invariantes(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
DECLARE
  v_fixed jsonb := '{}'::jsonb;
  v_count int;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin puede ejecutar esta operación.';
  END IF;

  -- ── INV14: re-sync cargos_neto ──
  -- Va ANTES de INV3 porque el estado depende de cargos_neto.
  -- FIX F5 (2026-08-02): `calcular_cargos_neto` respeta el SIGNO (reconexión/otro
  -- suman; descuento_*/credito_aplicado restan). Antes SUM(ce.monto) sin signo.
  UPDATE cuotas q
  SET cargos_neto = public.calcular_cargos_neto(q.id)
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND COALESCE(q.cargos_neto, 0) <> public.calcular_cargos_neto(q.id);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV14', v_count);

  -- ── INV2: re-sync monto_pagado ──
  -- Va ANTES de INV3 porque el estado depende de monto_pagado.
  UPDATE cuotas q
  SET monto_pagado = COALESCE((
    SELECT SUM(p.monto_cordobas) FROM pagos p
    WHERE p.cuota_id = q.id AND p.anulado = false
  ), 0)
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND q.monto_pagado <> COALESCE((
      SELECT SUM(p.monto_cordobas) FROM pagos p
      WHERE p.cuota_id = q.id AND p.anulado = false
    ), 0);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV2', v_count);

  -- ── INV3: re-sync estado basado en monto_pagado vs total ──
  UPDATE cuotas q
  SET estado = CASE
    WHEN q.monto_pagado >= q.monto + COALESCE(q.cargos_neto, 0) THEN 'pagada'
    WHEN q.monto_pagado > 0 THEN 'parcial'
    ELSE 'pendiente'
  END
  WHERE q.tenant_id = p_tenant
    AND q.estado <> 'anulada'
    AND q.tipo_cargo_manual IS NULL
    AND q.estado <> CASE
      WHEN q.monto_pagado >= q.monto + COALESCE(q.cargos_neto, 0) THEN 'pagada'
      WHEN q.monto_pagado > 0 THEN 'parcial'
      ELSE 'pendiente'
    END;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV3', v_count);

  -- ── INV17: regenerar colchón para contratos indefinidos ──
  SELECT COUNT(*) INTO v_count
  FROM contratos c
  WHERE c.tenant_id = p_tenant
    AND c.duracion_meses IS NULL
    AND c.estado = 'activo'
    AND (
      SELECT COUNT(*) FROM cuotas q2
      WHERE q2.contrato_id = c.id
        AND q2.estado IN ('pendiente','parcial')
        AND q2.tipo_cargo_manual IS NULL
        AND q2.periodo >= date_trunc('month', CURRENT_DATE)::date
    ) < 3;

  PERFORM public.generar_cuotas_contrato(c.id)
  FROM contratos c
  WHERE c.tenant_id = p_tenant
    AND c.duracion_meses IS NULL
    AND c.estado = 'activo'
    AND (
      SELECT COUNT(*) FROM cuotas q2
      WHERE q2.contrato_id = c.id
        AND q2.estado IN ('pendiente','parcial')
        AND q2.tipo_cargo_manual IS NULL
        AND q2.periodo >= date_trunc('month', CURRENT_DATE)::date
    ) < 3;

  v_fixed := v_fixed || jsonb_build_object('INV17', v_count);

  RETURN v_fixed;
END;
$function$;

COMMIT;
