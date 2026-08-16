-- 0103: Fase 3 — Fundación de Tickets (slice 3A).
--
-- Agrega: roles `tecnico` + `admin_tickets`; módulo opcional `tickets`; y las
-- tablas núcleo ticket_tipos / tickets / ticket_eventos / ticket_adjuntos con
-- RLS per-tenant, audit y un trigger que valida las transiciones de estado
-- server-side ("server gana", decisión D2). Materiales (engancha inventario) e
-- incidentes llegan en 3C/3D — por eso `tickets.incidente_id` queda sin FK aún.
--
-- Correlativo del ticket: cliente-computado (MAX+1 por tenant) con UNIQUE de
-- respaldo, mismo patrón que recibos (decisión D4). Módulo `tickets` es_base=false
-- → OFF por defecto; lo enciende el super_admin.
--
-- IDEMPOTENTE + transaccional (lección de 0102).

BEGIN;

-- =========================================================================
-- 1. Roles: agregar tecnico + admin_tickets al CHECK
-- =========================================================================
ALTER TABLE public.cobradores DROP CONSTRAINT IF EXISTS cobradores_rol_check;
ALTER TABLE public.cobradores ADD CONSTRAINT cobradores_rol_check
  CHECK (rol IN ('super_admin','admin','admin_cobranza','cobrador',
                 'tecnico','admin_tickets'));

-- set_cobrador_rol: permitir los dos roles nuevos. tecnico/admin_tickets NO
-- cobran → caen al `else null` del prefijo (no llevan correlativo de recibo).
CREATE OR REPLACE FUNCTION public.set_cobrador_rol(
  p_cobrador_id uuid,
  p_nuevo_rol   text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_tenant uuid;
  v_target_rol    text;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin' USING errcode = '42501';
  END IF;
  IF p_cobrador_id = auth.uid() THEN
    RAISE EXCEPTION 'No podés modificar tu propio rol';
  END IF;
  IF p_nuevo_rol NOT IN ('admin','admin_cobranza','cobrador','tecnico','admin_tickets') THEN
    RAISE EXCEPTION 'Rol inválido. Permitidos: admin, admin_cobranza, cobrador, tecnico, admin_tickets';
  END IF;

  SELECT tenant_id, rol INTO v_target_tenant, v_target_rol
  FROM public.cobradores WHERE id = p_cobrador_id FOR UPDATE;

  IF v_target_rol IS NULL THEN
    RAISE EXCEPTION 'Cobrador no existe' USING errcode = 'P0002';
  END IF;
  IF v_target_rol = 'super_admin' THEN
    RAISE EXCEPTION 'No se puede modificar el rol de otro super_admin';
  END IF;
  IF v_target_rol = p_nuevo_rol THEN
    RETURN;
  END IF;

  UPDATE public.cobradores
  SET rol = p_nuevo_rol,
      prefijo_recibo = CASE
        WHEN p_nuevo_rol IN ('cobrador','admin','admin_cobranza')
          THEN prefijo_recibo
        ELSE NULL
      END
  WHERE id = p_cobrador_id;

  INSERT INTO public.audit_log (
    tenant_id, tabla, registro_id, campo,
    valor_anterior, valor_nuevo, user_id, user_rol
  ) VALUES (
    v_target_tenant, 'cobradores', p_cobrador_id, 'rol',
    to_jsonb(v_target_rol), to_jsonb(p_nuevo_rol), auth.uid(), 'super_admin'
  );
END;
$$;
REVOKE ALL ON FUNCTION public.set_cobrador_rol(uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.set_cobrador_rol(uuid, text) TO authenticated;

-- =========================================================================
-- 2. Módulo opcional `tickets` (OFF por defecto)
-- =========================================================================
INSERT INTO public.modulos (codigo, nombre, descripcion, es_base, orden) VALUES
  ('tickets', 'Tickets',
   'Gestión de trabajo de campo: instalaciones, reparaciones, reclamos y cortes (outages), con rol técnico.',
   false, 30)
ON CONFLICT (codigo) DO NOTHING;

-- =========================================================================
-- 3. Helpers de rol para tickets
-- =========================================================================
CREATE OR REPLACE FUNCTION public.is_admin_or_tickets() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.current_user_rol() IN ('admin','admin_tickets');
$$;

-- Staff que opera tickets: admin, admin_tickets y el técnico (crea/resuelve).
CREATE OR REPLACE FUNCTION public.is_ticket_staff() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.current_user_rol() IN ('admin','admin_tickets','tecnico');
$$;

-- =========================================================================
-- 4. ticket_tipos (catálogo per-tenant con SLA por tipo)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.ticket_tipos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  nombre text NOT NULL,
  descripcion text,
  sla_horas integer CHECK (sla_horas IS NULL OR sla_horas > 0),
  color text,
  orden integer NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_tipos_by_tenant ON public.ticket_tipos (tenant_id);

-- =========================================================================
-- 5. tickets
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  correlativo integer NOT NULL CHECK (correlativo > 0),
  tipo_id uuid REFERENCES public.ticket_tipos(id) ON DELETE RESTRICT,
  cliente_id uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  puerto_id uuid REFERENCES public.red_puertos(id) ON DELETE SET NULL,
  incidente_id uuid,                       -- FK en 3D (incidentes aún no existe)
  titulo text NOT NULL,
  descripcion text,
  estado text NOT NULL DEFAULT 'abierto'
    CHECK (estado IN ('abierto','asignado','en_progreso','en_espera',
                      'resuelto','cerrado','reabierto','cancelado')),
  prioridad text CHECK (prioridad IS NULL OR
    prioridad IN ('baja','media','alta','urgente')),
  asignado_a uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  creado_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  resuelto_en timestamptz,
  cerrado_en timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz NOT NULL DEFAULT now(),   -- device-time (offline)
  UNIQUE (tenant_id, correlativo)
);
CREATE INDEX IF NOT EXISTS tickets_by_tenant   ON public.tickets (tenant_id, estado);
CREATE INDEX IF NOT EXISTS tickets_by_cliente  ON public.tickets (tenant_id, cliente_id);
CREATE INDEX IF NOT EXISTS tickets_by_asignado ON public.tickets (tenant_id, asignado_a);

-- Validación de transición de estado (D2: server gana). Rechaza saltos inválidos.
CREATE OR REPLACE FUNCTION public.tickets_validar_transicion() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.estado = OLD.estado THEN RETURN NEW; END IF;
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
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_tickets_validar_transicion ON public.tickets;
CREATE TRIGGER trg_tickets_validar_transicion
  BEFORE UPDATE OF estado ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.tickets_validar_transicion();

-- =========================================================================
-- 6. ticket_eventos (bitácora APPEND-ONLY)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.ticket_eventos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  ticket_id uuid NOT NULL REFERENCES public.tickets(id) ON DELETE CASCADE,
  tipo_evento text NOT NULL CHECK (tipo_evento IN
    ('creado','asignado','cambio_estado','comentario','material','adjunto',
     'reabierto','cerrado','cancelado')),
  estado_anterior text,
  estado_nuevo text,
  comentario text,
  hecho_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  ocurrido_en timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_eventos_by_ticket ON public.ticket_eventos (ticket_id);

-- =========================================================================
-- 7. ticket_adjuntos (fotos del ticket)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.ticket_adjuntos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  ticket_id uuid NOT NULL REFERENCES public.tickets(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  descripcion text,
  subido_por uuid REFERENCES public.cobradores(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_adjuntos_by_ticket ON public.ticket_adjuntos (ticket_id);

-- =========================================================================
-- 8. RLS — read: miembro del tenant; write: staff de tickets (o config admin)
-- =========================================================================
ALTER TABLE public.ticket_tipos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickets         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_eventos  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_adjuntos ENABLE ROW LEVEL SECURITY;

-- ticket_tipos: lo configura el admin/admin_tickets.
DROP POLICY IF EXISTS "tt_read"   ON public.ticket_tipos;
DROP POLICY IF EXISTS "tt_write"  ON public.ticket_tipos;
DROP POLICY IF EXISTS "super_admin_all" ON public.ticket_tipos;
CREATE POLICY "tt_read"  ON public.ticket_tipos FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "tt_write" ON public.ticket_tipos FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_tickets())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_tickets());
CREATE POLICY "super_admin_all" ON public.ticket_tipos
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- tickets: crea/edita el staff (admin/admin_tickets/tecnico).
DROP POLICY IF EXISTS "tk_read"   ON public.tickets;
DROP POLICY IF EXISTS "tk_write"  ON public.tickets;
DROP POLICY IF EXISTS "super_admin_all" ON public.tickets;
CREATE POLICY "tk_read"  ON public.tickets FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "tk_write" ON public.tickets FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_ticket_staff())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_ticket_staff());
CREATE POLICY "super_admin_all" ON public.tickets
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- ticket_eventos: APPEND-ONLY (read + insert; sin update/delete).
DROP POLICY IF EXISTS "te_read"   ON public.ticket_eventos;
DROP POLICY IF EXISTS "te_insert" ON public.ticket_eventos;
DROP POLICY IF EXISTS "super_admin_all" ON public.ticket_eventos;
CREATE POLICY "te_read"   ON public.ticket_eventos FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "te_insert" ON public.ticket_eventos FOR INSERT
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_ticket_staff());
CREATE POLICY "super_admin_all" ON public.ticket_eventos
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- ticket_adjuntos: read + write del staff (puede borrar una foto equivocada).
DROP POLICY IF EXISTS "ta_read"  ON public.ticket_adjuntos;
DROP POLICY IF EXISTS "ta_write" ON public.ticket_adjuntos;
DROP POLICY IF EXISTS "super_admin_all" ON public.ticket_adjuntos;
CREATE POLICY "ta_read"  ON public.ticket_adjuntos FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "ta_write" ON public.ticket_adjuntos FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_ticket_staff())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_ticket_staff());
CREATE POLICY "super_admin_all" ON public.ticket_adjuntos
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- =========================================================================
-- 9. Audit log (trigger genérico) en las 4 tablas
-- =========================================================================
DROP TRIGGER IF EXISTS trg_changelog_ticket_tipos ON public.ticket_tipos;
CREATE TRIGGER trg_changelog_ticket_tipos
  AFTER INSERT OR UPDATE OR DELETE ON public.ticket_tipos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

DROP TRIGGER IF EXISTS trg_changelog_tickets ON public.tickets;
CREATE TRIGGER trg_changelog_tickets
  AFTER INSERT OR UPDATE OR DELETE ON public.tickets
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

DROP TRIGGER IF EXISTS trg_changelog_ticket_eventos ON public.ticket_eventos;
CREATE TRIGGER trg_changelog_ticket_eventos
  AFTER INSERT OR UPDATE OR DELETE ON public.ticket_eventos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

DROP TRIGGER IF EXISTS trg_changelog_ticket_adjuntos ON public.ticket_adjuntos;
CREATE TRIGGER trg_changelog_ticket_adjuntos
  AFTER INSERT OR UPDATE OR DELETE ON public.ticket_adjuntos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

COMMIT;
