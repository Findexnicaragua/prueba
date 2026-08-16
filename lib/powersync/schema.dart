// Schema del SQLite local que PowerSync mantiene sincronizado con Postgres.
//
// Reglas de tipo:
//   uuid / text / date / timestamptz → Column.text
//   numeric(10,2) / double precision → Column.real
//   boolean / int                    → Column.integer (SQLite no tiene bool)
//
// La columna `id` (text) se incluye automáticamente — no se declara.

import 'package:powersync/powersync.dart';

const schema = Schema([
  // ── Catálogos geo (per-tenant desde migración 0097) ───────────────────────
  Table('departamentos', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('codigo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('municipios', [
    Column.text('tenant_id'),
    Column.text('departamento_id'),
    Column.text('nombre'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_departamento', [
      IndexedColumn('tenant_id'),
      IndexedColumn('departamento_id'),
    ]),
  ]),

  Table('comunidades', [
    Column.text('tenant_id'),
    Column.text('municipio_id'),
    Column.text('nombre'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_municipio', [
      IndexedColumn('tenant_id'),
      IndexedColumn('municipio_id'),
    ]),
  ]),

  // ── Topología de red (per-tenant, migración 0098): Nodo → Hub → Puerto ────
  Table('red_nodos', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('codigo'),
    Column.text('tipo'),
    Column.real('lat'),
    Column.real('lng'),
    Column.text('notas'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('red_hubs', [
    Column.text('tenant_id'),
    Column.text('nodo_id'),
    Column.text('nombre'),
    Column.text('codigo'),
    Column.text('notas'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_nodo', [IndexedColumn('tenant_id'), IndexedColumn('nodo_id')]),
  ]),

  Table('red_puertos', [
    Column.text('tenant_id'),
    Column.text('hub_id'),
    Column.text('nombre'),
    Column.text('codigo'),
    Column.text('notas'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_hub', [IndexedColumn('tenant_id'), IndexedColumn('hub_id')]),
  ]),

  // ── Feature flags por tenant (read-only en la app; los togglea el
  //    super_admin vía RPC). Gatea módulos opcionales como Inventario. ───────
  Table('tenant_modulos', [
    Column.text('tenant_id'),
    Column.text('modulo_codigo'),
    Column.integer('habilitado'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  // ── Inventario (módulo opcional, migración 0099). Per-tenant. ─────────────
  Table('inv_categorias', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.integer('orden'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('inv_proveedores', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('telefono'),
    Column.text('notas'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('inv_productos', [
    Column.text('tenant_id'),
    Column.text('categoria_id'),
    Column.text('codigo'),
    Column.text('nombre'),
    Column.integer('es_serializado'),
    Column.text('unidad'),
    Column.integer('maneja_decimal'),
    Column.real('costo_promedio'),
    Column.real('stock_minimo'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_categoria',
        [IndexedColumn('tenant_id'), IndexedColumn('categoria_id')]),
  ]),

  Table('inv_ubicaciones', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('tipo'),
    Column.text('cobrador_id'),
    Column.integer('activa'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('inv_seriales', [
    Column.text('tenant_id'),
    Column.text('producto_id'),
    Column.text('serial'),
    Column.text('mac'),
    Column.text('estado'),
    Column.text('ubicacion_id'),
    Column.text('cliente_id'),
    Column.text('contrato_id'),
    Column.real('costo_ingreso'),
    Column.text('notas'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_producto',
        [IndexedColumn('tenant_id'), IndexedColumn('producto_id')]),
    Index('by_cliente',
        [IndexedColumn('tenant_id'), IndexedColumn('cliente_id')]),
  ]),

  Table('inv_movimientos', [
    Column.text('tenant_id'),
    Column.text('tipo'),
    Column.text('producto_id'),
    Column.text('serial_id'),
    Column.real('cantidad'),
    Column.text('ubicacion_origen_id'),
    Column.text('ubicacion_destino_id'),
    Column.text('cliente_id'),
    Column.text('contrato_id'),
    Column.text('proveedor_id'),
    Column.text('numero_factura'),
    Column.real('costo_unitario'),
    Column.text('motivo'),
    Column.text('notas'),
    Column.text('ticket_id'),
    Column.text('hecho_por'),
    Column.text('ocurrido_en'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_producto',
        [IndexedColumn('tenant_id'), IndexedColumn('producto_id')]),
    Index('by_serial', [IndexedColumn('serial_id')]),
  ]),

  // ── Tickets (módulo opcional, Fase 3) ─────────────────────────────────────
  Table('ticket_tipos', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('descripcion'),
    Column.integer('sla_horas'),
    Column.text('color'),
    Column.integer('orden'),
    Column.integer('activo'),
    // Efecto de servicio del tipo (0172): ninguno|instalacion|corte|reconexion.
    // Clasifica la orden de trabajo para derivar las colas de facturación.
    Column.text('efecto'),
    Column.text('checklist_template'),
    // Precio default del cobro del ticket (0173): 0 = no cobrable; >0 = el ticket
    // RESUELTO ofrece "Generar cobro" con este monto precargado (editable).
    Column.real('precio'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('tickets', [
    Column.text('tenant_id'),
    Column.integer('correlativo'),
    Column.text('tipo_id'),
    Column.text('cliente_id'),
    // Contrato al que aplica la orden de trabajo (0172). NULL = sin contrato
    // (instalación pre-contrato / outage). Un cliente puede tener varios.
    Column.text('contrato_id'),
    Column.text('puerto_id'),
    Column.text('incidente_id'),
    Column.text('titulo'),
    Column.text('descripcion'),
    Column.text('estado'),
    Column.text('prioridad'),
    // Posición en la cola del técnico (0206). NULL = sin posición explícita:
    // va después de las ordenadas, por antigüedad. La setea el coordinador.
    Column.integer('orden_cola'),
    Column.text('asignado_a'),
    Column.text('creado_por'),
    // Ubicación REAL donde el técnico ejecutó la orden (0204). Es del TICKET,
    // no del cliente: la ficha puede estar mal geolocalizada y lo que audita
    // el trabajo es dónde se paró el técnico. NULL = sin marcar.
    Column.real('lat'),
    Column.real('lng'),
    Column.text('resuelto_en'),
    Column.text('cerrado_en'),
    // Cómo se cerró la orden (0208). `cerrado_sin_confirmar` = se cerró tras N
    // intentos fallidos, sin que el cliente confirmara. Se guarda para poder
    // MEDIR cuántas se cierran a ciegas. Ambas nullables a propósito: una NOT
    // NULL que el cliente no setee viaja como NULL y traba la cola de upload.
    Column.integer('cerrado_sin_confirmar'),
    Column.text('motivo_cierre'),
    // Verificación del gestor sobre una instalación cerrada (0209). NULL = no
    // aplica (la orden no instala nada); 'pendiente' lo pone un trigger server
    // al cerrarse; 'verificada' lo firma el gestor.
    Column.text('verificacion_estado'),
    Column.text('verificado_por'),
    Column.text('verificado_en'),
    Column.integer('segundos_pausado'),
    Column.text('en_espera_desde'),
    Column.text('checklist'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id'), IndexedColumn('estado')]),
    Index('by_cliente', [IndexedColumn('cliente_id')]),
    Index('by_asignado', [IndexedColumn('asignado_a')]),
  ]),

  Table('ticket_eventos', [
    Column.text('tenant_id'),
    Column.text('ticket_id'),
    Column.text('tipo_evento'),
    Column.text('estado_anterior'),
    Column.text('estado_nuevo'),
    Column.text('comentario'),
    Column.text('hecho_por'),
    Column.text('ocurrido_en'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_ticket', [IndexedColumn('ticket_id')]),
  ]),

  Table('ticket_adjuntos', [
    Column.text('tenant_id'),
    Column.text('ticket_id'),
    Column.text('storage_path'),
    Column.text('descripcion'),
    Column.text('subido_por'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_ticket', [IndexedColumn('ticket_id')]),
  ]),

  // Materiales consumidos en un ticket (Fase 3C). El descuento de stock lo hace
  // un trigger server-side; el cliente sólo inserta esta fila.
  Table('ticket_materiales', [
    Column.text('tenant_id'),
    Column.text('ticket_id'),
    // 'consumo' (material que se instala) | 'retiro' (equipo que vuelve del
    // cliente a revisión) — 0205. El server discrimina la rama del trigger por
    // acá; default 'consumo', así una fila vieja o de una app previa no cambia
    // de comportamiento.
    Column.text('tipo'),
    Column.text('producto_id'),
    Column.text('serial_id'),
    Column.real('cantidad'),
    Column.text('ubicacion_origen_id'),
    Column.real('costo_unit_snapshot'),
    Column.text('hecho_por'),
    Column.text('ocurrido_en'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_ticket', [IndexedColumn('ticket_id')]),
    Index('by_serial', [IndexedColumn('serial_id')]),
  ]),

  // Incidentes / outages (Fase 3D). Alcance por nodo/hub/puerto o general.
  Table('incidentes', [
    Column.text('tenant_id'),
    Column.text('titulo'),
    Column.text('descripcion'),
    Column.text('nodo_id'),
    Column.text('hub_id'),
    Column.text('puerto_id'),
    Column.text('alcance_label'), // snapshot del alcance (0108): sobrevive al borrado del FK
    Column.text('estado'),
    Column.text('inicio'),
    Column.text('fin'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id'), IndexedColumn('estado')]),
  ]),

  // ── Catálogo del tenant ───────────────────────────────────────────────────
  Table('planes', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('tipo'),
    Column.real('precio_mensual'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('settings', [
    Column.text('tenant_id'),
    Column.text('clave'),
    Column.text('valor'),
    Column.text('tipo'),
    Column.text('categoria'),
    Column.text('descripcion'),
    Column.text('editable_por'),
    Column.text('updated_at'),
  ], indexes: [
    Index('by_categoria', [
      IndexedColumn('tenant_id'),
      IndexedColumn('categoria'),
    ]),
  ]),

  // ── Operativas ────────────────────────────────────────────────────────────
  Table('clientes', [
    Column.text('tenant_id'),
    Column.text('cobrador_id'),
    Column.text('comunidad_id'),
    Column.text('puerto_id'),
    Column.text('codigo'),
    Column.text('nombre'),
    Column.text('cedula'),
    Column.text('telefono'),
    Column.text('email'),
    Column.text('direccion'),
    Column.text('direccion_referencia'),
    Column.real('latitud'),
    Column.real('longitud'),
    Column.text('foto_path'),
    // Nota INTERNA sobre la persona (0227). La del CONTRATO describe el
    // servicio; ésta describe al cliente y sobrevive a sus contratos. La ven
    // todos los roles, la edita solo `admin`. Nunca sale en recibo ni PDF.
    Column.text('notas'),
    Column.integer('activo'),
    // Precalculado (server trigger + mirror offline): fecha de la cuota
    // pendiente más vieja → el mapa deriva el estado/color de acá sin cruzar
    // cuotas (Opción 2). Es una FECHA, no un estado.
    Column.text('vencimiento_mas_viejo'),
    Column.text('created_at'),
    Column.text('updated_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cobrador', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cobrador_id'),
    ]),
    Index('by_comunidad', [IndexedColumn('comunidad_id')]),
  ]),

  Table('contratos', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('codigo'),
    Column.text('cobrador_id'),
    Column.text('plan_id'),
    Column.integer('dia_pago'),
    Column.text('fecha_inicio'),
    Column.text('fecha_fin'),
    Column.integer('duracion_meses'),
    Column.text('fecha_primer_cobro'),
    Column.real('costo_instalacion'),
    Column.text('notas'),
    Column.text('estado'),
    Column.text('documento_path'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
    // Cancelación (0123): dinámica de suspensión pero permanente. Snapshot de
    // deuda (JSON texto) para reimprimir el documento.
    Column.text('cancelado_en'),
    Column.text('cancelado_por'),
    Column.text('motivo_cancelacion'),
    Column.text('cancelacion_deuda_snapshot'),
  ], indexes: [
    Index('by_cliente', [IndexedColumn('cliente_id')]),
  ]),

  // Suspensión temporal de contrato (Feature A): historial de pausas. Admin-only
  // (sync solo a buckets admin/admin_cobranza). deuda_snapshot = JSON (texto).
  Table('contrato_suspensiones', [
    Column.text('tenant_id'),
    Column.text('contrato_id'),
    Column.text('motivo'),
    Column.text('notas'),
    Column.text('deuda_snapshot'),
    Column.text('suspendido_en'),
    Column.text('suspendido_por'),
    Column.text('reactivado_en'),
    Column.text('reactivado_por'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_contrato', [
      IndexedColumn('tenant_id'),
      IndexedColumn('contrato_id'),
    ]),
  ]),

  Table('cuotas', [
    Column.text('tenant_id'),
    Column.text('contrato_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.text('periodo'),
    Column.text('fecha_vencimiento'),
    Column.real('monto'),
    Column.real('monto_pagado'),
    Column.real('cargos_neto'),
    Column.text('estado'),
    Column.text('anulada_en'),
    Column.text('anulada_por'),
    Column.text('motivo_anulacion'),
    Column.text('descripcion'),
    Column.text('tipo_cargo_manual'),
    // Liga la cuota manual (cobro puntual) al ticket que la originó (0173) — para
    // el recibo ("Ticket #N") y para no cobrar dos veces el mismo ticket.
    Column.text('ticket_id'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cobrador_estado', [
      IndexedColumn('cobrador_id'),
      IndexedColumn('estado'),
    ]),
    Index('by_cliente', [IndexedColumn('cliente_id')]),
    Index('by_vencimiento', [IndexedColumn('fecha_vencimiento')]),
    // Cuota más vieja por contrato (WHERE contrato_id = ? ORDER BY
    // fecha_vencimiento LIMIT 1): lo usan el mapa (mapa_screen) y el detalle de
    // contrato (contrato_detail_screen) — antes hacían full scan. (El resumen de
    // Cobros NO lo usa: su PARTITION es sobre una expresión COALESCE, ver
    // cobros_query.dart.) Verificado con EXPLAIN QUERY PLAN.
    Index('by_contrato_vencimiento', [
      IndexedColumn('contrato_id'),
      IndexedColumn('fecha_vencimiento'),
    ]),
  ]),

  Table('pagos', [
    Column.text('tenant_id'),
    Column.text('cuota_id'),
    Column.text('cobrador_id'),
    Column.real('monto_cordobas'),
    Column.real('vuelto_cordobas'),
    Column.text('moneda'),
    Column.real('monto_original'),
    Column.real('tasa_conversion'),
    Column.text('metodo'),
    Column.text('referencia'),
    Column.text('foto_comprobante_path'),
    Column.real('lat'),
    Column.real('lng'),
    Column.text('notas'),
    Column.text('fecha_pago'),
    Column.integer('anulado'),
    Column.text('anulado_en'),
    Column.text('anulado_por'),
    Column.text('motivo_anulacion'),
    // Cuarentena (0218): un sobrepago no-exacto queda en_revision=1 → NO cuenta
    // en ninguna métrica de caja hasta que una persona decide cuál pago es el
    // verdadero (pantalla "Cobros a revisar"). El server (guard 0214) lo setea.
    Column.integer('en_revision'),
    Column.text('revision_motivo'),
    Column.text('grupo_cobro'),
    Column.text('client_local_id'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cuota', [IndexedColumn('cuota_id')]),
    Index('by_fecha', [IndexedColumn('fecha_pago')]),
    Index('by_cobrador_fecha', [
      IndexedColumn('cobrador_id'),
      IndexedColumn('fecha_pago'),
    ]),
    Index('by_grupo_cobro', [IndexedColumn('grupo_cobro')]),
  ]),

  Table('recibos', [
    Column.text('tenant_id'),
    Column.text('pago_id'),
    Column.text('cobrador_id'),
    Column.text('prefijo'),
    Column.integer('correlativo'),
    Column.text('numero_completo'),
    Column.text('impreso_en'),
    Column.integer('reimpresiones'),
    Column.integer('ultimo_formato_mm'),
    Column.integer('anulado'),
    Column.text('anulado_en'),
    Column.text('anulado_por'),
    Column.text('created_at'),
    Column.text('client_local_id'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_correlativo', [
      IndexedColumn('cobrador_id'),
      IndexedColumn('prefijo'),
      IndexedColumn('correlativo'),
    ]),
  ]),

  Table('cargos_extra', [
    Column.text('tenant_id'),
    Column.text('cuota_id'),
    Column.text('cobrador_id'),
    Column.text('tipo'),
    Column.real('monto'),
    Column.real('porcentaje'),
    Column.text('descripcion'),
    Column.text('aplicado_por'),
    Column.text('aplicado_en'),
    Column.text('client_local_id'),
    Column.text('ocurrido_en'),
    // 0115 (Sprint 2): origen del cargo ('cobro'|'ajuste'|'promo'|
    // 'liquidacion'), grupo de promoción y pago que lo insertó (reversión M3).
    Column.text('origen'),
    Column.text('grupo_promo'),
    Column.text('pago_id'),
  ], indexes: [
    Index('by_cuota', [IndexedColumn('cuota_id')]),
  ]),

  Table('notificaciones_mora', [
    Column.text('tenant_id'),
    Column.text('cuota_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.integer('dias_mora'),
    Column.real('monto_adeudado'),
    Column.text('generada_en'),
    Column.text('vista_en'),
    Column.text('vista_por'),
    Column.text('resuelta_en'),
    Column.text('resuelta_por'),
  ], indexes: [
    Index('by_cobrador_resuelta', [
      IndexedColumn('cobrador_id'),
      IndexedColumn('resuelta_en'),
    ]),
  ]),

  // op_log — log de INTENCIÓN del usuario (rework de change log,
  // CHANGELOG-REWORK.md). Lo escribe el CLIENTE dentro de su writeTransaction:
  // 1 fila por cada objeto afectado, scoped a sus atributos. Lo LEEN
  // admin/admin_cobranza; el cobrador lo ESCRIBE (sus cobros offline) pero NO lo
  // descarga. Tabla aditiva → NO bumpea _dbWipeVersion (in-place, política R4).
  Table('op_log', [
    Column.text('tenant_id'),
    Column.text('op_id'),
    Column.text('tipo_op'),
    Column.text('entidad'),
    Column.text('entidad_id'),
    Column.text('actor_id'),
    Column.text('actor_label'),
    Column.text('accion'),
    Column.text('diff'),
    Column.text('ocurrido_en'),
    Column.text('created_at'),
  ], indexes: [
    // Historial de un objeto: WHERE entidad=? AND entidad_id=? ORDER BY ocurrido_en.
    Index('by_entidad', [
      IndexedColumn('entidad'),
      IndexedColumn('entidad_id'),
      IndexedColumn('ocurrido_en'),
    ]),
    Index('by_op', [IndexedColumn('op_id')]),
  ]),

  // Vista limitada del cobrador (su propia fila) o del tenant entero
  // (bucket admin/admin_cobranza).
  Table('cobradores', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('telefono'),
    Column.text('rol'),
    Column.text('prefijo_recibo'),
    Column.integer('activo'),
    // Permiso por usuario para el cambio de fecha de pago por días (0119).
    Column.integer('puede_cambiar_fecha'),
    // Solo el FLAG viaja tenant-wide: dice si tiene PIN, no cuál (0201). El
    // valor vive en `dashboard_pins`, que baja únicamente el del propio user.
    Column.integer('dashboard_pin_configurado'),
  ]),

  // PIN del Resumen — UNA fila, la del usuario logueado (0202). Tabla aparte
  // justamente para que el bucket sea inequívoco y el PIN ajeno nunca llegue.
  Table('dashboard_pins', [
    Column.text('tenant_id'),
    Column.text('pin'),
    Column.text('updated_at'),
  ]),

  // ── Fotos del cliente (max 10 por cliente) ──────────────────────────
  Table('fotos_cliente', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.text('storage_path'),
    Column.text('created_at'),
    Column.text('created_by'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cliente', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cliente_id'),
    ]),
    Index('by_cobrador', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cobrador_id'),
    ]),
  ]),

  // ── Visitas registradas por el cobrador ─────────────────────────────
  Table('visitas', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.text('resultado'),
    Column.text('notas'),
    Column.text('fecha'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cliente', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cliente_id'),
    ]),
    Index('by_cobrador', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cobrador_id'),
    ]),
  ]),

  // ── Etiquetas personalizables de clientes (P5, migración 0122) ────────
  // Catálogo por tenant (color + icono). Lo leen todos; lo escriben
  // admin/admin_cobranza.
  Table('etiquetas', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('color'),
    Column.text('icono'),
    Column.integer('orden'),
    Column.integer('activo'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  // Relación M2M cliente↔etiqueta. `cobrador_id` denormalizado para el
  // bucket por_cobrador (lo setea/mantiene el server, 0122/0068).
  Table('cliente_etiquetas', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('etiqueta_id'),
    Column.text('cobrador_id'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cliente', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cliente_id'),
    ]),
    Index('by_cobrador', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cobrador_id'),
    ]),
  ]),

  // Saldos a favor del cliente (crédito por excedente al suspender/cancelar,
  // 0127). Libro append-only: tipo acreditado(+)/aplicado/devuelto/condonado/
  // revertido. saldo_disponible = +acreditado − (resto). Lo gestiona
  // admin/admin_cobranza; sincroniza al bucket admin del tenant.
  Table('saldos_favor', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('contrato_id'),
    Column.text('tipo'),
    Column.real('monto'),
    Column.text('cuota_id'),
    Column.text('origen_evento_id'),
    Column.text('cargo_id'),
    Column.text('recibo_id'),
    Column.text('cobrador_id'),
    Column.text('fecha_devolucion'),
    Column.text('motivo'),
    Column.text('creado_por'),
    Column.text('ocurrido_en'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_cliente', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cliente_id'),
    ]),
  ]),

  // ── Cola de aprobación (Fase 3B): admin_usuarios solicita acciones
  //    estructurales; admin/admin_cobranza aprueba/rechaza. ─────────────
  Table('solicitudes_accion', [
    Column.text('tenant_id'),
    Column.text('solicitante_id'),
    Column.text('tipo'),
    Column.text('entidad_id'),
    Column.text('datos'),
    // Motivo y notas de la solicitud en COLUMNAS (0222). Antes iban dentro del
    // jsonb `datos`, que es el BORRADOR del contrato: ahí las `notas` de la
    // solicitud pisaban las notas del CONTRATO al aprobar.
    Column.text('motivo'),
    Column.text('notas'),
    // Deuda cobrable calculada al PEDIR (0229), en JSON de texto. Referencia
    // histórica: el aprobador ve el recálculo en vivo, no este valor.
    Column.text('deuda_snapshot'),
    Column.text('estado'),
    Column.text('aprobador_id'),
    Column.text('motivo_rechazo'),
    Column.text('solicitante_label'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
    Column.text('resolved_at'),
  ], indexes: [
    Index('by_tenant_estado', [
      IndexedColumn('tenant_id'),
      IndexedColumn('estado'),
    ]),
    Index('by_solicitante', [
      IndexedColumn('tenant_id'),
      IndexedColumn('solicitante_id'),
    ]),
  ]),

  // ── Impersonación de tenant por super_admin ──────────────────────────
  // Una sola row (o ninguna) por super_admin. Sincronizada vía el bucket
  // `impersonated_tenant` en sync-rules.yaml. Cuando existe, indica que
  // el super_admin está "dentro" de un tenant y la app muestra el
  // AdminShell con la data de ese tenant.
  Table('super_admin_impersonation', [
    Column.text('user_id'),
    Column.text('tenant_id'),
    Column.text('started_at'),
  ]),
]);
