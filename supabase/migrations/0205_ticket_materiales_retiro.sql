-- =========================================================================
-- 0205 — Retiro de equipo desde la orden (Fase 2, el técnico)
--
-- Pedido del nuevo dueño (audio 7): "cuando retire un cliente […] lo va a
-- retirar del cliente y se le tiene que buscar en el inventario de los
-- clientes". Hoy el técnico puede CONSUMIR material desde la orden pero no
-- puede DEVOLVER lo que desinstala.
--
-- POR QUÉ POR ACÁ Y NO CON UNA ESCRITURA DEL CLIENTE: el rol `tecnico` NO
-- tiene RLS de UPDATE sobre `inv_seriales` (`inv_update` exige
-- `is_admin_or_cobranza()`). Un botón que escriba inventario desde su app se
-- vería OK offline y lo rechazaría el server al sincronizar. En cambio SÍ
-- puede insertar en `ticket_materiales` (`tm_insert` usa `is_ticket_staff()`),
-- y el trigger SECURITY DEFINER mueve el inventario por él. Es exactamente el
-- camino que ya usa el consumo desde 0106.
--
-- 1. `ticket_materiales.tipo` — 'consumo' (lo de siempre) | 'retiro' (nuevo).
-- 2. `ticket_materiales_consumo()` — se le antepone la rama del retiro.
--    El cuerpo del CONSUMO queda IDÉNTICO al vigente en la DB (partido de
--    `pg_get_functiondef`, no de la migración 0106 ni de memoria — lección
--    0151→0152: reescribir desde el cuerpo viejo pierde llamadas en silencio).
--
-- Aditivo: `tipo` nace con DEFAULT 'consumo', así TODA fila existente y toda
-- fila que escriba una app v0.28.0 (que no conoce la columna) sigue el camino
-- de siempre. No se bumpea `_dbWipeVersion`.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Discriminador de la fila
-- -------------------------------------------------------------------------
ALTER TABLE public.ticket_materiales
  ADD COLUMN IF NOT EXISTS tipo text NOT NULL DEFAULT 'consumo';

ALTER TABLE public.ticket_materiales
  DROP CONSTRAINT IF EXISTS ticket_materiales_tipo_check;
ALTER TABLE public.ticket_materiales
  ADD CONSTRAINT ticket_materiales_tipo_check
  CHECK (tipo IN ('consumo','retiro'));

-- -------------------------------------------------------------------------
-- 2. Trigger: rama de retiro + consumo intacto
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ticket_materiales_consumo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cliente uuid;
  v_existe  boolean := false;
BEGIN
  -- Defensa cross-tenant (SECURITY DEFINER saltea RLS → validamos a mano que TODO
  -- FK pertenezca a NEW.tenant_id; la FK sola sólo garantiza existencia, no co-
  -- tenencia, y NEW.tenant_id está anclado por la RLS WITH CHECK al tenant real
  -- del que escribe). Sin esto, una fila podría referenciar recursos de otro tenant.
  SELECT cliente_id, true INTO v_cliente, v_existe
    FROM public.tickets
   WHERE id = NEW.ticket_id AND tenant_id = NEW.tenant_id;
  IF NOT COALESCE(v_existe, false) THEN
    RAISE EXCEPTION 'Ticket % no pertenece al tenant %', NEW.ticket_id, NEW.tenant_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.inv_productos
                  WHERE id = NEW.producto_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Producto % no pertenece al tenant %', NEW.producto_id, NEW.tenant_id;
  END IF;
  IF NEW.ubicacion_origen_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.inv_ubicaciones
         WHERE id = NEW.ubicacion_origen_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Ubicación % no pertenece al tenant %', NEW.ubicacion_origen_id, NEW.tenant_id;
  END IF;
  IF NEW.serial_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.inv_seriales
         WHERE id = NEW.serial_id AND tenant_id = NEW.tenant_id) THEN
    RAISE EXCEPTION 'Serial % no pertenece al tenant %', NEW.serial_id, NEW.tenant_id;
  END IF;

  -- =======================================================================
  -- RAMA NUEVA (0205): RETIRO — el equipo vuelve del cliente a revisión.
  -- Sale por RETURN antes de tocar el camino del consumo, que queda igual.
  -- =======================================================================
  IF NEW.tipo = 'retiro' THEN
    -- El retiro es de equipo serializado: el granel consumido no "vuelve".
    IF NEW.serial_id IS NULL THEN
      RETURN NEW;
    END IF;
    -- Guards espejo del consumo:
    --  (a) sólo se retira lo que está REALMENTE instalado en el cliente de ESTE
    --      ticket → un insert crafteado no puede arrancarle el equipo a otro;
    --  (b) idempotencia del duplicado offline — el 2º retiro del mismo serial
    --      ya no lo encuentra 'instalado' → no-op sin movimiento duplicado.
    -- Si el ticket no tiene cliente (outage), v_cliente es NULL y no matchea
    -- nada: un retiro sin cliente es un no-op, no un error.
    UPDATE public.inv_seriales
       SET estado = 'en_revision', cliente_id = NULL, contrato_id = NULL,
           ubicacion_id = NULL
     WHERE id = NEW.serial_id AND tenant_id = NEW.tenant_id
       AND estado = 'instalado' AND cliente_id IS NOT DISTINCT FROM v_cliente;
    IF NOT FOUND THEN
      RETURN NEW; -- ya retirado / no estaba instalado en este cliente
    END IF;
    -- Movimiento NEUTRO en el ledger: sin origen NI destino. Un 'instalado' ya
    -- fue debitado de su ubicación al instalarse (su `ubicacion_id` es NULL), y
    -- `en_revision` todavía no aterrizó en ninguna bodega. El +1 lo hace recién
    -- `devolverEquipo` cuando aprueba la revisión. Mandar un origen acá dejaría
    -- ese stock en negativo; mandar un destino lo inflaría (ver 0204).
    INSERT INTO public.inv_movimientos
      (id, tenant_id, tipo, producto_id, serial_id, cantidad,
       cliente_id, ticket_id, motivo, hecho_por, ocurrido_en, created_at)
    VALUES
      (gen_random_uuid(), NEW.tenant_id, 'devolucion', NEW.producto_id,
       NEW.serial_id, NEW.cantidad, v_cliente, NEW.ticket_id,
       'Retirado en ticket → revisión', NEW.hecho_por, NEW.ocurrido_en, now());
    RETURN NEW;
  END IF;

  -- 1. Serializado: el serial pasa a 'instalado' en el cliente del ticket.
  --    Guards: estado='en_stock' (no pisa un serial ya instalado/dado de baja) +
  --    ubicacion_id == ubicacion_origen_id declarada. Este 2º guard cierra dos cosas:
  --    (a) custodia intra-tenant — sólo consumís un serial de DONDE realmente está
  --        (la UI siempre setea ubicacion_origen_id = la ubicación del serial), así un
  --        insert crafteado con un serial ajeno + otra ubicación no lo instala;
  --    (b) idempotencia del dup offline — el 2º consumo del mismo serial ya no está
  --        en_stock allí → no consume.
  --    Si no consumió nada → no-op SIN registrar movimiento (offline-safe, sin RAISE
  --    para no trabar la cola de upload de PowerSync). La fila ticket_materiales queda
  --    igual como registro del intento.
  IF NEW.serial_id IS NOT NULL THEN
    UPDATE public.inv_seriales
       SET estado = 'instalado', cliente_id = v_cliente, ubicacion_id = NULL
     WHERE id = NEW.serial_id AND tenant_id = NEW.tenant_id AND estado = 'en_stock'
       AND ubicacion_id IS NOT DISTINCT FROM NEW.ubicacion_origen_id;
    IF NOT FOUND THEN
      RETURN NEW; -- ya instalado / no está en el origen → no duplicamos el movimiento
    END IF;
  END IF;

  -- 2. Movimiento de consumo (descuenta del origen = custodia/ubicación). Serial:
  --    sólo si se consumió arriba. Granel (serial NULL): siempre — el stock granel
  --    tolera ir negativo si dos devices descuentan offline (por diseño; se reconcilia
  --    en el ledger append-only).
  INSERT INTO public.inv_movimientos
    (id, tenant_id, tipo, producto_id, serial_id, cantidad,
     ubicacion_origen_id, cliente_id, ticket_id, costo_unitario,
     motivo, hecho_por, ocurrido_en, created_at)
  VALUES
    (gen_random_uuid(), NEW.tenant_id, 'consumo', NEW.producto_id, NEW.serial_id,
     NEW.cantidad, NEW.ubicacion_origen_id, v_cliente, NEW.ticket_id,
     NEW.costo_unit_snapshot, 'Consumo en ticket', NEW.hecho_por,
     NEW.ocurrido_en, now());

  RETURN NEW;
END;
$function$;

COMMIT;

-- =========================================================================
-- VERIFICACIÓN POR CONTENIDO. Las 4 filas deben dar ok = true.
-- =========================================================================
SELECT 'ticket_materiales.tipo existe con default consumo' AS chequeo,
       column_default LIKE '%consumo%' AND is_nullable = 'NO' AS ok
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='ticket_materiales' AND column_name='tipo'
UNION ALL
SELECT 'el CHECK admite retiro',
       pg_get_constraintdef(oid) LIKE '%retiro%'
  FROM pg_constraint
 WHERE conrelid='public.ticket_materiales'::regclass
   AND conname='ticket_materiales_tipo_check'
UNION ALL
SELECT 'el trigger tiene la rama de retiro',
       pg_get_functiondef(oid) LIKE '%en_revision%'
  FROM pg_proc WHERE proname='ticket_materiales_consumo'
UNION ALL
SELECT 'el camino del consumo sigue intacto',
       pg_get_functiondef(oid) LIKE '%Consumo en ticket%'
   AND pg_get_functiondef(oid) LIKE '%ubicacion_id IS NOT DISTINCT FROM NEW.ubicacion_origen_id%'
  FROM pg_proc WHERE proname='ticket_materiales_consumo';
