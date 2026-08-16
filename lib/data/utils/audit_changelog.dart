// Catálogos de campos y labels del change log, REUSADOS por el sistema op_log
// (`op_log.dart` / `op_log_campos.dart` / `rechazos_sync_service.dart`).
//
// El parser del `audit_log` forense (`auditExtraerCambios`, `auditDetectarAccion`,
// `auditSnapshotField`, `CampoChange` y sus helpers de formateo) vivía acá pero se
// ELIMINÓ junto con el `audit_log` en la migración 0140 (ver BITACORA). Quedan solo
// los catálogos/labels que el op_log sigue usando: la allowlist por defecto, el
// catálogo seleccionable por entidad, los labels por entidad/campo y las claves a
// omitir.

// ---------------------------------------------------------------------------
// Catálogo curado por entidad (allowlist). SOLO estos campos se muestran en
// el historial. Si la tabla NO está en el map, el comportamiento es permisivo
// (se muestran todos los campos que no estén en `kAuditSkipKeys`).
// ---------------------------------------------------------------------------
const Map<String, Set<String>> kAuditCamposVisiblesDefault = {
  'pagos': {
    'fecha_pago',
    'monto_cordobas',
    'vuelto_cordobas',
    'metodo',
    'notas',
    'referencia',
    'anulado',
  },
  'cuotas': {
    'estado',
    'monto',
    'monto_pagado',
    'periodo',
    'fecha_vencimiento',
    'tipo_cargo_manual',
    'descripcion',
  },
  'clientes': {
    'codigo',
    'nombre',
    'telefono',
    'email',
    'direccion',
    'cedula',
    'direccion_referencia',
    'notas',
    'activo',
    'cobrador_id',
    'comunidad_id',
    'puerto_id',
  },
  'contratos': {
    'codigo',
    'estado',
    'precio_mensual',
    'dia_pago',
    'fecha_inicio',
    'fecha_fin',
    'duracion_meses',
    'plan_id',
    'cobrador_id',
    'documento_path',
    // Nota interna del servicio (0227/0228). Faltaba: se escribía al crear el
    // contrato y ningún cambio quedaba registrado. Los tenants con override
    // persistido lo filtrarían igual → 0228 se lo agrega al setting.
    'notas',
  },
  // Cola de aprobación. FALTABA, y no era cosmético: `SolicitudesRepo.crear`
  // llama a `escribirCambioEntidad` DENTRO de su writeTransaction, y sin la
  // entidad registrada `diffVisible` dispara su `assert` → en build DEBUG la
  // transacción se cae y la solicitud NO se crea. En release el assert se
  // strippea y el efecto era otro: las solicitudes no dejaban NINGÚN rastro.
  'solicitudes_accion': {
    'tipo',
    'estado',
    'motivo_rechazo',
  },
  'contrato_suspensiones': {
    'motivo',
    'notas',
    'suspendido_por',
    'reactivado_en',
    'reactivado_por',
  },
  'recibos': {
    'numero_completo',
    'anulado',
    'reimpresiones',
  },
  'cargos_extra': {
    'monto',
    'tipo',
    'descripcion',
    // Rediseño 2026-06-11: sin el origen, una Promo era indistinguible de
    // un Ajuste o de un descuento del cobro en el historial.
    'origen',
  },
  // 'visitas' NO tiene entrada propia: visitas_service loguea bajo entidad
  // 'clientes' (la visita aparece en el historial del CLIENTE). Se removió la
  // entrada muerta (listaba 'estado', columna inexistente — la real es 'resultado').
  'fotos_cliente': {
    'descripcion',
  },
  // Etiquetas de clientes (P5, 0122).
  'etiquetas': {'nombre', 'color', 'icono', 'orden', 'activo'},
  'cliente_etiquetas': {'etiqueta_id'},
  // Saldo a favor (crédito por excedente, 0127). monto formatea como C$.
  'saldos_favor': {'tipo', 'monto', 'motivo', 'fecha_devolucion'},
  'planes': {
    'nombre',
    'tipo',
    'precio_mensual',
    'activo',
  },
  // Cobradores (0116, fix #9 del audit: era la única entidad editable sin
  // changelog — el prefijo de recibo es rastro de dinero).
  'cobradores': {
    'nombre',
    'telefono',
    'prefijo_recibo',
    'rol',
    'activo',
    'puede_cambiar_fecha',
  },
  // Geografía (per-tenant desde 0097) + topología de red (0098).
  'departamentos': {'nombre', 'codigo'},
  'municipios': {'nombre', 'departamento_id'},
  'comunidades': {'nombre', 'municipio_id'},
  'red_nodos': {'nombre', 'codigo', 'tipo', 'notas', 'activo'},
  'red_hubs': {'nombre', 'codigo', 'nodo_id', 'notas', 'activo'},
  'red_puertos': {'nombre', 'codigo', 'hub_id', 'notas', 'activo'},
  // Inventario (módulo opcional, 0099).
  'inv_categorias': {'nombre', 'orden', 'activo'},
  'inv_proveedores': {'nombre', 'telefono', 'notas', 'activo'},
  'inv_productos': {
    'nombre', 'codigo', 'es_serializado', 'unidad', 'maneja_decimal', 'activo',
    'stock_minimo',
  },
  'inv_ubicaciones': {'nombre', 'tipo', 'activa'},
  'inv_seriales': {'serial', 'mac', 'estado', 'cliente_id', 'notas'},
  'inv_movimientos': {'tipo', 'cantidad', 'motivo', 'notas', 'numero_factura'},
  // Tickets (módulo opcional, Fase 3).
  'ticket_tipos': {'nombre', 'descripcion', 'sla_horas', 'efecto', 'precio', 'activo'},
  // FK (tipo_id/asignado_a) fuera: el lookup no las resuelve → mostrarían UUID;
  // el timeline de ticket_eventos narra tipo/asignación legible. cliente_id sí
  // se resuelve (está en _kClavesFk).
  'tickets': {'titulo', 'descripcion', 'estado', 'prioridad', 'cliente_id'},
  'ticket_eventos': {'tipo_evento', 'comentario', 'estado_nuevo'},
  'ticket_adjuntos': {'descripcion'},
  // ticket_materiales (Fase 3C): producto/serial son FK; cantidad es el dato
  // legible. El evento se rotula "Consumido en ticket" en HistorialSerialWidget.
  'ticket_materiales': {'cantidad'},
  // incidentes (Fase 3D): nodo/hub/puerto son FK; el alcance lo narra la UI.
  'incidentes': {'titulo', 'descripcion', 'estado'},
};

// ---------------------------------------------------------------------------
// Catálogo de campos SELECCIONABLES por entidad. Es el superset que el panel de
// configuración de op_log ofrece como opciones. El subconjunto efectivamente
// visible se guarda en el setting per-tenant; si no hay setting, se usa el
// default curado de `kAuditCamposVisiblesDefault`.
//
// Orden de la lista = orden de presentación en el panel.
// ---------------------------------------------------------------------------
const Map<String, List<String>> kAuditCamposCatalogo = {
  'clientes': [
    'codigo',
    'nombre',
    'telefono',
    'email',
    'direccion',
    'cedula',
    'direccion_referencia',
    'notas',
    'activo',
    'cobrador_id',
    'comunidad_id',
    'puerto_id',
  ],
  'contratos': [
    'codigo',
    'estado',
    'precio_mensual',
    'dia_pago',
    'fecha_inicio',
    'fecha_fin',
    'duracion_meses',
    'documento_path',
    'plan_id',
    'cobrador_id',
    'notas',
  ],
  'solicitudes_accion': [
    'tipo',
    'estado',
    'motivo_rechazo',
  ],
  'contrato_suspensiones': [
    'motivo',
    'notas',
    'suspendido_por',
    'reactivado_en',
    'reactivado_por',
  ],
  'cuotas': [
    'estado',
    'monto',
    'monto_pagado',
    'periodo',
    'fecha_vencimiento',
    'tipo_cargo_manual',
    'descripcion',
    'cargos_neto',
  ],
  'pagos': [
    'fecha_pago',
    'monto_cordobas',
    'vuelto_cordobas',
    'monto_original',
    'moneda',
    'tasa_conversion',
    'metodo',
    'referencia',
    'notas',
    'anulado',
  ],
  'recibos': [
    'numero_completo',
    'anulado',
    'reimpresiones',
  ],
  'cargos_extra': [
    'monto',
    'tipo',
    'descripcion',
    'origen',
  ],
  // 'visitas' sin entrada propia (loguea bajo 'clientes' — ver default arriba).
  'fotos_cliente': [
    'descripcion',
  ],
  'etiquetas': ['nombre', 'color', 'icono', 'orden', 'activo'],
  'cliente_etiquetas': ['etiqueta_id'],
  'saldos_favor': ['tipo', 'monto', 'motivo', 'fecha_devolucion'],
  'planes': [
    'nombre',
    'tipo',
    'precio_mensual',
    'activo',
  ],
  'cobradores': [
    'nombre', 'telefono', 'prefijo_recibo', 'rol', 'activo',
    'puede_cambiar_fecha',
  ],
  'departamentos': ['nombre', 'codigo'],
  'municipios': ['nombre', 'departamento_id'],
  'comunidades': ['nombre', 'municipio_id'],
  'red_nodos': ['nombre', 'codigo', 'tipo', 'notas', 'activo'],
  'red_hubs': ['nombre', 'codigo', 'nodo_id', 'notas', 'activo'],
  'red_puertos': ['nombre', 'codigo', 'hub_id', 'notas', 'activo'],
  'inv_categorias': ['nombre', 'orden', 'activo'],
  'inv_proveedores': ['nombre', 'telefono', 'notas', 'activo'],
  'inv_productos': [
    'nombre', 'codigo', 'es_serializado', 'unidad', 'maneja_decimal', 'activo',
    'stock_minimo',
  ],
  'inv_ubicaciones': ['nombre', 'tipo', 'activa'],
  'inv_seriales': ['serial', 'mac', 'estado', 'cliente_id', 'notas'],
  'inv_movimientos': ['tipo', 'cantidad', 'motivo', 'notas', 'numero_factura'],
  'ticket_tipos': ['nombre', 'descripcion', 'sla_horas', 'efecto', 'precio', 'activo'],
  'tickets': ['titulo', 'descripcion', 'estado', 'prioridad', 'cliente_id'],
  'ticket_eventos': ['tipo_evento', 'comentario', 'estado_nuevo'],
  'ticket_adjuntos': ['descripcion'],
  'ticket_materiales': ['cantidad'],
  'incidentes': ['titulo', 'descripcion', 'estado'],
};

// Label humano por entidad (para los títulos de las secciones del panel).
const Map<String, String> kAuditEntidadLabel = {
  'clientes': 'Clientes',
  'contratos': 'Contratos',
  // Sin esto, un rechazo de sync sobre esta tabla le mostraba al usuario el
  // nombre crudo: "Un cambio en solicitudes_accion fue rechazado".
  'solicitudes_accion': 'Solicitudes de aprobación',
  'cuotas': 'Cuotas',
  'pagos': 'Pagos',
  'recibos': 'Recibos',
  'cargos_extra': 'Cargos y descuentos',
  'visitas': 'Visitas',
  'fotos_cliente': 'Fotos',
  'etiquetas': 'Etiquetas',
  'cliente_etiquetas': 'Etiquetas de cliente',
  'planes': 'Planes',
  'cobradores': 'Personal',
  'departamentos': 'Departamentos',
  'municipios': 'Municipios',
  'comunidades': 'Comunidades',
  'red_nodos': 'Nodos de red',
  'red_hubs': 'Hubs de red',
  'red_puertos': 'Puertos de red',
  'inv_categorias': 'Categorías de inventario',
  'inv_proveedores': 'Proveedores',
  'inv_productos': 'Productos',
  'inv_ubicaciones': 'Ubicaciones',
  'inv_seriales': 'Equipos serializados',
  'inv_movimientos': 'Movimientos de inventario',
  'ticket_tipos': 'Tipos de ticket',
  'tickets': 'Tickets',
  'ticket_eventos': 'Eventos de ticket',
  'ticket_adjuntos': 'Adjuntos de ticket',
  'ticket_materiales': 'Materiales de ticket',
  'incidentes': 'Incidentes',
  'contrato_suspensiones': 'Suspensiones de contrato',
  'saldos_favor': 'Saldo a favor',
};

// Columnas computadas / auto que se omiten en cualquier snapshot, además del
// allowlist. Esto evita filtrar ids/FKs/geo aunque la tabla caiga al fallback
// permisivo (tabla no presente en el map de arriba).
const Set<String> kAuditSkipKeys = {
  'id', 'tenant_id', 'client_local_id', 'created_at', 'updated_at',
  'foto_comprobante_path',
  // Campos de anulación/auditoría que cargan la UI con nulls
  // cuando se muestra una creación o snapshot de delete.
  'anulado_en', 'anulado_por', 'motivo_anulacion',
  // FK ids siempre ocultos (no aportan info o ya están reflejados en otro
  // lado del card): id de la entidad misma, group, user resuelto via JOIN.
  'cuota_id', 'pago_id', 'recibo_id', 'grupo_cobro', 'user_id',
  // Geo del cobro: deprecado (ya no se captura ubicación al cobrar).
  'lat', 'lng',
};

/// Label humano para una columna del change log.
String auditFieldLabel(String raw) {
  const labels = {
    'monto_cordobas': 'Monto',
    'monto_original': 'Monto original',
    'monto_pagado': 'Monto pagado',
    'vuelto_cordobas': 'Vuelto',
    'fecha_pago': 'Fecha de pago',
    'fecha_vencimiento': 'Fecha vencimiento',
    'fecha_inicio': 'Fecha inicio',
    'fecha_fin': 'Fecha fin',
    'cobrador_id': 'Cobrador',
    'cliente_id': 'Cliente',
    'contrato_id': 'Contrato',
    'cuota_id': 'Cuota',
    'plan_id': 'Plan',
    'metodo': 'Método de pago',
    'moneda': 'Moneda',
    'tasa_conversion': 'Tasa de conversión',
    'motivo_rechazo': 'Motivo del rechazo',
    'anulado': 'Anulado',
    'anulado_en': 'Anulado en',
    'anulado_por': 'Anulado por',
    'motivo_anulacion': 'Motivo anulación',
    'estado': 'Estado',
    'monto': 'Monto',
    'periodo': 'Período',
    'codigo': 'Código',
    'nombre': 'Nombre',
    'telefono': 'Teléfono',
    'direccion': 'Dirección',
    'cedula': 'Cédula',
    'comunidad_id': 'Comunidad',
    'departamento_id': 'Departamento',
    'municipio_id': 'Municipio',
    'puerto_id': 'Puerto',
    'hub_id': 'Hub',
    'nodo_id': 'Nodo',
    'activo': 'Activo',
    'referencia': 'Referencia',
    'notas': 'Notas',
    'descripcion': 'Descripción',
    'stock_minimo': 'Stock mínimo',
    'numero_completo': 'Número recibo',
    'grupo_cobro': 'Cobro agrupado',
    'cargos_neto': 'Cargos neto',
    'lat': 'Latitud',
    'lng': 'Longitud',
    'dia_pago': 'Día de pago',
    'reimpresiones': 'Reimpresiones',
    'documento_path': 'Documento adjunto',
    'precio_mensual': 'Precio mensual',
    'tipo_cargo_manual': 'Tipo de cargo',
    'origen': 'Origen',
    'pago_id': 'Pago',
    'recibo_id': 'Recibo',
    'numero': 'Número',
    'prefijo': 'Prefijo',
    'serie': 'Serie',
    'rol': 'Rol',
    'email': 'Email',
    'prefijo_recibo': 'Prefijo recibo',
    'puede_cambiar_fecha': 'Puede cambiar fecha',
    'duracion_meses': 'Duración (meses)',
    'tipo': 'Tipo',
    'resultado': 'Resultado',
    // Etiquetas (P5).
    'etiqueta_id': 'Etiqueta',
    'icono': 'Icono',
    'color': 'Color',
    'orden': 'Orden',
    // Tickets (Fase 3).
    'titulo': 'Título',
    'prioridad': 'Prioridad',
    'tipo_evento': 'Evento',
    'sla_horas': 'SLA (horas)',
    'efecto': 'Efecto en el servicio',
    'asignado_a': 'Asignado a',
    'tipo_id': 'Tipo de ticket',
    'estado_anterior': 'Estado anterior',
    'estado_nuevo': 'Estado nuevo',
    'comentario': 'Comentario',
    'correlativo': 'N° de ticket',
  };
  return labels[raw] ??
      raw
          .replaceAll('_', ' ')
          .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());
}
