-- 0261_condonacion_sin_corte_por_fecha.sql
--
-- QUE: la condonacion al cancelar deja de tener corte por FECHA. Si un contrato
-- esta en estado 'cancelado', no puede quedar nada pendiente — sin importar
-- cuando se cancelo. Y se backfillea la poblacion que quedaba.
--
-- REGLA (dueño, 2026-08-26): "los 5 cancelados de Telenet deberian ya aplicarse
-- de acuerdo a nuestra norma: si estan en estado cancelado se condona lo
-- pendiente y lo que se pago queda como historico. ¿Que decision esperas que se
-- tome en esos casos?"
--
-- POR QUE SE SACA EL CORTE Y NO SE HACE UNA EXCEPCION PUNTUAL: el corte
-- `cancelado_en >= 2026-08-24` de 0259 no representaba ninguna regla de
-- negocio. Existia por UNA razon concreta y escrita: proteger a esos 5
-- contratos de Telenet, que 0258 preservo porque el ISP los estaba usando para
-- perseguir la deuda. El dueño acaba de decidir lo contrario -dos veces, la
-- segunda ante la observacion explicita de que 0258 los habia preservado a
-- proposito-, asi que la razon del corte desaparecio. Dejarlo seria un fosil:
-- una condicion en el codigo que ya no corresponde a nada, y que el proximo que
-- la lea va a tomar por una regla.
--
-- ALCANCE medido antes de escribir esto (2026-08-26): la poblacion ENTERA de
-- contratos cancelados con deuda son esos **5 de Telenet: C$19.147,81 en 23
-- cuotas**, todos con `cancelado_en` y `cancelado_por` (ningun caso sin fecha
-- ni sin actor). Mairena: cero.
--
-- QUE NO CAMBIA: el gate sigue exigiendo `cancelado_en IS NOT NULL` porque la
-- funcion usa esa fecha como `ocurrido_en` del rastro. Un contrato cancelado
-- sin fecha seguiria afuera; hoy no hay ninguno CON DEUDA en esa situacion
-- (verificado), y si aparece lo caza el mismo invariante que caza todo esto.
-- Tampoco cambia el flag `cobranza.cancelar_condona`: sigue siendo la valvula
-- de escape explicita, con default TRUE y leida de forma tolerante.

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUE 1 — El gate, sin el corte por fecha
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.condonacion_cancelacion_aplica(p_contrato uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  -- SECURITY DEFINER porque `settings` y `contratos` están bajo RLS por
  -- `current_tenant_id()`, y el super_admin impersonando no matchea.
  SELECT ct.estado = 'cancelado'
     -- La fecha se sigue exigiendo, pero YA NO SE COMPARA (ver cabecera): la
     -- funcion la usa como `ocurrido_en` del rastro. Antes acá vivía
     -- `cancelado_en >= '2026-08-24'`, que existia solo para proteger los 5 de
     -- Telenet; esa proteccion la levanto el dueño el 2026-08-26.
     AND ct.cancelado_en IS NOT NULL
     -- Default TRUE: "cancelar no deja nada pendiente" es LA regla del
     -- producto, no una feature opcional. Se lee A MANO y NO con `setting_bool`,
     -- que hace `(valor)::boolean` y REVIENTA con 22P02 si el valor quedó
     -- JSON-quoteado ('"true"') — hay filas asi en produccion, y este gate corre
     -- en el camino caliente de TODO cobro (trigger del bloque 4 de 0259). Lo
     -- que no sea true/false cae al default.
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

COMMENT ON FUNCTION public.condonacion_cancelacion_aplica(uuid) IS
  'Regla 2026-08-26: un contrato cancelado no deja nada pendiente, sin corte '
  'por fecha. El flag cobranza.cancelar_condona sigue siendo la valvula.';

-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUE 2 — Backfill de lo que el corte dejaba afuera
-- ═══════════════════════════════════════════════════════════════════════════
-- Usa `condonar_deuda_contrato`, la MISMA funcion del trigger: sus tres ramas
-- ya estan auditadas (sin pago: anular; con abono: `monto = pagado`; con pago
-- en cuarentena: NO se toca) y su rastro sale con la forma que espera el
-- historial. Duplicar esa aritmetica aca seria un segundo lugar donde la regla
-- puede divergir.
DO $backfill$
DECLARE
  v_ct    record;
  v_res   jsonb;
  v_n     int := 0;
  v_monto numeric := 0;
BEGIN
  FOR v_ct IN
    SELECT DISTINCT ct.id, ct.codigo, ct.cancelado_por
      FROM public.contratos ct
      JOIN public.cuotas cu ON cu.contrato_id = ct.id
     WHERE ct.estado = 'cancelado'
       AND cu.estado IN ('pendiente', 'parcial')
       AND (cu.monto + COALESCE(cu.cargos_neto, 0)
            - COALESCE(cu.monto_pagado, 0)) > 0.009
     ORDER BY ct.codigo
  LOOP
    v_res := public.condonar_deuda_contrato(v_ct.id, v_ct.cancelado_por);
    v_n := v_n + 1;
    v_monto := v_monto + COALESCE((v_res->>'monto')::numeric, 0);
    RAISE LOG '0261 backfill: contrato % -> %', v_ct.codigo, v_res;
  END LOOP;

  RAISE LOG '0261 backfill: % contratos, C$% condonados', v_n, round(v_monto, 2);
END $backfill$;

COMMIT;
