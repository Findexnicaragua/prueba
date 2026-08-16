-- 0106: Tickets Fase 3C — materiales consumidos en un ticket (engancha INVENTARIO).
--
-- El técnico (o admin) registra el material que instaló/usó en un ticket. El
-- descuento de stock es 100% SERVER-SIDE (decisión D1 del FASE3-PLAN): el técnico
-- NO tiene permiso directo sobre inv_* (esas policies son is_admin_or_cobranza),
-- así que un trigger SECURITY DEFINER hace el inv_movimientos tipo 'consumo' y,
-- si es serializado, marca el serial 'instalado' en el cliente del ticket.
--
-- OFFLINE-FIRST + "server gana": el técnico crea la fila `ticket_materiales`
-- offline (un simple append); al sincronizar corre el trigger y proyecta el
-- inventario. NO bloquea por stock insuficiente (tolerancia negativa offline,
-- igual que el resto del inventario — el ledger es la verdad y se concilia).
--
-- TRAZABILIDAD: la fila `ticket_materiales` ES la acción auditada del usuario
-- (insert a depth 0 → audit a depth 1, dispara). El inv_movimientos de consumo y
-- el UPDATE del serial los crea el trigger a depth 1 → su audit caería a depth 2 →
-- el guard `pg_trigger_depth() < 2` los saltea a propósito (son PROYECCIÓN
-- derivada, no acción de usuario, como `cuota.monto_pagado`). El consumo se
-- surfacea en la bitácora del ticket y en el historial cuna-a-tumba del serial
-- (HistorialSerialWidget une `ticket_materiales`).
--
-- Idempotente + transaccional. NO deployado aún → schema v22→v23.

BEGIN;

-- 1. Materiales consumidos por ticket. APPEND-ONLY (read + insert; corregir un
--    error = flujo inverso futuro, NO update/delete — como el ledger de inventario).
CREATE TABLE IF NOT EXISTS public.ticket_materiales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  ticket_id uuid NOT NULL REFERENCES public.tickets(id) ON DELETE CASCADE,
  producto_id uuid NOT NULL REFERENCES public.inv_productos(id) ON DELETE RESTRICT,
  serial_id uuid REFERENCES public.inv_seriales(id) ON DELETE SET NULL,
  cantidad numeric(12,2) NOT NULL DEFAULT 1 CHECK (cantidad > 0),
  ubicacion_origen_id uuid REFERENCES public.inv_ubicaciones(id) ON DELETE SET NULL,
  costo_unit_snapshot numeric(12,2),
  hecho_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  ocurrido_en timestamptz NOT NULL DEFAULT now(),   -- device-time (offline)
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_materiales_by_ticket ON public.ticket_materiales (ticket_id);
CREATE INDEX IF NOT EXISTS ticket_materiales_by_serial ON public.ticket_materiales (serial_id);

-- 2. FK de inv_movimientos.ticket_id (existía sin FK desde 0101; ahora se usa).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inv_mov_ticket_fk') THEN
    ALTER TABLE public.inv_movimientos
      ADD CONSTRAINT inv_mov_ticket_fk FOREIGN KEY (ticket_id)
      REFERENCES public.tickets(id) ON DELETE SET NULL;
  END IF;
END $$;

-- 3. RLS: read = miembro del tenant; insert = staff de tickets (incluye TÉCNICO,
--    a diferencia de inv_* que es is_admin_or_cobranza). Append-only.
ALTER TABLE public.ticket_materiales ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "tm_read"   ON public.ticket_materiales;
DROP POLICY IF EXISTS "tm_insert" ON public.ticket_materiales;
DROP POLICY IF EXISTS "super_admin_all" ON public.ticket_materiales;
CREATE POLICY "tm_read"   ON public.ticket_materiales FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "tm_insert" ON public.ticket_materiales FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_ticket_staff());
CREATE POLICY "super_admin_all" ON public.ticket_materiales
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- 4. Audit del change-log (la fila ticket_materiales = la acción del usuario).
DROP TRIGGER IF EXISTS trg_changelog_ticket_materiales ON public.ticket_materiales;
CREATE TRIGGER trg_changelog_ticket_materiales
  AFTER INSERT OR UPDATE OR DELETE ON public.ticket_materiales
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- 5. Trigger de CONSUMO (D1, SECURITY DEFINER → puede escribir inv_* aunque el
--    técnico no tenga permiso directo). Descuenta del origen y, si es serial,
--    lo marca 'instalado' en el cliente del ticket.
CREATE OR REPLACE FUNCTION public.ticket_materiales_consumo() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
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
$$;

DROP TRIGGER IF EXISTS trg_ticket_materiales_consumo ON public.ticket_materiales;
CREATE TRIGGER trg_ticket_materiales_consumo
  AFTER INSERT ON public.ticket_materiales
  FOR EACH ROW EXECUTE FUNCTION public.ticket_materiales_consumo();

COMMIT;
