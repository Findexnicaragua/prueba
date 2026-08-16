-- 0178 — Colchón de indefinidos: NO rellenar el hueco de una suspensión larga.
--
-- BUG (latente, 0 casos en prod): un indefinido suspendido MÁS de 3 meses y
-- luego reactivado queda con un HUECO — los meses de la pausa (entre el colchón
-- anulado al suspender y `mesReactivación`) nunca se crearon (el colchón sólo
-- materializa 3 meses adelante, una pausa larga nunca los alcanza). El generador
-- (esta función + su espejo Dart) arrancaba el loop en `v_primer_mes` y como esos
-- períodos NO existen, el `ON CONFLICT DO NOTHING` no los saltaba → los insertaba
-- como 'pendiente' con vencimiento PASADO = deuda FALSA por meses SIN servicio
-- (viola 0120: los meses suspendidos no se facturan).
--
-- FIX: para un contrato que YA tiene cuotas, no generar NUNCA períodos interiores
-- anteriores al mes SIGUIENTE a la cuota existente más nueva (de cualquier estado)
-- = `v_start`. El único hueco interior posible de un indefinido lo deja una
-- suspensión; `reactivarContrato` siempre crea el colchón desde `mesR+1`, así que
-- el máximo existente cae DESPUÉS del hueco → el piso lo salta. En generación
-- INICIAL (0 cuotas) `v_start = v_primer_mes` → comportamiento intacto. Sólo aplica
-- al ramo INDEFINIDO (los fijos ya nacen con todas sus cuotas contiguas → el hueco
-- de una suspensión existe como fila 'anulada' y el ON CONFLICT ya lo salta).
--
-- Espejo Dart: lib/data/utils/colchon_indefinido.dart (mismo piso). Idempotente:
-- CREATE OR REPLACE. SIN backfill (0 contratos afectados hoy; sólo cambia el
-- comportamiento futuro). Base: 0148 (última definición vigente).

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
  v_max_periodo   date;         -- período de la cuota existente MÁS NUEVA (cualquier estado)
  v_start         date;         -- PISO anti-backfill: no generar períodos < v_start
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

  -- PISO anti-backfill. Default = v_primer_mes (fijos + generación inicial → sin
  -- cambio: v_periodo nunca cae por debajo). Sólo se ELEVA para indefinidos que
  -- ya tienen cuotas (ver bloque ELSE abajo).
  v_start := v_primer_mes;

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

    -- ANTI-BACKFILL (0178): si el indefinido YA tiene cuotas, el piso pasa al mes
    -- siguiente a la más nueva. Nunca se rellenan períodos interiores anteriores
    -- (el hueco de una suspensión larga = meses sin servicio → no se facturan).
    SELECT MAX(periodo) INTO v_max_periodo
      FROM public.cuotas WHERE contrato_id = p_contrato_id;
    IF v_max_periodo IS NOT NULL THEN
      v_start := GREATEST(
        v_primer_mes,
        (date_trunc('month', v_max_periodo) + interval '1 month')::date
      );
    END IF;
  END IF;

  FOR i IN 0 .. v_num_cuotas - 1 LOOP
    v_periodo := (v_primer_mes + (i || ' months')::interval)::date;
    -- Piso anti-backfill: no materializar el hueco de una suspensión larga.
    IF v_periodo < v_start THEN
      CONTINUE;
    END IF;
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
