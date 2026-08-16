-- 0105: SLA con pausa EXACTA por `en_espera` (Fase 3, completa la pausa del PLAN).
--
-- 3A dejó la pausa aproximada (solo pausa si el ticket está en espera AHORA). Acá
-- la hacemos exacta: acumulamos el tiempo total que el ticket estuvo en `en_espera`
-- en `tickets.segundos_pausado`, y el SLA derivado en el cliente lo suma al plazo.
--
-- OFFLINE-AWARE: el trigger usa `NEW.ocurrido_en` (device-time de la transición),
-- NO `now()` server — así el cómputo es correcto aunque la transición se haya hecho
-- offline y sincronice más tarde. `en_espera_desde` guarda el device-time de entrada
-- a en_espera; al salir, suma (salida.ocurrido_en − en_espera_desde) a los segundos.
--
-- Idempotente + transaccional. NO deployado aún (3A pendiente) → schema v21→v22.

BEGIN;

ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS segundos_pausado integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS en_espera_desde timestamptz;

-- Re-crear el trigger de transición (0103) sumándole la contabilidad de la pausa.
-- Sigue siendo BEFORE UPDATE OF estado, así que puede mutar NEW.
CREATE OR REPLACE FUNCTION public.tickets_validar_transicion() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.estado = OLD.estado THEN RETURN NEW; END IF;

  -- 1. Validar la transición (matriz, igual que 0103). "server gana".
  IF NOT (
    (OLD.estado = 'abierto'     AND NEW.estado IN ('asignado','en_progreso','cancelado')) OR
    (OLD.estado = 'asignado'    AND NEW.estado IN ('en_progreso','en_espera','abierto','cancelado')) OR
    (OLD.estado = 'en_progreso' AND NEW.estado IN ('en_espera','resuelto','asignado','cancelado')) OR
    (OLD.estado = 'en_espera'   AND NEW.estado IN ('en_progreso','resuelto','cancelado')) OR
    (OLD.estado = 'resuelto'    AND NEW.estado IN ('cerrado','reabierto')) OR
    (OLD.estado = 'reabierto'   AND NEW.estado IN ('asignado','en_progreso','en_espera','resuelto','cancelado')) OR
    (OLD.estado = 'cerrado'     AND NEW.estado IN ('reabierto')) OR
    (OLD.estado = 'cancelado'   AND NEW.estado IN ('reabierto'))
  ) THEN
    RAISE EXCEPTION 'Transición de estado inválida: % → %', OLD.estado, NEW.estado;
  END IF;

  -- 2. Contabilidad de la pausa de SLA (device-time → offline-safe).
  IF NEW.estado = 'en_espera' AND OLD.estado <> 'en_espera' THEN
    NEW.en_espera_desde := NEW.ocurrido_en;
  ELSIF OLD.estado = 'en_espera' AND NEW.estado <> 'en_espera' THEN
    NEW.segundos_pausado := COALESCE(OLD.segundos_pausado, 0)
      + GREATEST(0, EXTRACT(EPOCH FROM
          (NEW.ocurrido_en - COALESCE(OLD.en_espera_desde, NEW.ocurrido_en)))::int);
    NEW.en_espera_desde := NULL;
  END IF;

  RETURN NEW;
END;
$$;
-- El trigger trg_tickets_validar_transicion (0103) ya apunta a esta función.

COMMIT;
