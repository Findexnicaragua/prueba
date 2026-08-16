-- 0180 — tenants.nombre único case/trim-insensitive, excepto System (audit F0).
--
-- crear-tenant valida vacío/largo/'system'/control-chars pero NO colisión de
-- nombre, y no había UNIQUE → dos tenants podían llamarse igual o quedar con un
-- typo permanente (no hay UI de rename; sí es editable por el super vía la policy
-- super_admin_all de 0026). Este índice impide NUEVOS duplicados. El fold es
-- `lower(trim(...))` (Postgres lower() es unicode-aware — ñ/acentos OK); no se usa
-- unaccent para no depender de la extensión. Excluye el pseudo-tenant System
-- (UUID fijo). Verificado: 0 duplicados en prod al crear el índice.

CREATE UNIQUE INDEX IF NOT EXISTS tenants_nombre_unico
  ON public.tenants (lower(trim(nombre)))
  WHERE id <> '00000000-0000-0000-0000-000000000000';
