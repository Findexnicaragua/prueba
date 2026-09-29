-- ===========================================================================
-- 0268 — El recibo CONGELA el plan que imprime. Espejo exacto de 0262.
--
-- EL PROBLEMA: `recibos` no guarda el nombre del plan. Cada impresión lo
-- resuelve por JOIN al plan VIVO del contrato (`recibo_screen.dart:94` y :127,
-- `pl.nombre` vía `ct.plan_id`). El día que un contrato cambia de plan, TODOS
-- sus recibos anteriores pasan a decir el plan nuevo — incluida la reimpresión
-- del recibo que el cliente tiene guardado en la mano.
--
-- Es EL MISMO bug que 0262 cerró para el mes, con la misma forma: un dato de
-- presentación que se recalcula en cada impresión en vez de congelarse al
-- emitir. 0262 lo arregló para `periodo_label` y dejó `plan` abierto.
--
-- Y desde que existe el cambio de plan (R22) el disparador es cotidiano, no
-- teórico: 37 cambios en Telecable Mairena entre el 2026-08-22 y el 2026-09-01.
-- Cada uno reescribió, en silencio, el plan que dicen todos los recibos viejos
-- de ese contrato.
--
-- CASO CONCRETO: un cliente en Básico 5 Megas paga junio; su recibo dice
-- "Servicio: Básico 5 Megas". El 20 de junio pasa a Fibra 10 Megas. Si alguien
-- reimprime el recibo de junio, ahora dice "Fibra 10 Megas" — un plan que en
-- junio ese cliente no tenía y por el que no pagó.
--
-- NULLABLE Y SIN BACKFILL, por los mismos motivos que 0262:
--   · NULL = recibo anterior al congelamiento. Los tres renderers caen al JOIN
--     de siempre, o sea que se comportan EXACTAMENTE como hoy. No puede romper.
--   · Rellenarlos sería escribir una mentira: para los contratos que ya
--     cambiaron de plan, el plan de HOY no es el que decía su papel, y el plan
--     original no quedó guardado en ninguna parte recuperable (el `op_log` del
--     cambio tiene el UUID del plan viejo, pero solo para los 41 cambios hechos
--     con la app — y no cubre los recibos anteriores a ellos).
--   · No lo escribe un trigger: es una decisión de PRESENTACIÓN del cliente,
--     igual que el mes. El server no opina.
--
-- EQUIPO SIN ACTUALIZAR: nada. PowerSync sube solo las columnas que el device
-- conoce, y PostgREST las traduce a `ON CONFLICT DO UPDATE SET` de ESAS
-- columnas: un build viejo re-subiendo un recibo NO pisa `plan_label` con NULL.
--
-- GUARD DEL COBRADOR (0022, `recibos_check_cobrador_update`): es lista NEGRA,
-- así que la columna nueva queda escribible por el cobrador sin tocar el
-- trigger. Es lo que queremos: el recibo nace en SU device, offline, y el
-- rótulo se escribe en el mismo INSERT.
--
-- ADITIVA: no se bumpea `_dbWipeVersion` (política en ARQUITECTURA R4).
-- ===========================================================================
BEGIN;

ALTER TABLE public.recibos
  ADD COLUMN IF NOT EXISTS plan_label text;

COMMENT ON COLUMN public.recibos.plan_label IS
  'Nombre del plan TAL COMO SE IMPRIMIÓ en este recibo, congelado al emitirlo '
  '(ej. "Básico 5 Megas"). NULL = recibo anterior al congelamiento '
  '(2026-09-02) o recibo sin servicio asociado (cobro puntual): en ese caso los '
  'renderers lo resuelven por JOIN al plan vivo, como siempre. NUNCA rellenar '
  'los NULL con el plan actual: para todo contrato que cambió de plan eso '
  'escribiría un plan que el cliente no tenía cuando pagó. Espejo de '
  '`periodo_label` (0262) y por el mismo motivo.';

COMMIT;
