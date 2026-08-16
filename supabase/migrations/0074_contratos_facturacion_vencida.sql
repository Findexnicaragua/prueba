-- 0074_contratos_facturacion_vencida.sql
-- Modelo de facturación VENCIDA + retroactividad de indefinidos + extras.
--
-- Cambios de negocio (decisión de Rubén, ver REPORTE-SESION):
--   1. La primera cuota vence el MES SIGUIENTE a la instalación, mismo día.
--      Antes la primera cuota podía caer en el mes de instalación (modelo
--      "adelantado"). Ahora es VENCIDA: el cliente paga al final del período
--      de servicio. Instalado el 14/may → primera cuota vence 14/jun.
--   2. El día de pago sale de la fecha de instalación (un solo campo en el
--      form). fecha_primer_cobro deja de ser un input del admin; el server
--      la deriva (= mes siguiente). Se mantiene la columna poblada para la UI.
--   3. Contratos FIJOS: se generan exactamente `duracion_meses` cuotas
--      (invariante de dinero #5: total = precio × meses definidos al crear).
--   4. Contratos INDEFINIDOS: se generan retroactivamente desde el primer
--      cobro hasta hoy + colchón de 3 meses. El cron extiende el colchón
--      mes a mes. Antes solo se generaban 3 cuotas fijas desde el ancla.
--   5. El "mes simbólico" que sale en el recibo (mes con más días del período)
--      NO se almacena: se deriva en el cliente desde (periodo, dia_pago). Por
--      eso esta migración NO toca la columna `periodo` ni las cuotas viejas.
--   6. Columnas nuevas: contratos.costo_instalacion + contratos.notas
--      (informativas; no generan cobro automático en este sprint).
--
-- NOTA sobre `periodo`: sigue siendo el primer día del MES DE VENCIMIENTO de
-- la cuota (igual que 0073). El dedup (contrato_id, periodo) no cambia.

-- =========================================================================
-- 1. Columnas nuevas en contratos
-- =========================================================================
ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS costo_instalacion numeric(10,2),
  ADD COLUMN IF NOT EXISTS notas text;

-- =========================================================================
-- 2. generar_cuotas_contrato — modelo vencido + retroactividad
-- =========================================================================
-- Idempotente vía ON CONFLICT (contrato_id, periodo). Devuelve cuántas creó.
-- Se la llama desde el trigger AFTER INSERT (0015) y desde el cron (abajo).
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
    v_num_cuotas := GREATEST(
      0,
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
$$;

-- =========================================================================
-- 3. generar_cuotas_mes — ahora delega en generar_cuotas_contrato (DRY)
-- =========================================================================
-- Mantiene la firma vieja por compatibilidad. p_periodo se ignora (la lógica
-- de fechas vive en generar_cuotas_contrato). Itera los contratos activos del
-- tenant y deja que cada uno genere/extienda sus cuotas. Idempotente.
CREATE OR REPLACE FUNCTION public.generar_cuotas_mes(
  p_tenant_id uuid,
  p_periodo date DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total int := 0;
  v_c     record;
BEGIN
  FOR v_c IN
    SELECT id FROM public.contratos
     WHERE tenant_id = p_tenant_id AND estado = 'activo'
  LOOP
    v_total := v_total + public.generar_cuotas_contrato(v_c.id);
  END LOOP;
  RETURN v_total;
END;
$$;

-- =========================================================================
-- 4. Cron: regenerar/extender cuotas el 1° de cada mes
-- =========================================================================
-- Llama generar_cuotas_contrato por cada contrato activo de todos los
-- tenants. Para fijos ya completos es no-op (ON CONFLICT). Para indefinidos
-- extiende el colchón de 3 meses hacia adelante.
SELECT cron.unschedule('generar_cuotas_mensual');
SELECT cron.schedule(
  'generar_cuotas_mensual',
  '5 6 1 * *',
  $$
    SELECT public.generar_cuotas_contrato(c.id)
    FROM public.contratos c
    WHERE c.estado = 'activo';
  $$
);
