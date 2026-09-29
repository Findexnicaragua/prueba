-- Red del SERVER: al pasar un contrato a cancelado o suspendido, anular sus
-- cuotas futuras pendientes.
--
-- POR QUÉ. Hoy ese cierre lo hace SOLO el cliente, dentro de su
-- writeTransaction, leyendo su copia local de `cuotas`. Pero las cuotas las
-- genera un trigger del SERVER. Si PowerSync todavía no bajó las recién
-- generadas, el cliente mira, no ve nada futuro y no anula nada — y el contrato
-- queda cancelado con cuotas vivas que se le siguen facturando a alguien que ya
-- se dio de baja.
--
-- Medido en producción el 2026-08-11: 8 cuotas a precio completo por C$6.411 en
-- 3 clientes (CF0190 de Mairena; QH0073 y MV0049 de Telenet). Los gaps entre la
-- generación y la cancelación fueron de 1 y 6 minutos — la ventana de sync
-- exacta. Un caso al revés: se canceló 20:28 y el server generó 21:09, porque
-- el cambio de estado todavía no había subido.
--
-- QUÉ ANULA. Solo lo que el modelo llama FUTURO: cuotas cuyo servicio ni siquiera
-- empezó a la fecha de baja. La ventana de servicio se ancla al `dia_pago`
-- (ARQUITECTURA §3.5), NUNCA al mes calendario: su INICIO es el vencimiento de
-- la cuota anterior del mismo contrato. Si esa fecha es posterior a la baja, el
-- servicio no arrancó y la cuota no corresponde.
--
-- QUÉ NO TOCA:
--   - Cuotas con CUALQUIER pago (`monto_pagado > 0`): plata real, jamás se anula.
--   - La cuota EN CURSO (su ventana contiene la fecha de baja): va prorrateada a
--     los días consumidos, y de eso se encarga el cliente. El server no la toca
--     para no pisar un prorrateo ya aplicado.
--   - Las CUMPLIDAS: deuda real y cobrable.
-- O sea: es una RED, no un reemplazo. Cierra lo que el cliente no pudo ver.

CREATE OR REPLACE FUNCTION public.contratos_anular_cuotas_futuras_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_fecha date;
  v_por uuid;
  v_motivo text;
  v_n int;
BEGIN
  -- Fecha de la baja: la que registró el cliente, o hoy en hora de Nicaragua
  -- (UTC-6, regla #1b) si viniera nula.
  IF new.estado = 'cancelado' THEN
    v_fecha := COALESCE(new.cancelado_en::date, (now() - interval '6 hours')::date);
    v_por := new.cancelado_por;
    v_motivo := 'Cancelación de contrato (red del server)';
  ELSE
    -- La fecha de suspensión no vive en `contratos` sino en su propia tabla:
    -- se toma la de la suspensión ABIERTA (sin reactivar) más reciente.
    SELECT s.suspendido_en::date, s.suspendido_por INTO v_fecha, v_por
      FROM public.contrato_suspensiones s
     WHERE s.contrato_id = new.id AND s.reactivado_en IS NULL
     ORDER BY s.suspendido_en DESC
     LIMIT 1;
    v_fecha := COALESCE(v_fecha, (now() - interval '6 hours')::date);
    v_motivo := 'Suspensión de contrato (red del server)';
  END IF;

  v_por := COALESCE(v_por, auth.uid());
  IF v_por IS NULL THEN
    RAISE LOG 'contrato %: sin autor de la baja, no se anula nada', new.id;
    RETURN new;
  END IF;

  WITH futuras AS (
    SELECT cu.id
      FROM public.cuotas cu
     WHERE cu.contrato_id = new.id
       AND cu.estado = 'pendiente'
       AND COALESCE(cu.monto_pagado, 0) <= 0.009
       -- Inicio de la ventana de servicio = vencimiento de la cuota anterior
       -- del mismo contrato. Sin anterior, un mes antes de la propia.
       AND COALESCE(
             (SELECT max(cu2.fecha_vencimiento)
                FROM public.cuotas cu2
               WHERE cu2.contrato_id = cu.contrato_id
                 AND cu2.fecha_vencimiento < cu.fecha_vencimiento
                 AND cu2.estado <> 'anulada'),
             (cu.fecha_vencimiento - interval '1 month')::date
           ) > v_fecha
  )
  UPDATE public.cuotas c
     SET estado = 'anulada',
         anulada_en = now(),
         anulada_por = v_por,
         motivo_anulacion = v_motivo
   WHERE c.id IN (SELECT id FROM futuras);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN
    RAISE LOG 'contrato % -> %: anuladas % cuotas futuras', new.id, new.estado, v_n;
  END IF;
  RETURN new;
END;
$fn$;

COMMENT ON FUNCTION public.contratos_anular_cuotas_futuras_trg() IS
  'Red del server: anula las cuotas FUTURAS sin pago al dar de baja un contrato. '
  'El cierre principal lo hace el cliente; esto cubre la carrera contra el '
  'trigger de generacion cuando PowerSync no alcanzo a bajar las cuotas nuevas.';

-- El prefijo `z` es a propósito: los triggers de una tabla corren en orden
-- ALFABÉTICO, y este tiene que ver el contrato con su estado ya definitivo,
-- después de los demás.
DROP TRIGGER IF EXISTS z_contratos_anular_cuotas_futuras ON public.contratos;
CREATE TRIGGER z_contratos_anular_cuotas_futuras
  AFTER UPDATE OF estado ON public.contratos
  FOR EACH ROW
  WHEN (new.estado IN ('cancelado', 'suspendido')
        AND old.estado IS DISTINCT FROM new.estado)
  EXECUTE FUNCTION public.contratos_anular_cuotas_futuras_trg();

-- ── Reparación de lo que ya se escapó ────────────────────────────────────────
-- El trigger cubre de acá en adelante; estas son las cuotas que quedaron vivas
-- antes de que existiera. Misma definición exacta: servicio que nunca arrancó,
-- sin un centavo pagado.
--
-- Simulado en seco contra producción el 2026-08-11: 9 cuotas por C$7.364 en 4
-- contratos (CF0190 de Mairena; MV0049, MV0167 y QH0073 de Telenet). En todas,
-- el servicio arrancaba entre 16 días y 4 meses DESPUÉS de la baja.
WITH baja AS (
  SELECT ct.id,
         CASE WHEN ct.estado = 'cancelado' THEN ct.cancelado_en::date
              ELSE (SELECT s.suspendido_en::date
                      FROM public.contrato_suspensiones s
                     WHERE s.contrato_id = ct.id AND s.reactivado_en IS NULL
                     ORDER BY s.suspendido_en DESC LIMIT 1) END AS fecha,
         COALESCE(ct.cancelado_por,
                  (SELECT s.suspendido_por FROM public.contrato_suspensiones s
                    WHERE s.contrato_id = ct.id AND s.reactivado_en IS NULL
                    ORDER BY s.suspendido_en DESC LIMIT 1)) AS por,
         ct.estado
    FROM public.contratos ct
   WHERE ct.estado IN ('cancelado', 'suspendido')
), futuras AS (
  SELECT cu.id, b.por
    FROM baja b
    JOIN public.cuotas cu ON cu.contrato_id = b.id
   WHERE b.fecha IS NOT NULL AND b.por IS NOT NULL
     AND cu.estado = 'pendiente'
     AND COALESCE(cu.monto_pagado, 0) <= 0.009
     AND COALESCE(
           (SELECT max(cu2.fecha_vencimiento) FROM public.cuotas cu2
             WHERE cu2.contrato_id = cu.contrato_id
               AND cu2.fecha_vencimiento < cu.fecha_vencimiento
               AND cu2.estado <> 'anulada'),
           (cu.fecha_vencimiento - interval '1 month')::date) > b.fecha
)
UPDATE public.cuotas c
   SET estado = 'anulada',
       anulada_en = now(),
       anulada_por = f.por,
       motivo_anulacion = 'Servicio no prestado: el contrato ya estaba de baja '
                          '(reparación 0234)'
  FROM futuras f
 WHERE c.id = f.id;
