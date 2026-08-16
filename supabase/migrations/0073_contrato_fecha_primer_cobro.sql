-- 0073_contrato_fecha_primer_cobro.sql
-- Fecha explícita del primer cobro del contrato.
--
-- Hasta ahora la primera cuota se derivaba de (mes de fecha_inicio + dia_pago),
-- saltando al mes siguiente si esa fecha caía antes de la instalación. Era
-- correcto pero opaco: el admin no veía ni controlaba cuándo vencía la
-- primera cuota. Ahora el form pide "fecha del primer cobro" y de ahí se
-- deriva el dia_pago mensual. La primera cuota vence EXACTAMENTE en esa
-- fecha; las siguientes son mensuales en el mismo día.
--
-- Esta migración:
--   1. Agrega contratos.fecha_primer_cobro (date, nullable = contratos viejos).
--   2. Backfill: calcula la fecha que el sistema YA usaba para el primer mes
--      con cuota → NO cambia ninguna cuota existente.
--   3. Reescribe generar_cuotas_contrato para anclar el período inicial al mes
--      de fecha_primer_cobro. Idempotente (ON CONFLICT do nothing): no toca
--      cuotas ya creadas, solo afecta contratos nuevos.

-- =========================================================================
-- 1. Columna
-- =========================================================================
ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS fecha_primer_cobro date;

-- =========================================================================
-- 2. Backfill con la MISMA fecha que el sistema ya calculaba
-- =========================================================================
-- Lógica original (migración 0015): se itera desde el mes de fecha_inicio y
-- la primera cuota real es la del primer mes cuyo vencimiento NO sea anterior
-- a fecha_inicio. Reproducimos eso: si el vencimiento del mes de instalación
-- cae antes de la instalación, el primer cobro es el mes siguiente.
UPDATE public.contratos c
   SET fecha_primer_cobro = CASE
         WHEN public.calcular_fecha_pago(c.fecha_inicio, c.dia_pago) >= c.fecha_inicio
           THEN public.calcular_fecha_pago(c.fecha_inicio, c.dia_pago)
         ELSE public.calcular_fecha_pago(
                (date_trunc('month', c.fecha_inicio) + interval '1 month')::date,
                c.dia_pago)
       END
 WHERE c.fecha_primer_cobro IS NULL;

-- =========================================================================
-- 3. Reescribir generar_cuotas_contrato anclando al primer cobro
-- =========================================================================
-- Cambios vs 0015:
--   - El loop arranca en el MES de fecha_primer_cobro (no el de fecha_inicio).
--   - El vencimiento del período inicial es fecha_primer_cobro EXACTA; los
--     siguientes usan calcular_fecha_pago (clamp último día + ajuste domingo).
--   - Fallback: si fecha_primer_cobro es NULL (no debería tras backfill), cae
--     a la lógica vieja basada en fecha_inicio + dia_pago.
CREATE OR REPLACE FUNCTION public.generar_cuotas_contrato(
  p_contrato_id uuid,
  p_meses int DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_max_meses     int;
  v_creadas       int := 0;
  v_ancla         date;   -- mes 0 del loop (mes del primer cobro)
  v_periodo       date;
  v_vencimiento   date;
  v_inserto       boolean;
BEGIN
  SELECT * INTO v_contrato FROM public.contratos WHERE id = p_contrato_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % no existe', p_contrato_id;
  END IF;

  SELECT cobrador_id INTO v_cobrador_id FROM public.clientes WHERE id = v_contrato.cliente_id;
  SELECT precio_mensual INTO v_precio FROM public.planes WHERE id = v_contrato.plan_id;

  -- Mes ancla: el del primer cobro (o el de fecha_inicio si falta el dato).
  v_ancla := date_trunc('month',
               coalesce(v_contrato.fecha_primer_cobro, v_contrato.fecha_inicio))::date;

  -- Cuántos meses iterar.
  IF p_meses IS NOT NULL THEN
    v_max_meses := p_meses;
  ELSIF v_contrato.fecha_fin IS NULL THEN
    v_max_meses := 3;  -- indefinido: colchón inicial
  ELSE
    -- diff en meses entre el ancla y fecha_fin, +1 para incluir ambos extremos.
    v_max_meses := ((extract(year from v_contrato.fecha_fin) - extract(year from v_ancla)) * 12
                  + (extract(month from v_contrato.fecha_fin) - extract(month from v_ancla)))::int + 1;
  END IF;

  FOR i IN 0 .. v_max_meses - 1 LOOP
    v_periodo := (v_ancla + (i || ' months')::interval)::date;

    -- Período inicial: vencimiento = fecha_primer_cobro exacta (si existe).
    -- Resto de meses: calcular_fecha_pago normal.
    IF i = 0 AND v_contrato.fecha_primer_cobro IS NOT NULL THEN
      v_vencimiento := v_contrato.fecha_primer_cobro;
    ELSE
      v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);
    END IF;

    -- Fuera de rango por fecha_fin → terminar.
    EXIT WHEN v_contrato.fecha_fin IS NOT NULL AND v_periodo > v_contrato.fecha_fin;

    INSERT INTO public.cuotas (
      tenant_id, contrato_id, cliente_id, cobrador_id,
      periodo, fecha_vencimiento, monto, estado
    ) VALUES (
      v_contrato.tenant_id, v_contrato.id, v_contrato.cliente_id, v_cobrador_id,
      v_periodo, v_vencimiento, v_precio, 'pendiente'
    )
    ON CONFLICT (contrato_id, periodo) DO NOTHING;

    GET DIAGNOSTICS v_inserto = ROW_COUNT;
    IF v_inserto THEN
      v_creadas := v_creadas + 1;
    END IF;
  END LOOP;

  RETURN v_creadas;
END;
$$;
