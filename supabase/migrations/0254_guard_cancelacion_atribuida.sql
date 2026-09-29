-- 0254_guard_cancelacion_atribuida.sql
--
-- Cancelar un contrato es el evento de plata mas grande que existe: mata todas
-- las cuotas futuras (trigger 0234) y deja la deuda viva. `pagos` y `cuotas`
-- tienen cada uno su CHECK de atribucion; cancelar NO tenia ninguno.
--
-- POR QUE UN TRIGGER Y NO UN CHECK (el plan pedia un CHECK NOT VALID; se
-- descarto al medirlo):
--   Un CHECK evalua el ESTADO de la fila, no la TRANSICION. `NOT VALID` salta
--   el escaneo inicial, pero el CHECK SIGUE disparando en cualquier UPDATE
--   futuro de una fila vieja. Y `propagate_cobrador_id_from_cliente` hace
--   `UPDATE contratos SET cobrador_id = ... WHERE cliente_id = NEW.id`, SIN
--   filtrar por estado -> toca tambien los cancelados.
--   Medido: hay 94 contratos cancelados sin atribucion completa, de 93
--   clientes, en las 3 empresas. Con un CHECK, reasignar de cobrador a
--   cualquiera de esos 93 clientes fallaria con check_violation. Un guard que
--   rompe una operacion diaria para proteger un dato historico esta al reves.
--
--   El trigger valida SOLO la transicion a 'cancelado'. Las filas que ya estan
--   canceladas no se miran nunca -> reasignar sigue funcionando igual.
--
-- DESGLOSE HISTORICO (2026-08-23): 189 cancelados, 95 completos, 94 sin actor.
-- De esos 94: 37 vacios del todo (legacy, sin fecha ni motivo) y 57 con fecha
-- y motivo pero sin actor, de una limpieza SQL manual del 19/08. NINGUN camino
-- de la app deja el actor vacio.
--
-- LOS DOS UNICOS CAMINOS QUE CANCELAN, verificados uno por uno:
--   1. `contratos_repo.cancelarContrato` (Dart) escribe los tres campos. Sus
--      dos llamadores pasan motivo, y la UI corta antes con
--      `res.motivo.isEmpty` -> la app NO puede mandar un motivo vacio.
--   2. `super_admin_baja_deuda_impl` (0244) setea actor y motivo.
--   O sea: este guard no puede romper nada que funcione hoy. Lo que atrapa es
--   una regresion futura y el proximo script SQL manual - con el guard puesto,
--   el del 19/08 habria fallado, que es exactamente lo deseado.
--
-- ERRCODE 23514 A PROPOSITO: el connector lo trata como NO retryable
-- (`esCodigoNoRetryable`: todo `23*`), asi que un write offline sin atribucion
-- no se reintenta para siempre - se descarta y queda como aviso en la bandeja,
-- con su payload completo para reconstruirlo. Falla ruidosa, no silenciosa.
--
-- `cancelado_en` SI se autocompleta: que falte solo la marca de tiempo no
-- justifica rechazar una baja legitima, y `now()` del server es mejor dato que
-- el rechazo. Actor y motivo NO se inventan: no hay de donde sacarlos, y
-- rellenarlos con un valor de relleno seria peor que dejarlos vacios.

CREATE OR REPLACE FUNCTION public.contratos_guard_cancelacion_atribuida()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.estado IS DISTINCT FROM 'cancelado' THEN
    RETURN NEW;
  END IF;

  -- Ya estaba cancelado: esto es otra cosa (reasignacion de cobrador, notas,
  -- lo que sea). No es la transicion, no se valida. Esta rama es la que hace
  -- que los 94 historicos sigan siendo editables.
  IF TG_OP = 'UPDATE' AND OLD.estado = 'cancelado' THEN
    RETURN NEW;
  END IF;

  -- Lo mismo, por el camino del UPSERT. PowerSync sube los `put` con
  -- `table.upsert(...)`, que PostgREST traduce a INSERT ... ON CONFLICT DO
  -- UPDATE, y el BEFORE INSERT dispara ANTES de que se detecte el conflicto:
  -- TG_OP dice 'INSERT' y OLD no existe, aunque la fila SI este en la tabla.
  -- Sin esta rama, un re-put de cualquiera de los 94 cancelados historicos
  -- rebotaria como si fuera una baja nueva sin atribuir. Es lookup por PK.
  IF TG_OP = 'INSERT'
     AND EXISTS (SELECT 1 FROM public.contratos c
                  WHERE c.id = NEW.id AND c.estado = 'cancelado') THEN
    RETURN NEW;
  END IF;

  IF NEW.cancelado_en IS NULL THEN
    NEW.cancelado_en := now();
  END IF;

  IF NEW.cancelado_por IS NULL
     OR COALESCE(btrim(NEW.motivo_cancelacion), '') = '' THEN
    RAISE EXCEPTION
      'Para dar de baja un contrato hay que registrar quién la hace y por qué.'
      USING errcode = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_contratos_guard_cancelacion ON public.contratos;
DROP TRIGGER IF EXISTS a_trg_contratos_guard_cancelacion ON public.contratos;

-- Nombre con prefijo `a_` para que corra ANTES que el resto de los BEFORE de
-- la tabla (Postgres los dispara por orden alfabetico): si la baja no esta
-- atribuida, conviene frenarla antes de que otro trigger empiece a derivar.
CREATE TRIGGER a_trg_contratos_guard_cancelacion
  BEFORE INSERT OR UPDATE ON public.contratos
  FOR EACH ROW
  EXECUTE FUNCTION public.contratos_guard_cancelacion_atribuida();
