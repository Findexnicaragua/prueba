-- 0054: Fix generar_cuotas_mes after contrato.activo → estado migration.
-- La función 0014 usaba c.activo = true, pero 0052 reemplazó la columna
-- con estado text. Ahora filtra por c.estado = 'activo'.

CREATE OR REPLACE FUNCTION public.generar_cuotas_mes(p_tenant_id uuid, p_periodo date)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_creadas int;
BEGIN
  INSERT INTO public.cuotas (
    tenant_id, contrato_id, cliente_id, cobrador_id,
    periodo, fecha_vencimiento, monto, estado
  )
  SELECT
    c.tenant_id,
    c.id,
    c.cliente_id,
    cli.cobrador_id,
    date_trunc('month', p_periodo)::date,
    public.calcular_fecha_pago(p_periodo, c.dia_pago),
    p.precio_mensual,
    'pendiente'
  FROM public.contratos c
  JOIN public.planes   p   ON p.id = c.plan_id
  JOIN public.clientes cli ON cli.id = c.cliente_id
  WHERE c.tenant_id = p_tenant_id
    AND c.estado = 'activo'
    AND c.fecha_inicio <= public.calcular_fecha_pago(p_periodo, c.dia_pago)
    AND (c.fecha_fin IS NULL OR c.fecha_fin >= date_trunc('month', p_periodo)::date)
  ON CONFLICT (contrato_id, periodo) DO NOTHING;

  GET DIAGNOSTICS v_creadas = ROW_COUNT;
  RETURN v_creadas;
END;
$$;

-- Recrear el índice único de "un contrato activo por cliente+plan".
-- El original (0023) usaba `WHERE activo = true` — fue eliminado
-- implícitamente al dropear la columna `activo` en migración 0052.
DROP INDEX IF EXISTS public.contratos_unique_activo_por_cliente_plan;

CREATE UNIQUE INDEX contratos_unique_activo_por_cliente_plan
  ON public.contratos (cliente_id, plan_id)
  WHERE estado = 'activo';
