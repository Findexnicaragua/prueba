-- 0148 — Colchón de indefinidos: anclar a max(última pagada, mes actual) + 3.
--
-- Hasta 0142 la cantidad de cuotas de un INDEFINIDO se calculaba sólo contra
-- `current_date` (mes actual + 3). Eso NO contemplaba el pago POR ADELANTADO:
-- si un cliente paga jun→sep (4 meses), el colchón debía correrse a oct·nov·dic
-- (3 después de la ÚLTIMA pagada), no quedarse en mes_actual+3. Esta migración:
--   (a) re-ancla la generación a `GREATEST(meses_hasta_hoy, meses_hasta_última
--       _pagada)` → siempre 3 cuotas después de la más nueva entre el mes
--       actual y la última cuota pagada;
--   (b) hace el BACKFILL de todos los indefinidos activos (idempotente, ON
--       CONFLICT DO NOTHING) para curar los que hoy están sin colchón.
--
-- Es el lado server (trigger al crear + cron mensual) del fix; el ESPEJO OFFLINE
-- vive en `lib/data/utils/colchon_indefinido.dart` (mismo ancla), que corre al
-- crear el contrato y al cobrar — los triggers Postgres no corren en SQLite.
-- Idempotente: CREATE OR REPLACE + el backfill sólo agrega lo que falta.

CREATE OR REPLACE FUNCTION public.generar_cuotas_contrato(p_contrato_id uuid, p_meses integer DEFAULT NULL::integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
DECLARE
  v_contrato      public.contratos%rowtype;
  v_cobrador_id   uuid;
  v_precio        numeric(10,2);
  v_num_cuotas    int;          -- cuántas cuotas generar
  v_creadas       int := 0;
  v_primer_mes    date;         -- mes de vencimiento de la 1ª cuota (mes sig. a instalación)
  v_periodo       date;         -- mes de vencimiento de la cuota i
  v_vencimiento   date;
  v_inserto       boolean;
  v_ult_pagada    date;         -- período de la última cuota PAGADA (NULL si no hay)
  v_meses_ancla   int;          -- meses desde primer_mes hasta el ancla (hoy o última pagada)
  v_colchon       constant int := 3;  -- meses adelante a pregenerar (indefinidos)
BEGIN
  SELECT * INTO v_contrato FROM public.contratos WHERE id = p_contrato_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % no existe', p_contrato_id;
  END IF;

  -- Contrato no activo (cancelado/suspendido): no generar nada nuevo.
  IF v_contrato.estado IS DISTINCT FROM 'activo' THEN
    RETURN 0;
  END IF;

  SELECT cobrador_id INTO v_cobrador_id FROM public.clientes WHERE id = v_contrato.cliente_id;
  SELECT precio_mensual INTO v_precio FROM public.planes WHERE id = v_contrato.plan_id;

  -- Mes de vencimiento de la PRIMERA cuota = mes siguiente a la instalación
  -- (facturación vencida; se deriva de fecha_inicio, autoridad del dinero).
  v_primer_mes := (date_trunc('month', v_contrato.fecha_inicio) + interval '1 month')::date;

  -- Cuántas cuotas generar.
  IF p_meses IS NOT NULL THEN
    v_num_cuotas := p_meses;
  ELSIF v_contrato.duracion_meses IS NOT NULL THEN
    -- Fijo: exactamente duracion_meses cuotas (invariante de dinero #5).
    v_num_cuotas := v_contrato.duracion_meses;
  ELSE
    -- Indefinido: desde el primer mes hasta el ANCLA + colchón. El ancla es la
    -- más nueva entre el mes actual y la última cuota con ALGÚN pago (pagada o
    -- parcial) → un adelanto, aun parcial, corre el colchón (siempre 3 después
    -- de la última con pago). GREATEST(3,…): piso de 3 cuotas SIEMPRE, aun con
    -- instalación futura. (Espejo Dart: lib/data/utils/colchon_indefinido.dart.)
    SELECT MAX(periodo) INTO v_ult_pagada
      FROM public.cuotas
     WHERE contrato_id = p_contrato_id AND estado IN ('pagada', 'parcial');

    v_meses_ancla :=
      ((extract(year  from current_date)::int - extract(year  from v_primer_mes)::int) * 12
     +  (extract(month from current_date)::int - extract(month from v_primer_mes)::int));

    IF v_ult_pagada IS NOT NULL THEN
      v_meses_ancla := GREATEST(
        v_meses_ancla,
        ((extract(year  from v_ult_pagada)::int - extract(year  from v_primer_mes)::int) * 12
       +  (extract(month from v_ult_pagada)::int - extract(month from v_primer_mes)::int))
      );
    END IF;

    v_num_cuotas := GREATEST(3, v_meses_ancla + 1 + v_colchon);
  END IF;

  FOR i IN 0 .. v_num_cuotas - 1 LOOP
    v_periodo := (v_primer_mes + (i || ' months')::interval)::date;
    v_vencimiento := public.calcular_fecha_pago(v_periodo, v_contrato.dia_pago);

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
$function$;

-- Backfill: regenerar el colchón de TODOS los indefinidos activos con la fórmula
-- nueva. Cura los que hoy están sin las 3 cuotas. Idempotente (ON CONFLICT).
SELECT public.generar_cuotas_contrato(c.id)
  FROM public.contratos c
 WHERE c.estado = 'activo' AND c.duracion_meses IS NULL;
