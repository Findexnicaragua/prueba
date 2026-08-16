import '../../../powersync/db.dart' as ps;

/// Metadata humanizada de cada invariante de dinero (INV1-INV20).
class InvInfo {
  const InvInfo({
    required this.titulo,
    required this.explicacion,
    required this.correccion,
    required this.severidad,
    required this.tipoId,
    this.autoFix = false,
  });

  final String titulo;
  final String explicacion;
  final String correccion;
  final String severidad; // 'critica', 'alta', 'media', 'info'
  final String tipoId; // 'contrato', 'cuota', 'pago', 'cliente', 'texto'
  final bool autoFix;
}

/// Códigos de invariantes que se corrigen automáticamente con la RPC
/// `super_admin_corregir_invariantes` (0189).
const kAutoFixCodes = {'INV2', 'INV3', 'INV14', 'INV17'};

const kInvInfo = <String, InvInfo>{
  'INV1': InvInfo(
    titulo: 'Pago descuadrado (entregado ≠ aplicado + vuelto)',
    explicacion:
        'Lo que entregó el cliente (monto original × tasa) no coincide con lo '
        'que se aplicó a la cuota + el vuelto devuelto. La diferencia supera '
        'C\$0.50, así que no es redondeo.',
    correccion:
        'Abrí el detalle del pago desde el contrato del cliente. Verificá la '
        'tasa de conversión y el vuelto. Si están mal, anulá el pago y '
        'registralo de nuevo con los valores correctos.',
    severidad: 'critica',
    tipoId: 'pago',
  ),
  'INV2': InvInfo(
    titulo: 'Cuota con monto pagado incorrecto',
    explicacion:
        'El campo "monto pagado" de la cuota no coincide con la suma real de '
        'los pagos no anulados. Esto hace que el saldo de la cuota esté mal '
        'y el recaudado del contrato no cuadre.',
    correccion:
        'Se corrige automáticamente re-sincronizando monto_pagado con la '
        'suma real de pagos no anulados.',
    severidad: 'critica',
    tipoId: 'cuota',
    autoFix: true,
  ),
  'INV3': InvInfo(
    titulo: 'Estado de cuota no coincide con lo pagado',
    explicacion:
        'Una cuota dice "pagada" pero le falta plata, o dice "pendiente" pero '
        'tiene pagos, o dice "parcial" pero el monto no cuadra. El cobrador '
        'podría verla en la lista equivocada.',
    correccion:
        'Se corrige automáticamente re-calculando el estado basado en '
        'monto_pagado vs monto + cargos.',
    severidad: 'alta',
    tipoId: 'cuota',
    autoFix: true,
  ),
  'INV4': InvInfo(
    titulo: 'Cuota con sobrepago',
    explicacion:
        'Una cuota tiene más pagado de lo que cuesta (monto + cargos). El '
        'excedente no se devolvió como vuelto → infla el recaudado.',
    correccion:
        'Abrí el contrato y revisá los pagos de esa cuota. El excedente '
        'debería haberse registrado como vuelto o como saldo a favor. Anulá '
        'el pago de más y re-registralo correctamente.',
    severidad: 'critica',
    tipoId: 'cuota',
  ),
  'INV5': InvInfo(
    titulo: 'Pago sin recibo',
    explicacion:
        'Un pago no anulado no tiene recibo asociado. El cliente no tiene '
        'comprobante y el correlativo está roto.',
    correccion:
        'Usá "Generar recibos faltantes" más abajo en esta misma pantalla. '
        'Genera el recibo automáticamente con el correlativo siguiente.',
    severidad: 'alta',
    tipoId: 'pago',
  ),
  'INV6': InvInfo(
    titulo: 'Vuelto negativo',
    explicacion:
        'Un pago tiene vuelto negativo, lo cual no tiene sentido contable '
        '(no se le puede "cobrar de más" al vuelto).',
    correccion:
        'Anulá el pago y re-registralo con el vuelto correcto (≥ 0).',
    severidad: 'alta',
    tipoId: 'pago',
  ),
  'INV7': InvInfo(
    titulo: 'Recibo duplicado (mismo número)',
    explicacion:
        'Dos o más recibos comparten el mismo número de comprobante. Esto '
        'rompe la numeración fiscal y puede causar confusión al imprimir.',
    correccion:
        'Identificá cuál de los recibos duplicados es el correcto y contactá '
        'al administrador para eliminar el duplicado vía SQL.',
    severidad: 'alta',
    tipoId: 'texto',
  ),
  'INV8': InvInfo(
    titulo: 'Cobrador del contrato ≠ cobrador del cliente',
    explicacion:
        'Un contrato activo tiene un cobrador distinto al de su cliente. Esto '
        'hace que el contrato aparezca en la lista de un cobrador pero el '
        'cliente en la de otro.',
    correccion:
        'Reasigná el cobrador del cliente (la propagación automática '
        'actualiza contratos y cuotas). O usá "Reasignar cobrador en masa" '
        'más abajo.',
    severidad: 'media',
    tipoId: 'contrato',
  ),
  'INV9': InvInfo(
    titulo: 'Cobrador de cuota ≠ cobrador del contrato',
    explicacion:
        'Una cuota operativa (pendiente/parcial) tiene un cobrador distinto '
        'al de su contrato. El cobrador podría no verla en su lista de cobro.',
    correccion:
        'Se corrige reasignando el cobrador del cliente (propaga a contratos '
        'y cuotas automáticamente). Si persiste, contactá al administrador.',
    severidad: 'media',
    tipoId: 'cuota',
  ),
  'INV10': InvInfo(
    titulo: 'Datos en el tenant equivocado',
    explicacion:
        'Un pago, recibo o cargo tiene un tenant_id distinto al de su padre '
        '(cuota/pago). La plata se está contando en el ISP equivocado.',
    correccion:
        'Esto es un error grave de integridad. Contactá al administrador del '
        'sistema para corregir los tenant_id vía SQL.',
    severidad: 'critica',
    tipoId: 'texto',
  ),
  'INV11': InvInfo(
    titulo: 'Contrato fijo con cuotas de más o de menos',
    explicacion:
        'Un contrato con duración fija tiene un número de cuotas distinto al '
        'esperado. El total del contrato no cuadra con sus cuotas.',
    correccion:
        'Verificá el contrato: si tiene cuotas de más, puede ser una '
        'generación duplicada. Si tiene de menos, faltó generar. Contactá '
        'al administrador para ajustar vía SQL.',
    severidad: 'alta',
    tipoId: 'contrato',
  ),
  'INV12': InvInfo(
    titulo: 'Recaudado del contrato descuadrado',
    explicacion:
        'La suma de monto_pagado de las cuotas no coincide con la suma de '
        'pagos reales del contrato. El recaudado que se muestra está mal.',
    correccion:
        'Es una consecuencia de INV2. Corregí las cuotas descuadradas '
        'primero y este invariante debería resolverse solo.',
    severidad: 'critica',
    tipoId: 'contrato',
  ),
  'INV13': InvInfo(
    titulo: 'Ajuste sin descuento o sin motivo',
    explicacion:
        'Un cargo de origen "ajuste" no es un descuento o no tiene '
        'descripción. Los ajustes del admin siempre deben ser descuentos '
        'con motivo justificado.',
    correccion:
        'Abrí la cuota afectada y revisá los cargos. Eliminá el cargo '
        'mal formado y re-aplicalo correctamente como descuento con motivo.',
    severidad: 'media',
    tipoId: 'cuota',
  ),
  'INV14': InvInfo(
    titulo: 'Cargos de cuota descuadrados',
    explicacion:
        'El campo cargos_neto de la cuota no coincide con la suma real de '
        'sus cargos_extra. El saldo pendiente está mal calculado.',
    correccion:
        'Se corrige automáticamente re-sincronizando cargos_neto con la '
        'suma real de cargos_extra.',
    severidad: 'alta',
    tipoId: 'cuota',
    autoFix: true,
  ),
  'INV15': InvInfo(
    titulo: 'Saldo a favor negativo',
    explicacion:
        'Un cliente tiene saldo a favor negativo: se aplicó o devolvió más '
        'crédito del que se acreditó. Puede ser una condición de carrera '
        'offline.',
    correccion:
        'Revisá el historial de saldo a favor del cliente. Anulá la '
        'aplicación excedente o acreditá la diferencia manualmente.',
    severidad: 'alta',
    tipoId: 'cliente',
  ),
  'INV16': InvInfo(
    titulo: 'Pago con método inválido',
    explicacion:
        'Un pago tiene un método de pago que no es efectivo, transferencia, '
        'depósito ni tarjeta. El crédito a favor NO es un pago (va por '
        'cargos_extra).',
    correccion:
        'Anulá el pago y re-registralo con el método correcto. Si era un '
        'crédito aplicado, debería estar como cargo descuento, no como pago.',
    severidad: 'alta',
    tipoId: 'pago',
  ),
  'INV17': InvInfo(
    titulo: 'Colchón de cuotas futuras insuficiente',
    explicacion:
        'Estos contratos indefinidos (sin fecha de fin) no tienen al menos 3 '
        'cuotas pendientes futuras generadas. Sin colchón, al cobrar la '
        'última cuota no habrá cuota siguiente lista para el cobrador.',
    correccion:
        'Se corrige automáticamente regenerando las cuotas faltantes. '
        'El cron nocturno (06:05 UTC, diario) también lo mantiene.',
    severidad: 'media',
    tipoId: 'contrato',
    autoFix: true,
  ),
  // INV18-INV20 los agrega el RPC en 0220. Sin su entrada acá el panel igual
  // funciona (cae al render crudo: etiqueta + UUIDs pelados), pero el
  // super_admin no tendría ni el porqué ni el cómo se arregla — justo lo que
  // esta tabla existe para dar.
  'INV18': InvInfo(
    titulo: 'Pago anulado sin quién lo anuló',
    explicacion:
        'Estos pagos figuran anulados pero sin usuario responsable. El único '
        'que puede anular sin actor es el guard de sobrepago automático, y ese '
        'deja siempre su motivo "Duplicado automático:". Cualquier otro caso '
        'es una anulación sin rastro de quién la hizo.',
    correccion:
        'Revisá el historial (op_log) del pago para identificar al responsable '
        'y completá el motivo de anulación. Si la anulación no correspondía, '
        're-registrá el cobro.',
    severidad: 'alta',
    tipoId: 'pago',
  ),
  'INV19': InvInfo(
    titulo: 'Cliente desactivado que todavía debe',
    explicacion:
        'Desactivar un cliente significa que ya no tiene servicio Y está '
        'saldado. Estos están desactivados pero tienen cuotas pendientes o '
        'parciales con saldo: su deuda es INVISIBLE — no salen en las listas '
        'de cobro, pero se les siguen venciendo cuotas. La deuda de un '
        'contrato cancelado sigue siendo deuda y se cobra igual.',
    correccion:
        'Reactivá al cliente para que vuelva a la lista de cobro (esa es la '
        'salida normal), o anulá las cuotas que ya no se van a cobrar. Desde '
        '0220 el server impide desactivar a un cliente con deuda, así que '
        'estos son casos anteriores al guard.',
    severidad: 'alta',
    tipoId: 'cliente',
  ),
  'INV20': InvInfo(
    titulo: 'Vencimiento más viejo desincronizado',
    explicacion:
        'La fecha de vencimiento más vieja guardada en el cliente no coincide '
        'con la que sale de sus cuotas. De ese dato dependen el color del pin '
        'en el mapa y la priorización de la ruta: si quedó adelantado, el '
        'cliente se ve menos vencido de lo que está y el cobrador no lo '
        'visita.',
    correccion:
        'Se resincroniza recalculándolo desde las cuotas. Cualquier cobro o '
        'cambio de cuota de ese cliente también lo corrige solo (lo mantiene '
        'un trigger del server).',
    severidad: 'media',
    tipoId: 'cliente',
  ),
};

/// Extrae "INV17" de "INV17: indefinido activo tiene >= 3 ...".
String? extraerCodigoInv(String invariante) {
  final match = RegExp(r'INV\d+').firstMatch(invariante);
  return match?.group(0);
}

/// Dato resuelto de un registro ofensor.
class RegistroResuelto {
  const RegistroResuelto({
    required this.id,
    required this.descripcion,
    this.detalle,
  });
  final String id;
  final String descripcion;
  final String? detalle;
}

/// Resuelve IDs de ejemplo a información legible (nombre de cliente, contrato,
/// período, etc.) consultando la SQLite local.
Future<List<RegistroResuelto>> resolverIds(
    String codigoInv, String idsStr) async {
  if (idsStr.isEmpty) return [];

  final info = kInvInfo[codigoInv];
  if (info == null) return _fallback(idsStr);

  final ids =
      idsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  if (ids.isEmpty) return [];

  switch (info.tipoId) {
    case 'contrato':
      return _resolverContratos(ids, codigoInv);
    case 'cuota':
      return _resolverCuotas(ids, codigoInv);
    case 'pago':
      return _resolverPagos(ids, codigoInv);
    case 'cliente':
      return _resolverClientes(ids);
    case 'texto':
      return ids
          .map((id) => RegistroResuelto(id: id, descripcion: id))
          .toList();
    default:
      return _fallback(idsStr);
  }
}

Future<List<RegistroResuelto>> _resolverContratos(
    List<String> ids, String codigo) async {
  final ph = List.filled(ids.length, '?').join(',');
  final rows = await ps.db.getAll(
    'SELECT ct.id, ct.codigo, c.nombre AS cliente, '
    "COALESCE(p.nombre, 'Sin plan') AS plan, ct.duracion_meses "
    'FROM contratos ct '
    'LEFT JOIN clientes c ON c.id = ct.cliente_id '
    'LEFT JOIN planes p ON p.id = ct.plan_id '
    'WHERE ct.id IN ($ph)',
    ids,
  );

  final resueltos = <RegistroResuelto>[];
  final encontrados = <String>{};

  for (final r in rows) {
    final id = r['id'] as String;
    encontrados.add(id);
    final cliente = r['cliente'] as String? ?? '?';
    final plan = r['plan'] as String? ?? '?';
    final cod = r['codigo'] as String? ?? '';
    var detalle = '$plan${cod.isNotEmpty ? ' ($cod)' : ''}';

    if (codigo == 'INV17') {
      final futuras = await _contarCuotasFuturas(id);
      detalle += ' — $futuras cuota(s) futura(s)';
    } else if (codigo == 'INV11') {
      final dm = r['duracion_meses'] as int?;
      final actual = await _contarCuotasActivas(id);
      detalle += ' — tiene $actual cuotas (esperadas: $dm)';
    }

    resueltos.add(RegistroResuelto(
      id: id,
      descripcion: cliente,
      detalle: detalle,
    ));
  }

  for (final id in ids) {
    if (!encontrados.contains(id)) {
      resueltos.add(RegistroResuelto(
        id: id,
        descripcion: '(no encontrado en data local)',
      ));
    }
  }

  return resueltos;
}

Future<int> _contarCuotasFuturas(String contratoId) async {
  final rows = await ps.db.getAll(
    'SELECT COUNT(*) AS n FROM cuotas '
    "WHERE contrato_id = ? AND estado = 'pendiente' "
    'AND tipo_cargo_manual IS NULL '
    "AND periodo > date('now', '-6 hours')",
    [contratoId],
  );
  return (rows.firstOrNull?['n'] as int?) ?? 0;
}

Future<int> _contarCuotasActivas(String contratoId) async {
  final rows = await ps.db.getAll(
    'SELECT COUNT(*) AS n FROM cuotas '
    'WHERE contrato_id = ? AND tipo_cargo_manual IS NULL '
    "AND estado <> 'anulada'",
    [contratoId],
  );
  return (rows.firstOrNull?['n'] as int?) ?? 0;
}

Future<List<RegistroResuelto>> _resolverCuotas(
    List<String> ids, String codigo) async {
  final ph = List.filled(ids.length, '?').join(',');
  final rows = await ps.db.getAll(
    'SELECT cu.id, cu.periodo, cu.monto, cu.monto_pagado, cu.estado, '
    'cu.cargos_neto, c.nombre AS cliente, ct.codigo AS contrato_codigo '
    'FROM cuotas cu '
    'LEFT JOIN contratos ct ON ct.id = cu.contrato_id '
    'LEFT JOIN clientes c ON c.id = ct.cliente_id '
    'WHERE cu.id IN ($ph)',
    ids,
  );

  final resueltos = <RegistroResuelto>[];
  final encontrados = <String>{};

  for (final r in rows) {
    final id = r['id'] as String;
    encontrados.add(id);
    final cliente = r['cliente'] as String? ?? '?';
    final periodo = r['periodo'] as String? ?? '?';
    final monto = r['monto'] as num? ?? 0;
    final pagado = r['monto_pagado'] as num? ?? 0;
    final estado = r['estado'] as String? ?? '?';
    final cod = r['contrato_codigo'] as String? ?? '';

    var detalle = 'Período $periodo — C\$$monto';
    if (pagado > 0) detalle += ' (pagado: C\$$pagado)';
    detalle += ' — $estado';
    if (cod.isNotEmpty) detalle += ' — $cod';

    resueltos.add(RegistroResuelto(
      id: id,
      descripcion: cliente,
      detalle: detalle,
    ));
  }

  for (final id in ids) {
    if (!encontrados.contains(id)) {
      resueltos.add(RegistroResuelto(
        id: id,
        descripcion: '(no encontrado en data local)',
      ));
    }
  }

  return resueltos;
}

Future<List<RegistroResuelto>> _resolverPagos(
    List<String> ids, String codigo) async {
  final ph = List.filled(ids.length, '?').join(',');
  final rows = await ps.db.getAll(
    'SELECT p.id, p.monto_cordobas, p.monto_original, p.vuelto_cordobas, '
    'p.tasa_conversion, p.metodo, substr(p.fecha_pago,1,10) AS fecha, '
    'c.nombre AS cliente '
    'FROM pagos p '
    'LEFT JOIN cuotas cu ON cu.id = p.cuota_id '
    'LEFT JOIN contratos ct ON ct.id = cu.contrato_id '
    'LEFT JOIN clientes c ON c.id = ct.cliente_id '
    'WHERE p.id IN ($ph)',
    ids,
  );

  final resueltos = <RegistroResuelto>[];
  final encontrados = <String>{};

  for (final r in rows) {
    final id = r['id'] as String;
    encontrados.add(id);
    final cliente = r['cliente'] as String? ?? '?';
    final monto = r['monto_cordobas'] as num? ?? 0;
    final metodo = r['metodo'] as String? ?? '?';
    final fecha = r['fecha'] as String? ?? '?';

    var detalle = 'C\$$monto — $metodo — $fecha';

    if (codigo == 'INV1') {
      final original = r['monto_original'] as num? ?? 0;
      final tasa = r['tasa_conversion'] as num? ?? 1;
      final vuelto = r['vuelto_cordobas'] as num? ?? 0;
      final esperado = (original * tasa).toStringAsFixed(2);
      final real = (monto + vuelto).toStringAsFixed(2);
      detalle += '\nEntregado: $original × $tasa = C\$$esperado'
          ' vs aplicado+vuelto: C\$$real';
    }

    resueltos.add(RegistroResuelto(
      id: id,
      descripcion: cliente,
      detalle: detalle,
    ));
  }

  for (final id in ids) {
    if (!encontrados.contains(id)) {
      resueltos.add(RegistroResuelto(
        id: id,
        descripcion: '(no encontrado en data local)',
      ));
    }
  }

  return resueltos;
}

Future<List<RegistroResuelto>> _resolverClientes(List<String> ids) async {
  final ph = List.filled(ids.length, '?').join(',');
  final rows = await ps.db.getAll(
    'SELECT id, nombre, codigo FROM clientes WHERE id IN ($ph)',
    ids,
  );

  final resueltos = <RegistroResuelto>[];
  final encontrados = <String>{};

  for (final r in rows) {
    final id = r['id'] as String;
    encontrados.add(id);
    final nombre = r['nombre'] as String? ?? '?';
    final codigo = r['codigo'] as String? ?? '';
    resueltos.add(RegistroResuelto(
      id: id,
      descripcion: nombre,
      detalle: codigo.isNotEmpty ? 'Código: $codigo' : null,
    ));
  }

  for (final id in ids) {
    if (!encontrados.contains(id)) {
      resueltos.add(RegistroResuelto(
        id: id,
        descripcion: '(no encontrado en data local)',
      ));
    }
  }

  return resueltos;
}

List<RegistroResuelto> _fallback(String idsStr) {
  return idsStr
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map((id) => RegistroResuelto(id: id, descripcion: id))
      .toList();
}
