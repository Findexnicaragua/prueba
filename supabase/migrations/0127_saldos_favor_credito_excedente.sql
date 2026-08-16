-- 0127 — Crédito por excedente al suspender / cancelar (saldos a favor).
--
-- QUÉ: cuando un cliente pagó por adelantado servicio que NO se va a prestar
-- (suspensión/cancelación con cuotas pagadas a futuro o el sobre-pago del mes
-- en curso), el admin/admin_cobranza decide qué hacer con ese EXCEDENTE:
--   · ACREDITAR  → queda como saldo a favor del CLIENTE (cualquier contrato suyo).
--   · DEVOLVER   → se le devuelve en efectivo (recibo de devolución; sale de caja).
--   · CONDONAR   → el cliente cede el saldo (queda en caja, pero AUDITADO).
-- El saldo a favor NO caduca. Lo decide admin/admin_cobranza; el cobrador no.
-- Gateado por setting super-only `cobranza.credito_excedente` (default ON);
-- en OFF la suspensión/cancelación se comportan como antes (excedente perdido).
--
-- DECISIÓN DE MODELO (validación adversarial, ver BITACORA 2026-06-18):
--   El crédito NO es un `pago`. Modelarlo como pago (metodo='credito') rompía
--   ~15 agregados de caja y 5+ invariantes. En su lugar:
--     - El crédito vive en la tabla nueva `saldos_favor` (libro append-only).
--     - APLICARLO a una cuota = un `cargos_extra` origen='credito'
--       tipo='credito_aplicado' (RESTA del saldo canónico, igual que un
--       descuento) → NO toca `pagos`, NO infla recaudado ni arqueo.
--   Invariante #4 se PARTE en dos (ver AGENTS.md):
--     recaudado_caja = SUM(pagos no anulados) − SUM(saldos_favor devuelto)
--     cobertura_cuota = monto + cargos_neto − monto_pagado (fórmula canónica).
--
-- R10: tabla nueva con tenant_id + RLS + super_admin_all A MANO + audit +
-- schema.dart + bump _schemaVersion + sync rules. Append-only (sin UPDATE/DELETE
-- para usuarios del tenant; "deshacer" = fila nueva tipo='revertido').

-- =========================================================================
-- 1. Tabla saldos_favor (libro append-only de movimientos de crédito)
-- =========================================================================
-- saldo_disponible(cliente) = SUM(+acreditado) − SUM(aplicado+devuelto+
--   condonado+revertido). TODA disposición arranca con una fila 'acreditado';
--   devolver/condonar agregan su fila que la neutraliza (net 0); acreditar la
--   deja parada hasta que se aplique (o se revierta/devuelva después).
CREATE TABLE public.saldos_favor (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  contrato_id uuid NOT NULL REFERENCES public.contratos(id) ON DELETE CASCADE,

  -- 'acreditado' (origen, +) / 'aplicado' (a una cuota, −) / 'devuelto' (efectivo
  -- a caja, −) / 'condonado' (cede, −) / 'revertido' (deshacer acreditación, −).
  tipo text NOT NULL CHECK (tipo IN
    ('acreditado','aplicado','devuelto','condonado','revertido')),
  -- Siempre POSITIVO; el signo lo da el tipo.
  monto numeric(12,2) NOT NULL CHECK (monto >= 0),

  -- Trazabilidad (A6/A8 de la validación: revert-aware + anti doble-acreditación).
  cuota_id uuid REFERENCES public.cuotas(id) ON DELETE SET NULL,        -- origen (acreditado) o destino (aplicado)
  origen_evento_id uuid,                                                -- FK lógica a contrato_suspensiones.id (suspensión); NULL en cancelación
  cargo_id uuid REFERENCES public.cargos_extra(id) ON DELETE SET NULL,  -- el cargos_extra creado al APLICAR
  recibo_id uuid REFERENCES public.recibos(id) ON DELETE SET NULL,      -- recibo de devolución (solo tipo='devuelto')

  -- Solo tipo='devuelto': a qué caja/cobrador se resta y EN QUÉ DÍA (local-naive
  -- Nicaragua, análogo a pagos.fecha_pago — el arqueo bucketea por acá, NUNCA
  -- por ocurrido_en UTC, ver regla 1b de AGENTS.md / hallazgo A3).
  cobrador_id uuid REFERENCES public.cobradores(id),
  fecha_devolucion date,

  motivo text,
  creado_por uuid NOT NULL REFERENCES public.cobradores(id),
  ocurrido_en timestamptz NOT NULL,                 -- device-time UTC (.toUtc()) — audit, NO para bucketing de caja
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX saldos_favor_by_cliente ON public.saldos_favor (tenant_id, cliente_id);
CREATE INDEX saldos_favor_by_evento  ON public.saldos_favor (origen_evento_id);
CREATE INDEX saldos_favor_by_cuota   ON public.saldos_favor (cuota_id);
CREATE INDEX saldos_favor_devueltos  ON public.saldos_favor (tenant_id, cobrador_id, fecha_devolucion)
  WHERE tipo = 'devuelto';

-- =========================================================================
-- 2. Helper: saldo a favor DISPONIBLE de un cliente (todos sus contratos)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.saldo_favor_disponible(p_cliente_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(
    CASE WHEN tipo = 'acreditado' THEN monto ELSE -monto END
  ), 0)::numeric
  FROM public.saldos_favor
  WHERE cliente_id = p_cliente_id;
$$;

-- =========================================================================
-- 3. Trigger anti-sobregiro (A5: "server gana" ante carrera offline)
-- =========================================================================
-- Dos dispositivos podrían aplicar/devolver el mismo crédito antes de
-- sincronizar → saldo_disponible < 0 = el ISP regala plata. El server rechaza
-- la segunda. El cliente espeja optimista; el rechazo rebota por sync.
CREATE OR REPLACE FUNCTION public.saldos_favor_no_sobregiro_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Solo los movimientos que RESTAN pueden sobregirar. 'acreditado' suma.
  IF NEW.tipo IN ('aplicado','devuelto','condonado','revertido') THEN
    -- saldo_favor_disponible aún NO ve a NEW (BEFORE INSERT): es el disponible
    -- previo. Dentro de la misma transacción ya ve las filas insertadas antes
    -- (p.ej. el 'acreditado' que precede a un 'devuelto'/'condonado').
    IF public.saldo_favor_disponible(NEW.cliente_id) < NEW.monto - 0.005 THEN
      RAISE EXCEPTION
        'Saldo a favor insuficiente: disponible %, intentó % (cliente %)',
        public.saldo_favor_disponible(NEW.cliente_id), NEW.monto, NEW.cliente_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_saldos_favor_no_sobregiro
  BEFORE INSERT ON public.saldos_favor
  FOR EACH ROW EXECUTE FUNCTION public.saldos_favor_no_sobregiro_trg();

-- =========================================================================
-- 4. RLS — read: miembro del tenant; insert: admin/admin_cobranza;
--    super_admin_all A MANO. SIN policies UPDATE/DELETE = append-only para los
--    usuarios del tenant (deshacer = fila 'revertido').
-- =========================================================================
ALTER TABLE public.saldos_favor ENABLE ROW LEVEL SECURITY;

CREATE POLICY "saldos_favor_read" ON public.saldos_favor
  FOR SELECT USING (tenant_id = public.current_tenant_id());
CREATE POLICY "saldos_favor_insert" ON public.saldos_favor
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.saldos_favor
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- =========================================================================
-- 5. Audit log (toda entidad editable tiene historial; guard depth < 2)
-- =========================================================================
CREATE TRIGGER trg_changelog_saldos_favor
  AFTER INSERT OR UPDATE OR DELETE ON public.saldos_favor
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- =========================================================================
-- 6. cargos_extra: el vehículo de la APLICACIÓN del crédito
-- =========================================================================
-- 6a. Nuevo origen 'credito' (esquiva el guard de ajustes, que solo dispara con
--     origen='ajuste', y el de promo/ajuste de 0117). Reemplaza el CHECK con
--     nombre estable (igual que 0119 hizo con 'puente').
ALTER TABLE public.cargos_extra DROP CONSTRAINT IF EXISTS cargos_extra_origen_check;
ALTER TABLE public.cargos_extra
  ADD CONSTRAINT cargos_extra_origen_check
  CHECK (origen IN ('cobro','ajuste','promo','liquidacion','puente','credito'));

-- 6b. Nuevo tipo 'credito_aplicado' (RESTA del saldo, como un descuento, pero
--     SEPARADO para no contaminar reportes de descuentos). El CHECK del tipo es
--     inline (nombre autogenerado) → lo ubicamos por pg_constraint.
DO $$
DECLARE
  v_con text;
BEGIN
  SELECT c.conname INTO v_con
    FROM pg_constraint c
   WHERE c.conrelid = 'public.cargos_extra'::regclass
     AND c.contype = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%tipo%'
     AND pg_get_constraintdef(c.oid) ILIKE '%descuento_monto%'
     AND pg_get_constraintdef(c.oid) ILIKE '%reconexion%'
   LIMIT 1;
  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.cargos_extra DROP CONSTRAINT %I', v_con);
  END IF;
END $$;

ALTER TABLE public.cargos_extra
  ADD CONSTRAINT cargos_extra_tipo_check
  CHECK (tipo IN (
    'descuento_monto','descuento_porcentaje','reconexion','otro','credito_aplicado'));

-- 6c. calcular_cargos_neto: 'credito_aplicado' resta (como los descuentos).
--     Reproduce el cuerpo vigente (0023), incluido SECURITY DEFINER +
--     search_path, + el tipo nuevo. (Espeja `cuotas.cargos_neto`.)
CREATE OR REPLACE FUNCTION public.calcular_cargos_neto(p_cuota_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(
    CASE
      WHEN tipo IN ('reconexion','otro') THEN monto
      WHEN tipo IN ('descuento_monto','descuento_porcentaje','credito_aplicado') THEN -monto
      ELSE 0
    END
  ), 0)::numeric
  FROM public.cargos_extra
  WHERE cuota_id = p_cuota_id;
$$;

-- 6d. cuota_total_a_cobrar: el TOTAL real de la cuota que usa el trigger server
--     `recalcular_cuota_desde_pagos` (0012/0018) para derivar el ESTADO. DEBE
--     restar 'credito_aplicado' igual que calcular_cargos_neto; si no, al
--     sincronizar el cargo de crédito el server recalcula el estado SIN el
--     crédito → vuelve la cuota a 'pendiente'/'parcial' (server gana) y una
--     cuota saldo-0 pendiente traba el orden de cobro (bug que 0117 evita).
--     Reproduce el cuerpo vigente (0018) + el tipo nuevo en la RESTA.
CREATE OR REPLACE FUNCTION public.cuota_total_a_cobrar(p_cuota_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    cu.monto
    - COALESCE((
        SELECT SUM(ce.monto)
          FROM public.cargos_extra ce
         WHERE ce.cuota_id = cu.id
           AND ce.tipo IN ('descuento_monto','descuento_porcentaje','credito_aplicado')
      ), 0)
    + COALESCE((
        SELECT SUM(ce.monto)
          FROM public.cargos_extra ce
         WHERE ce.cuota_id = cu.id
           AND ce.tipo IN ('reconexion','otro')
      ), 0)
  FROM public.cuotas cu
  WHERE cu.id = p_cuota_id
$$;

-- =========================================================================
-- 7. Setting cobranza.credito_excedente (super-only, DEFAULT ON)
-- =========================================================================
-- Reproduce el cuerpo vigente de seed_settings_super_only (0125) + la clave
-- nueva. A diferencia del resto (default OFF), este arranca en 'true'.
CREATE OR REPLACE FUNCTION public.seed_settings_super_only(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.settings
    (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
  VALUES
    (p_tenant_id, 'cobranza.comprobante_habilitado', 'false'::jsonb, 'boolean',
     'cobranza',
     'Permite adjuntar foto del comprobante en el cobro (consume Storage)',
     'super_admin'),
    (p_tenant_id, 'cobranza.foto_obligatoria', 'false'::jsonb, 'boolean',
     'cobranza',
     'Exige la foto del comprobante (sólo si la foto está habilitada)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_pagos', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de historial de pagos del tenant (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.pantalla_notificaciones', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra la pantalla de gestión de notificaciones de mora (admin)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuentos_habilitados', 'false'::jsonb, 'boolean',
     'cobranza', 'Permitir aplicar descuentos en campo', 'super_admin'),
    (p_tenant_id, 'cobranza.descuento_tipo', '"monto"'::jsonb, 'string',
     'cobranza', 'Tipo de descuento permitido (monto|porcentaje|ambos)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_monto', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento monto sin aprobación (0=deshabilitado)',
     'super_admin'),
    (p_tenant_id, 'cobranza.descuento_max_porcentaje', '0'::jsonb, 'number',
     'cobranza', 'Tope de descuento porcentual sin aprobación (0=deshabilitado)',
     'super_admin'),
    (p_tenant_id, 'cobranza.cargo_reconexion_habilitado', 'false'::jsonb,
     'boolean', 'cobranza', 'Permitir cobrar reconexión', 'super_admin'),
    (p_tenant_id, 'cobranza.monto_reconexion', '0'::jsonb, 'number',
     'cobranza', 'Monto de reconexión en C$', 'super_admin'),
    (p_tenant_id, 'cobranza.audit_visible_admin', 'false'::jsonb, 'boolean',
     'cobranza',
     'Muestra el panel de Auditoría (historial de cambios) al admin del tenant',
     'super_admin'),
    (p_tenant_id, 'cobranza.registrar_visitas', 'false'::jsonb, 'boolean',
     'cobranza',
     'Habilita la pestaña Visitas en el detalle del cliente (registrar visita + historial)',
     'super_admin'),
    -- Crédito por excedente al suspender/cancelar → super-only, DEFAULT ON (0127).
    (p_tenant_id, 'cobranza.credito_excedente', 'true'::jsonb, 'boolean',
     'cobranza',
     'Al suspender/cancelar, ofrece acreditar/devolver/condonar el excedente pagado por adelantado (en OFF se pierde, como antes)',
     'super_admin')
  ON CONFLICT (tenant_id, clave) DO UPDATE SET editable_por = 'super_admin';
END $$;

-- Backfill a todos los tenants existentes (el ON CONFLICT preserva el `valor` de
-- las claves viejas; la nueva entra en 'true').
DO $$
DECLARE
  v_t record;
BEGIN
  FOR v_t IN SELECT id FROM public.tenants LOOP
    PERFORM public.seed_settings_super_only(v_t.id);
  END LOOP;
END $$;

-- =========================================================================
-- VERIFICACIÓN post-deploy (correr aparte; nunca asumir que la migración corrió)
-- =========================================================================
-- SELECT to_regclass('public.saldos_favor');                       -- no NULL
-- SELECT polname FROM pg_policies WHERE tablename='saldos_favor';  -- 3 policies
-- SELECT tgname FROM pg_trigger WHERE tgrelid='public.saldos_favor'::regclass; -- no_sobregiro + changelog
-- SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid='public.cargos_extra'::regclass AND conname IN
--   ('cargos_extra_origen_check','cargos_extra_tipo_check');       -- incluyen credito/credito_aplicado
-- SELECT clave, valor, editable_por FROM public.settings
--   WHERE clave='cobranza.credito_excedente';                      -- true / super_admin (1 por tenant)
