-- 0257_backfill_cancelado_en.sql
--
-- QUE: reponer `contratos.cancelado_en` en los 36 contratos terminados que lo
-- tienen NULL, tomando la fecha REAL del propio `op_log`.
--
-- POR QUE ESTABA VACIO: esos contratos se terminaron con el estado viejo
-- **'completado'** -que despues se elimino como alias de 'cancelado'-, por un
-- camino que NO escribia la atribucion; una migracion posterior los mapeo a
-- 'cancelado' sin reponer la fecha. Ese camino ya no existe (el CHECK todavia
-- admite 'completado' pero no queda ni una fila con ese estado, y ningun codigo
-- lo escribe), asi que esto es deuda historica cerrada, no un agujero abierto.
--
-- POR QUE IMPORTA: sin fecha, TODA logica que pregunte "que cuotas cubren
-- servicio posterior a la baja" queda ciega. Ahi vivia la deuda fantasma que
-- INV25 no veia: 11 cuotas por C$10.257 en 5 clientes de dos empresas que
-- ademas RECONTRATARON, o sea que se les facturaba el mismo mes dos veces (a
-- Tomasa Rios le pedian C$1.795 cuando debia C$513). Esas 11 ya se anularon con
-- `super_admin_cuota_estado_impl` -preview, motivo, respaldo y triple registro-
-- ANTES de esta migracion. Esto cierra el flanco para que no vuelva a pasar.
--
-- NO INVENTA NADA: la fecha sale del evento que el CLIENTE registro en su
-- momento (la fila de `op_log` que puso el contrato en 'completado', o la
-- `cancelacion`). Se toma el `min()` por si hubiera mas de una. Los contratos
-- sin ningun rastro (1 de 37, del Test Tenant) se quedan como estan: preferimos
-- un NULL honesto a una fecha inventada.
--
-- QUE NO REPONE: `cancelado_por` ni `motivo_cancelacion`. El actor no se puede
-- reconstruir con certeza y rellenarlo seria una atribucion FALSA - peor que el
-- vacio. INV26 no se mueve: su corte es 2026-08-20 y la fecha mas nueva que
-- esto escribe es 2026-08-08 (verificado: 0 cruzan el corte).
--
-- NO DISPARA NADA: `z_contratos_anular_cuotas_futuras` es
-- `AFTER UPDATE OF estado ... WHEN (old.estado IS DISTINCT FROM new.estado)`
-- (verificado con pg_get_triggerdef). Tocar solo `cancelado_en` NO lo activa,
-- asi que esto no anula ninguna cuota por efecto colateral. Y el guard de 0254
-- valida solo la TRANSICION a cancelado: una fila que YA esta cancelada pasa
-- por su rama de salida temprana.
--
-- IDEMPOTENTE: el WHERE exige `cancelado_en IS NULL`.

UPDATE public.contratos ct
   SET cancelado_en = sub.baja
  FROM (
    SELECT c.id,
           (SELECT min(o.ocurrido_en) FROM public.op_log o
             WHERE o.entidad = 'contratos'
               AND o.entidad_id = c.id
               AND (o.diff LIKE '%completado%' OR o.tipo_op = 'cancelacion')) AS baja
      FROM public.contratos c
     WHERE c.estado = 'cancelado' AND c.cancelado_en IS NULL
  ) sub
 WHERE ct.id = sub.id
   AND sub.baja IS NOT NULL
   AND ct.cancelado_en IS NULL;
