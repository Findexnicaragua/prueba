-- 0072_contrato_duracion_meses.sql
-- Materializa la duración del contrato como columna inmutable.
--
-- Invariante de dinero #5: el total de un contrato fijo = precio_mensual ×
-- meses DEFINIDOS AL CREAR, nunca re-derivado. Hasta ahora el total se
-- recalculaba en la UI desde (fecha_fin - fecha_inicio), lo que sería
-- incorrecto si en el futuro se permite editar fecha_fin (extensión /
-- renovación de contrato). Guardamos la duración una vez y la usamos como
-- fuente de verdad.
--
-- NULL = contrato indefinido (sin total fijo; solo se reporta el recaudado
-- acumulado, invariante #6).

ALTER TABLE public.contratos
  ADD COLUMN IF NOT EXISTS duracion_meses integer;

-- Backfill desde las fechas existentes, con EXACTAMENTE la misma fórmula que
-- usaba la UI (años*12 + diff de meses) para no cambiar ningún total ya
-- mostrado. fecha_fin NULL (indefinido) deja duracion_meses en NULL.
UPDATE public.contratos
   SET duracion_meses = (
           (EXTRACT(YEAR  FROM fecha_fin::date)::int
          - EXTRACT(YEAR  FROM fecha_inicio::date)::int) * 12
         + (EXTRACT(MONTH FROM fecha_fin::date)::int
          - EXTRACT(MONTH FROM fecha_inicio::date)::int)
       )
 WHERE fecha_fin IS NOT NULL
   AND duracion_meses IS NULL;
