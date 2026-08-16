-- 0052: Contrato estados: activo boolean → estado text.
-- Valores: 'activo', 'completado', 'cancelado'.

ALTER TABLE public.contratos ADD COLUMN IF NOT EXISTS estado text NOT NULL DEFAULT 'activo';

-- Migrar datos existentes.
UPDATE public.contratos SET estado = CASE
  WHEN activo = true THEN 'activo'
  ELSE 'cancelado'
END;

-- Eliminar columna vieja.
ALTER TABLE public.contratos DROP COLUMN IF EXISTS activo;
