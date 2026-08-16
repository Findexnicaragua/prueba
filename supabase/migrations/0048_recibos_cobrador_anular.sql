-- 0048: Permitir al cobrador anular sus propios recibos.
-- El trigger de 0022 bloqueaba cambios a anulado/anulado_en/anulado_por
-- en recibos para cobradores. Ahora permitimos esos campos además de
-- los de impresión. El setting cobrador_anula_cobros controla la UI.

CREATE OR REPLACE FUNCTION public.recibos_check_cobrador_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rol text;
BEGIN
  v_rol := public.current_user_rol();
  IF v_rol = 'cobrador' THEN
    IF new.prefijo          IS DISTINCT FROM old.prefijo          OR
       new.correlativo      IS DISTINCT FROM old.correlativo      OR
       new.numero_completo  IS DISTINCT FROM old.numero_completo  OR
       new.pago_id          IS DISTINCT FROM old.pago_id          OR
       new.cobrador_id      IS DISTINCT FROM old.cobrador_id      OR
       new.tenant_id        IS DISTINCT FROM old.tenant_id
    THEN
      RAISE EXCEPTION 'cobrador solo puede modificar campos de impresión y anulación en recibos';
    END IF;
  END IF;
  RETURN new;
END;
$$;
