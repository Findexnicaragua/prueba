-- 0076_audit_planes.sql
-- Change log para `planes`: cierra el gap de cobertura del audit/historial.
--
-- Bajo la regla de change log universal (ver CLAUDE.md): toda entidad editable
-- por usuarios debe tener su historial. `planes` quedaba afuera de los 8
-- triggers de 0062. Acá se suma.
--
-- `planes` es per-tenant (tiene tenant_id), así que el trigger genérico
-- `audit_changelog_trg` (0047/0062/0069) aplica directo, sin variantes.
--
-- NO se agrega columna `ocurrido_en`: los planes los edita el admin ONLINE
-- desde el panel web, no el cobrador offline, así que el device-time no aporta.
-- El trigger lee `to_jsonb(NEW)->>'ocurrido_en'`; al faltar la key devuelve
-- NULL (no error) → `audit_log.ocurrido_en` queda NULL → la UI cae a
-- `created_at` vía COALESCE. Correcto para una entidad online-only.
--
-- Sin cambios de PowerSync schema/sync: `audit_log` ya sincroniza (SELECT *) y
-- `planes` no cambia de columnas. Las filas de audit de un plan heredan su
-- tenant_id → visibles solo para ese tenant (RLS de audit_log).

begin;

drop trigger if exists trg_changelog_planes on public.planes;
create trigger trg_changelog_planes
  after insert or update or delete on public.planes
  for each row when (pg_trigger_depth() < 2)
  execute function public.audit_changelog_trg();

commit;
