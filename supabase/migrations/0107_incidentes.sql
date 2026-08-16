-- 0107: Tickets Fase 3D — incidentes (outages/cortes). Un incidente agrupa un
-- corte de servicio; los clientes afectados se DERIVAN de la topología de red
-- (clientes.puerto_id → red_puertos.hub_id → red_hubs.nodo_id), y los tickets se
-- agrupan por `incidente_id` (la columna ya existe en tickets desde 0103, sin FK).
--
-- Alcance del corte (jerárquico, EXCLUYENTE): a lo sumo UNO de nodo/hub/puerto
-- (corte de ese nivel hacia abajo) o TODOS NULL (corte general del tenant). El
-- CHECK lo fuerza. FK a red con ON DELETE SET NULL (recablear la red no borra el
-- histórico del incidente).
--
-- Admin-facing (write = is_admin_or_tickets; el técnico NO crea incidentes, sólo
-- ve sus tickets que el admin agrupó). Idempotente + transaccional. schema v23→v24.

BEGIN;

CREATE TABLE IF NOT EXISTS public.incidentes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  titulo text NOT NULL,
  descripcion text,
  -- Alcance: a lo sumo uno set (nivel del corte) o todos NULL (corte general).
  nodo_id   uuid REFERENCES public.red_nodos(id)   ON DELETE SET NULL,
  hub_id    uuid REFERENCES public.red_hubs(id)    ON DELETE SET NULL,
  puerto_id uuid REFERENCES public.red_puertos(id) ON DELETE SET NULL,
  estado text NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','resuelto')),
  inicio timestamptz NOT NULL DEFAULT now(),
  fin timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  ocurrido_en timestamptz NOT NULL DEFAULT now(),   -- device-time (offline/audit)
  CONSTRAINT incidentes_un_solo_nivel CHECK (
    ((nodo_id IS NOT NULL)::int + (hub_id IS NOT NULL)::int
     + (puerto_id IS NOT NULL)::int) <= 1
  )
);
CREATE INDEX IF NOT EXISTS incidentes_by_tenant ON public.incidentes (tenant_id, estado);

-- FK diferida de 0103: ahora que incidentes existe, atamos tickets.incidente_id.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tickets_incidente_fk') THEN
    ALTER TABLE public.tickets
      ADD CONSTRAINT tickets_incidente_fk FOREIGN KEY (incidente_id)
      REFERENCES public.incidentes(id) ON DELETE SET NULL;
  END IF;
END $$;

-- RLS: read = miembro del tenant; write = admin/admin_tickets (config-level).
ALTER TABLE public.incidentes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "inc_read"  ON public.incidentes;
DROP POLICY IF EXISTS "inc_write" ON public.incidentes;
DROP POLICY IF EXISTS "super_admin_all" ON public.incidentes;
CREATE POLICY "inc_read"  ON public.incidentes FOR SELECT
  USING (tenant_id = public.current_tenant_id());
CREATE POLICY "inc_write" ON public.incidentes FOR ALL
  USING (tenant_id = public.current_tenant_id() AND public.is_admin_or_tickets())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_admin_or_tickets());
CREATE POLICY "super_admin_all" ON public.incidentes
  USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

-- Audit del change-log.
DROP TRIGGER IF EXISTS trg_changelog_incidentes ON public.incidentes;
CREATE TRIGGER trg_changelog_incidentes
  AFTER INSERT OR UPDATE OR DELETE ON public.incidentes
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

COMMIT;
