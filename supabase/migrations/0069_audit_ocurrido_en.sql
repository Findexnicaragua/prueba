-- 0069: Change Log Fase B — guardar la HORA REAL DEL DISPOSITIVO de cada acción.
--
-- Problema: hoy audit_log usa `created_at` (hora del server al sincronizar).
-- En offline-first, una acción hecha sin conexión se registra recién cuando
-- PowerSync sincroniza — la hora del historial NO refleja cuándo el cobrador
-- realmente hizo la acción.
--
-- Solución: columna uniforme `ocurrido_en timestamptz` en las tablas
-- auditadas. El cliente la setea con la hora de dispositivo en UTC
-- (DateTime.now().toUtc()). El trigger genérico la copia a
-- `audit_log.ocurrido_en`. El historial la muestra con `.toLocal()`.
--
-- Idempotente (IF NOT EXISTS / CREATE OR REPLACE). Solo corre en Postgres.
-- Envuelta en transacción: columnas + funciones + backfill todo-o-nada.

BEGIN;

-- 1. Columna en audit_log (sin default: la setea el trigger vía COALESCE).
ALTER TABLE public.audit_log ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;

-- 2. Columna en las 8 tablas de entidad SIN DEFAULT.
--    Motivo: `DEFAULT now()` es VOLATILE → Postgres reescribe físicamente
--    toda la tabla con lock ACCESS EXCLUSIVE (lento/bloqueante en tablas
--    grandes). Sin default, el ADD COLUMN es metadata-only (instantáneo).
--    El cliente setea ocurrido_en en cada write; el trigger hace COALESCE a
--    now() como fallback. El backfill de filas viejas es opcional (el display
--    lee audit_log.ocurrido_en, no estas columnas) — no hace falta.
ALTER TABLE public.pagos         ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.cuotas        ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.clientes      ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.contratos     ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.recibos       ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.cargos_extra  ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.visitas       ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;
ALTER TABLE public.fotos_cliente ADD COLUMN IF NOT EXISTS ocurrido_en timestamptz;

-- 3. audit_registrar: nuevo param p_ocurrido_en (con DEFAULT NULL → no rompe
--    callers existentes). Inserta ocurrido_en = COALESCE(p_ocurrido_en, now()).
CREATE OR REPLACE FUNCTION public.audit_registrar(
  p_tenant_id uuid,
  p_tabla text,
  p_registro_id uuid,
  p_campo text,
  p_valor_anterior jsonb,
  p_valor_nuevo jsonb,
  p_accion text DEFAULT 'update',
  p_ocurrido_en timestamptz DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, accion,
    user_id, user_rol, ocurrido_en
  ) VALUES (
    p_tenant_id, p_tabla, p_registro_id, p_campo,
    p_valor_anterior, p_valor_nuevo, p_accion,
    auth.uid(), public.current_user_rol(),
    COALESCE(p_ocurrido_en, now())
  );
END;
$$;

-- 4. audit_changelog_trg: computar el device time genéricamente desde
--    la columna ocurrido_en de la fila y pasarlo a audit_registrar.
--    NO se cambia la lógica de depth/guard ni los eventos.
CREATE OR REPLACE FUNCTION public.audit_changelog_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dev timestamptz;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_dev := (to_jsonb(NEW)->>'ocurrido_en')::timestamptz;
    PERFORM public.audit_registrar(
      NEW.tenant_id, TG_TABLE_NAME, NEW.id, NULL,
      to_jsonb(OLD), to_jsonb(NEW), 'update', v_dev
    );
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    v_dev := (to_jsonb(NEW)->>'ocurrido_en')::timestamptz;
    PERFORM public.audit_registrar(
      NEW.tenant_id, TG_TABLE_NAME, NEW.id, NULL,
      NULL, to_jsonb(NEW), 'create', v_dev
    );
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    v_dev := (to_jsonb(OLD)->>'ocurrido_en')::timestamptz;
    PERFORM public.audit_registrar(
      OLD.tenant_id, TG_TABLE_NAME, OLD.id, NULL,
      to_jsonb(OLD), NULL, 'delete', v_dev
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

-- 5. Backfill: las filas viejas del audit_log muestran su hora server
--    (mejor que null). Acotado e idempotente.
UPDATE public.audit_log SET ocurrido_en = created_at WHERE ocurrido_en IS NULL;

COMMIT;
