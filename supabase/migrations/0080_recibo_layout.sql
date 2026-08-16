-- 0080 — Layout configurable del recibo ("diseñador de recibo", rework).
--
-- El recibo pasa a ser una LISTA ORDENADA de bloques; cada uno con
-- visibilidad + tamaño de letra. Este setting (`recibo.layout`) guarda esa
-- lista como un array JSON. El default = orden actual del catálogo, todo
-- visible, tamaño normal → los recibos existentes se ven igual (back-compat).
--
-- El bloque `totales` (dinero) se siembra visible y NO es ocultable (el
-- cliente Dart lo fuerza visible aunque alguien lo edite). Es fila nueva en
-- `settings` (key-value), sin columnas → sin bump de schema ni redeploy de
-- sync rules (SELECT * ya cubre).
--
-- Nota: los settings viejos de visibilidad (recibo.mostrar_empresa,
-- recibo.mostrar_cedula, recibo.orden_pie, recibo.monto_en_letras,
-- recibo.mostrar_adeudado, recibo.imprimir_logo) quedan vigentes hasta que el
-- render migre al layout (fase siguiente del rework). No se tocan acá.

DO $$
DECLARE
  v_tenant record;
  v_layout text := '[' ||
    '{"id":"logo","visible":true,"size":"normal"},' ||
    '{"id":"empresa","visible":true,"size":"normal"},' ||
    '{"id":"titulo","visible":true,"size":"normal"},' ||
    '{"id":"meta","visible":true,"size":"normal"},' ||
    '{"id":"cliente","visible":true,"size":"normal"},' ||
    '{"id":"servicio","visible":true,"size":"normal"},' ||
    '{"id":"cuota","visible":true,"size":"normal"},' ||
    '{"id":"metodo","visible":true,"size":"normal"},' ||
    '{"id":"letras","visible":true,"size":"normal"},' ||
    '{"id":"totales","visible":true,"size":"normal"},' ||
    '{"id":"pie","visible":true,"size":"normal"},' ||
    '{"id":"whatsapp","visible":true,"size":"normal"}' ||
  ']';
BEGIN
  FOR v_tenant IN SELECT id FROM tenants LOOP
    INSERT INTO settings (tenant_id, clave, valor, tipo, categoria, descripcion, editable_por)
    VALUES
      (v_tenant.id, 'recibo.layout', v_layout, 'json', 'recibos',
       'Layout del recibo: orden, visibilidad y tamaño de cada bloque', 'admin')
    ON CONFLICT (tenant_id, clave) DO NOTHING;
  END LOOP;
END $$;
