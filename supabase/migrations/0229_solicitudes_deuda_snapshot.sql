-- 0229 — Foto de la deuda al PEDIR suspender/cancelar un contrato
--
-- Desde v0.31.28 todo rol que no sea admin tiene que SOLICITAR la suspensión o
-- la cancelación. Efecto colateral: el rol que antes lo ejecutaba directo veía
-- el bloque "Deuda a la fecha" (lo que queda cobrable después del corte) y al
-- pasar a pedir permiso dejó de verlo — y la solicitud que le llega al admin
-- tampoco lo llevaba. O sea: se pedía cortar el servicio a ciegas y se aprobaba
-- a ciegas.
--
-- Esta columna guarda el cálculo del MOMENTO DEL PEDIDO. La tarjeta de
-- aprobación NO lo muestra como el número bueno: recalcula en vivo (que es lo
-- que el sistema va a aplicar al aprobar) y usa el snapshot para explicar la
-- diferencia — si bajó, el cliente pagó; si subió, corrieron días de servicio
-- del ciclo en curso mientras la solicitud esperaba.
--
-- TEXT, no jsonb, a propósito. `contratos.cancelacion_deuda_snapshot` nació
-- jsonb en 0123 y hubo que migrarla a text en 0126: el cliente manda el JSON ya
-- serializado, entraba como string-escalar y volvía doble-codificado, reventando
-- con "type 'String' is not a subtype of type 'Map'". Con text el valor viaja
-- tal cual y se decodifica una sola vez, en Dart.
--
-- Aditiva y nullable: las solicitudes ya creadas quedan sin snapshot y la
-- tarjeta las muestra igual (solo sin la línea comparativa). Los buckets de
-- `solicitudes_accion` usan SELECT * → no hay que editar sync-rules.yaml. NO se
-- bumpea `_dbWipeVersion` (política R4).

ALTER TABLE public.solicitudes_accion
  ADD COLUMN IF NOT EXISTS deuda_snapshot text;

COMMENT ON COLUMN public.solicitudes_accion.deuda_snapshot IS
  'JSON (texto) con la deuda cobrable calculada al crear la solicitud: '
  '{total, cuotas[], dia_pago, precio_mensual, fecha}. Solo aplica a '
  'suspender/cancelar contrato. Es referencia histórica: el aprobador ve el '
  'recálculo en vivo, no este valor.';
