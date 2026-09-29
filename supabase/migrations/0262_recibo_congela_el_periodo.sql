-- ===========================================================================
-- 0262 — El recibo CONGELA el mes que imprime.
--
-- EL PROBLEMA (caso real, Telecable Mairena 2026-08-26):
-- el recibo HL-00230 (cliente R20014, Gloria Maria Larios) esta en manos del
-- cliente diciendo "Julio 2026", y la app hoy muestra "Junio 2026" para ese
-- MISMO recibo. Mismo cobro, misma plata, el correlativo se uso una sola vez.
--
-- POR QUE PASA: `recibos` guarda numero, cobrador, monto, fecha, formato y
-- anulacion — pero NO guarda el rotulo del mes. Cada impresion lo RECALCULA
-- desde `cuota.periodo` + `contrato.dia_pago` con la regla vigente en ese
-- momento (dia <= 14 -> mes anterior; ver docs/reglas/mes-servicio.md). Esa
-- regla cambio 3+ veces en 2026, asi que un recibo reimpreso despues de un
-- cambio contradice al papel que el cliente guardo.
--
-- LO QUE HACE ESTA COLUMNA: la app escribe el rotulo AL EMITIR el recibo, y
-- toda impresion posterior lo lee de aca en vez de recalcularlo. El papel deja
-- de poder contradecirse a si mismo aunque la regla vuelva a cambiar.
--
-- POR QUE ES NULLABLE Y NO SE HACE BACKFILL — decision deliberada:
--   · NULL significa "este recibo es anterior al congelamiento". Los tres
--     renderers (raster, PDF y texto ESC/POS) caen a calcular, o sea que se
--     comportan EXACTAMENTE como hoy. La columna no puede romper nada.
--   · Rellenar los viejos con la regla de HOY seria escribir una mentira: para
--     los ~49 recibos impresos entre el 2026-07-31 17:37 y el 2026-08-01 12:32
--     (la ventana en que la regla decia "el mes del periodo") el valor de hoy
--     NO es lo que dice su papel. No hay forma de recuperar el rotulo original:
--     no quedo guardado en ningun lado. Inventarlo seria peor que dejarlo NULL.
--   · Tampoco lo escribe un trigger: el rotulo es una decision de PRESENTACION
--     del cliente (que ademas depende de si la cuota es manual, caso en que el
--     recibo NO imprime periodo). El server no deberia opinar sobre eso.
--
-- QUE PASA CON UN EQUIPO QUE NO ACTUALIZO: nada. PowerSync sube solo las
-- columnas que el device conoce (`connector.dart` -> `upsert({...data})`), y
-- PostgREST traduce eso a `ON CONFLICT DO UPDATE SET` de ESAS columnas. Un
-- build viejo re-subiendo un recibo NO pisa `periodo_label` con NULL.
--
-- EL GUARD DE COLUMNAS DEL COBRADOR (0022, `recibos_check_cobrador_update`) es
-- una lista NEGRA —enumera lo que NO puede cambiar— asi que esta columna nueva
-- queda escribible por el cobrador sin tocar el trigger. Es lo que queremos: el
-- recibo nace en SU device, offline, y el rotulo se escribe en el mismo INSERT.
--
-- ADITIVA: no se bumpea `_dbWipeVersion` (politica en ARQUITECTURA R4).
-- ===========================================================================
BEGIN;

ALTER TABLE public.recibos
  ADD COLUMN IF NOT EXISTS periodo_label text;

COMMENT ON COLUMN public.recibos.periodo_label IS
  'Mes de servicio TAL COMO SE IMPRIMIO en este recibo, congelado al emitirlo '
  '(ej. "Junio 2026"). NULL = recibo anterior al congelamiento (2026-08-26) o '
  'recibo que no imprime periodo (cuota manual / puente): en ese caso los '
  'renderers lo calculan como siempre. NUNCA rellenar los NULL con la regla '
  'vigente: para los recibos de la ventana 2026-07-31/2026-08-01 eso escribiria '
  'un mes distinto al del papel que tiene el cliente.';

COMMIT;
