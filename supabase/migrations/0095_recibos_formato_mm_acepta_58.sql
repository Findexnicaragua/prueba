-- 0095 — Permitir 58 en recibos.ultimo_formato_mm.
--
-- Bug: el CHECK original (0006) era `ultimo_formato_mm in (57, 80)`. Al
-- estandarizar el ancho angosto a 58mm (migr 0094 + UI), la impresión escribe
-- `ultimo_formato_mm = 58` y la fila de `recibos` VIOLA el constraint →
-- "new row for relation recibos violates check constraint
-- recibos_ultimo_formato_mm_check" → el sync del recibo falla (aunque el cobro
-- ya quedó guardado).
--
-- Fix: ampliar el CHECK para aceptar 57 (legacy), 58 y 80. Idempotente
-- (drop if exists + add). Sin columnas nuevas → sin bump de schema ni redeploy
-- de sync rules.

alter table public.recibos
  drop constraint if exists recibos_ultimo_formato_mm_check;

alter table public.recibos
  add constraint recibos_ultimo_formato_mm_check
  check (ultimo_formato_mm is null or ultimo_formato_mm in (57, 58, 80));
