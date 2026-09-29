-- ============================================================================
-- INVARIANTES DE DINERO — diagnóstico contable del CRM
-- ============================================================================
--
-- Propósito: detectar corrupción contable en la data real. Cada invariante
-- es una regla que SIEMPRE debe cumplirse. Si una devuelve > 0 violaciones,
-- hay un bug (o data corrupta de testing) que afecta el dinero del tenant.
--
-- CÓMO USARLO:
--   1. Pegar todo este archivo en Supabase SQL Editor.
--   2. Run. El resultado es UNA tabla con una fila por invariante.
--   3. Columna `violaciones` debe ser 0 en TODAS las filas, MENOS el baseline.
--
-- BASELINE ACEPTADO (no son bugs; estan documentados en BITACORA):
--   INV11 = 3   ·   INV20 = 1   (INV19 volvio a 0 el 2026-08-26)
--
-- (INV25 estuvo en 6 el 2026-08-23, entre 0255 y 0257: eran 11 cuotas por
--  C$10.257 de doble facturación — 5 clientes que recontrataron y a los que el
--  contrato viejo les seguía facturando el mismo mes que el nuevo. Se anularon
--  con `super_admin_cuota_estado_impl` (preview, motivo, respaldo y triple
--  registro) y 0257 repuso la fecha de baja desde `op_log`. Volvió a 0.)
-- La regla real es: **tu fix no puede AUMENTAR ningun contador** ni sumar
-- invariantes nuevos a la lista. Corre el script ANTES de tocar y compara.
--
-- ALCANCE (leer antes de decir "la plata esta verificada"): estos chequeos
-- verifican COHERENCIA entre tablas, no CORRECCION del calculo. Un monto
-- prorrateado mal, un plan facturado a precio equivocado o una fecha de
-- vencimiento mal derivada CIERRAN igual y NO aparecen aca. Para eso estan
-- los tests de `prorrateo.dart` y el testing manual.
--   4. Si alguna > 0, la columna `ejemplo_ids` muestra los registros
--      ofensivos para investigar.
--
-- ES READ-ONLY: solo SELECT. No modifica nada. Seguro de correr en prod.
--
-- Correr DESPUÉS de cada deploy que toque pagos/cuotas/recibos/contratos.
-- ============================================================================

WITH

-- INV 1: En todo pago NO anulado, lo entregado (monto_original * tasa) debe
-- igualar lo aplicado + el vuelto. Tolerancia 0.50 por redondeo de tasa.
--   monto_original = entregado en moneda original (USD o NIO)
--   monto_cordobas = aplicado a la cuota (entra a la caja del ISP)
--   vuelto_cordobas = devuelto al cliente (siempre en NIO)
inv1 AS (
  SELECT 'INV1: entregado = aplicado + vuelto (pagos)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id
    FROM public.pagos
    WHERE anulado = false
      AND ABS((monto_original * tasa_conversion) - (monto_cordobas + vuelto_cordobas)) > 0.50
  ) t
),

-- INV 2: cuota.monto_pagado debe igualar la suma de pagos NO anulados
-- aplicados a esa cuota. Es el invariante más crítico — si falla, el
-- recaudado y el saldo de la cuota están mal.
inv2 AS (
  SELECT 'INV2: cuota.monto_pagado = SUM(pagos aplicados)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(cuota_id::text, ', ' ORDER BY cuota_id), '') AS ejemplo_ids
  FROM (
    SELECT cu.id AS cuota_id
    FROM public.cuotas cu
    LEFT JOIN (
      SELECT cuota_id, SUM(monto_cordobas) AS pagado
      FROM public.pagos
      WHERE anulado = false AND en_revision = false
      GROUP BY cuota_id
    ) p ON p.cuota_id = cu.id
    WHERE cu.estado <> 'anulada'
      AND ABS(cu.monto_pagado - COALESCE(p.pagado, 0)) > 0.01
  ) t
),

-- INV 3: estado de la cuota coherente con lo pagado.
--   pagada   → monto_pagado >= monto + cargos_neto
--   pendiente → monto_pagado = 0
--   parcial  → 0 < monto_pagado < total
inv3 AS (
  SELECT 'INV3: estado de cuota coherente con monto_pagado' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id
    FROM public.cuotas
    -- CANON DEL TRIGGER (0255). La banda de +-0.01 que habia aca NO es la de
    -- `cuotas_forzar_derivados`, el BEFORE UPDATE que decide el estado de
    -- verdad y gana siempre. Como la plata es numeric(10,2), el hueco mas chico
    -- posible es exactamente 0.01 - y ahi los dos canon se contradecian: el
    -- trigger dejaba 'parcial' y este chequeo lo marcaba como violacion. Una
    -- cuota a un centavo del total ES parcial para el server y para el cliente
    -- (`cuota_estado.dart`). Ademas el corrector no podia arreglarla (el
    -- trigger revertia su UPDATE), asi que la bandera quedaba inapagable.
    WHERE estado <> 'anulada'
      AND estado IS DISTINCT FROM (CASE
            WHEN (monto + COALESCE(cargos_neto,0)) <= 0 THEN 'pagada'
            WHEN monto_pagado <= 0 THEN 'pendiente'
            WHEN monto_pagado < (monto + COALESCE(cargos_neto,0)) THEN 'parcial'
            ELSE 'pagada' END)
  ) t
),

-- INV 4: ninguna cuota pagada de más (monto_pagado > total). Si esto pasa,
-- el vuelto no se descontó correctamente y se infló el recaudado.
inv4 AS (
  SELECT 'INV4: ninguna cuota con sobrepago (monto_pagado > total)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id
    FROM public.cuotas
    WHERE estado <> 'anulada'
      AND monto_pagado > (monto + COALESCE(cargos_neto,0)) + 0.01
  ) t
),

-- INV 5: todo pago NO anulado debe tener un recibo asociado.
inv5 AS (
  SELECT 'INV5: todo pago no anulado tiene recibo' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(p.id::text, ', ' ORDER BY p.id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    WHERE p.anulado = false
      AND NOT EXISTS (
        SELECT 1 FROM public.recibos r WHERE r.pago_id = p.id
      )
  ) p
),

-- INV 6: vuelto_cordobas nunca negativo (lo refuerza el CHECK, verificamos).
inv6 AS (
  SELECT 'INV6: vuelto_cordobas >= 0' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id FROM public.pagos WHERE vuelto_cordobas < 0
  ) t
),

-- INV 7: correlativo de recibo único por (cobrador, prefijo). Dos recibos
-- con el mismo número rompen la numeración fiscal.
inv7 AS (
  SELECT 'INV7: correlativo de recibo único por cobrador+prefijo' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(numero_completo, ', ' ORDER BY numero_completo), '') AS ejemplo_ids
  FROM (
    SELECT numero_completo
    FROM public.recibos
    GROUP BY cobrador_id, prefijo, correlativo, numero_completo
    HAVING COUNT(*) > 1
  ) t
),

-- INV 8: contrato activo denormaliza cobrador_id consistente con su cliente.
-- P3b (2026-06-17): un contrato activo PUEDE no tener cobrador (cliente
-- "admin-managed"; sus cuotas solo las ven admin/admin_cobranza). Lo que sigue
-- siendo invariante es que el cobrador del contrato COINCIDA con el del cliente
-- (IS DISTINCT FROM trata NULL=NULL como iguales → ambos NULL NO es violación).
inv8 AS (
  SELECT 'INV8: contrato.cobrador_id = cliente.cobrador_id' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ct.id
    FROM public.contratos ct
    JOIN public.clientes c ON c.id = ct.cliente_id
    WHERE ct.estado = 'activo'
      AND ct.cobrador_id IS DISTINCT FROM c.cobrador_id
  ) t
),

-- INV 9: cuota OPERATIVA (pendiente/parcial) denormaliza cobrador_id consistente
-- con su contrato. Las PAGADAS/ANULADAS se EXCLUYEN a propósito: el trigger
-- propagate_cobrador_id_from_cliente() (vigente: migración 0122) CONGELA su
-- cobrador_id al reasignar (auditoría: "quién la cobró queda registrado"), así que
-- un mismatch en una pagada/anulada es ESPERADO, no un bug. "Quién cobró" lo
-- garantizan pagos/recibos.cobrador_id (NOT NULL; INV5/INV7); cuota.cobrador_id es
-- solo organizativo (routing/sync, jamás métricas de plata). El WHERE espeja al
-- trigger (estado IN pendiente/parcial). (cuotas manuales con contrato_id NULL se saltan.)
inv9 AS (
  SELECT 'INV9: cuota.cobrador_id = contrato.cobrador_id (operativas)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(cu.id::text, ', ' ORDER BY cu.id), '') AS ejemplo_ids
  FROM (
    SELECT cu.id
    FROM public.cuotas cu
    JOIN public.contratos ct ON ct.id = cu.contrato_id
    WHERE cu.contrato_id IS NOT NULL
      AND cu.estado IN ('pendiente','parcial')
      AND cu.cobrador_id IS DISTINCT FROM ct.cobrador_id
  ) cu
),

-- INV 10: coherencia de tenant entre una fila hija y su padre — lo mismo que
-- enforça el trigger validar_tenant_coherente() (migración 0082). Si una hija
-- quedó con un tenant_id distinto al de su padre, la data está scopeada mal y
-- el dinero podría contarse en el tenant equivocado. Tres sub-checks unidos:
--   pagos.tenant_id        debe == cuotas.tenant_id  (por pago.cuota_id)
--   recibos.tenant_id      debe == pagos.tenant_id   (por recibo.pago_id)
--   cargos_extra.tenant_id debe == cuotas.tenant_id  (por cargo.cuota_id)
-- Hijas SIN padre se excluyen (FK NULL o sin match): igual que el trigger, que
-- solo valida cuando el tenant del padre existe (`v_tenant_padre is not null`).
-- Así un pago manual sin cuota no falsea el conteo.
inv10 AS (
  SELECT 'INV10: tenant_id de hija == tenant_id de su padre (0082)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(ofensor, ', ' ORDER BY ofensor), '') AS ejemplo_ids
  FROM (
    SELECT 'pago:' || p.id::text AS ofensor
    FROM public.pagos p
    JOIN public.cuotas cu ON cu.id = p.cuota_id
    WHERE p.cuota_id IS NOT NULL
      AND p.tenant_id <> cu.tenant_id
    UNION ALL
    SELECT 'recibo:' || r.id::text AS ofensor
    FROM public.recibos r
    JOIN public.pagos p ON p.id = r.pago_id
    WHERE r.pago_id IS NOT NULL
      AND r.tenant_id <> p.tenant_id
    UNION ALL
    SELECT 'cargo:' || ce.id::text AS ofensor
    FROM public.cargos_extra ce
    JOIN public.cuotas cu ON cu.id = ce.cuota_id
    WHERE ce.cuota_id IS NOT NULL
      AND ce.tenant_id <> cu.tenant_id
  ) t
),

-- INV 11: un contrato FIJO (duracion_meses) activo debe tener EXACTAMENTE
-- duracion_meses cuotas generadas. La regla #5 (total = precio×meses) presupone
-- que se generaron `meses` cuotas; si la generación under/over-generó, el total
-- fijo no cuadra con sus cuotas. Indefinidos (duracion_meses NULL/0) se excluyen
-- (#6: no tienen total fijo). Las cuotas MANUALES (cargo de reconexión/instalación,
-- `tipo_cargo_manual` NOT NULL) se auto-asocian un contrato_id pero NO son cuotas de
-- facturación → se EXCLUYEN del conteo (si no, cualquier contrato con un cargo manual
-- daría falso positivo). Las ANULADAS también se EXCLUYEN del conteo: el cambio de
-- fecha de pago (feature C, 0119) absorbe (anula) la cuota que cae en el puente y, en
-- fijos, agrega 1 cuota de cierre al final → el conteo que debe dar duracion_meses es
-- el de cuotas ACTIVAS (no anuladas). Sin esto, absorbida+cierre daría duracion_meses+1.
-- EXCEPCIÓN: la SUSPENSIÓN (feature A, 0120) anula el gap de meses suspendidos SIN
-- cuota de cierre (decisión: el período suspendido no se factura y fecha_fin no se
-- estira), bajando el conteo activo por debajo de duracion_meses. Por eso REINTEGRAMOS
-- al conteo las anuladas con motivo='Suspensión temporal' (ver el + en la condición):
-- activas + gap-suspendido = duracion_meses. Sin esto, todo fijo suspendido-y-reactivado
-- daría falso positivo permanente.
inv11 AS (
  SELECT 'INV11: contrato fijo activo tiene exactamente duracion_meses cuotas activas (#5)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ct.id
    FROM public.contratos ct
    WHERE COALESCE(ct.estado, 'activo') = 'activo'
      AND ct.duracion_meses IS NOT NULL
      AND ct.duracion_meses > 0
      AND (
            (SELECT COUNT(*) FROM public.cuotas cu
               WHERE cu.contrato_id = ct.id
                 AND cu.tipo_cargo_manual IS NULL
                 AND cu.estado <> 'anulada')
            +
            (SELECT COUNT(*) FROM public.cuotas cu
               WHERE cu.contrato_id = ct.id
                 AND cu.tipo_cargo_manual IS NULL
                 AND cu.estado = 'anulada'
                 AND cu.motivo_anulacion = 'Suspensión temporal')
          )
          <> ct.duracion_meses
  ) t
),

-- INV 12: recaudado por contrato coherente entre las dos formas de calcularlo
-- (regla #4 a nivel agregado). `SUM(cuotas.monto_pagado)` de un contrato debe
-- igualar `SUM(pagos.monto_cordobas)` de los pagos NO anulados de esas cuotas.
-- INV2 lo garantiza por cuota; esto cierra el lazo a nivel contrato y atrapa
-- denormalizaciones rotas (un pago apuntando a una cuota de otro contrato, o
-- monto_pagado desincronizado del agregado). Tolerancia 0.01 por redondeo.
inv12 AS (
  SELECT 'INV12: recaudado por contrato = SUM(pagos no anulados de sus cuotas) (#4)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ct.id
    FROM public.contratos ct
    WHERE ABS(
      COALESCE((SELECT SUM(cu.monto_pagado)
                  FROM public.cuotas cu
                 WHERE cu.contrato_id = ct.id), 0)
      - COALESCE((SELECT SUM(pa.monto_cordobas)
                    FROM public.pagos pa
                    JOIN public.cuotas cu2 ON cu2.id = pa.cuota_id
                   WHERE cu2.contrato_id = ct.id
                     AND pa.anulado = false AND pa.en_revision = false), 0)
    ) > 0.01
  ) t
)

-- INV13 (Sprint 2, 0115): todo AJUSTE es un descuento con motivo. El guard
-- server (trg_cargos_ajuste_guard) lo impide hacia adelante; esto detecta
-- data legacy/migrada inconsistente o un bypass.
,inv13 AS (
  SELECT 'INV13: cargos origen=ajuste son descuento_* con motivo no vacío' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ce.id
    FROM public.cargos_extra ce
    WHERE ce.origen = 'ajuste'
      AND (ce.tipo NOT IN ('descuento_monto', 'descuento_porcentaje')
           OR ce.descripcion IS NULL
           OR btrim(ce.descripcion) = '')
  ) t
)

-- INV14 (QA Fase 4, Sprint 2): cuotas.cargos_neto debe coincidir con la suma
-- real de cargos_extra. Detecta el "fantasma": un cargo cuyo INSERT/DELETE
-- fue rechazado/filtrado en el server mientras el PATCH espejo de la cuota
-- sí entró (divergencia muda que ninguna otra INV veía).
,inv14 AS (
  SELECT 'INV14: cuotas.cargos_neto == SUM real de cargos_extra' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT cu.id
    FROM public.cuotas cu
    WHERE abs(
      COALESCE(cu.cargos_neto, 0)
      - COALESCE((SELECT SUM(CASE
                    WHEN ce.tipo IN ('reconexion','otro') THEN ce.monto
                    WHEN ce.tipo IN ('descuento_monto','descuento_porcentaje','credito_aplicado')
                      THEN -ce.monto
                    ELSE 0 END)
                   FROM public.cargos_extra ce
                  WHERE ce.cuota_id = cu.id), 0)
    ) > 0.01
  ) t
)

-- INV15 (crédito por excedente, 0127): el saldo a favor DISPONIBLE de un cliente
-- nunca puede ser negativo. disponible = SUM(+acreditado) − SUM(aplicado +
-- devuelto + condonado + revertido). Si da < 0, se gastó/devolvió más crédito
-- del que se acreditó (carrera offline sin el trigger anti-sobregiro, o data mala).
,inv15 AS (
  SELECT 'INV15: saldo a favor del cliente nunca negativo' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(cliente_id::text, ', ' ORDER BY cliente_id), '') AS ejemplo_ids
  FROM (
    SELECT cliente_id
    FROM public.saldos_favor
    GROUP BY cliente_id
    HAVING SUM(CASE WHEN tipo = 'acreditado' THEN monto ELSE -monto END) < -0.005
  ) t
)

-- INV16 (crédito por excedente, 0127): el crédito NO es un pago. Ningún `pagos`
-- debe tener un método fuera de los 4 reales (efectivo/transferencia/deposito/
-- tarjeta) — la aplicación del crédito va por cargos_extra, nunca por pagos, así
-- el arqueo/recaudado no lo cuentan como efectivo.
,inv16 AS (
  SELECT 'INV16: ningún pago con método de crédito (crédito no es pago)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id FROM public.pagos
    WHERE anulado = false
      AND metodo NOT IN ('efectivo','transferencia','deposito','tarjeta')
  ) t
)

-- INV17 (colchón indefinidos, 0148): todo contrato INDEFINIDO activo debe tener
-- al menos 3 cuotas 'pendiente' con período POSTERIOR al ancla = la más nueva
-- entre el mes actual (Managua) y la última cuota con pago (pagada/parcial). Es
-- el colchón que mantienen el espejo Dart (al cobrar) y el trigger+cron server.
-- < 3 = colchón roto (un indefinido sin cuotas por cobrar hacia adelante) — antes silencioso.
-- Las cuotas MANUALES (tipo_cargo_manual) se excluyen (no son facturación).
,inv17 AS (
  SELECT 'INV17: indefinido activo tiene >= 3 cuotas pendientes futuras (colchón)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ct.id
    FROM public.contratos ct
    WHERE COALESCE(ct.estado, 'activo') = 'activo'
      AND ct.duracion_meses IS NULL
      AND (
        SELECT COUNT(*) FROM public.cuotas cu
         WHERE cu.contrato_id = ct.id
           AND cu.estado = 'pendiente'
           AND cu.tipo_cargo_manual IS NULL
           AND cu.periodo > GREATEST(
             date_trunc('month', (now() AT TIME ZONE 'America/Managua'))::date,
             COALESCE((SELECT MAX(cu2.periodo) FROM public.cuotas cu2
                         WHERE cu2.contrato_id = ct.id
                           AND cu2.estado IN ('pagada', 'parcial')),
                      '1900-01-01'::date)
           )
      ) < 3
  ) t
)

-- INV 18: toda anulación está atribuida. El guard de sobrepago (0214) es el
-- ÚNICO que puede anular sin usuario, y solo con su motivo automático — el
-- CHECK `pagos_anulacion_coherencia` lo permite por ese prefijo exacto. Si
-- aparece un anulado sin actor con otro motivo, alguien está escribiendo
-- anulaciones sin dejar rastro de quién.
,inv18 AS (
  SELECT 'INV18: anulación sin actor solo si la hizo el guard (0214)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT id
    FROM public.pagos
    WHERE anulado = true
      AND anulado_por IS NULL
      AND COALESCE(motivo_anulacion, '') NOT LIKE 'Duplicado automático:%'
  ) t
)
-- INV19/INV20 se agregaron en 0220 al RPC del panel; van también acá para que
-- la corrida MANUAL (la que se hace tras cada deploy que toca dinero) los mire.
-- Sin esto, el archivo y el panel reportaban cosas distintas.
,inv19 AS (
  -- Regla de negocio: desactivado = ya no tiene servicio Y está saldado. Un
  -- cliente con saldo pendiente NO puede estar desactivado: la app lo esconde
  -- de las 3 rutas de cobro y la deuda se vuelve invisible (se detectaron 75
  -- casos por C$309.486 el 2026-08-08). El guard de 0220 impide nuevos; esto
  -- detecta los que queden.
  SELECT 'INV19: cliente desactivado con deuda pendiente' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT c.id
    FROM public.clientes c
    WHERE c.activo = false
      AND EXISTS (
        SELECT 1 FROM public.cuotas cu
        WHERE cu.cliente_id = c.id
          AND cu.estado IN ('pendiente', 'parcial')
          AND (cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado) > 0.01
      )
  ) t
)
,inv20 AS (
  -- `clientes.vencimiento_mas_viejo` es derivada y la escriben DOS lados (el
  -- trigger server y el cliente) → puede quedar pegada en un valor viejo. El
  -- mapa y Avisos derivan el color/urgencia de esta columna SIN cruzar cuotas,
  -- así que un valor podrido saca al cliente de la cola de corte.
  -- Predicado idéntico al de `recalc_vencimiento_mas_viejo`.
  SELECT 'INV20: vencimiento_mas_viejo divergente de las cuotas' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT c.id
    FROM public.clientes c
    WHERE c.vencimiento_mas_viejo IS DISTINCT FROM (
      SELECT MIN(cu.fecha_vencimiento)
      FROM public.cuotas cu
      LEFT JOIN public.contratos ct ON ct.id = cu.contrato_id
      WHERE cu.cliente_id = c.id
        AND cu.estado IN ('pendiente', 'parcial')
        AND COALESCE(ct.estado, 'activo') = 'activo'
    )
  ) t
)

-- ============================================================================
-- INV 21: oldest-first (invariante #11 de AGENTS). La ÚNICA regla de dinero
-- que no tenía red: por DECISIÓN de producto NO hay trigger server, solo el
-- guard del cliente (`pagos_repo._validarOldestFirst`), que es ciego al
-- multi-device offline. `k` = (fecha_vencimiento, período) = el MISMO criterio
-- de orden que usa `keyDe` en el guard. Una violación por CUOTA SALTADA.
-- SOLO cuenta la que NUNCA vio plata (`pendiente` + monto_pagado <= 0.01):
-- incluir 'parcial' da 1 falso positivo (una cuota pagada completa que después
-- recibe un cargo vuelve a 'parcial' sin que nadie viole el orden).
-- ============================================================================
,of_regs AS (
  SELECT cu.id, cu.contrato_id, cu.estado, cu.monto_pagado, cu.monto, cu.cargos_neto,
         to_char(cu.fecha_vencimiento,'YYYYMMDD') || to_char(cu.periodo,'YYYYMMDD') AS k
  FROM public.cuotas cu
  WHERE cu.contrato_id IS NOT NULL
    AND cu.tipo_cargo_manual IS NULL
    AND cu.estado <> 'anulada'
)
,of_tope AS (
  SELECT contrato_id, max(k) AS k_max
  FROM of_regs WHERE monto_pagado > 0.01 GROUP BY contrato_id
)
,inv21 AS (
  SELECT 'INV21: ninguna cuota vieja saltada por un cobro posterior (#11 oldest-first)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT r.id
    FROM of_regs r
    JOIN of_tope t ON t.contrato_id = r.contrato_id
    WHERE r.estado = 'pendiente'
      AND r.monto_pagado <= 0.01
      AND (r.monto + COALESCE(r.cargos_neto,0)) > 0.01
      AND r.k < t.k_max
  ) t
)

-- ============================================================================
-- INV 22: INV5 es unidireccional (pago vivo -> recibo). Este es el reverso.
-- Un recibo vivo sin pago vivo detrás es un comprobante con número fiscal
-- circulando sin plata en caja.
-- ============================================================================
,inv22 AS (
  SELECT 'INV22: todo recibo vivo cuelga de un pago vivo (reverso de INV5)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT r.id
    FROM public.recibos r
    LEFT JOIN public.pagos p ON p.id = r.pago_id
    WHERE COALESCE(r.anulado, false) = false
      AND (r.pago_id IS NULL OR p.id IS NULL OR p.anulado = true)
  ) t
)

-- ============================================================================
-- INV 23: INV5 se satisface con un recibo ANULADO (solo pregunta NOT EXISTS).
-- Este exige EXACTAMENTE UNO vivo: caza el cobro sin comprobante válido Y el
-- duplicado que quema un correlativo. SUBSUME a INV5; se dejan los dos porque
-- si divergen (INV5=0, INV23=N) el par te dice que el problema son recibos
-- anulados y no recibos faltantes.
-- ============================================================================
,inv23 AS (
  SELECT 'INV23: todo pago vivo tiene EXACTAMENTE un recibo vivo (refuerza INV5)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    WHERE p.anulado = false
      AND (SELECT COUNT(*) FROM public.recibos r
            WHERE r.pago_id = p.id AND COALESCE(r.anulado,false) = false) <> 1
  ) t
)

-- ============================================================================
-- INV 24: el hueco entre INV2 (excluye anuladas) e INV12 (recorre contratos).
-- Un pago VIVO sobre una cuota anulada o inexistente no lo mira NADIE, y esa
-- plata SÍ entra al arqueo y al dashboard (que suman monto_cordobas bruto).
-- Las cuotas manuales pueden tener contrato_id NULL (hay 2 en prod), así que
-- INV12 tampoco llega por ese lado.
-- ============================================================================
,inv24 AS (
  SELECT 'INV24: ningún pago vivo cuelga de una cuota anulada o inexistente' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    LEFT JOIN public.cuotas cu ON cu.id = p.cuota_id
    WHERE p.anulado = false
      AND (p.cuota_id IS NULL OR cu.id IS NULL OR cu.estado = 'anulada')
  ) t
)

-- ============================================================================
-- INV 25: verifica que la red de 0234 (anular cuotas futuras al dar de baja)
-- haya funcionado. 0234 nació de 8 cuotas por C$6.411 que se siguieron
-- facturando después de la baja.
-- ¡OJO! El predicado del WHERE es COPIA EXACTA del CTE `futuras` de
-- `contratos_anular_cuotas_futuras_trg`, A PROPÓSITO: si el trigger cambia,
-- este invariante tiene que cambiar con él.
-- Anclado a la VENTANA DE SERVICIO, nunca al mes calendario (regla 1c de
-- AGENTS): anclado al mes da 14 FALSOS POSITIVOS que son prorrateos de baja
-- correctos (facturación vencida con dia_pago <> 1).
-- ============================================================================
,inv25 AS (
  SELECT 'INV25: contrato dado de baja sin cuotas FUTURAS vivas (red 0234)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT cu.id
    FROM public.contratos ct
    -- COALESCE A HOY-NICARAGUA (0255). El trigger 0234 hace exactamente esto
    -- (`COALESCE(new.cancelado_en::date, (now() - interval '6 hours')::date)`)
    -- y este chequeo NO lo copiaba, pese a que su comentario juraba ser copia
    -- exacta. Justo ahi vivia la deuda fantasma: 37 contratos cancelados SIN
    -- fecha de baja quedaban fuera del chequeo, y con ellos 6 cuotas por
    -- C$6.154 que el panel reportaba como "0 violaciones".
    -- OJO: borrar `AND b.fecha IS NOT NULL` a secas NO arregla nada - con
    -- logica de tres valores `x > NULL` ya da NULL y la fila se excluye igual.
    -- El filtro de `tipo_cargo_manual` tambien se saca: el CTE `futuras` del
    -- trigger NO lo tiene, y esto dice ser su espejo.
    JOIN LATERAL (
      SELECT COALESCE(
               CASE WHEN ct.estado = 'cancelado' THEN ct.cancelado_en::date
                    ELSE (SELECT s.suspendido_en::date FROM public.contrato_suspensiones s
                           WHERE s.contrato_id = ct.id AND s.reactivado_en IS NULL
                           ORDER BY s.suspendido_en DESC LIMIT 1) END,
               (now() - interval '6 hours')::date) AS fecha
    ) b ON true
    JOIN public.cuotas cu ON cu.contrato_id = ct.id
    WHERE ct.estado IN ('cancelado','suspendido')
      AND cu.estado = 'pendiente'
      AND COALESCE(cu.monto_pagado, 0) <= 0.009
      AND COALESCE(
            (SELECT max(cu2.fecha_vencimiento) FROM public.cuotas cu2
              WHERE cu2.contrato_id = cu.contrato_id
                AND cu2.fecha_vencimiento < cu.fecha_vencimiento
                AND cu2.estado <> 'anulada'),
            (cu.fecha_vencimiento - interval '1 month')::date
          ) > b.fecha
  ) t
)

-- ============================================================================
-- INV 26: cancelar contrato es el único evento de plata sin CHECK de
-- atribución (`pagos` y `cuotas` sí tienen el suyo). CORTE 2026-08-20: los 94
-- históricos sin atribuir son 37 legacy + 57 de una limpieza SQL manual del
-- 19/08. Ningún camino de la APP deja el actor vacío. La segunda rama cubre
-- el caso sin fecha, que si no se escaparía por el propio filtro de fecha.
-- ============================================================================
,inv26 AS (
  SELECT 'INV26: cancelación de contrato atribuida (desde 2026-08-20)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT ct.id
    FROM public.contratos ct
    WHERE ct.estado = 'cancelado'
      AND (ct.cancelado_en >= DATE '2026-08-20'
           OR (ct.cancelado_en IS NULL AND ct.created_at >= DATE '2026-08-20'))
      AND (ct.cancelado_por IS NULL
           OR ct.cancelado_en IS NULL
           OR COALESCE(btrim(ct.motivo_cancelacion), '') = '')
  ) t
)

-- ============================================================================
-- INV 27: `op_log` es el ÚNICO registro de cambios (audit_log se eliminó en
-- 0140) y lo escribe el CLIENTE -> la fila puede perderse sin que el cobro se
-- pierda. Ningún INV1-20 lo miraba.
--
-- CORTE 2026-08-20 + GRACIA DE 48 h. El corte deja afuera los 177 cobros
-- históricos (causa conocida: `op_log` no tenía policy de SELECT para
-- cobrador, el upsert fallaba con 42501 y el connector lo descartaba;
-- cerrado por 0190 el 2026-07-17). La gracia de 48 h evita el FALSO POSITIVO
-- del cobrador offline: `uploadData` sube las ops de a una y el insert de
-- op_log es la ÚLTIMA del writeTransaction del cobro; si se corta la señal en
-- el medio, el server queda con el pago y sin rastro hasta la próxima sync.
--
-- QUÉ NO VE: (a) el 2º pago o posterior sobre la MISMA cuota (es EXISTS, no
-- conteo: ~3% de los pagos de Mairena desde julio); (b) los 177 históricos,
-- a propósito. La variante estricta por conteo también arranca en 0 hoy.
-- ============================================================================
,inv27 AS (
  SELECT 'INV27: todo cobro deja rastro en op_log (desde 2026-08-20, gracia 48h)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    WHERE COALESCE(p.ocurrido_en, p.fecha_pago) >= TIMESTAMPTZ '2026-08-20 00:00-06'
      AND COALESCE(p.ocurrido_en, p.fecha_pago) < now() - INTERVAL '48 hours'
      AND NOT EXISTS (
        SELECT 1 FROM public.op_log o
         WHERE o.tenant_id = p.tenant_id
           AND o.entidad = 'cuotas' AND o.entidad_id = p.cuota_id
           AND o.tipo_op IN ('cobro', 'cobro_recuperado'))
  ) t
)

-- ============================================================================
-- INV 28: el invariante #4 tiene DOS sumandos
-- (`recaudado_caja = SUM(pagos) - SUM(saldos_favor devuelto)`) y los 20
-- chequeos vigentes miran solo el primero. Bucketea por `fecha_devolucion` y
-- `fecha_pago::date` — local-naive A PROPÓSITO, igual que el arqueo
-- (regla 1b: el wall-clock de fecha_pago sostiene el bucketing). Solo
-- `metodo='efectivo'`: una devolución en efectivo no sale de una transferencia.
-- PREVENCIÓN PURA: hoy hay 0 filas tipo='devuelto' en toda la base, pero
-- C$18.207 acreditados esperando a que alguien los aplique.
-- El `ejemplo_ids` devuelve `cobrador_id@fecha`, no un uuid: la violación es
-- del PAR, no de una fila.
-- ============================================================================
,inv28 AS (
  SELECT 'INV28: devoluciones del día <= efectivo cobrado ese día (#4 caja neta)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(clave, ', ' ORDER BY clave), '') AS ejemplo_ids
  FROM (
    -- CONTRA LA CAJA DEL TENANT (0255), no la del usuario. Antes exigia que la
    -- devolucion saliera del efectivo que ESE MISMO usuario cobro ESE MISMO
    -- dia. Eso no esta en el modelo: quien devuelve es admin/admin_cobranza
    -- (oficina, por gating) y la plata sale de la caja de la oficina, no de la
    -- calle. Simulado sobre las 10 disposiciones de excedente reales, 2
    -- habrian marcado rojo por una operacion correcta - una de C$30.516 - y no
    -- hay corrector ni forma de bajar la bandera. Se conserva el sentido: no
    -- puede salir mas efectivo del que entro ese dia en la empresa.
    SELECT d.fecha_devolucion::text AS clave
    FROM public.saldos_favor d
    WHERE d.tipo = 'devuelto' AND d.fecha_devolucion IS NOT NULL
    GROUP BY d.tenant_id, d.fecha_devolucion
    HAVING SUM(d.monto) > COALESCE((
        SELECT SUM(p.monto_cordobas) FROM public.pagos p
         WHERE p.tenant_id = d.tenant_id
           AND p.anulado = false AND p.metodo = 'efectivo'
           AND p.fecha_pago::date = d.fecha_devolucion), 0) + 0.005
  ) t
)

-- ============================================================================
-- INV 29: sin cobrador+fecha la devolución no cae en NINGÚN bucket del arqueo
-- (el ISP sigue mostrando en caja plata que ya devolvió); sin recibo no hay
-- papel de la salida de efectivo. Las tres columnas son NULLABLE y no hay
-- CHECK que las exija. Va de la mano de INV28: sin INV29, INV28 es EVADIBLE
-- (una devolución sin cobrador ni fecha se saltea su GROUP BY).
-- ============================================================================
,inv29 AS (
  SELECT 'INV29: devolución de saldo con cobrador, fecha y recibo (#2/#4)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT sf.id
    FROM public.saldos_favor sf
    -- SIN `recibo_id` (0255): ese campo NO LO ESCRIBE NINGUN CAMINO del
    -- sistema. `registrarDisposicionExcedente` es el unico productor de filas
    -- 'devuelto' y no lo setea; no hay UPDATE de saldos_favor en todo lib/; el
    -- unico trigger de la tabla no lo toca; y las 30 filas vivas tienen
    -- count(recibo_id) = 0. Era una condicion IMPOSIBLE de satisfacer: la
    -- primera devolucion real dejaba esto en rojo permanente, con un texto en
    -- pantalla que mandaba a completar un dato que no tiene campo. Peor, se
    -- tapaba a si mismo: si TODA devolucion viola, deja de distinguir a la que
    -- de verdad es inimputable - y sin ese filo INV28 vuelve a ser evadible,
    -- que es literalmente lo que este chequeo previene.
    -- Emitir un recibo de devolucion es una FEATURE, no un fix de audit.
    WHERE sf.tipo = 'devuelto'
      AND (sf.cobrador_id IS NULL OR sf.fecha_devolucion IS NULL)
  ) t
)

-- ============================================================================
-- INV 30: la moneda es el único ángulo del modelo contable cuyo SÍ es por
-- código y no por datos: los 31.826 pagos son todos NIO, efectivo, vuelto 0.
-- INV1 verifica la CONSISTENCIA de la ecuación, no la SANIDAD de sus factores:
-- con tasa=0 pasa a exigir monto_cordobas+vuelto=0, y un pago marcado NIO con
-- tasa 36 cumple igual si monto_original se guardó 36 veces más chico.
-- Supuesto NIO => tasa=1 verificado al 100% sobre los 31.826 pagos.
-- ============================================================================
,inv30 AS (
  SELECT 'INV30: moneda y tasa coherentes en pagos vivos (#3)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id), '') AS ejemplo_ids
  FROM (
    SELECT p.id
    FROM public.pagos p
    WHERE p.anulado = false
      AND (p.tasa_conversion IS NULL OR p.tasa_conversion <= 0
           OR p.monto_original IS NULL OR p.monto_original <= 0
           OR (p.moneda = 'NIO' AND ABS(p.tasa_conversion - 1) > 0.0001))
  ) t
)

-- ============================================================================
-- INV 31: el crédito por excedente (0127) se escribe en DOS tablas desde el
-- CLIENTE, en la misma writeTransaction, y nadie verifica el puente.
-- Si entra SOLO el cargo: la cuota se descuenta sin consumir saldo -> el
-- cliente usa el mismo crédito infinitas veces. Si entra SOLO el saldo: se
-- consume el crédito sin descontar la cuota. Ninguno rompe INV14 (mira la suma
-- de los cargos que SÍ llegaron) ni INV15 (mira el neto de saldos_favor).
-- Prefijo saldo:/cargo: igual que INV10, para saber a qué tabla ir.
-- ============================================================================
,inv31 AS (
  SELECT 'INV31: crédito aplicado <-> cargo credito_aplicado, mismo monto (#4)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(ofensor, ', ' ORDER BY ofensor), '') AS ejemplo_ids
  FROM (
    SELECT 'saldo:' || sf.id::text AS ofensor
    FROM public.saldos_favor sf
    LEFT JOIN public.cargos_extra ce ON ce.id = sf.cargo_id
    WHERE sf.tipo = 'aplicado'
      AND (ce.id IS NULL OR ce.tipo <> 'credito_aplicado' OR ABS(sf.monto - ce.monto) > 0.01)
    UNION ALL
    SELECT 'cargo:' || ce.id::text
    FROM public.cargos_extra ce
    WHERE ce.tipo = 'credito_aplicado'
      AND NOT EXISTS (SELECT 1 FROM public.saldos_favor sf
                       WHERE sf.cargo_id = ce.id AND sf.tipo = 'aplicado')
  ) t
)

-- INV32 — LA PREMISA DEL TITULAR DEL DASHBOARD (2026-08-26).
-- Desde hoy el titular "Cuotas por cobrar"/"En mora", el reporte de Mora y la
-- tarjeta de Recuperacion NO llevan filtro de estado de contrato: miden toda la
-- deuda viva. Eso es correcto SOLO mientras cancelar siga condonando, porque un
-- cancelado con deuda ya no queda escondido detras de un filtro: se SUMA al
-- numero que el dueno mira primero, y lo infla sin que nadie se entere.
-- Este invariante es esa premisa, escrita.
--
-- Checklist #14 — las dos preguntas, contestadas:
--   ¿Puede dar >0?  SI, y ya paso: 44 contratos de Mairena (C$102.834,54)
--   quedaron con deuda viva porque el equipo que aprobo la baja tenia un build
--   viejo, con la regla anterior a 0259. La condonacion vive en el server desde
--   0259/0261, pero un `estado='cancelado'` escrito por otra via no dispara el
--   trigger de condonacion.
--   ¿Puede satisfacerse? SI: verificado en cero contra vxxz el 2026-08-26.
--
-- SI DA >0: correr `condonar_deuda_contrato` sobre los ofensores (es la misma
-- funcion que usa el trigger). NO anular a mano las cuotas con plata aplicada:
-- la cascada mataria pagos y recibos (invariante 6b de AGENTS.md).
--
-- #13c (el que MIDE y el que ARREGLA comparten predicado): el WHERE de aca es
-- el del TITULAR restringido a cancelados —misma condicion de estado, mismo
-- saldo canonico— y coincide con el de `condonar_deuda_contrato`, verificado
-- contra el cuerpo VIVO de la funcion con `pg_get_functiondef` y no contra un
-- comentario (#14b). La funcion tiene ademas una rama para una cuota ANULADA
-- con plata encima: esa NO va aca a proposito, porque una anulada tampoco entra
-- al titular — no es deuda, es una anomalia de datos, y la cubre INV24.
--
-- Poblacion (medida 2026-08-26, para que no sea un chequeo vacio): 253
-- contratos cancelados con 2.544 cuotas colgando; 0 de ellas vivas. El join
-- tiene filas de sobra, el discriminador es el estado de la cuota.
,inv32 AS (
  SELECT 'INV32: contrato cancelado sin deuda viva (premisa del titular del dashboard)' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(ofensor, ', ' ORDER BY ofensor), '') AS ejemplo_ids
  FROM (
    SELECT DISTINCT ct.id::text AS ofensor
    FROM public.contratos ct
    JOIN public.cuotas cu ON cu.contrato_id = ct.id
    WHERE ct.estado = 'cancelado'
      AND cu.estado IN ('pendiente', 'parcial')
      AND (cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0)) > 0.009
  ) t
)

,inv33 AS (
  -- INV33: `pagos.fecha_cobro` es SIEMPRE el dia de `fecha_pago`.
  --
  -- Desde el 2026-09-04 el dashboard filtra el ciclo por esta columna en vez
  -- de por `date(fecha_pago)` — es lo que permite usar el indice y lo que
  -- llevo una pasada del Resumen de 9.546 ms a 2.234 ms. Si las dos se
  -- separan, la plata de un cobro aparece en el ciclo equivocado y NADIE se
  -- entera: el numero se ve perfectamente razonable, solo esta en otro dia.
  --
  -- En el server lo mantiene el trigger `aa_pagos_fecha_cobro` (0273) y el
  -- cliente la escribe en su INSERT (los triggers no corren en el SQLite del
  -- dispositivo). Este chequeo existe para el dia que alguien agregue un
  -- camino que edite `fecha_pago` sin mover las dos.
  --
  -- `AT TIME ZONE 'UTC'` y NO 'America/Managua': `fecha_pago` guarda el
  -- wall-clock local etiquetado como UTC (convencion vieja, ver 0096 y 0214).
  -- Convertir a Managua movería 26.178 de 34.010 pagos al dia anterior.
  SELECT 'INV33: pagos.fecha_cobro coincide con el dia de fecha_pago' AS invariante,
         COUNT(*) AS violaciones,
         COALESCE(string_agg(id::text, ', ' ORDER BY id::text), '') AS ejemplo_ids
  FROM public.pagos
  WHERE fecha_cobro IS DISTINCT FROM (fecha_pago AT TIME ZONE 'UTC')::date
)

SELECT * FROM inv1
UNION ALL SELECT * FROM inv2
UNION ALL SELECT * FROM inv3
UNION ALL SELECT * FROM inv4
UNION ALL SELECT * FROM inv5
UNION ALL SELECT * FROM inv6
UNION ALL SELECT * FROM inv7
UNION ALL SELECT * FROM inv8
UNION ALL SELECT * FROM inv9
UNION ALL SELECT * FROM inv10
UNION ALL SELECT * FROM inv11
UNION ALL SELECT * FROM inv12
UNION ALL SELECT * FROM inv13
UNION ALL SELECT * FROM inv14
UNION ALL SELECT * FROM inv15
UNION ALL SELECT * FROM inv16
UNION ALL SELECT * FROM inv17
UNION ALL SELECT * FROM inv18
UNION ALL SELECT * FROM inv19
UNION ALL SELECT * FROM inv20
UNION ALL SELECT * FROM inv21
UNION ALL SELECT * FROM inv22
UNION ALL SELECT * FROM inv23
UNION ALL SELECT * FROM inv24
UNION ALL SELECT * FROM inv25
UNION ALL SELECT * FROM inv26
UNION ALL SELECT * FROM inv27
UNION ALL SELECT * FROM inv28
UNION ALL SELECT * FROM inv29
UNION ALL SELECT * FROM inv30
UNION ALL SELECT * FROM inv31
UNION ALL SELECT * FROM inv32
UNION ALL SELECT * FROM inv33
ORDER BY invariante;
