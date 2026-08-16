-- 0120: Suspensión temporal de contrato (Feature A).
--
-- Permite a admin / admin_cobranza PAUSAR un contrato: estado='suspendido'.
-- El cron `generar_cuotas_mensual` y `generar_cuotas_contrato` (0074) ya gatean
-- por estado='activo' → al suspender, dejan de generar cuotas SOLOS (pausa
-- gratis). La transacción del cliente (offline-first) hace el resto:
--   - SUSPENDER: anula las cuotas futuras pendientes del período + prorratea la
--     del mes en curso (fijos) / solo pausa (indefinidos), e inserta una fila en
--     `contrato_suspensiones` (motivo + notas + snapshot de deuda).
--   - REACTIVAR: estado='activo', re-ancla `dia_pago` a la fecha de reactivación
--     y regenera cuotas hasta el mes ORIGINAL de `fecha_fin` (sin estirar); cierra
--     la fila (reactivado_en/por). NO cobra puente (lo suspendido no se factura).
-- El PDF de deuda se genera on-demand del `deuda_snapshot` (offline, reimprimible).
-- Decisiones cerradas (Rubén 2026-06-15): no se cobra el período suspendido,
-- el contrato termina en el mismo mes, solo se suspende a futuro (lo pagado no se
-- toca), solo admin/admin_cobranza. schema v28 → v29.

BEGIN;

-- 1) contratos.estado: agregar 'suspendido'. Hoy NO hay CHECK (0052 lo dejó
--    libre); lo creamos con nombre estable e idempotente.
ALTER TABLE public.contratos DROP CONSTRAINT IF EXISTS contratos_estado_check;
ALTER TABLE public.contratos
  ADD CONSTRAINT contratos_estado_check
  CHECK (estado IN ('activo', 'suspendido', 'completado', 'cancelado'));

-- 2) Tabla de historial de suspensiones (Receta R10). Append-only salvo el
--    UPDATE de cierre al reactivar (reactivado_en/por). `deuda_snapshot` = JSON
--    (texto) de las cuotas pendientes al momento de suspender, para reimprimir
--    el PDF sin re-calcular. Sin denormalizar cobrador_id (es hija de contratos).
CREATE TABLE IF NOT EXISTS public.contrato_suspensiones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  contrato_id uuid NOT NULL REFERENCES public.contratos(id) ON DELETE CASCADE,
  motivo text NOT NULL,
  notas text,                                      -- nota libre opcional del porqué
  deuda_snapshot text,                             -- JSON: cuotas pendientes + total al suspender
  suspendido_en timestamptz NOT NULL DEFAULT now(),
  suspendido_por uuid REFERENCES public.cobradores(id),
  reactivado_en timestamptz,                       -- NULL = suspensión vigente
  reactivado_por uuid REFERENCES public.cobradores(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz NOT NULL DEFAULT now()   -- device-time (offline/audit)
);
CREATE INDEX IF NOT EXISTS contrato_suspensiones_by_contrato
  ON public.contrato_suspensiones (tenant_id, contrato_id);

-- RLS: read = miembro del tenant; write = admin/admin_cobranza; super_admin A MANO.
ALTER TABLE public.contrato_suspensiones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "susp_read"  ON public.contrato_suspensiones;
DROP POLICY IF EXISTS "susp_write" ON public.contrato_suspensiones;
DROP POLICY IF EXISTS "super_admin_all" ON public.contrato_suspensiones;
CREATE POLICY "susp_read" ON public.contrato_suspensiones FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "susp_write" ON public.contrato_suspensiones FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_cobranza());
CREATE POLICY "super_admin_all" ON public.contrato_suspensiones
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- Audit del change-log (genérico AFTER I/U/D, guard de profundidad).
DROP TRIGGER IF EXISTS trg_changelog_contrato_suspensiones ON public.contrato_suspensiones;
CREATE TRIGGER trg_changelog_contrato_suspensiones
  AFTER INSERT OR UPDATE OR DELETE ON public.contrato_suspensiones
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

COMMIT;
