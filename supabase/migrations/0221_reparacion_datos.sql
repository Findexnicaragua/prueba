-- ============================================================================
-- 0221: REPARACIÓN DE DATOS (producción, vxxzesbmilfolwjhfxgr)
-- ============================================================================
--
-- Cuatro reparaciones que salen de la regla de negocio que fijó el dueño:
--
--   (a) "Desactivar un cliente = ya no tiene servicio Y está saldado."
--       → un cliente CON deuda NO puede estar desactivado. Se reactiva.
--   (b) El estado de contrato 'completado' SE ELIMINA: era un alias de
--       'cancelado'. Si un contrato cancelado quedó saldado o no es un dato
--       DERIVADO (se calcula de las cuotas), no un estado guardado.
--   (c) `clientes.vencimiento_mas_viejo` (denormalización que pinta el color
--       del pin del mapa) quedó desincronizado en 9 clientes.
--   (d) Checklists de tickets guardados como STRING jsonb en vez de array
--       (doble-encoding de PowerSync). 0220 pone el trigger que arregla las
--       escrituras FUTURAS; las 4 filas ya podridas se normalizan acá.
--
-- NINGUNO de los cuatro toca plata: no se crean/anulan/modifican cuotas, pagos,
-- recibos ni cargos. Solo se cambian cuatro columnas de ETIQUETA/METADATO
-- (`clientes.activo`, `contratos.estado`, `clientes.vencimiento_mas_viejo`,
-- `tickets.checklist`). Para que eso sea verificable y no una promesa, la
-- migración toma un SNAPSHOT global de la deuda viva al abrir la transacción y
-- ASSERTEA al cerrar que quedó idéntica: si algún trigger movió un centavo, la
-- transacción entera se revierte (RAISE EXCEPTION → ROLLBACK).
--
-- ES RE-EJECUTABLE: los cuatro bloques están acotados por el predicado del daño
-- (no por listas de IDs hardcodeadas), así que una segunda corrida toca 0
-- filas. Las temp tables son ON COMMIT DROP.
--
-- ----------------------------------------------------------------------------
-- ORDEN DE DEPLOY — LEER ANTES DE CORRER EL BLOQUE (b2)
-- ----------------------------------------------------------------------------
-- El bloque (b2) endurece el CHECK de `contratos.estado` sacando 'completado'.
-- La app INSTALADA HOY (v0.31.23) TODAVÍA ESCRIBE ese valor: el menú de
-- `contrato_detail_header.dart` ofrece la opción "Completado" (verificado en
-- HEAD, no solo en el working tree). Si el CHECK se endurece ANTES de que los
-- dispositivos actualicen, el usuario con la app vieja que marque "Completado"
-- recibe un `check_violation` (SQLSTATE 23514) al subir.
--
-- QUÉ TAN GRAVE: NO traba la cola. `esCodigoNoRetryable` (`connector.dart`,
-- ya shippeado) clasifica toda la clase 23 como PERMANENTE → avisa al usuario
-- y DESCARTA la op para no bloquear el resto. O sea: no se pierden cobros ni
-- se traba el device. El daño se limita a que ese contrato queda mostrando
-- 'Completado' en LA PANTALLA de ese equipo hasta que PowerSync le vuelva a
-- bajar la fila del server (que sigue diciendo 'cancelado' — el valor bueno),
-- más un error feo en pantalla.
--
-- Molesto pero no crítico. Aun así conviene correr (b2) junto con (o después
-- de) el release que saca la opción del menú; (a), (b1) y (c) se pueden correr
-- cuando sea, no dependen de ninguna versión de la app.
--
-- CÓMO CORRER SIN (b2): comentar las 3 líneas del `ALTER TABLE` del bloque
-- (b2) (están marcadas) y correr el archivo igual. Todo lo demás es
-- independiente. Después, cuando salga el release, descomentarlas y volver a
-- correr el archivo entero: es re-ejecutable, los otros bloques tocan 0 filas.
-- ----------------------------------------------------------------------------
--
-- MEDICIONES REALES (SELECTs corridos contra vxxz el 2026-08-08, antes de
-- aplicar nada): están citadas bloque por bloque más abajo.
-- ============================================================================

-- Lección 0218 → 0219 (mismo cuidado que 0220): forzar el encoding de la
-- sesión y NO meter acentos ni flechas en literales SQL que se van a devolver
-- o guardar. Los acentos quedan SOLO en comentarios, que no viajan a ningún
-- lado.
SET client_encoding = 'UTF8';

BEGIN;

-- ── Snapshot global de la deuda viva (la red de seguridad de plata) ─────────
-- Fórmula canónica del saldo (AGENTS, invariante #10):
--   saldo = monto + COALESCE(cargos_neto,0) - monto_pagado
-- Medido antes de aplicar (2026-08-08): 28.374 cuotas vivas por
-- C$26.190.362,58 · 28.222 pagos no anulados por C$25.151.117,05.
-- (El número exacto no importa acá — lo que importa es que sea IDÉNTICO al
-- final. Por eso se compara contra sí mismo, no contra una constante.)
CREATE TEMP TABLE _0221_deuda_global ON COMMIT DROP AS
SELECT count(*)                                                            AS cuotas,
       COALESCE(sum(cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado), 0) AS saldo,
       (SELECT count(*) FROM public.pagos WHERE anulado = false)           AS pagos_vivos,
       (SELECT COALESCE(sum(monto_cordobas),0) FROM public.pagos WHERE anulado = false) AS recaudado
  FROM public.cuotas cu
 WHERE cu.estado IN ('pendiente','parcial');


-- ============================================================================
-- (a) REACTIVAR CLIENTES DESACTIVADOS QUE TIENEN DEUDA
-- ============================================================================
-- POR QUÉ: la regla del dueño dice que desactivar = "sin servicio Y saldado".
-- Un cliente desactivado con deuda es una contradicción: su plata se sigue
-- cobrando pero queda escondido de las listas de la app (los filtros de UI
-- esconden a los inactivos), así que nadie va a cobrarle. 14 de estos 35
-- registraron un pago en los últimos 60 días → son clientes VIVOS mal
-- etiquetados, no bajas.
--
-- SELECT "antes" (corrido el 2026-08-08 → 35 clientes / 242 cuotas /
-- C$227.817,00 en deuda, TODOS del tenant Telecable Mairena):
--   SELECT count(DISTINCT c.id) AS clientes, count(*) AS cuotas,
--          sum(cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado) AS saldo
--     FROM clientes c
--     JOIN cuotas cu    ON cu.cliente_id = c.id
--     JOIN contratos ct ON ct.id = cu.contrato_id
--    WHERE c.activo = false
--      AND cu.estado IN ('pendiente','parcial')
--      AND cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado > 0
--      AND ct.estado = 'activo';
--
-- ⚠️ ALCANCE ACOTADO A PROPÓSITO — Y NO COINCIDE CON EL GUARD DE 0220. LEER:
-- El predicado de acá exige `ct.estado = 'activo'`, que es el hallazgo medido
-- y aprobado (35 clientes). Si se afloja a "cualquier cuota viva con saldo,
-- sin mirar el estado del contrato", el universo sube a 75 clientes /
-- 378 cuotas / C$309.486,41 — 40 clientes más, casi todos con el contrato
-- suspendido o cancelado.
--
-- El guard nuevo de 0220 (`clientes_guard_desactivar_con_deuda_trg`) usa la
-- versión AMPLIA: no filtra por estado de contrato, "la deuda de un contrato
-- cancelado sigue siendo deuda". Con lo cual, corriendo 0220 + 0221 como están,
-- quedan 40 clientes en un estado que el guard ya no dejaría crear: inactivos
-- con deuda. No rompe nada (el guard solo mira la transición true→false, así
-- que esos 40 se siguen editando normal) pero es una inconsistencia declarada.
--
-- Se dejó acotado porque ampliarlo es una decisión de PRODUCTO que no estaba
-- aprobada — reactivar 40 clientes los devuelve a las listas y rutas de cobro.
-- Si el dueño la aprueba, alcanza con borrar la línea `AND ct.estado = 'activo'`
-- del EXISTS de abajo (y el JOIN a contratos queda de más).
--
-- NO se tocan contratos ni cuotas: solo el flag `activo`.
UPDATE public.clientes c
   SET activo = true
 WHERE c.activo = false
   AND EXISTS (
     SELECT 1
       FROM public.cuotas cu
       JOIN public.contratos ct ON ct.id = cu.contrato_id
      WHERE cu.cliente_id = c.id
        AND cu.estado IN ('pendiente','parcial')
        AND cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado > 0
        AND ct.estado = 'activo'
   );


-- ============================================================================
-- (b1) MIGRAR contratos.estado 'completado' → 'cancelado'
-- ============================================================================
-- POR QUÉ: 'completado' y 'cancelado' significaban lo mismo (contrato
-- terminal, sin servicio). Peor: 31 de los 34 contratos marcados 'completado'
-- son INDEFINIDOS — un contrato sin duración no puede "completarse", así que
-- la etiqueta era directamente incorrecta.
--
-- ⚠️ ESTO ES UN CAMBIO DE ETIQUETA, NADA MÁS. No se ejecuta la lógica de
-- cancelación del contrato: NO se anulan cuotas, NO se toca fecha_fin, NO se
-- borra deuda. Esos 34 contratos arrastran 211 cuotas vivas por C$193.676,00
-- (84 de ellas ya vencidas, C$83.337,00) y esa plata es COBRABLE: tiene que
-- sobrevivir intacta. El assert del final lo verifica.
--
-- SELECT "antes" (corrido el 2026-08-08):
--   SELECT estado, count(*) FROM contratos GROUP BY estado;
--     activo 5478 · cancelado 59 · completado 34 · suspendido 55
--   (los 34 'completado' = 27 Telecable Mairena + 7 Telenet)
--
-- EFECTO COLATERAL ESPERADO (benigno): el trigger `contratos_vmv` dispara en
-- los 34 UPDATEs y recalcula `vencimiento_mas_viejo` del cliente. El valor NO
-- cambia, porque `recalc_vencimiento_mas_viejo` solo cuenta cuotas de
-- contratos con estado = 'activo' y tanto 'completado' como 'cancelado' quedan
-- fuera de ese filtro por igual. En el peor caso corrige un valor ya podrido,
-- que es justo lo que hace el bloque (c).
UPDATE public.contratos
   SET estado = 'cancelado'
 WHERE estado = 'completado';


-- ============================================================================
-- (b2) SACAR 'completado' DEL CHECK DE contratos.estado
-- ============================================================================
-- PREFERIBLEMENTE NO CORRER ESTE BLOQUE ANTES DEL RELEASE — ver la advertencia
-- de ORDEN DE DEPLOY en la cabecera (la app v0.31.23 todavía escribe
-- 'completado' → check_violation 23514 → op descartada + error en pantalla de
-- ESE equipo; la cola NO se traba, pero es una fricción evitable).
--
-- Constraint vigente medida en producción (2026-08-08):
--   contratos_estado_check
--     CHECK (estado = ANY (ARRAY['activo','suspendido','completado','cancelado']))
--
-- Se verificó además que 'completado' NO aparece en NINGÚN otro objeto del
-- server: 0 funciones (`SELECT proname FROM pg_proc WHERE prosrc ILIKE
-- '%completado%'` → vacío), 0 vistas, 0 policies RLS y 0 reglas de sync de
-- PowerSync. La única referencia server-side era esta CHECK.
--
-- Va DESPUÉS de (b1) a propósito: primero se normalizan las filas, después se
-- angosta el dominio. Al revés fallaría la validación de la constraint.
--
-- ↓↓↓ ESTAS 3 LÍNEAS SON LAS QUE SE COMENTAN SI EL RELEASE TODAVÍA NO SALIÓ ↓↓↓
ALTER TABLE public.contratos DROP CONSTRAINT IF EXISTS contratos_estado_check;
ALTER TABLE public.contratos
  ADD CONSTRAINT contratos_estado_check
  CHECK (estado = ANY (ARRAY['activo'::text, 'suspendido'::text, 'cancelado'::text]));
-- ↑↑↑ FIN DEL BLOQUE (b2) OPCIONAL ↑↑↑


-- ============================================================================
-- (c) RESINCRONIZAR clientes.vencimiento_mas_viejo
-- ============================================================================
-- QUÉ ES: denormalización que alimenta el color del pin en el mapa y el filtro
-- "solo cobrables" (`mapa_screen.dart`). NO es plata — ningún invariante de
-- `invariantes_dinero.sql` la usa (0 menciones en ese archivo).
--
-- SELECT "antes" (corrido el 2026-08-08 → 9 clientes divergentes, todos del
-- tenant Telenet, todos con `activo = true` y contratos activos):
--   WITH esperado AS (
--     SELECT c.id, c.vencimiento_mas_viejo AS guardado,
--            (SELECT MIN(cu.fecha_vencimiento) FROM cuotas cu
--               LEFT JOIN contratos ct ON ct.id = cu.contrato_id
--              WHERE cu.cliente_id = c.id
--                AND cu.estado IN ('pendiente','parcial')
--                AND COALESCE(ct.estado,'activo') = 'activo') AS real
--       FROM clientes c)
--   SELECT count(*) FROM esperado WHERE guardado IS DISTINCT FROM real;   -- 9
--
-- En los 9 el valor guardado está 29-31 días DESPUÉS del real (exactamente un
-- mes tarde): el pin del mapa los muestra menos vencidos de lo que están, o
-- sea que se caen del filtro de cobrables y el cobrador no los visita.
--
-- CAUSA PROBABLE (para el que venga después, NO se arregla acá): el cliente
-- Dart espeja esta columna offline con `recalcVmvDeContrato`
-- (`lib/data/utils/colchon_indefinido.dart`), que usa el MISMO predicado pero
-- contra la base LOCAL. Si el dispositivo no tenía sincronizada la cuota más
-- vieja, su MIN local da un mes más tarde y PowerSync lo sube pisando el valor
-- correcto del server — sin que cambie ninguna cuota, así que el trigger
-- `cuotas_vmv` nunca se entera. Esta migración limpia el daño acumulado; la
-- reincidencia hay que atacarla del lado del mirror, no acá.
--
-- CÓMO SE REPARA: NO se duplica la fórmula en el UPDATE. Se detectan los
-- divergentes y después se invoca la función viva del server,
-- `recalc_vencimiento_mas_viejo(uuid)` (definición de 0185, verificada en
-- producción), que ya trae su propia guarda anti-escritura-no-op: si el valor
-- coincide no escribe, así que no genera churn de PowerSync.
--
-- POR QUÉ NO UN BARRIDO DE TODOS LOS CLIENTES: son 6.096 clientes y `cuotas`
-- no tiene índice por `cliente_id` solo (el que hay es
-- `(tenant_id, cliente_id, estado)`), así que 6.096 llamadas sueltas a la
-- función escanean el índice entero cada vez (57.005 cuotas) y la migración
-- tardaría minutos. Detectando primero, el loop hace 9 llamadas.
--
-- Va ÚLTIMO para absorber cualquier recálculo que hayan disparado (a) y (b1).
CREATE TEMP TABLE _0221_vmv_divergentes ON COMMIT DROP AS
SELECT c.id
  FROM public.clientes c
 WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
         SELECT MIN(cu.fecha_vencimiento)
           FROM public.cuotas cu
           LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
          WHERE cu.cliente_id = c.id
            AND cu.estado IN ('pendiente','parcial')
            AND COALESCE(ct.estado,'activo') = 'activo'
       );

DO $$
DECLARE
  v_id      uuid;
  v_total   int := 0;
BEGIN
  FOR v_id IN SELECT id FROM _0221_vmv_divergentes LOOP
    PERFORM public.recalc_vencimiento_mas_viejo(v_id);
    v_total := v_total + 1;
  END LOOP;
  -- Mensajes de RAISE en ASCII puro a proposito: la salida de psql/CLI ya
  -- rompio acentos antes en este repo (ver 0219_fix_mojibake_*).
  RAISE NOTICE '0221 (c): recalculados % clientes (esperado 9 en la 1ra corrida, 0 despues)', v_total;
END;
$$;


-- ============================================================================
-- (d) NORMALIZAR LOS CHECKLISTS jsonb DOBLE-ENCODEADOS
-- ============================================================================
-- QUÉ PASÓ: PowerSync sube el valor de una columna jsonb como STRING JSON
-- literal, así que Postgres guarda el ESCALAR "[]" en vez del array []. Es el
-- mismo bug que 0194 arregló para `solicitudes_accion.datos`.
--
-- 0220 (b) instala los triggers de desempaquetado, pero un BEFORE trigger solo
-- toca lo que se ESCRIBE: las filas ya guardadas mal siguen mal hasta que
-- alguien las vuelva a escribir. La reparación del dato en reposo es acá — el
-- encabezado de 0220 la promete explícitamente ("las 3+1 filas ya corruptas las
-- normaliza 0221") y sin este bloque esa promesa quedaba sin cumplir.
--
-- SELECT "antes" (corrido el 2026-08-08): 3 de 6 `tickets` y 1 de 3
-- `ticket_tipos`, los 4 con el valor "[]" (o sea, checklist VACÍO). El daño de
-- HOY es cero; lo que se cierra es el bug LATENTE: si alguno se llenara con
-- ítems, todo `jsonb_array_elements` / `->>` sobre esa columna revienta o
-- devuelve nada.
--
-- ORDEN vs 0220: indistinto. Si 0220 ya corrió, sus triggers ven el valor ya
-- normalizado y no hacen nada (idempotente). Si todavía no corrió, este UPDATE
-- arregla igual — solo que sin el trigger la corrupción puede volver.
--
-- POR QUÉ ES SEGURO (los 6 triggers de `tickets` verificados uno por uno):
--   · trg_tickets_validar_transicion  — BEFORE UPDATE OF estado: no dispara.
--   · trg_tickets_marcar_verificacion — pide `NEW.estado='cerrado'` y que el
--     estado CAMBIE: no dispara (acá el estado no se toca).
--   · trg_tickets_eventos_auto        — solo inserta evento si cambió `estado`
--     o `asignado_a`: no dispara, no se inventa historial.
--   · trg_tickets_coordinador_solo_orden / trg_tickets_gestor_solo_verificacion
--     — hacen early-return si el rol no es coordinador/gestor. Verificado en
--     producción que con el rol que corre migraciones `is_coordinador()` e
--     `is_admin_usuarios()` devuelven false sin lanzar excepción.
--   · trg_tickets_correlativo         — BEFORE INSERT: no dispara.
UPDATE public.tickets
   SET checklist = (checklist #>> '{}')::jsonb
 WHERE jsonb_typeof(checklist) = 'string';

UPDATE public.ticket_tipos
   SET checklist_template = (checklist_template #>> '{}')::jsonb
 WHERE jsonb_typeof(checklist_template) = 'string';


-- ============================================================================
-- ASSERT DE PLATA — si algo movió un centavo, esto revierte TODO
-- ============================================================================
-- Ninguno de los tres bloques debería tocar cuotas ni pagos. Lo verificamos en
-- vez de asumirlo: la app tiene triggers que recalculan solos (cancelación de
-- contrato, limpieza de cuotas excedentes, mora) y un cambio de etiqueta mal
-- pensado podría despertarlos. Si el conteo o el saldo cambió, cortamos con
-- excepción y la transacción entera hace ROLLBACK.
DO $$
DECLARE
  a record;
  d record;
BEGIN
  SELECT * INTO a FROM _0221_deuda_global;

  SELECT count(*) AS cuotas,
         COALESCE(sum(cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado), 0) AS saldo,
         (SELECT count(*) FROM public.pagos WHERE anulado = false) AS pagos_vivos,
         (SELECT COALESCE(sum(monto_cordobas),0) FROM public.pagos WHERE anulado = false) AS recaudado
    INTO d
    FROM public.cuotas cu
   WHERE cu.estado IN ('pendiente','parcial');

  IF d.cuotas <> a.cuotas OR ABS(d.saldo - a.saldo) > 0.01
     OR d.pagos_vivos <> a.pagos_vivos OR ABS(d.recaudado - a.recaudado) > 0.01 THEN
    RAISE EXCEPTION
      '0221 ABORTADA: la migracion movio plata. cuotas % -> %, saldo % -> %, pagos % -> %, recaudado % -> %',
      a.cuotas, d.cuotas, a.saldo, d.saldo, a.pagos_vivos, d.pagos_vivos, a.recaudado, d.recaudado;
  END IF;

  RAISE NOTICE '0221 assert OK: % cuotas vivas / saldo % / % pagos vivos / recaudado % - sin cambios',
    d.cuotas, d.saldo, d.pagos_vivos, d.recaudado;
END;
$$;

COMMIT;


-- ============================================================================
-- VERIFICACIÓN "DESPUÉS" — correr esto y leer la columna `resultado`
-- ============================================================================
-- Las filas cuyo `esperado` es 0 son ASERCIONES DURAS: si no dan 0, algo falló.
-- Las que citan totales son de REFERENCIA: los conteos medidos el 2026-08-08
-- se mueven solos con la operación normal (altas, cobros, generación mensual).
-- Lo que ahí importa es la MAGNITUD — que la deuda de los cancelados haya
-- SUBIDO ~211 cuotas / ~C$193.676, no que baje.
SELECT 'a) clientes inactivos con deuda (contrato activo)' AS chequeo,
       (SELECT count(DISTINCT c.id)
          FROM public.clientes c
          JOIN public.cuotas cu    ON cu.cliente_id = c.id
          JOIN public.contratos ct ON ct.id = cu.contrato_id
         WHERE c.activo = false
           AND cu.estado IN ('pendiente','parcial')
           AND cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado > 0
           AND ct.estado = 'activo')::text AS resultado,
       '0' AS esperado

UNION ALL
SELECT 'b1) contratos con estado = completado',
       (SELECT count(*) FROM public.contratos WHERE estado = 'completado')::text,
       '0'

UNION ALL
SELECT 'b1) contratos por estado (activo/suspendido/cancelado)',
       (SELECT string_agg(estado || '=' || n::text, ' | ' ORDER BY estado)
          FROM (SELECT estado, count(*) AS n FROM public.contratos GROUP BY estado) t),
       'sin completado (ref. 2026-08-08: activo=5478 | cancelado=93 | suspendido=55)'

UNION ALL
SELECT 'b2) el CHECK ya no admite completado',
       (SELECT pg_get_constraintdef(oid) ILIKE '%completado%'
          FROM pg_constraint
         WHERE conrelid = 'public.contratos'::regclass
           AND conname = 'contratos_estado_check')::text,
       'false (si da true es que comentaste el bloque b2 a proposito)'

UNION ALL
-- La deuda de los ex-'completado' tiene que seguir viva. Se cuenta sobre TODOS
-- los cancelados porque después del UPDATE ya no hay forma de distinguirlos.
-- Aritmética verificada el 2026-08-08 (esto es la prueba de que no se borró
-- deuda, es el chequeo más importante del archivo):
--   59 contratos cancelados de antes -> 137 cuotas vivas / C$93.668,46
--   34 contratos ex-'completado'     -> 211 cuotas vivas / C$193.676,00
--   ----------------------------------------------------------------
--   93 cancelados despues            -> 348 cuotas vivas / C$287.344,46
SELECT 'b) deuda viva de contratos cancelados (incluye la de los 34 ex-completado)',
       (SELECT count(*)::text || ' cuotas / C$' ||
               to_char(COALESCE(sum(cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado),0),
                       'FM999999999.00')
          FROM public.cuotas cu
          JOIN public.contratos ct ON ct.id = cu.contrato_id
         WHERE ct.estado = 'cancelado'
           AND cu.estado IN ('pendiente','parcial')
           AND cu.monto + COALESCE(cu.cargos_neto,0) - cu.monto_pagado > 0),
       '~348 cuotas / ~C$287344.46 (antes eran 137 / C$93668.46: tiene que SUBIR)'

UNION ALL
SELECT 'c) clientes con vencimiento_mas_viejo divergente',
       (SELECT count(*)
          FROM public.clientes c
         WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
                 SELECT MIN(cu.fecha_vencimiento)
                   FROM public.cuotas cu
                   LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
                  WHERE cu.cliente_id = c.id
                    AND cu.estado IN ('pendiente','parcial')
                    AND COALESCE(ct.estado,'activo') = 'activo'))::text,
       '0'

UNION ALL
-- Los 4 checklists tienen que haber quedado como ARRAY. Si sigue habiendo
-- 'string', el `#>> '{}'` no desempaquetó (valor no parseable como jsonb).
SELECT 'd) checklists jsonb todavia guardados como string',
       ((SELECT count(*) FROM public.tickets      WHERE jsonb_typeof(checklist) = 'string')
      + (SELECT count(*) FROM public.ticket_tipos WHERE jsonb_typeof(checklist_template) = 'string'))::text,
       '0 (antes 2026-08-08: 3 tickets + 1 ticket_tipo)';
