-- 0142 — Colchón de cuotas de indefinidos: GREATEST(0,…) → GREATEST(3,…).
--
-- Un contrato INDEFINIDO genera `meses_desde_primer_mes + 1 + colchón(3)` cuotas,
-- con piso GREATEST(0,…). Con fecha de instalación FUTURA ese cálculo da < 3 (o 0
-- con +3 meses) → el cobrador no ve cuotas por cobrar hasta que el cron mensual
-- las completa. Decisión Rubén: el indefinido SIEMPRE arranca con el colchón de 3
-- desde la primera cuota de pago, sin importar la fecha. Fix de 1 línea
-- (GREATEST 0→3). Idempotente (CREATE OR REPLACE); no toca cuotas existentes.

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
  v_colchon       constant int := 3;  -- meses adelante a pregenerar (indefinidos)
BEGIN
  SELECT * INTO v_contrato FROM public.contratos WHERE id = p_contrato_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % no existe', p_contrato_id;
  END IF;

  -- Contrato no activo (cancelado): no generar nada nuevo.
  IF v_contrato.estado IS DISTINCT FROM 'activo' THEN
    RETURN 0;
  END IF;

  SELECT cobrador_id INTO v_cobrador_id FROM public.clientes WHERE id = v_contrato.cliente_id;
  SELECT precio_mensual INTO v_precio FROM public.planes WHERE id = v_contrato.plan_id;

  -- Mes de vencimiento de la PRIMERA cuota = mes siguiente a la instalación.
  -- Facturación vencida: paga al final del período de servicio. Se deriva de
  -- fecha_inicio (autoridad del dinero); el form pobla fecha_primer_cobro
  -- aparte, solo para display.
  v_primer_mes := (date_trunc('month', v_contrato.fecha_inicio) + interval '1 month')::date;

  -- Cuántas cuotas generar.
  IF p_meses IS NOT NULL THEN
    v_num_cuotas := p_meses;
  ELSIF v_contrato.duracion_meses IS NOT NULL THEN
    -- Fijo: exactamente duracion_meses cuotas (invariante de dinero #5).
    v_num_cuotas := v_contrato.duracion_meses;
  ELSE
    -- Indefinido: desde el primer mes hasta hoy + colchón. Retroactivo:
    -- si el contrato arrancó hace meses, genera las que falten. El cron
    -- recalcula cada mes con current_date → mantiene el colchón futuro.
    -- GREATEST(3,…) (fix 0142): piso de 3 cuotas SIEMPRE — una instalación con
    -- fecha futura ya no arranca con < 3 (o 0) cuotas por cobrar.
    v_num_cuotas := GREATEST(
      3,
      ((extract(year  from current_date)::int - extract(year  from v_primer_mes)::int) * 12
     +  (extract(month from current_date)::int - extract(month from v_primer_mes)::int))
      + 1 + v_colchon
    );
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
