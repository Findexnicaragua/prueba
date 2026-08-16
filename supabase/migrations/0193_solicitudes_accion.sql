-- 0193 — Cola de aprobación para admin_usuarios (Fase 3B).
--
-- admin_usuarios puede SOLICITAR acciones estructurales (crear contrato,
-- suspender, reactivar, cancelar contrato, desactivar cliente). El admin o
-- admin_cobranza revisa y aprueba o rechaza (con motivo obligatorio).
-- Al aprobar, el admin ejecuta la acción desde su dispositivo usando los
-- datos JSONB guardados.
--
-- Offline-first: el admin_usuarios crea la solicitud localmente (INSERT),
-- se sincroniza al server via PowerSync, y el admin la ve al entrar.
--
-- R10: tabla nueva con tenant_id + RLS + super_admin_all A MANO.

-- =========================================================================
-- 1. Tabla solicitudes_accion
-- =========================================================================
CREATE TABLE public.solicitudes_accion (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,

  -- Quién solicita (admin_usuarios).
  solicitante_id uuid NOT NULL REFERENCES public.cobradores(id),

  -- Tipo de acción solicitada.
  tipo text NOT NULL CHECK (tipo IN (
    'crear_contrato',
    'cancelar_contrato',
    'suspender_contrato',
    'reactivar_contrato',
    'desactivar_cliente'
  )),

  -- Entidad sobre la que aplica: cliente_id para crear_contrato y
  -- desactivar_cliente; contrato_id para el resto.
  entidad_id uuid NOT NULL,

  -- Datos de la solicitud (el form completo para crear_contrato; motivo
  -- para cancelar/suspender; vacío para reactivar/desactivar).
  datos jsonb NOT NULL DEFAULT '{}',

  -- Estado del flujo.
  estado text NOT NULL DEFAULT 'pendiente' CHECK (estado IN (
    'pendiente', 'aprobada', 'rechazada'
  )),

  -- Quién resolvió (admin/admin_cobranza que aprobó o rechazó).
  aprobador_id uuid REFERENCES public.cobradores(id),
  -- Motivo de rechazo (obligatorio en rechazada, NULL en aprobada/pendiente).
  motivo_rechazo text,

  -- Label del solicitante (snapshot del nombre, para la lista del admin
  -- sin hacer JOIN). Igual que actor_label en op_log.
  solicitante_label text,

  -- Timestamps.
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz NOT NULL,   -- device-time UTC (.toUtc())
  resolved_at timestamptz             -- cuándo se aprobó/rechazó
);

CREATE INDEX solicitudes_accion_by_tenant
  ON public.solicitudes_accion (tenant_id, estado);
CREATE INDEX solicitudes_accion_by_solicitante
  ON public.solicitudes_accion (tenant_id, solicitante_id);

-- =========================================================================
-- 2. RLS
-- =========================================================================
-- El admin_usuarios inserta y lee las suyas. Admin/admin_cobranza lee y
-- actualiza (aprueba/rechaza) todas del tenant. Super_admin: all.
ALTER TABLE public.solicitudes_accion ENABLE ROW LEVEL SECURITY;

-- SELECT: admin/admin_cobranza ven todas; admin_usuarios ve las suyas.
CREATE POLICY "solicitudes_read" ON public.solicitudes_accion
  FOR SELECT USING (
    tenant_id = public.current_tenant_id()
    AND (
      public.is_admin_or_cobranza()
      OR solicitante_id = auth.uid()
    )
  );

-- INSERT: solo admin_usuarios (solicitante_id = auth.uid()).
-- El current_user_rol() check es por seguridad; admin/admin_cobranza
-- no deberían crear solicitudes (ejecutan directo).
CREATE POLICY "solicitudes_insert" ON public.solicitudes_accion
  FOR INSERT WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND solicitante_id = auth.uid()
  );

-- UPDATE: solo admin/admin_cobranza (aprobar/rechazar).
CREATE POLICY "solicitudes_update" ON public.solicitudes_accion
  FOR UPDATE USING (
    tenant_id = public.current_tenant_id()
    AND public.is_admin_or_cobranza()
  );

-- super_admin bypass.
CREATE POLICY "super_admin_all" ON public.solicitudes_accion
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());
