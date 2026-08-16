-- Migración 0092: prefijo de recibo único por tenant.
--
-- Ahora que los 3 roles que cobran (cobrador / admin / admin_cobranza)
-- pueden tener prefijo de recibo, dos usuarios del mismo tenant con el
-- mismo prefijo colisionarían sus correlativos de recibo (ej: COB-01-0001
-- emitido por dos personas distintas). Este índice único lo impide a nivel
-- de DB.
--
-- - Parcial (WHERE prefijo_recibo IS NOT NULL): los usuarios sin prefijo
--   (ej: super_admin, o uno todavía sin asignar) no chocan entre sí.
-- - upper(prefijo_recibo): comparación case-insensitive — la UI ya
--   normaliza a mayúsculas, pero esto blinda contra writes directos.
-- - Por tenant: prefijos pueden repetirse ENTRE tenants distintos (cada ISP
--   tiene su propio espacio de correlativos).
--
-- IF NOT EXISTS: idempotente. NOTA: si la data actual ya tiene duplicados,
-- la creación del índice fallará; en ese caso hay que deduplicar primero.

CREATE UNIQUE INDEX IF NOT EXISTS cobradores_prefijo_tenant_uq
  ON public.cobradores (tenant_id, upper(prefijo_recibo))
  WHERE prefijo_recibo IS NOT NULL;
