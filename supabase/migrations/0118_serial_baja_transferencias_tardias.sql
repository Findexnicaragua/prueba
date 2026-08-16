-- 0118 — Restricción de transiciones de inv_seriales: baja es terminal, y se bloquean transferencias tardías sobre instalado.
-- M19 — Auto-generación de eventos de ticket en el servidor para evitar eventos huérfanos.

BEGIN;

-- 1. Actualizar la función trg_inv_seriales_guard_transicion para incluir:
--    a) si old.estado = 'baja' y new.estado <> 'baja', error (estado terminal).
--    b) si old.estado = 'instalado' y new.ubicacion_id is distinct from old.ubicacion_id y new.estado <> 'en_stock', error (transferencia tardía).
CREATE OR REPLACE FUNCTION public.inv_seriales_guard_transicion_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- 'baja' es un estado terminal: no se puede salir de 'baja'
  IF OLD.estado = 'baja' AND NEW.estado IS DISTINCT FROM OLD.estado THEN
    RAISE EXCEPTION
      'El equipo % está dado de baja (estado terminal) y no se puede modificar su estado', OLD.serial;
  END IF;

  -- pasar a 'instalado' exige venir de 'en_stock'
  IF NEW.estado = 'instalado'
     AND OLD.estado IS DISTINCT FROM NEW.estado
     AND OLD.estado <> 'en_stock' THEN
    RAISE EXCEPTION
      'El equipo % no está en stock (estado actual: %)', OLD.serial, OLD.estado;
  END IF;

  -- un 'instalado' no cambia de cliente sin pasar por stock
  IF NEW.estado = 'instalado' AND OLD.estado = 'instalado'
     AND NEW.cliente_id IS DISTINCT FROM OLD.cliente_id THEN
    RAISE EXCEPTION
      'El equipo % ya está instalado en otro cliente; devolvelo a stock primero',
      OLD.serial;
  END IF;

  -- si old.estado = 'instalado' y cambia ubicacion_id, exige pasar a 'en_stock' (bloquea transferencias tardías)
  IF OLD.estado = 'instalado'
     AND NEW.ubicacion_id IS DISTINCT FROM OLD.ubicacion_id
     AND NEW.estado <> 'en_stock' THEN
    RAISE EXCEPTION
      'No se puede transferir el equipo % si está instalado (estado actual: %)',
      OLD.serial, OLD.estado;
  END IF;

  RETURN NEW;
END $$;

-- 2. (M19) Auto-generación de ticket_eventos en el servidor.
CREATE OR REPLACE FUNCTION public.tickets_eventos_auto_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cobrador_nombre text;
  v_hecho_por uuid;
BEGIN
  v_hecho_por := COALESCE(auth.uid(), NEW.creado_por);

  IF TG_OP = 'INSERT' THEN
    -- Evento: creado
    INSERT INTO public.ticket_eventos (
      id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
      comentario, hecho_por, ocurrido_en, created_at
    ) VALUES (
      gen_random_uuid(), NEW.tenant_id, NEW.id, 'creado', NULL, NEW.estado,
      NULL, v_hecho_por, NEW.ocurrido_en, NEW.created_at
    );

    -- Evento: asignado (si se crea asignado)
    IF NEW.asignado_a IS NOT NULL THEN
      SELECT nombre INTO v_cobrador_nombre FROM public.cobradores WHERE id = NEW.asignado_a;
      INSERT INTO public.ticket_eventos (
        id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
        comentario, hecho_por, ocurrido_en, created_at
      ) VALUES (
        gen_random_uuid(), NEW.tenant_id, NEW.id, 'asignado', 'abierto', NEW.estado,
        'Asignado a ' || COALESCE(v_cobrador_nombre, 'desconocido'), v_hecho_por, NEW.ocurrido_en, NEW.created_at
      );
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Evento: cambio de estado
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
      INSERT INTO public.ticket_eventos (
        id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
        comentario, hecho_por, ocurrido_en, created_at
      ) VALUES (
        gen_random_uuid(), NEW.tenant_id, NEW.id,
        CASE NEW.estado
          WHEN 'cancelado' THEN 'cancelado'
          WHEN 'cerrado' THEN 'cerrado'
          WHEN 'reabierto' THEN 'reabierto'
          ELSE 'cambio_estado'
        END,
        OLD.estado, NEW.estado,
        NULL, v_hecho_por, NEW.ocurrido_en, now()
      );
    END IF;

    -- Evento: reasignado
    IF NEW.asignado_a IS DISTINCT FROM OLD.asignado_a THEN
      IF NEW.asignado_a IS NULL THEN
        v_cobrador_nombre := 'Sin asignar';
      ELSE
        SELECT nombre INTO v_cobrador_nombre FROM public.cobradores WHERE id = NEW.asignado_a;
        v_cobrador_nombre := 'Asignado a ' || COALESCE(v_cobrador_nombre, 'desconocido');
      END IF;

      INSERT INTO public.ticket_eventos (
        id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
        comentario, hecho_por, ocurrido_en, created_at
      ) VALUES (
        gen_random_uuid(), NEW.tenant_id, NEW.id, 'asignado', OLD.estado, NEW.estado,
        v_cobrador_nombre, v_hecho_por, NEW.ocurrido_en, now()
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tickets_eventos_auto ON public.tickets;
CREATE TRIGGER trg_tickets_eventos_auto
  AFTER INSERT OR UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_eventos_auto_trg();

COMMIT;
