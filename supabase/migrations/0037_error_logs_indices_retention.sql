-- Migración 0037: índice por error_type + RPC de purga para retention.
--
-- Sprint 4 (BULK 3): índice en error_logs.error_type para que los
-- filtros por chip (flutter/zone/platform) en /super/logs no hagan
-- sequential scan cuando la tabla crezca.
--
-- Sprint 2 (BULK 3): RPC purge_error_logs para retention manual.
-- Guard: solo super_admin puede ejecutarla. Complementa el cron
-- diario (cuando se configure pg_cron).

-- Índice por tipo de error para filtros en el viewer.
CREATE INDEX IF NOT EXISTS idx_error_logs_error_type
  ON error_logs(error_type);

-- Índice por timestamp para el filtro de rango de fechas y la purga.
CREATE INDEX IF NOT EXISTS idx_error_logs_ts
  ON error_logs(ts);

-- RPC de purga: borra logs anteriores a la fecha dada.
-- Solo super_admin puede ejecutarla (guard via is_super_admin).
CREATE OR REPLACE FUNCTION purge_error_logs(p_before timestamptz)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin puede purgar error_logs';
  END IF;

  DELETE FROM public.error_logs WHERE ts < p_before;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;
