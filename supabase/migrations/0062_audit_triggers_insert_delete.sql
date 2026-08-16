-- 0062: Completar triggers de audit_changelog para INSERT y DELETE.
--
-- Bug crítico encontrado: la función audit_changelog_trg maneja
-- TG_OP = 'INSERT' / 'UPDATE' / 'DELETE', pero los CREATE TRIGGER
-- de 0047 solo registraron AFTER UPDATE. Resultado: las creaciones
-- y eliminaciones no se registran en audit_log.
--
-- Esta migración:
--   1. Re-crea los triggers existentes con INSERT OR UPDATE OR DELETE
--   2. Agrega triggers para visitas, fotos_cliente, cargos_extra
--      (tablas operativas que también necesitan trazabilidad)

-- pagos
DROP TRIGGER IF EXISTS trg_changelog_pagos ON public.pagos;
CREATE TRIGGER trg_changelog_pagos
  AFTER INSERT OR UPDATE OR DELETE ON public.pagos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- cuotas
DROP TRIGGER IF EXISTS trg_changelog_cuotas ON public.cuotas;
CREATE TRIGGER trg_changelog_cuotas
  AFTER INSERT OR UPDATE OR DELETE ON public.cuotas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- clientes
DROP TRIGGER IF EXISTS trg_changelog_clientes ON public.clientes;
CREATE TRIGGER trg_changelog_clientes
  AFTER INSERT OR UPDATE OR DELETE ON public.clientes
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- contratos
DROP TRIGGER IF EXISTS trg_changelog_contratos ON public.contratos;
CREATE TRIGGER trg_changelog_contratos
  AFTER INSERT OR UPDATE OR DELETE ON public.contratos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- recibos
DROP TRIGGER IF EXISTS trg_changelog_recibos ON public.recibos;
CREATE TRIGGER trg_changelog_recibos
  AFTER INSERT OR UPDATE OR DELETE ON public.recibos
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- visitas (nuevo)
DROP TRIGGER IF EXISTS trg_changelog_visitas ON public.visitas;
CREATE TRIGGER trg_changelog_visitas
  AFTER INSERT OR UPDATE OR DELETE ON public.visitas
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- fotos_cliente (nuevo)
DROP TRIGGER IF EXISTS trg_changelog_fotos_cliente ON public.fotos_cliente;
CREATE TRIGGER trg_changelog_fotos_cliente
  AFTER INSERT OR UPDATE OR DELETE ON public.fotos_cliente
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();

-- cargos_extra (nuevo)
DROP TRIGGER IF EXISTS trg_changelog_cargos_extra ON public.cargos_extra;
CREATE TRIGGER trg_changelog_cargos_extra
  AFTER INSERT OR UPDATE OR DELETE ON public.cargos_extra
  FOR EACH ROW WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.audit_changelog_trg();
