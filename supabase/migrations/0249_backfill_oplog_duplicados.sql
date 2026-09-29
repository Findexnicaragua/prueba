-- 0249_backfill_oplog_duplicados.sql
--
-- QUE: reponer las filas de `op_log` de los pagos que el guard de sobrepago
-- auto-anulo ANTES de que ese guard emitiera historial. Son 14 (verificado
-- 2026-08-23): 13 de Telecable Mairena y 1 del Test Tenant, C$8.288 en total,
-- entre el 2026-08-01 y el 2026-08-12.
--
-- POR QUE: el auto-anulado era SILENCIO TOTAL - el cobrador no lo ve (su
-- bucket filtra anulados) y la cuota no mostraba nada. El agujero ya esta
-- cerrado HACIA ADELANTE (`pagos_guard_sobrepago_trg` inserta op_log desde el
-- audit del 2026-08-19; hoy hay 0 filas con ese tipo_op porque no volvio a
-- pasar). Esto es solo la deuda historica.
--
-- FORMA: espeja EXACTAMENTE la fila que emite el trigger vigente - mismo
-- tipo_op, misma entidad ('cuotas'), mismo actor ('Sistema', actor_id NULL) y
-- el mismo resumen con `monto` + `pago_duplicado` + `pago_original`. El id del
-- pago original se extrae del propio motivo de anulacion, que lo lleva entre
-- parentesis; verificado: los 14 lo tienen y los 14 apuntan a un pago que
-- existe. Sin eso, la fila diria "se anulo un duplicado" sin decir duplicado
-- DE QUE, que es justo el dato que se necesita al reclamar.
--
-- `ocurrido_en` = la fecha REAL de la anulacion, no now(): el historial es una
-- linea de tiempo y meter 14 eventos de agosto con fecha de hoy la falsea.
-- (`pagos` NO tiene `created_at`: el fallback es ocurrido_en -> fecha_pago.
--  Verificado igual: los 14 tienen `anulado_en`, el COALESCE nunca se usa.)
--
-- NO TOCA DINERO: es un INSERT en un log append-only. No modifica `pagos`,
-- `cuotas` ni ninguna metrica de caja. `invariantes_dinero.sql` no se mueve.
--
-- IDEMPOTENTE: el NOT EXISTS matchea por el id del pago DENTRO del diff (no
-- solo por cuota), asi que una cuota con dos duplicados repone los dos y una
-- segunda corrida no repone nada.

INSERT INTO public.op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id,
                           actor_id, actor_label, accion, diff, ocurrido_en)
SELECT gen_random_uuid(), p.tenant_id, gen_random_uuid(),
       'duplicado_auto_anulado', 'cuotas', p.cuota_id,
       NULL, 'Sistema', 'update',
       jsonb_build_object(
         'campos', '[]'::jsonb,
         'resumen', jsonb_build_object(
           'monto',          p.monto_cordobas,
           'pago_duplicado', p.id,
           'pago_original',  substring(p.motivo_anulacion from '\(([0-9a-f-]{36})\)'),
           'motivo',         'Cobro identico duplicado (mismo monto y dia), '
                             'anulado automaticamente al sincronizar '
                             '(rastro repuesto por 0249)'))::text,
       COALESCE(p.anulado_en, p.ocurrido_en, p.fecha_pago)
  FROM public.pagos p
 WHERE p.anulado
   AND p.anulado_por IS NULL
   AND p.motivo_anulacion LIKE 'Duplicado autom%'
   AND p.cuota_id IS NOT NULL
   AND NOT EXISTS (
         SELECT 1 FROM public.op_log o
          WHERE o.tenant_id = p.tenant_id
            AND o.entidad = 'cuotas'
            AND o.entidad_id = p.cuota_id
            AND o.tipo_op = 'duplicado_auto_anulado'
            AND o.diff LIKE '%' || p.id::text || '%');
