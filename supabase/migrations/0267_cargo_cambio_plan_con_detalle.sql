-- 0267 — El cargo del cambio de plan se identifica y guarda su transición.
--
-- POR QUÉ (pedido de Rubén, 2026-09-02): al cambiar de plan con prorrateo, el
-- recibo del cliente no explica NADA. Verificado contra producción: los tres
-- tenants tienen el bloque del desglose apagado ("cuota","visible":false), así
-- que el cliente recibe un papel que dice "Monto: 745,16" y ni una línea sobre
-- el cambio. Y aunque lo prendieran, la única línea posible sería
-- "Cargo: Diferencia por cambio de plan +245,16": sin decir de qué plan a qué
-- plan, cuántos días, ni a qué precio diario.
--
-- La causa de fondo es que ESOS DATOS NO SE GUARDAN. El plan viejo, su precio,
-- el rango de días y el desglose por mes viven en el diálogo del admin y mueren
-- cuando se cierra. `cargos_extra` no tiene dónde ponerlos.
--
-- DOS CAMBIOS, los dos ADITIVOS:
--
-- 1. `origen = 'cambio_plan'` — hoy el cargo nace con origen='cobro', que es el
--    cajón de los cargos manuales, así que es indistinguible de un cargo que
--    alguien puso a mano. Con origen propio, las dos funciones que rotulan un
--    cargo (`cargoEtiquetaRecibo` y `etiquetaDe`) pueden darle nombre propio,
--    igual que ya hacen con 'puente' (el cambio de fecha de pago, R13).
--    Se elige extender `origen` y NO agregar un `tipo` nuevo: hay cuatro
--    lugares que enumeran los TIPOS a mano para sumar plata, y un tipo
--    desconocido sumaría cero EN SILENCIO. `origen` no participa de ninguna
--    suma; el cargo sigue siendo tipo='otro', que ya suma bien.
--
-- 2. `cargos_extra.detalle` (text, NULL) — el JSON de la transición: nombre y
--    precio del plan viejo y del nuevo, el rango de días y los tramos por mes.
--    Va en columna propia y NO en `descripcion` porque `descripcion` se imprime
--    CRUDA en el recibo y en el detalle de la cuota: meter JSON ahí se lo
--    mostraría al cliente.
--    Nullable a propósito: los 41 cambios de plan ya hechos no lo tienen y no
--    se puede reconstruir (el plan viejo solo sobrevive como UUID en `op_log`,
--    que no se sincroniza al celular del cobrador). Sus reimpresiones siguen
--    como hoy; está documentado en docs/reglas/cambio-plan.md.
--
-- ADITIVO: NO se bumpea `_dbWipeVersion` (política de R4 — PowerSync aplica
-- columnas nuevas in-place). Las sync rules NO cambian: los cinco buckets ya
-- bajan `SELECT * FROM cargos_extra`.

-- ── 1. origen: sumar 'cambio_plan' a los permitidos ──────────────────────────
alter table public.cargos_extra
  drop constraint if exists cargos_extra_origen_check;

alter table public.cargos_extra
  add constraint cargos_extra_origen_check
  check (origen = any (array[
    'cobro'::text,
    'ajuste'::text,
    'promo'::text,
    'liquidacion'::text,
    'puente'::text,
    'credito'::text,
    'cambio_plan'::text
  ]));

comment on column public.cargos_extra.origen is
  'De qué operación nació el cargo. cobro=manual del cobrador/admin · ajuste y '
  'promo=descuentos del admin · liquidacion=cancelación · puente=cambio de '
  'fecha de pago (R13) · credito=aplicación de saldo a favor (R17) · '
  'cambio_plan=diferencia prorrateada del cambio de plan (R22). NO participa de '
  'ninguna suma de plata: eso lo decide `tipo`.';

-- ── 2. detalle: el JSON de la transición, para que el recibo pueda explicarla ─
alter table public.cargos_extra
  add column if not exists detalle text;

comment on column public.cargos_extra.detalle is
  'JSON con el contexto que la línea del cargo necesita para explicarse sola en '
  'el recibo. Hoy lo escribe SOLO el cambio de plan (origen=cambio_plan): '
  '{plan_antes, precio_antes, plan_despues, precio_despues, desde, hasta, '
  'dias, tramos:[{anio,mes,dias,precio_dia,subtotal}]}. NULL en todo cargo que '
  'no lo necesite y en los cambios de plan anteriores al 2026-09-02. NUNCA se '
  'imprime crudo: los renderers lo parsean y lo maquetan.';

-- ── 3. Lo mismo para la BAJA de plan, que no pasa por cargos_extra ───────────
--
-- El upgrade deja un `cargos_extra` sobre la cuota; el downgrade acredita en
-- `saldos_favor` y NO toca la cuota (invariante #4: el crédito no es un pago).
-- Por eso hoy una baja de plan es INVISIBLE en todo comprobante: el cliente no
-- se entera de que le quedó plata a favor. Para que el recibo pueda decirlo,
-- el crédito necesita el mismo contexto que el cargo.
--
-- `saldos_favor` ya tiene `cuota_id`, así que el recibo puede encontrarlo por
-- la misma cuota que ya está cobrando.

alter table public.saldos_favor
  add column if not exists detalle text;

comment on column public.saldos_favor.detalle is
  'Mismo JSON que cargos_extra.detalle y por el mismo motivo: que el recibo '
  'pueda explicar la transición. Lo escribe la BAJA de plan (motivo "Crédito '
  'por cambio de plan (downgrade)"). NULL en el resto de los créditos, que ya '
  'se explican con su `motivo`.';
