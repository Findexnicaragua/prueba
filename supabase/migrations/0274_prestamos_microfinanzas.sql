-- 0274: Adaptación de contratos y cuotas a Préstamos y Microfinanzas
-- Permite que los contratos funcionen como créditos/préstamos sin depender de planes de internet.

-- 1. Desacoplar planes (hacer plan_id opcional en contratos)
ALTER TABLE public.contratos ALTER COLUMN plan_id DROP NOT NULL;

-- 2. Nuevas columnas de Préstamos en contratos
ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS monto_prestado numeric(12,2),
  ADD COLUMN IF NOT EXISTS tasa_interes numeric(5,2),
  ADD COLUMN IF NOT EXISTS frecuencia text DEFAULT 'mensual',
  ADD COLUMN IF NOT EXISTS plazo_cuotas int,
  ADD COLUMN IF NOT EXISTS metodo_calculo text DEFAULT 'interes_fijo',
  ADD COLUMN IF NOT EXISTS monto_cuota numeric(12,2),
  ADD COLUMN IF NOT EXISTS total_interes numeric(12,2),
  ADD COLUMN IF NOT EXISTS total_pagar numeric(12,2),
  ADD COLUMN IF NOT EXISTS moneda text DEFAULT 'NIO',
  ADD COLUMN IF NOT EXISTS destino_credito text,
  ADD COLUMN IF NOT EXISTS aval_nombre text,
  ADD COLUMN IF NOT EXISTS aval_telefono text;

-- 3. Desglose opcional en cuotas para capital e interés
ALTER TABLE public.cuotas
  ADD COLUMN IF NOT EXISTS capital numeric(12,2),
  ADD COLUMN IF NOT EXISTS interes numeric(12,2),
  ADD COLUMN IF NOT EXISTS saldo_restante numeric(12,2);

-- 4. El índice unique activo por cliente y plan no debe bloquear clientes sin plan_id
DROP INDEX IF EXISTS public.contratos_unique_activo_por_cliente_plan;
CREATE UNIQUE INDEX IF NOT EXISTS contratos_unique_activo_por_cliente_plan
  ON public.contratos (tenant_id, cliente_id, plan_id)
  WHERE (estado = 'activo' AND plan_id IS NOT NULL);

-- 5. Trigger de generación inicial de cuotas:
-- Si las cuotas ya fueron generadas por el cliente o si es un préstamo sin plan, no intentar consultar planes.
CREATE OR REPLACE FUNCTION public.trg_contratos_generar_cuotas_iniciales_fn()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Si ya existen cuotas insertadas para este contrato (generadas por el cliente), no duplicar
  IF EXISTS (SELECT 1 FROM public.cuotas WHERE contrato_id = NEW.id) THEN
    RETURN NEW;
  END IF;

  -- Si no tiene plan_id (es préstamo directo), no intentar generar cuotas de ISP con precio_mensual
  IF NEW.plan_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Para contratos legacy con plan de internet, mantener comportamiento anterior
  PERFORM public.generar_cuotas_contrato(NEW.id);
  RETURN NEW;
END;
$$;
