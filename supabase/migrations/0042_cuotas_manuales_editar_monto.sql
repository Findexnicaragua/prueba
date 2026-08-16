-- Migración 0042: soporte para cuotas manuales y edición de monto.
--
-- 1. contrato_id pasa a nullable para cuotas manuales (no ligadas a contrato).
-- 2. Se agrega columna `descripcion` para dar contexto a cuotas manuales
--    (ej: "Cargo por reconexión", "Instalación", etc.).
-- 3. El unique index (contrato_id, periodo) se mantiene — las cuotas con
--    contrato_id NULL no colisionan entre sí porque NULL != NULL en Postgres.
--    Esto significa que pueden existir múltiples cuotas manuales para el
--    mismo periodo sin conflicto.

-- 1. Hacer contrato_id nullable.
ALTER TABLE public.cuotas ALTER COLUMN contrato_id DROP NOT NULL;

-- 2. Agregar columna descripcion (texto libre, nullable).
ALTER TABLE public.cuotas ADD COLUMN IF NOT EXISTS descripcion text;
