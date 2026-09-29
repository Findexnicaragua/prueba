-- 0259_condonar_deuda_al_cancelar.sql
--
-- QUE: mover al SERVER la regla del dueño (2026-08-24) "cancelar un contrato
-- condona TODA la deuda viva". Hoy vive SOLO en `contratos_repo.cancelarContrato`
-- (Dart), así que se aplica únicamente si quien APRUEBA la baja tiene el build
-- nuevo: 39 cancelaciones con la lógica vieja y CERO con la nueva.
--
-- MEDIDO EN PRODUCCIÓN (vxxz, 2026-08-25), tres corridas seguidas, idéntico:
--   Telecable Mairena: 44 contratos / 146 cuotas / C$102.834,54, TODAS
--     `pendiente`, TODAS con `cancelado_en >= 2026-08-24`, CERO con un peso
--     encima, CERO cargos, actor válido con rol 'admin' en las 44.
--   Telenet: 5 contratos / 23 cuotas / C$19.147,81, TODAS anteriores al 24/08.
-- La población NO estaba creciendo (el diseño A leyó mal dos snapshots): las
-- bajas entran a RÁFAGAS por PowerSync (48 el 25/08, 57 el 19/08, 5 el 24/08).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- DECISIÓN 1 — POR QUÉ SE REESCRIBE `monto` Y NO SE INSERTA UN DESCUENTO
-- ═══════════════════════════════════════════════════════════════════════════
-- `cuotas_forzar_derivados` es BEFORE UPDATE sin WHEN: recalcula SIEMPRE
-- `monto_pagado` desde `pagos` y `cargos_neto` desde `cargos_extra`, y re-deriva
-- `estado`. De los cuatro campos del saldo, el ÚNICO que no toca es `monto`.
--   · escribir `cargos_neto = 0` (lo que hace hoy el Dart) NO sobrevive;
--   · imponer `estado` NO sobrevive (salvo 'anulada');
--   · escribir `monto := pagado_aplicado - calcular_cargos_neto(cuota)` SÍ:
--     el propio trigger calcula v_total = monto + cargos = pagado = v_pagado
--     y deriva 'pagada'. Saldo canónico (invariante #10) = 0 EXACTO.
-- No se le pelea al trigger: se le despeja la ecuación.
--
-- La alternativa "insertar un `cargos_extra` descuento_monto origen='liquidacion'"
-- se DESCARTÓ con código en la mano, no por gusto: `_previasValidadas`
-- (contratos_repo.dart:1259) aborta `revertirCancelacion` si `cargos_neto` o
-- `monto_pagado` difieren del snapshot que escribió el CLIENTE. Un descuento
-- inyectado por el server cambia `cargos_neto` en TODA baja ⇒ el revert queda
-- roto para siempre, y el revert lo corre el cliente, incluidas las versiones
-- viejas que son justamente las que no se pueden arreglar. Tocar SOLO `monto`
-- es lo único que la guarda del revert NO mira.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- DECISIÓN 2 — TRES RAMAS, NO DOS (la del medio es la que faltaba)
-- ═══════════════════════════════════════════════════════════════════════════
--   (a) cuota con un pago EN CUARENTENA  -> NO SE TOCA, se loguea.
--   (b) cuota con plata aplicada         -> monto := pagado - cargos.
--   (c) cuota sin un peso encima         -> ANULAR.
--
-- (c) nunca puede tocar una cuota con plata: `cuotas_anular_pagos_asociados_trg`
-- anula EN CASCADA sus `pagos` y sus `recibos` — borraría plata de caja y un
-- comprobante que el cliente tiene en la mano. Regla inviolable.
--
-- (a) es la corrección más importante sobre los tres diseños previos. Si una
-- cuota tiene como única plata un pago `en_revision`, `monto_pagado` la ve
-- VACÍA. Anularla mata en cascada un cobro real pendiente de aprobación (ese
-- agujero lo tienen HOY el trigger 0234, la migración 0258 y el Dart). Pero
-- condonarla por la rama (b) es PEOR y es una trampa permanente: monto := 0,
-- `cuota_total_a_cobrar` queda en 0, y cuando el operador aprueba la cuarentena
-- `pagos_guard_sobrepago_update_trg` evalúa 0 + X <= 0 + 0.01 = falso y la
-- devuelve a cuarentena PARA SIEMPRE — el cliente pagó y el sistema no puede
-- acreditarlo nunca. Además el op_log declararía "condonado C$X" sobre plata
-- que el cliente SÍ pagó.
-- Por eso se SALTEA: la cuota queda como está, el humano resuelve la bandeja, y
-- cuando el pago se aplica el trigger de `pagos` (bloque 3) la termina de
-- condonar sola. Nada se destruye y el invariante la reporta mientras tanto.
-- Medido hoy: 2 pagos en cuarentena, 0 sobre contratos cancelados.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- DECISIÓN 3 — UNA SOLA REGLA PARA TODOS · FLAG COMO VÁLVULA (default ON)
-- ═══════════════════════════════════════════════════════════════════════════
-- La regla nace ENCENDIDA en TODOS los tenants. Decisión de Rubén (2026-08-25).
--
-- Se evaluó excluir a Telenet y se decidió que NO. El caso que se planteó:
-- Telenet usa la cancelación como "se fue debiendo" —de los 5 contratos que
-- 0258 preservó a mano, TRES son de agosto (0193 y 0354 del 09/08, 0605 del
-- 12/08)— y cancela ~28 contratos/mes. Rubén eligió igual que la regla sea una
-- sola, sin excepciones por empresa.
--
-- QUÉ PROTEGE LO VIEJO: **el corte por fecha, NO el flag.** Verificado uno por
-- uno: los 5 contratos preservados de Telenet (C$19.147,81 en total) son TODOS
-- anteriores al corte —el más nuevo por 12 días— así que ninguno entra ni al
-- backfill ni al trigger. Y el trigger corre solo en la TRANSICIÓN a cancelado,
-- así que un re-put de PowerSync tampoco los despierta.
--
-- QUÉ CAMBIA PARA TELENET, dicho crudo: de acá en adelante cada baja evapora la
-- cartera viva de ese contrato, sin aviso en la UI y sin palanca propia (el
-- setting es `editable_por='super_admin'`, y la RLS `settings_write_admin`
-- exige `editable_por <> 'super_admin'`). La herramienta para "se fue debiendo
-- y le quiero seguir cobrando" pasa a ser SUSPENDER —conserva la deuda y es
-- reversible— y eso HAY QUE AVISÁRSELO, antes de aplicar esto.
--
-- Dimensión real del impacto, medida y no estimada: en toda la historia de
-- Telenet hay 5 contratos con deuda viva post-baja, C$19.147,81, promedio
-- C$3.830 por contrato. (Un cálculo anterior de "~C$9.000/mes" NO lo sostiene
-- la data y se descartó.)
--
-- El flag queda como VÁLVULA DE ESCAPE explícita, no como interruptor de
-- encendido: para apagarlo en un tenant hay que escribir 'false' a mano.
-- Filtrar por el TEXTO del motivo se descartó: no discrimina (0605 dice
-- "Solicitud del cliente — ... Corte el 25 de julio" y matchea el regex de 0258
-- de puro casual).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- DECISIÓN 4 — CORTE POR FECHA, NO POR MOTIVO
-- ═══════════════════════════════════════════════════════════════════════════
-- 2026-08-24 00:00 hora Nicaragua (UTC-6, sin DST) = el día en que la regla
-- entró en vigor. VERIFICADO que parte la población exacto: los 44 de Mairena
-- son todos posteriores, los 5 de Telenet todos anteriores. Lo anterior a la
-- regla ya se decidió en 0258 y no se revisa. El corte vive también en el
-- trigger, no solo en el backfill: si mañana se prende el flag de Telenet, sus
-- deudas viejas siguen intocables.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- DECISIÓN 5 — EL TRIGGER NUNCA LEVANTA EXCEPCIÓN
-- ═══════════════════════════════════════════════════════════════════════════
-- Contra lo que proponían A y C. `esCodigoNoRetryable` (connector.dart:459)
-- descarta 23*/42*/22*/P0001: un RAISE acá NO es "falla ruidosa", es la
-- cancelación ENTERA tirada a la basura con el único rastro en el
-- shared_preferences del device — mientras el cliente ya subió sus UPDATE de
-- cuotas (van antes en el writeTransaction). Quedaría un contrato ACTIVO en
-- Postgres con las cuotas ya saldadas y el operador convencido de que canceló:
-- el ISP deja de facturar a un cliente vivo y no hay una fila que lo diga.
-- Peor todavía: `42*` incluye cualquier error de programación de ESTA función.
-- Se prefiere deuda que sobrevive (visible, la caza el invariante y se arregla)
-- antes que una baja que se pierde en silencio.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- ORDEN DE TRIGGERS (verificado, no de memoria)
-- ═══════════════════════════════════════════════════════════════════════════
-- `pg_get_triggerdef` contra vxxz:
--   cuotas_vmv                    -> AFTER INSERT OR DELETE OR UPDATE **OF
--                                    estado, fecha_vencimiento, contrato_id,
--                                    cliente_id**  (SÍ tiene lista de columnas)
--   trg_cuotas_anular_pagos_asoc. -> AFTER UPDATE **OF estado**
-- `UPDATE OF col` dispara si la columna está en el SET LIST, NO alcanza con que
-- un BEFORE la haya cambiado. Por eso la rama (b) escribe `estado = 'pagada'`
-- explícito aunque el trigger igual lo derive: sin eso `cuotas_vmv` no corre y
-- `clientes.vencimiento_mas_viejo` queda stale (INV20).
-- El prefijo `zz_` corre DESPUÉS de `z_contratos_anular_cuotas_futuras`
-- (verificado con un ORDER BY real, no asumido): 0234 se queda con su rol
-- histórico sobre las FUTURAS y este cierra el resto. Corra antes o después el
-- estado final es el mismo (su efecto es un subconjunto del nuestro).

-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
-- El DDL toma ACCESS EXCLUSIVE sobre `contratos` y `pagos` (tabla caliente).
-- Si una query larga tiene ACCESS SHARE, el CREATE TRIGGER se encola y BLOQUEA
-- toda la tabla detrás suyo — los cobradores colgados. Con esto aborta limpio
-- y se reintenta.
SET lock_timeout = '5s';
-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUE 0 — EL INTERRUPTOR
-- ════════════════════════════════════════════════════════════════════════════
-- `setting_bool` ya devuelve el default si la fila no existe, así que insertar
-- estas filas no es obligatorio para la corrección: es para que el valor sea
-- VISIBLE y editable por SQL. Va con `valor` en texto plano ('true'/'false')
-- porque `setting_bool` hace `(valor)::boolean` — comillas JSON lo reventarían.
-- editable_por='super_admin': ningún admin del ISP se auto-habilita el borrado
-- de cartera.
-- DECISION DE RUBEN (2026-08-25): va ENCENDIDA en TODOS los tenants, no solo
-- en el que estaba sangrando. Le plantee el riesgo de Telenet -usan cancelar
-- como "se fue debiendo": cancelan ~28/mes y 3 de sus 5 deudas preservadas son
-- de agosto- y decidio igual que la regla sea una sola para todos. Lo que
-- protege a Telenet NO es el flag sino el CORTE POR FECHA: sus 5 deudas viejas
-- (C$19.147,81) son TODAS anteriores al 2026-08-24, asi que quedan intactas.
-- Solo cambia de aca en adelante, y para "se fue debiendo" la herramienta pasa a
-- ser SUSPENDER (conserva la deuda y es reversible). Hay que avisarles.
INSERT INTO public.settings (tenant_id, clave, valor, tipo, categoria,
                             descripcion, editable_por)
SELECT t.id, 'cobranza.cancelar_condona', 'true',
       'boolean', 'cobranza',
       'Al cancelar un contrato, su deuda viva se pone en CERO (regla '
       '2026-08-24). Apagado = la deuda sobrevive a la baja, como antes.',
       'super_admin'
  FROM public.tenants t
ON CONFLICT (tenant_id, clave) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUE 1 — EL GATE (una sola definición: la usan los dos triggers y el backfill)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.condonacion_cancelacion_aplica(p_contrato uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  -- SECURITY DEFINER porque `settings` y `contratos` están bajo RLS por
  -- `current_tenant_id()`, y el super_admin impersonando no matchea.
  SELECT ct.estado = 'cancelado'
     AND ct.cancelado_en IS NOT NULL
     AND ct.cancelado_en >= TIMESTAMPTZ '2026-08-24 00:00:00-06'
     -- Default TRUE: "cancelar no deja nada pendiente" es LA regla del
     -- producto (decision del dueño 2026-08-24), no una feature opcional. Con
     -- default false un tenant NUEVO -que no tiene fila porque la clave no esta
     -- en `tenants_seed_settings_trg`- nacería con el comportamiento VIEJO en
     -- silencio, que es exactamente la deriva que esta migracion viene a cerrar.
     -- El flag queda como valvula de escape explicita, no como interruptor de
     -- encendido: para apagarlo hay que escribir 'false' a mano.
     --
     -- Se lee A MANO y NO con `setting_bool`, que hace `(valor)::boolean` y
     -- REVIENTA con 22P02 si el valor quedo JSON-quoteado ('"true"'). No es
     -- hipotetico: hay 2 filas asi HOY en produccion (settings del tenant
     -- System), escritas por el `jsonEncode` de settings_repo.dart cuando el
     -- caller pasa el String en vez del bool. Y este gate corre en el camino
     -- caliente de TODO cobro (trigger del bloque 4): como 22P02 es
     -- no-retryable (connector.dart), un solo valor mal escrito voltearia CADA
     -- cobro del tenant — el cobrador entrega el recibo en papel y el cobro no
     -- existe en el server. Asi no puede tirar nunca: lo que no sea
     -- true/false cae al default.
     AND COALESCE(
           (SELECT CASE lower(btrim(s.valor, '" '))
                     WHEN 'true'  THEN true
                     WHEN 'false' THEN false
                     ELSE NULL
                   END
              FROM public.settings s
             WHERE s.tenant_id = ct.tenant_id
               AND s.clave     = 'cobranza.cancelar_condona'),
           true)
    FROM public.contratos ct
   WHERE ct.id = p_contrato;
$fn$;

REVOKE ALL ON FUNCTION public.condonacion_cancelacion_aplica(uuid)
  FROM PUBLIC, anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUE 2 — LA REGLA, ESCRITA UNA SOLA VEZ
-- ════════════════════════════════════════════════════════════════════════════
-- p_cuota: si viene, se condona SOLO esa cuota. Lo usa el trigger de `pagos`
-- del bloque 4 para reajustar una cuota puntual sin recorrer el contrato.
CREATE OR REPLACE FUNCTION public.condonar_deuda_contrato(
  p_contrato uuid,
  p_actor    uuid        DEFAULT NULL,
  p_op       uuid        DEFAULT NULL,
  p_ocurrido timestamptz DEFAULT NULL,
  p_cuota    uuid        DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  k_motivo  CONSTANT text := 'Cancelación de contrato: la deuda no se cobra';
  v_ct        public.contratos%rowtype;
  v_op        uuid        := COALESCE(p_op, gen_random_uuid());
  v_cuando    timestamptz;
  v_actor     uuid;
  v_op_actor  uuid;
  v_label     text;
  v_rol       text;
  v_nom       text;
  r           record;
  v_n_anul    int := 0;
  v_n_cond    int := 0;
  v_n_omit    int := 0;
  v_total     numeric := 0;
  v_m_fin     numeric;
  v_c_fin     numeric;
  v_p_fin     numeric;
  v_e_fin     text;
  v_rows      int;
BEGIN
  -- El gate primero: sin él esta función podría borrarle la deuda a un contrato
  -- vivo, o a los cortados de Telenet.
  IF NOT COALESCE(public.condonacion_cancelacion_aplica(p_contrato), false) THEN
    RETURN jsonb_build_object('cuotas', 0, 'monto', 0, 'motivo', 'no_aplica');
  END IF;
  SELECT * INTO v_ct FROM public.contratos WHERE id = p_contrato;

  -- La fecha REAL de la baja, no `now()`: así el `anulada_en` del server coincide
  -- con el `ocurrido_en` que escribió el cliente en la misma operación, y el
  -- historial no miente en el backfill.
  v_cuando := COALESCE(p_ocurrido, v_ct.cancelado_en, now());

  -- ── ACTOR ────────────────────────────────────────────────────────────────
  -- `cuotas.anulada_por` es NOT NULL cuando estado='anulada' (CHECK
  -- `cuotas_anulacion_coherencia`) y es FK a `cobradores(id)`.
  -- `a_trg_contratos_guard_cancelacion` (0254) YA garantiza `cancelado_por` en
  -- toda transición a cancelado — verificado leyendo su cuerpo — así que el
  -- NULL es inalcanzable por el camino del trigger. Medido: las 44 filas del
  -- backfill tienen actor válido, rol 'admin'.
  -- Si igual faltara: se SALTEA con RAISE LOG. Levantar excepción acá tiraría
  -- la cancelación entera (ver DECISIÓN 5).
  v_actor := COALESCE(p_actor, v_ct.cancelado_por, auth.uid());
  IF v_actor IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.cobradores c WHERE c.id = v_actor) THEN
    v_actor := NULL;
  END IF;
  IF v_actor IS NULL THEN
    RAISE LOG 'condonacion: contrato % sin actor atribuible, no se condona nada',
      p_contrato;
    RETURN jsonb_build_object('cuotas', 0, 'monto', 0, 'motivo', 'sin_actor');
  END IF;

  -- Convención del change log (0128, igual que `OpLog.actorDeUsuario` en Dart):
  -- el super_admin —impersonando o no— se registra como 'System Admin' con
  -- actor_id NULL. Sin esto el historial del ISP nombraría al dueño del SaaS y
  -- `actor_id` apuntaría a un cobrador de OTRO tenant que el device no sincroniza.
  SELECT c.rol, c.nombre INTO v_rol, v_nom
    FROM public.cobradores c WHERE c.id = v_actor;
  IF v_rol = 'super_admin' THEN
    v_op_actor := NULL;  v_label := 'System Admin';
  ELSE
    v_op_actor := v_actor;
    v_label    := COALESCE(NULLIF(btrim(v_nom), ''), 'Sistema');
  END IF;

  -- ── NOTIFICACIONES DE MORA, ANTES DE TOCAR LAS CUOTAS ────────────────────
  -- Se cierran con `v_cuando`, NO con `now()`. Motivo concreto:
  -- `revertirCancelacion` (contratos_repo.dart:1226) las reabre con
  -- `WHERE resuelta_en = canceladoEn`. Si las cerrara `resolver_notificacion_
  -- al_pagar` (que usa now()) el revert no las encontraría y el cliente no
  -- volvería nunca a la lista de mora del cobrador. Cerrándolas ACÁ primero, ese
  -- trigger no encuentra ninguna en NULL y no pisa la fecha.
  IF p_cuota IS NULL THEN
    UPDATE public.notificaciones_mora
       SET resuelta_en = v_cuando, resuelta_por = v_actor
     WHERE resuelta_en IS NULL
       AND cuota_id IN (SELECT id FROM public.cuotas WHERE contrato_id = p_contrato);
  END IF;

  -- ── CUOTAS ───────────────────────────────────────────────────────────────
  FOR r IN
    SELECT cu.id, cu.estado AS estado_antes, cu.monto AS monto_antes,
           round(cu.monto + COALESCE(cu.cargos_neto,0)
                          - COALESCE(cu.monto_pagado,0), 2) AS saldo_antes,
           EXISTS (SELECT 1 FROM public.pagos p
                    WHERE p.cuota_id = cu.id AND p.anulado = false) AS con_plata,
           EXISTS (SELECT 1 FROM public.pagos p
                    WHERE p.cuota_id = cu.id AND p.anulado = false
                      AND p.en_revision = true)                    AS en_cuarentena
      FROM public.cuotas cu
     WHERE cu.contrato_id = p_contrato
       AND (p_cuota IS NULL OR cu.id = p_cuota)
       AND (cu.monto + COALESCE(cu.cargos_neto,0)
                     - COALESCE(cu.monto_pagado,0)) > 0.009
       -- Normalmente solo pendiente/parcial. Se admite una ANULADA que tenga un
       -- pago VIVO encima porque eso es exactamente la violación de INV24 que
       -- deja un cobro tardío: la rama (b) la rescata (ver bloque 4). Una cuota
       -- anulada por cualquier otra vía no llega acá: la cascada ya le anuló los
       -- pagos, así que no tiene plata viva.
       AND (cu.estado <> 'anulada'
            OR EXISTS (SELECT 1 FROM public.pagos p
                        WHERE p.cuota_id = cu.id AND p.anulado = false))
     ORDER BY cu.fecha_vencimiento
     FOR UPDATE
  LOOP
    IF r.en_cuarentena THEN
      -- (a) NO SE TOCA. Ver DECISIÓN 2: condonarla la deja en una trampa de la
      -- que no se sale, y anularla mata un cobro real. El humano resuelve la
      -- bandeja y el trigger de `pagos` termina el trabajo solo.
      v_n_omit := v_n_omit + 1;
      RAISE LOG 'condonacion: cuota % omitida (tiene un cobro en cuarentena)', r.id;
      CONTINUE;

    ELSIF r.con_plata THEN
      -- (b) CONDONAR bajando el monto. El pago y su recibo no se tocan.
      -- Las dos subconsultas van DENTRO del UPDATE a propósito: en READ
      -- COMMITTED cada sentencia toma snapshot nuevo, así que usan exactamente
      -- el mismo que va a usar `cuotas_forzar_derivados` un instante después.
      -- Calcularlas afuera abre una ventana para que un cobro concurrente
      -- descuadre la cuenta.
      -- `cuotas.monto`, `cargos_neto`, `monto_pagado` y `pagos.monto_cordobas`
      -- son TODOS numeric(10,2) (verificado en `pg_attribute`): no hay un
      -- decimal escondido que desalinee el `monto` que escribimos del
      -- `cargos_neto` que recalcula el BEFORE. El `round(...,2)` va explícito
      -- para que la aritmética cierre ANTES del truncado de la asignación.
      -- Los tres campos de anulación se limpian por si esta cuota venía de la
      -- rama (c) y la está rescatando un pago tardío.
      UPDATE public.cuotas c
         SET monto = round(
               COALESCE((SELECT sum(p.monto_cordobas) FROM public.pagos p
                          WHERE p.cuota_id = c.id
                            AND p.anulado = false
                            AND p.en_revision = false), 0)
               - public.calcular_cargos_neto(c.id), 2),
             estado           = 'pagada',
             anulada_en       = NULL,
             anulada_por      = NULL,
             motivo_anulacion = NULL,
             ocurrido_en      = v_cuando
       WHERE c.id = r.id
      RETURNING c.monto, c.estado, COALESCE(c.cargos_neto,0),
                COALESCE(c.monto_pagado,0)
        INTO v_m_fin, v_e_fin, v_c_fin, v_p_fin;

      -- RETURNING devuelve la fila YA pasada por el BEFORE trigger: esto no es
      -- una predicción, es el estado final. Canario, no abort (DECISIÓN 5).
      IF round(v_m_fin + v_c_fin - v_p_fin, 2) <> 0 OR v_e_fin <> 'pagada' THEN
        RAISE WARNING 'condonacion: cuota % quedó estado=% saldo=% (revisar)',
          r.id, v_e_fin, round(v_m_fin + v_c_fin - v_p_fin, 2);
      END IF;
      -- Monto negativo (cargos > cobrado) se PERMITE: no hay CHECK sobre `monto`
      -- y clampear a 0 sería un bug silencioso — total = 0 + cargos > pagado y
      -- la deuda RESUCITA, que es justo lo que esto viene a arreglar. Medido:
      -- toda la base tiene 3 filas en `cargos_extra` y NINGUNA cae sobre una
      -- cuota con pago, así que la rama nunca fue alcanzable. Se loguea por si
      -- algún día lo es.
      IF v_m_fin < 0 THEN
        RAISE LOG 'condonacion: cuota % queda con monto % (cargos % > pagado %)',
          r.id, v_m_fin, v_c_fin, v_p_fin;
      END IF;
      v_n_cond := v_n_cond + 1;

    ELSE
      -- (c) ANULAR: sin un peso encima. Es el único estado TERMINAL que
      -- `cuotas_forzar_derivados` respeta (no lo re-deriva) y saca la cuota de
      -- toda lista de cobro.
      --
      -- El `NOT EXISTS` va DENTRO del UPDATE, NO en el cursor, y esto NO es
      -- redundante: verificado con EXPLAIN contra la base viva, los SubPlan de
      -- `con_plata`/`en_cuarentena` cuelgan del Index Scan, ABAJO del Sort y del
      -- LockRows — o sea que se calculan ANTES de que el FOR UPDATE lockee la
      -- fila. Y en READ COMMITTED el recheck de EvalPlanQual re-evalúa el qual
      -- contra la tupla nueva pero los subplanes sobre `pagos` siguen con el
      -- snapshot VIEJO. Un cobro PARCIAL que commitea en esa ventana llegaría
      -- acá con `con_plata=false` y plata viva encima, y la cascada de
      -- `cuotas_anular_pagos_asociados_trg` mataría el pago Y su recibo: lo
      -- único que este archivo declara inviolable.
      -- Este UPDATE es una sentencia NUEVA dentro de una función VOLATILE:
      -- toma snapshot fresco y SÍ ve el commit. Si toca 0 filas se saltea — la
      -- deuda sobrevive (visible, la caza el invariante y el bloque 4 la
      -- termina) en vez de destruir un cobro. Misma jerarquía que DECISIÓN 5.
      UPDATE public.cuotas
         SET estado           = 'anulada',
             anulada_en       = v_cuando,
             anulada_por      = v_actor,
             motivo_anulacion = k_motivo,
             ocurrido_en      = v_cuando
       WHERE id = r.id
         AND NOT EXISTS (SELECT 1 FROM public.pagos p
                          WHERE p.cuota_id = r.id AND p.anulado = false);
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        v_n_omit := v_n_omit + 1;
        RAISE LOG 'condonacion: cuota % NO se anuló (apareció un cobro entre '
          'el snapshot y el lock)', r.id;
        CONTINUE;
      END IF;
      v_m_fin := NULL;
      v_e_fin := 'anulada';
      v_n_anul := v_n_anul + 1;
    END IF;

    v_total := v_total + r.saldo_antes;

    -- ── RASTRO: 1 fila por CUOTA, todas con el mismo op_id ─────────────────
    -- Misma forma que la que escribe el cliente (`_opCuota`): tipo_op
    -- 'cancelacion', entidad 'cuotas', campos estado/monto/saldo — los tres ya
    -- están en el allowlist visible (0256), así que se renderizan en
    -- `HistorialOpLog` sin tocar una línea de Dart. En el historial no se
    -- distingue si la fila la escribió el celular o el server: ese es el punto.
    INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                               actor_id, actor_label, accion, diff, ocurrido_en)
    VALUES (gen_random_uuid(), v_ct.tenant_id, v_op, 'cancelacion', 'cuotas', r.id,
            v_op_actor, v_label, 'update',
            jsonb_build_object(
              'campos',
              CASE WHEN v_m_fin IS NULL THEN
                jsonb_build_array(
                  jsonb_build_object('campo','estado','antes',r.estado_antes,
                                     'despues','anulada'),
                  jsonb_build_object('campo','saldo','antes',r.saldo_antes,
                                     'despues',0))
              ELSE
                jsonb_build_array(
                  jsonb_build_object('campo','monto','antes',round(r.monto_antes,2),
                                     'despues',round(v_m_fin,2)),
                  jsonb_build_object('campo','estado','antes',r.estado_antes,
                                     'despues','pagada'),
                  jsonb_build_object('campo','saldo','antes',r.saldo_antes,
                                     'despues',0))
              END,
              -- `despues = 0` es lo que hace auditable el total condonado: los
              -- builds viejos escriben filas 'cancelacion'/'saldo' de PRORRATEO
              -- (saldo que BAJA, no que se borra) y sin ese filtro se cuentan
              -- dobles. Medido: 42 filas así por C$34.510 sobre esta misma
              -- población, todas con despues > 0.
              'resumen', jsonb_build_object(
                'motivo', k_motivo,
                'monto',  r.saldo_antes))::text,
            v_cuando);
  END LOOP;

  IF v_n_anul + v_n_cond = 0 THEN
    RETURN jsonb_build_object('cuotas', 0, 'monto', 0, 'omitidas', v_n_omit,
                              'op_id', v_op);
  END IF;

  RAISE LOG 'condonacion: contrato % -> % anuladas, % condonadas, % omitidas, C$%',
    p_contrato, v_n_anul, v_n_cond, v_n_omit, round(v_total,2);

  -- Libro de la plata condonada. `data_ops_log` NO está en las sync rules
  -- (verificado) => server-only, cero tráfico de PowerSync. Responde algo que
  -- hoy no responde ninguna tabla de dinero. OJO con su alcance: solo registra
  -- lo que condonó el SERVER; lo que ya condonó el cliente no pasa por acá. El
  -- total real se saca de `op_log` (query en la verificación).
  INSERT INTO public.data_ops_log (tenant_id, operacion, target_label, afectados,
                                   backup_id, actor_id, actor_label)
  VALUES (v_ct.tenant_id, 'condonacion_cancelacion',
          'Contrato ' || COALESCE(v_ct.codigo, left(p_contrato::text,8))
            || ': deuda condonada al cancelar',
          jsonb_build_object('contrato', p_contrato, 'anuladas', v_n_anul,
                             'condonadas', v_n_cond, 'omitidas', v_n_omit,
                             'monto', round(v_total,2), 'op_id', v_op),
          NULL, v_op_actor, v_label);

  RETURN jsonb_build_object('cuotas', v_n_anul + v_n_cond, 'anuladas', v_n_anul,
                            'condonadas', v_n_cond, 'omitidas', v_n_omit,
                            'monto', round(v_total,2), 'op_id', v_op);
END;
$fn$;

COMMENT ON FUNCTION public.condonar_deuda_contrato(uuid,uuid,uuid,timestamptz,uuid) IS
  'Pone en CERO la deuda viva de un contrato cancelado (regla 2026-08-24, gateada '
  'por cobranza.cancelar_condona y por cancelado_en >= 2026-08-24). Cuota con '
  'cuarentena -> se omite; con plata -> monto := pagado - cargos; sin plata -> '
  'anulada. Nunca levanta excepción. Idempotente: la población se define por '
  'saldo > 0.009.';

-- CRÍTICO: toda función de `public` queda expuesta como RPC de PostgREST. Ésta
-- es SECURITY DEFINER y liquida deuda: sin el REVOKE, cualquier autenticado (un
-- cobrador) le borra la deuda a un contrato pasándole un uuid.
REVOKE ALL ON FUNCTION public.condonar_deuda_contrato(uuid,uuid,uuid,timestamptz,uuid)
  FROM PUBLIC, anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUE 3 — EL EVENTO: al pasar a 'cancelado', se condona
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.contratos_condonar_deuda_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  -- Un op_id nuevo por cancelación = UNA intención, N objetos (modelo AGENTS).
  -- DECISION 5 enforceada TAMBIEN aca, igual que el bloque 4. El archivo
  -- declaraba "el trigger nunca levanta excepcion" y despues dejaba este
  -- PERFORM pelado, que es el UNICO camino que ejecuta la regla en la baja
  -- real. Si propaga, `esCodigoNoRetryable` descarta el UPDATE de contratos y
  -- queda el escenario inaceptable: contrato ACTIVO en Postgres con las cuotas
  -- ya saldadas -el cliente sube las cuotas ANTES-, o sea un cliente vivo al
  -- que el ISP deja de facturar sin una fila que lo diga. Que la deuda
  -- sobreviva es visible y arreglable; que la BAJA se pierda, no.
  BEGIN
    PERFORM public.condonar_deuda_contrato(
              new.id, new.cancelado_por, gen_random_uuid(),
              COALESCE(new.cancelado_en, now()), NULL);
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'condonacion: no se pudo condonar el contrato % al cancelar (%)',
      new.id, sqlerrm;
  END;
  RETURN NULL;   -- AFTER: el retorno se ignora.
END;
$fn$;

REVOKE ALL ON FUNCTION public.contratos_condonar_deuda_trg()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zz_contratos_condonar_deuda ON public.contratos;

-- `AFTER UPDATE OF estado` + WHEN sobre la TRANSICIÓN: un re-put de PowerSync
-- (que manda la fila entera) sobre un contrato ya cancelado NO lo dispara. Eso
-- es lo que hace intocables a los 5 de Telenet y a los 94 históricos sin autor.
-- No hay rama de INSERT: el generador de cuotas gatea por estado='activo' (un
-- contrato que nace cancelado no tiene nada que condonar) y el `put` de
-- PowerSync sobre una fila existente entra por ON CONFLICT DO UPDATE, que SÍ
-- dispara los triggers de UPDATE.
CREATE TRIGGER zz_contratos_condonar_deuda
  AFTER UPDATE OF estado ON public.contratos
  FOR EACH ROW
  WHEN (new.estado = 'cancelado' AND old.estado IS DISTINCT FROM 'cancelado')
  EXECUTE FUNCTION public.contratos_condonar_deuda_trg();

COMMENT ON TRIGGER zz_contratos_condonar_deuda ON public.contratos IS
  'Regla 2026-08-24: cancelar condona la deuda viva. Corre en la TRANSICIÓN, '
  'con cualquier versión de la app. Gateado por tenant y por fecha de la regla.';

-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUE 4 — LA PIEZA QUE FALTABA: reajustar cuando la plata cambia DESPUÉS
-- ════════════════════════════════════════════════════════════════════════════
-- La condonación es un evento, no un candado, y eso deja tres agujeros REALES
-- que ninguno de los diseños previos cierra. Los tres los tapa este trigger,
-- porque los tres se arreglan con lo mismo: volver a correr la regla sobre ESA
-- cuota (la función es idempotente y las tres ramas convergen al saldo 0).
--
--  (1) COBRO QUE ATERRIZA DESPUÉS DE LA BAJA. La cuota ya está 'anulada' cuando
--      llega el pago. `pagos_guard_sobrepago_trg` usa `cuota_total_a_cobrar`,
--      que NO mira `estado` -> el pago entra vivo y sin cuarentena; y
--      `recalcular_cuota_desde_pagos` sale antes si la cuota es 'anulada' ->
--      `monto_pagado` se queda en 0. Resultado: pago vivo + recibo colgando de
--      una cuota anulada = violación de INV24 (hoy en 0), y la cuota dice C$0
--      cobrados mientras el cliente tiene el comprobante en la mano.
--      MEDIDO: 25 pagos vivos por C$16.284,37 sobre 15 contratos cancelados
--      tienen hoy `ocurrido_en > cancelado_en` (gaps de minutos hasta 7 días).
--      Acá la cuota se RESCATA a la rama (b): se des-anula, monto := pagado, la
--      plata queda acreditada y el saldo en 0.
--  (2) ANULAR EL ÚNICO PAGO DE UNA CUOTA YA CONDONADA. Quedó monto = pagado; al
--      anular, monto_pagado vuelve a 0 y `cuotas_forzar_derivados` la re-deriva
--      a 'pendiente' con saldo = monto: LA DEUDA RESUCITA en un contrato
--      cancelado. Acá se re-corre la regla y cae en la rama (c).
--  (3) CUARENTENA RESUELTA DESPUÉS. La cuota que la rama (a) omitió termina de
--      condonarse sola cuando el pago se aplica o se anula.
--
-- Corre en el camino caliente (todo cobro), así que: sale en la primera línea si
-- la cuota no cuelga de un contrato gateado (dos lookups por PK), y va envuelto
-- en EXCEPTION WHEN OTHERS -> RAISE LOG. NUNCA puede voltear un cobro: si algo
-- falla, degrada exactamente al comportamiento de hoy y lo reporta el invariante.
CREATE OR REPLACE FUNCTION public.pagos_reajustar_condonacion_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_cuota uuid; v_ct uuid;
BEGIN
  -- Solo escrituras DIRECTAS de pagos. A profundidad > 1 el pago lo movió una
  -- cascada nuestra (o la de `cuotas_anular_pagos_asociados_trg`): reentrar
  -- sería recursión sin sentido.
  IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF;

  v_cuota := COALESCE(NEW.cuota_id, OLD.cuota_id);
  IF v_cuota IS NULL THEN RETURN NULL; END IF;
  SELECT cu.contrato_id INTO v_ct FROM public.cuotas cu WHERE cu.id = v_cuota;
  IF v_ct IS NULL THEN RETURN NULL; END IF;
  IF NOT COALESCE(public.condonacion_cancelacion_aplica(v_ct), false) THEN
    RETURN NULL;
  END IF;

  BEGIN
    PERFORM public.condonar_deuda_contrato(v_ct, NULL, NULL, NULL, v_cuota);
  EXCEPTION WHEN OTHERS THEN
    -- Camino conocido: si quien sube el pago es un COBRADOR,
    -- `cuotas_check_cobrador_update` prohíbe des-anular una cuota y esto rebota.
    -- Se degrada a lo de hoy (pago vivo sobre cuota anulada) y lo levanta INV24.
    -- Medido: los 25 pagos tardíos históricos los registraron admin y
    -- admin_cobranza, CERO cobradores.
    RAISE LOG 'condonacion: no se pudo reajustar la cuota % tras un cambio de pago (%)',
      v_cuota, sqlerrm;
  END;
  RETURN NULL;
END;
$fn$;

REVOKE ALL ON FUNCTION public.pagos_reajustar_condonacion_trg()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zz_pagos_reajustar_condonacion ON public.pagos;

-- Misma lista de columnas que `trg_pagos_update_recalcular` (los cuatro campos
-- que mueven la plata de una cuota). `zz_` para correr DESPUÉS de
-- `trg_pagos_insert_recalcular` / `trg_pagos_update_recalcular`, que ya hicieron
-- (o saltearon) su trabajo.
CREATE TRIGGER zz_pagos_reajustar_condonacion
  AFTER INSERT OR UPDATE OF monto_cordobas, cuota_id, anulado, en_revision
  ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.pagos_reajustar_condonacion_trg();

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUE 5 — BACKFILL, EN SU PROPIA TRANSACCIÓN
-- ════════════════════════════════════════════════════════════════════════════
-- SEPARADO A PROPÓSITO: `CREATE TRIGGER` toma ACCESS EXCLUSIVE sobre
-- `contratos` y lo retiene hasta el COMMIT. Con el backfill adentro, los 146
-- UPDATE de cuotas (cada uno dispara `cuotas_vmv` -> `recalc_vencimiento_mas_
-- viejo`, que hace LEFT JOIN a `contratos`) dejarían a toda la app esperando
-- ACCESS SHARE durante el apply, con timeouts de upload de PowerSync justo
-- cuando el trigger recién nace. Y si el guard aborta, el fix ya quedó puesto.
BEGIN;
-- El DDL toma ACCESS EXCLUSIVE sobre `contratos` y `pagos` (tabla caliente).
-- Si una query larga tiene ACCESS SHARE, el CREATE TRIGGER se encola y BLOQUEA
-- toda la tabla detrás suyo — los cobradores colgados. Con esto aborta limpio
-- y se reintenta.
SET lock_timeout = '5s';

DO $backfill$
DECLARE
  v_c int; v_q int; v_m numeric; v_plata int;
  v_ct record; v_r jsonb;
  v_nc int := 0; v_nq int := 0; v_nm numeric := 0;
BEGIN
  -- El SET se define con el MISMO gate que el trigger (`condonacion_cancelacion_
  -- aplica`), no con un filtro paralelo: es imposible que el backfill toque algo
  -- que el trigger no tocaría, ni al revés. Defensa en profundidad: aunque este
  -- WHERE estuviera mal, la función se auto-gatea.
  SELECT count(DISTINCT ct.id), count(*),
         COALESCE(round(sum(cu.monto + COALESCE(cu.cargos_neto,0)
                            - COALESCE(cu.monto_pagado,0)),2),0),
         count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.pagos p
                                         WHERE p.cuota_id = cu.id AND p.anulado = false))
    INTO v_c, v_q, v_m, v_plata
    FROM public.contratos ct
    JOIN public.cuotas cu ON cu.contrato_id = ct.id
   WHERE public.condonacion_cancelacion_aplica(ct.id)
     AND cu.estado <> 'anulada'
     AND (cu.monto + COALESCE(cu.cargos_neto,0) - COALESCE(cu.monto_pagado,0)) > 0.009;

  RAISE NOTICE 'BACKFILL 0259: % contratos / % cuotas / C$% (con plata encima: %)',
    v_c, v_q, v_m, v_plata;

  -- TECHO de cordura, no igualdad. Medido tres veces seguidas: 44/146/
  -- C$102.834,54, estable. Pero las bajas entran a ráfagas (48 en un día), así
  -- que una igualdad exacta como la de 0258 puede abortar por hacer bien su
  -- trabajo. Lo que se protege es correr esto en la base equivocada o sobre un
  -- orden de magnitud distinto. Si salta, NO es "subir el número": es que pasó
  -- algo que no entendemos.
  IF v_c > 150 OR v_m > 250000 THEN
    RAISE EXCEPTION 'ABORTA: la población (% contratos / C$%) supera el techo '
      '(150 / C$250.000). Re-medir antes de correr. No se tocó nada.', v_c, v_m;
  END IF;
  IF v_c = 0 THEN
    RAISE NOTICE 'Nada que limpiar (¿ya se corrió, o el flag está apagado?).';
  END IF;

  FOR v_ct IN
    SELECT ct.id, ct.cancelado_por, ct.cancelado_en
      FROM public.contratos ct
     WHERE public.condonacion_cancelacion_aplica(ct.id)
       AND EXISTS (SELECT 1 FROM public.cuotas cu
                    WHERE cu.contrato_id = ct.id AND cu.estado <> 'anulada'
                      AND (cu.monto + COALESCE(cu.cargos_neto,0)
                           - COALESCE(cu.monto_pagado,0)) > 0.009)
     ORDER BY ct.cancelado_en
  LOOP
    v_r := public.condonar_deuda_contrato(
             v_ct.id, v_ct.cancelado_por,
             -- op_id DETERMINÍSTICO por contrato: re-correr la migración no
             -- duplica op_log (y aunque lo hiciera, la población ya está vacía).
             md5('condonacion-cancelacion:' || v_ct.id::text)::uuid,
             -- La fecha REAL de la baja: el historial cuenta cuándo pasó, no
             -- cuándo se corrió la migración. Y así el revert del cliente sigue
             -- encontrando sus notificaciones por `resuelta_en = cancelado_en`.
             v_ct.cancelado_en, NULL);
    v_nc := v_nc + 1;
    v_nq := v_nq + COALESCE((v_r->>'cuotas')::int, 0);
    v_nm := v_nm + COALESCE((v_r->>'monto')::numeric, 0);
  END LOOP;

  RAISE NOTICE 'BACKFILL 0259 hecho: % contratos / % cuotas / C$%',
    v_nc, v_nq, round(v_nm,2);
END
$backfill$;

COMMIT;
