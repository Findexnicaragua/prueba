-- 0251_corregir_invariantes_rastro.sql
--
-- `super_admin_corregir_invariantes` es la UNICA operacion de dinero del panel
-- del Dev sin ningun rastro (verificado: op_log=no, data_ops_log=no) y hace
-- CUATRO mutaciones masivas por tenant: reescribe cargos_neto, monto_pagado,
-- estado, y regenera cuotas. Si algo sale mal no hay forma de saber QUE toco.
--
-- Esta migracion hace dos cosas:
--
-- (A) ARREGLA UN BUG VIVO: EL CORRECTOR NO CONVERGIA.
--     El corrector y el verificador NO usaban el mismo predicado para INV2: el
--     corrector sumaba `anulado = false` a secas, mientras que el verificador,
--     el trigger `cuotas_forzar_derivados` y el guard 0218 usan el canonico
--     `anulado = false AND en_revision = false`.
--
--     QUE NO PASABA (verificado, no supuesto): NO escribia plata fantasma. El
--     trigger es BEFORE UPDATE y FUERZA `monto_pagado` al valor canonico en
--     TODA escritura a `cuotas`, asi que el valor equivocado del corrector se
--     descartaba antes de tocar disco. La proteccion del server aguanto.
--
--     QUE SI PASABA: el boton NUNCA CONVERGIA. Medido en vivo sobre el Test
--     Tenant, reproduciendo el UPDATE viejo: 1a pasada "corrige" 2 filas, la
--     cuota queda igual (935,00, el trigger la fija), 2a pasada vuelve a
--     "corregir" LAS MISMAS 2. Para siempre. El WHERE preguntaba por un valor
--     (2.135,00 = incluyendo un cobro en cuarentena) que el trigger jamas iba a
--     dejar entrar. El super_admin apretaba, leia "2 registros corregidos",
--     volvia a verificar y seguia igual - sin manera de distinguir eso de un
--     corrector roto.
--
--     Y CON EL RASTRO DE (B) SE VOLVIA PEOR: cada apretón habria estampado 2
--     filas de op_log de "correccion" con antes = despues = 935,00 en el
--     historial de dinero de esas cuotas. Sumarle registro a un bucle que no
--     converge es como se ensucia un libro contable. Por eso las dos mitades
--     de esta migracion van juntas y en este orden.
--
--     De paso se alinean los otros dos predicados que divergian sin efecto
--     todavia (medido: 0 filas hoy), para que el boton corrija EXACTAMENTE lo
--     que el chequeo marca:
--       - INV3: el corrector decidia sin tolerancia y el verificador con 0.01.
--       - INV17: el corrector anclaba al mes calendario; el verificador ancla
--         a `max(periodo pagado)` cuando el contrato esta pago por adelantado
--         (regla 1c de AGENTS + el colchon de 0241).
--
--     ASIMETRIA QUE QUEDA, A PROPOSITO: INV14 del verificador mira TODAS las
--     cuotas y el corrector excluye las anuladas. Hoy hay 0 casos. No se
--     amplia el corrector a cuotas anuladas porque escribirles dispara
--     `cuotas_forzar_derivados_trg` (BEFORE UPDATE sin WHEN) sobre filas
--     muertas, y el beneficio es nulo: `cargos_neto` de una anulada no entra
--     en ninguna formula de plata. Si algun dia INV14 marca una anulada, se
--     arregla a mano.
--
-- (B) TRIPLE REGISTRO. Una fila de `op_log` por CUOTA/CONTRATO tocado (con
--     antes -> despues real, que es lo que sirve para revisar) y UNA fila
--     resumen en `data_ops_log`. Todas las filas comparten `op_id`: son una
--     sola intencion (un apretón del boton), como manda AGENTS.
--
-- FORMA DEL RETORNO: NO SE TOCA. El Dart hace `(e.value as num?)` sobre TODAS
-- las claves del mapa, asi que agregar una clave de texto (un 'op_id', por
-- ejemplo) romperia la pantalla con un TypeError. Sigue devolviendo solo
-- {INV14, INV2, INV3, INV17} con valores enteros.
--
-- PARTIDA: pg_get_functiondef() de la definicion VIVA. El ORDEN de los cuatro
-- bloques se conserva: INV14 va antes de INV3 porque el estado depende de
-- cargos_neto, e INV2 antes de INV3 por lo mismo con monto_pagado.

CREATE OR REPLACE FUNCTION public.super_admin_corregir_invariantes(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "TimeZone" TO 'America/Managua'
AS $function$
DECLARE
  v_fixed jsonb := '{}'::jsonb;
  v_count int;
  v_op_id uuid := gen_random_uuid();
  v_total int := 0;
  v_ids   uuid[];
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo super_admin puede ejecutar esta operación.';
  END IF;

  -- ── INV14: re-sync cargos_neto ──
  -- Va ANTES de INV3 porque el estado depende de cargos_neto.
  -- FIX F5 (2026-08-02): `calcular_cargos_neto` respeta el SIGNO (reconexión/otro
  -- suman; descuento_*/credito_aplicado restan). Antes SUM(ce.monto) sin signo.
  -- El self-join con `prev` lee el snapshot PRE-update: asi el rastro guarda el
  -- valor de ANTES, que es la mitad que sirve para revisar.
  WITH tocadas AS (
    UPDATE cuotas q
       SET cargos_neto = public.calcular_cargos_neto(q.id)
      FROM cuotas prev
     WHERE prev.id = q.id
       AND q.tenant_id = p_tenant
       AND q.estado <> 'anulada'
       AND COALESCE(q.cargos_neto, 0) <> public.calcular_cargos_neto(q.id)
    RETURNING q.id, prev.cargos_neto AS antes, q.cargos_neto AS despues
  )
  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  SELECT gen_random_uuid(), p_tenant, v_op_id, 'correccion_invariante',
         'cuotas', t.id, NULL, 'System Admin', 'update',
         jsonb_build_object(
           'campos', jsonb_build_array(jsonb_build_object(
             'campo','cargos_neto','antes',t.antes,'despues',t.despues)),
           'resumen', jsonb_build_object('motivo',
             'Corrección automática INV14: los cargos de la cuota no sumaban '
             'lo que decía el total guardado.'))::text,
         now()
    FROM tocadas t;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV14', v_count);
  v_total := v_total + v_count;

  -- ── INV2: re-sync monto_pagado ──
  -- Va ANTES de INV3 porque el estado depende de monto_pagado.
  -- `en_revision = false` es OBLIGATORIO: es el predicado canónico, el mismo
  -- que fuerza `cuotas_forzar_derivados` en cada escritura. Sin él, el WHERE
  -- pregunta por un valor que el trigger nunca va a dejar entrar -> la fila se
  -- "corrige" en cada pasada, sin cambiar nunca. No es plata mal escrita (el
  -- trigger la ataja): es un botón que no converge.
  WITH tocadas AS (
    UPDATE cuotas q
       SET monto_pagado = COALESCE((
             SELECT SUM(p.monto_cordobas) FROM pagos p
              WHERE p.cuota_id = q.id AND p.anulado = false
                AND p.en_revision = false), 0)
      FROM cuotas prev
     WHERE prev.id = q.id
       AND q.tenant_id = p_tenant
       AND q.estado <> 'anulada'
       AND q.monto_pagado <> COALESCE((
             SELECT SUM(p.monto_cordobas) FROM pagos p
              WHERE p.cuota_id = q.id AND p.anulado = false
                AND p.en_revision = false), 0)
    RETURNING q.id, prev.monto_pagado AS antes, q.monto_pagado AS despues
  )
  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  SELECT gen_random_uuid(), p_tenant, v_op_id, 'correccion_invariante',
         'cuotas', t.id, NULL, 'System Admin', 'update',
         jsonb_build_object(
           'campos', jsonb_build_array(jsonb_build_object(
             'campo','monto_pagado','antes',t.antes,'despues',t.despues)),
           'resumen', jsonb_build_object('motivo',
             'Corrección automática INV2: lo pagado guardado en la cuota no '
             'coincidía con la suma de sus cobros vigentes.'))::text,
         now()
    FROM tocadas t;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV2', v_count);
  v_total := v_total + v_count;

  -- ── INV3: re-sync estado basado en monto_pagado vs total ──
  -- La tolerancia de 0.01 es la MISMA del verificador. Sin ella, una cuota a
  -- medio centavo del total quedaba 'parcial' para el corrector y 'debería ser
  -- pagada' para el chequeo: se apretaba el botón y seguía en rojo.
  WITH tocadas AS (
    UPDATE cuotas q
       SET estado = CASE
             WHEN q.monto_pagado >= q.monto + COALESCE(q.cargos_neto, 0) - 0.01 THEN 'pagada'
             WHEN q.monto_pagado > 0.01 THEN 'parcial'
             ELSE 'pendiente'
           END
      FROM cuotas prev
     WHERE prev.id = q.id
       AND q.tenant_id = p_tenant
       AND q.estado <> 'anulada'
       AND q.tipo_cargo_manual IS NULL
       AND q.estado <> CASE
             WHEN q.monto_pagado >= q.monto + COALESCE(q.cargos_neto, 0) - 0.01 THEN 'pagada'
             WHEN q.monto_pagado > 0.01 THEN 'parcial'
             ELSE 'pendiente'
           END
    RETURNING q.id, prev.estado AS antes, q.estado AS despues
  )
  INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                             actor_id, actor_label, accion, diff, ocurrido_en)
  SELECT gen_random_uuid(), p_tenant, v_op_id, 'correccion_invariante',
         'cuotas', t.id, NULL, 'System Admin', 'update',
         jsonb_build_object(
           'campos', jsonb_build_array(jsonb_build_object(
             'campo','estado','antes',t.antes,'despues',t.despues)),
           'resumen', jsonb_build_object('motivo',
             'Corrección automática INV3: el estado de la cuota no coincidía '
             'con lo pagado.'))::text,
         now()
    FROM tocadas t;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_fixed := v_fixed || jsonb_build_object('INV3', v_count);
  v_total := v_total + v_count;

  -- ── INV17: regenerar colchón para contratos indefinidos ──
  -- Predicado IDÉNTICO al del verificador (INV17), incluido el ancla a
  -- `max(periodo pagado)`: un contrato pago por adelantado hasta diciembre
  -- necesita 3 cuotas DESPUÉS de diciembre, no después de este mes.
  -- Los ids se juntan ANTES de generar, porque después de generar el predicado
  -- ya no los selecciona y no habría a qué colgarle el rastro.
  SELECT array_agg(c.id) INTO v_ids
    FROM contratos c
   WHERE c.tenant_id = p_tenant
     AND c.duracion_meses IS NULL
     AND c.estado = 'activo'
     AND (SELECT COUNT(*) FROM cuotas q2
           WHERE q2.contrato_id = c.id
             AND q2.estado = 'pendiente'
             AND q2.tipo_cargo_manual IS NULL
             AND q2.periodo > GREATEST(
                   date_trunc('month', CURRENT_DATE)::date,
                   COALESCE((SELECT MAX(q3.periodo) FROM cuotas q3
                              WHERE q3.contrato_id = c.id
                                AND q3.estado IN ('pagada','parcial')),
                            '1900-01-01'::date))) < 3;

  v_count := COALESCE(array_length(v_ids, 1), 0);

  IF v_count > 0 THEN
    PERFORM public.generar_cuotas_contrato(t.cid) FROM unnest(v_ids) AS t(cid);

    INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                               actor_id, actor_label, accion, diff, ocurrido_en)
    SELECT gen_random_uuid(), p_tenant, v_op_id, 'correccion_invariante',
           'contratos', t.cid, NULL, 'System Admin', 'update',
           jsonb_build_object(
             'campos', '[]'::jsonb,
             'resumen', jsonb_build_object('motivo',
               'Corrección automática INV17: se regeneraron las cuotas futuras '
               'del contrato indefinido (colchón de 3 meses).'))::text,
           now()
      FROM unnest(v_ids) AS t(cid);
  END IF;

  v_fixed := v_fixed || jsonb_build_object('INV17', v_count);
  v_total := v_total + v_count;

  -- Resumen para el log de operaciones del Dev. Solo si tocó algo: apretar el
  -- botón sobre un tenant sano no es un evento.
  IF v_total > 0 THEN
    INSERT INTO public.data_ops_log (tenant_id, operacion, target_label,
        afectados, backup_id, actor_id, actor_label)
    VALUES (p_tenant, 'corregir_invariantes', 'INV14/INV2/INV3/INV17',
        v_fixed || jsonb_build_object('total', v_total, 'op_id', v_op_id),
        NULL, auth.uid(), 'System Admin');
  END IF;

  RETURN v_fixed;
END;
$function$;
