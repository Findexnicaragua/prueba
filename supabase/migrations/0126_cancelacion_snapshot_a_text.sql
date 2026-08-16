-- 0126 — cancelacion_deuda_snapshot: jsonb → text (consistencia con deuda_snapshot).
--
-- 0123 creó la columna como `jsonb`. El cliente (offline-first) guarda un STRING ya
-- codificado con jsonEncode; al sincronizar vía PowerSync/PostgREST ese string entra al
-- jsonb como STRING SCALAR y vuelve DOBLE-codificado ("{...}") → en el cliente
-- jsonDecode daba un String, no un Map, y el revert/PDF/tarjeta de cancelación fallaban
-- (type 'String' is not a subtype of type 'Map'). El `deuda_snapshot` de suspensión
-- (0120) es `text` y NO sufre esto.
--
-- Fix raíz: pasar la columna a `text` (igual que deuda_snapshot) y des-doble-codificar
-- las filas existentes (`#>> '{}'` extrae el string interno de un jsonb string-scalar).
-- Los writes futuros del cliente quedan single-encoded. El cliente además trae un decode
-- robusto (decodeSnapshotMap) que tolera ambos formatos → esta migración es de
-- CONSISTENCIA: la app YA funciona con el decode robusto, pero esto evita el footgun de
-- que cualquier lectura futura tenga que acordarse de des-doble-codificar.
--
-- Sin cambio de schema.dart (ya es Column.text) ni de sync rules (SELECT *).

ALTER TABLE public.contratos
  ALTER COLUMN cancelacion_deuda_snapshot TYPE text
  USING (
    CASE
      WHEN cancelacion_deuda_snapshot IS NULL THEN NULL
      WHEN jsonb_typeof(cancelacion_deuda_snapshot) = 'string'
        THEN cancelacion_deuda_snapshot #>> '{}'
      ELSE cancelacion_deuda_snapshot::text
    END
  );
