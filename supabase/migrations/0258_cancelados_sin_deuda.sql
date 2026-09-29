-- 0258_cancelados_sin_deuda.sql
--
-- QUE: poner en CERO la deuda de los contratos ya cancelados, siguiendo la
-- regla nueva del dueño (2026-08-24): **cancelar no deja deuda pendiente**.
-- El codigo ya lo hace hacia adelante (commit "cancelar un contrato ya no deja
-- deuda pendiente"); esto es la deuda historica.
--
-- POR QUE: el dueño reporto que un contrato CANCELADO seguia apareciendo con
-- deuda cobrable. Era el diseño viejo -cancelar dejaba intactos los meses
-- cumplidos y prorrateaba el mes en curso-, que hacia casi lo mismo que
-- suspender. Ahora se separan: SUSPENDER conserva la deuda y es reversible;
-- CANCELAR la condona.
--
-- ALCANCE, medido antes de escribir esto:
--   51 contratos cancelados arrastran C$120.234,28 en 158 cuotas.
--   De esos se limpian **46 contratos · 135 cuotas · C$101.086,47**.
--
-- QUE QUEDA AFUERA, A PROPOSITO: los **5 contratos cortados por falta de pago**
-- (C$19.147,81, 23 cuotas). Son el unico grupo donde NINGUN cliente
-- recontrato -se fueron debiendo- y donde el ISP escribio el motivo a mano
-- para acordarse: "Cliente cortado desde 25/6/2026 quedo pendiente con mes
-- junio". Estan usando el sistema para seguir esa deuda; borrarla se la haria
-- perder. Decision explicita de Ruben. Se los identifica por el motivo, que es
-- el unico dato que distingue "se fue debiendo" de "se cancelo por error".
--
-- CONTEXTO QUE JUSTIFICA LIMPIAR EL RESTO: de los 51, **36 siguen siendo
-- clientes con otro contrato activo** (recontrataron, migraron de plan, o el
-- contrato se cancelo porque estaba mal cargado). Su deuda vieja es residuo
-- administrativo que ademas les infla la mora y los muestra en las listas de
-- cobro por un servicio que ya no tienen.
--
-- COMO se pone en cero, y por que NO todo con anular:
--   · cuota SIN pago  -> se anula.
--   · cuota CON pago  -> `monto = monto_pagado`, `cargos_neto = 0`,
--                        `estado = 'pagada'` (saldo 0).
-- Anular una cuota con plata NO es una opcion: el trigger
-- `cuotas_anular_pagos_asociados_trg` anula EN CASCADA sus pagos y sus recibos
-- -verificado leyendo su cuerpo vivo-, o sea que borraria plata que entro a
-- caja y un comprobante que el cliente tiene en la mano. Es la misma regla que
-- respeta el codigo Dart. Medido: **1 sola cuota con abono (C$300)** entra por
-- esta rama.
--
-- `cargos_neto` se lleva a 0 en la misma sentencia: entra en el saldo canonico
-- (invariante #10), asi que un cargo vivo resucitaria la cuota en las listas de
-- cobro aunque el monto quedara en cero.
--
-- RASTRO: una fila de `op_log` por cuota, con el saldo condonado en el resumen,
-- y una fila de `data_ops_log` con el total. Todas comparten `op_id`: es UNA
-- intencion (AGENTS, modelo del change log).
--
-- REVERSIBLE: las cuotas anuladas se pueden revivir con
-- `super_admin_cuota_estado_impl` ('revivir'); las saldadas conservan su
-- `monto_pagado` intacto, asi que el monto original se recupera del `op_log`.

BEGIN;

-- Poblacion, congelada en una tabla temporal para que las tres sentencias
-- (anular, saldar, registrar) operen EXACTAMENTE sobre las mismas filas.
CREATE TEMP TABLE _objetivo ON COMMIT DROP AS
SELECT ct.id AS contrato_id, ct.tenant_id, cu.id AS cuota_id,
       cu.estado AS estado_antes,
       cu.monto AS monto_antes,
       COALESCE(cu.cargos_neto,0) AS cargos_antes,
       COALESCE(cu.monto_pagado,0) AS pagado,
       (cu.monto + COALESCE(cu.cargos_neto,0) - COALESCE(cu.monto_pagado,0)) AS saldo
  FROM public.contratos ct
  JOIN public.cuotas cu ON cu.contrato_id = ct.id
 WHERE ct.estado = 'cancelado'
   AND cu.estado IN ('pendiente','parcial')
   AND (cu.monto + COALESCE(cu.cargos_neto,0) - COALESCE(cu.monto_pagado,0)) > 0.009
   -- EXCLUIR los cortados por falta de pago (ver arriba).
   AND COALESCE(ct.motivo_cancelacion,'') !~* 'cortad|corte|pendiente con mes';

-- GUARD: si la poblacion no es la medida, se aborta todo. Protege contra correr
-- esto en una base distinta o despues de que la data cambio.
DO $$
DECLARE v_c int; v_q int; v_m numeric;
BEGIN
  SELECT count(DISTINCT contrato_id), count(*), sum(saldo)
    INTO v_c, v_q, v_m FROM _objetivo;
  IF v_c <> 46 OR v_q <> 135 OR round(v_m, 2) <> 101086.47 THEN
    RAISE EXCEPTION 'ABORTA: se esperaban 46 contratos / 135 cuotas / '
      'C$101086.47 y hay % / % / C$%. No se toca nada.', v_c, v_q, round(v_m,2);
  END IF;
END $$;

-- (a) SIN pago -> anular.
UPDATE public.cuotas cu
   SET estado = 'anulada',
       anulada_en = now(),
       -- El CHECK `cuotas_anulacion_coherencia` exige los tres campos de la
       -- anulacion. Se atribuye al super_admin porque ES quien corre esto: un
       -- NULL aca haria fallar la migracion entera (paso), y ademas dejaria una
       -- anulacion sin responsable, que es lo que INV18 vino a cazar.
       anulada_por = '92f4d735-e6ee-4da5-9ff1-0647ce44b4b5'::uuid,
       motivo_anulacion = 'Cancelación de contrato: la deuda no se cobra'
  FROM _objetivo o
 WHERE cu.id = o.cuota_id AND o.pagado <= 0.009;

-- (b) CON pago -> saldar sin tocar la plata ni el recibo.
UPDATE public.cuotas cu
   SET monto = o.pagado,
       cargos_neto = 0,
       estado = 'pagada'
  FROM _objetivo o
 WHERE cu.id = o.cuota_id AND o.pagado > 0.009;

-- (c) Rastro por cuota. `actor_id` NULL + 'System Admin' es la convencion del
--     super_admin (AGENTS); el motivo dice de cuanto era el saldo condonado.
INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                           actor_id, actor_label, accion, diff, ocurrido_en)
SELECT gen_random_uuid(), o.tenant_id,
       '0258aaaa-0000-4000-8000-000000000258'::uuid,
       'cancelacion', 'cuotas', o.cuota_id,
       NULL, 'System Admin', 'update',
       jsonb_build_object(
         'campos', jsonb_build_array(
           jsonb_build_object('campo','estado','antes',o.estado_antes,
                              'despues', CASE WHEN o.pagado > 0.009
                                              THEN 'pagada' ELSE 'anulada' END),
           jsonb_build_object('campo','saldo','antes',round(o.saldo,2),
                              'despues',0)),
         'resumen', jsonb_build_object('motivo',
           'Contrato cancelado: la deuda ya no se cobra (regla 2026-08-24). '
           'Saldo condonado: C$' || to_char(o.saldo,'FM999,999,990.00')))::text,
       now()
  FROM _objetivo o;

-- (d) Resumen por tenant en el log de operaciones del Dev.
INSERT INTO public.data_ops_log (tenant_id, operacion, target_label,
    afectados, backup_id, actor_id, actor_label)
SELECT o.tenant_id, 'cancelados_sin_deuda',
       'Contratos cancelados: deuda condonada (0258)',
       jsonb_build_object(
         'contratos', count(DISTINCT o.contrato_id),
         'cuotas', count(*),
         'monto', round(sum(o.saldo), 2),
         'op_id', '0258aaaa-0000-4000-8000-000000000258'),
       NULL, NULL, 'System Admin'
  FROM _objetivo o
 GROUP BY o.tenant_id;

COMMIT;
