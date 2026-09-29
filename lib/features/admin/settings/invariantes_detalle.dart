import '../../../powersync/db.dart' as ps;

/// Metadata humanizada de cada invariante de dinero (INV1-INV31).
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
        'Estos pagos figuran anulados pero sin usuario responsable. Hasta la '
        'migración 0264 había un caso legítimo: el guard de sobrepago anulaba '
        'solo el duplicado idéntico, dejando su motivo "Duplicado automático:". '
        'Esa rama se retiró —ahora todo duplicado espera decisión de una '
        'persona— así que de acá en adelante NINGUNA anulación nueva debería '
        'quedar sin actor. Los casos viejos con ese motivo siguen siendo '
        'válidos y por eso el chequeo los excluye.',
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
  // INV21-INV31 los agrega el RPC en 0248 (portados del archivo canónico
  // `supabase/tests/invariantes_dinero.sql`). Misma razón que el comentario de
  // INV18-20: sin entrada acá el panel cae al render crudo y el super_admin ve
  // una etiqueta con UUIDs pelados, justo cuando algo se rompió.
  'INV21': InvInfo(
    titulo: 'Cuota vieja saltada por un cobro posterior',
    explicacion:
        'Estas cuotas nunca recibieron plata pero el contrato ya tiene cobrada '
        'otra MÁS NUEVA. Se cobró salteándose la más vieja, que es la regla '
        'de oro del cobro (invariante #11). Pasa cuando dos equipos cobran el '
        'mismo contrato sin sincronizar entre medio: cada teléfono valida '
        'contra lo que él conoce y ninguno ve el cobro del otro.',
    correccion:
        'No se corrige solo ni conviene tocar la data: la plata cobrada es '
        'real y está bien registrada, lo que quedó mal es el ORDEN. Revisá el '
        'contrato y cobrá la cuota vieja; si ya no se va a cobrar, anulala con '
        'motivo. Si aparecen varias del mismo cobrador, revisá si está '
        'trabajando con dos dispositivos.',
    severidad: 'critica',
    tipoId: 'cuota',
  ),
  'INV22': InvInfo(
    titulo: 'Recibo vivo sin pago detrás',
    explicacion:
        'Estos recibos están vigentes pero el pago que los originó no existe o '
        'fue anulado. Es un comprobante con número fiscal circulando sin plata '
        'en caja: el cliente tiene el papel, el arqueo no tiene el monto.',
    correccion:
        'Si el pago se anuló, el recibo tiene que anularse también (esa es la '
        'salida normal). Si el pago desapareció, buscá el recibo en papel y '
        're-registrá el cobro para que vuelvan a estar emparejados.',
    severidad: 'alta',
    tipoId: 'texto',
  ),
  'INV23': InvInfo(
    titulo: 'Pago sin exactamente un recibo vigente',
    explicacion:
        'Estos pagos vivos no tienen UN recibo vigente: o ninguno (cobro sin '
        'comprobante válido) o más de uno (un duplicado que quemó un número '
        'de correlativo). El correlativo es la numeración fiscal del talonario '
        'y no se puede reusar.',
    correccion:
        'Si falta el recibo, re-emitilo desde el pago. Si hay dos, anulá el '
        'sobrante dejando el que el cliente tiene en la mano — no borres '
        'ninguno: el número quemado queda como hueco justificado.',
    severidad: 'alta',
    tipoId: 'pago',
  ),
  'INV24': InvInfo(
    titulo: 'Pago vivo sobre una cuota anulada o inexistente',
    explicacion:
        'Estos pagos siguen contando como plata cobrada (entran al arqueo y al '
        'dashboard) pero la cuota que pagaban ya no existe o fue anulada. La '
        'plata está en caja y no está aplicada a nada: nadie la ve del lado '
        'del cliente, que aparece debiendo lo que ya pagó.',
    correccion:
        'Buscá la cuota correcta y reasigná el pago, o reactivá la cuota si se '
        'anuló por error. Si el cobro no correspondía, anulalo (el trigger '
        'restaura la cuota solo).',
    severidad: 'critica',
    tipoId: 'pago',
  ),
  'INV25': InvInfo(
    titulo: 'Contrato dado de baja que sigue facturando',
    explicacion:
        'Estas cuotas son de meses POSTERIORES a la baja o suspensión del '
        'contrato y siguen vivas. Se le está facturando servicio a alguien que '
        'ya no lo tiene: la deuda crece sola y el cobrador va a pedir plata '
        'que el cliente no debe.',
    correccion:
        'Anulá las cuotas posteriores a la fecha de baja, desde Operaciones → '
        'estado de cuota (deja preview, motivo y respaldo). El server lo hace '
        'solo desde la reparación 0234, así que estas son anteriores a esa red '
        'o entraron por un camino que no la dispara — típicamente contratos '
        'cancelados sin fecha de baja registrada.',
    severidad: 'alta',
    tipoId: 'cuota',
  ),
  'INV26': InvInfo(
    titulo: 'Cancelación de contrato sin atribuir',
    explicacion:
        'Estos contratos figuran cancelados pero sin quién los canceló, sin '
        'cuándo, o sin motivo. Cancelar es el evento de plata más grande que '
        'existe (mata todas las cuotas futuras) y es el único que no tiene un '
        'control del server que exija el responsable.',
    correccion:
        'Buscá en el historial (op_log) del contrato quién lo canceló y '
        'completá el motivo. Ningún camino de la app deja el actor vacío, así '
        'que un caso nuevo acá significa que se tocó la data por fuera.',
    severidad: 'media',
    tipoId: 'contrato',
  ),
  'INV27': InvInfo(
    titulo: 'Cobro sin rastro en el historial',
    explicacion:
        'Estos cobros existen pero no dejaron su fila en el historial '
        '(op_log), que es el ÚNICO registro de cambios del sistema. La plata '
        'está bien, lo que falta es el "quién y cuándo": si mañana hay una '
        'discusión sobre ese cobro, no hay a qué recurrir.',
    correccion:
        'No se repone hacia atrás sin inventar datos. Lo que importa es que no '
        'aparezcan casos NUEVOS: el historial lo escribe el teléfono junto con '
        'el cobro, así que varios seguidos del mismo cobrador apuntan a un '
        'problema de sincronización de ese equipo.',
    severidad: 'media',
    tipoId: 'pago',
  ),
  'INV28': InvInfo(
    titulo: 'Devolución mayor al efectivo del día',
    explicacion:
        'Ese día la empresa devolvió más efectivo del que entró en efectivo. '
        'Puede ser una devolución mal cargada, o un cobro que la respaldaba y '
        'se anuló después. Se compara contra la caja de la EMPRESA, no la de '
        'un cobrador: devolver es una acción de oficina y la plata sale de la '
        'caja de la oficina, no de la calle.',
    correccion:
        'Revisá el arqueo de ese día y compará contra el papel. Corregí el '
        'monto de la devolución o restituí el cobro que falta. Cada fila de '
        'esta lista es una FECHA, no un registro suelto.',
    severidad: 'alta',
    tipoId: 'texto',
  ),
  'INV29': InvInfo(
    titulo: 'Devolución de saldo sin quién ni cuándo',
    explicacion:
        'Estas devoluciones no dicen quién entregó la plata o en qué fecha. '
        'Sin esos dos datos no caen en ningún arqueo: la empresa sigue '
        'mostrando en caja plata que ya devolvió. Además, es lo que permite '
        'distinguir una devolución normal de una que se metió por fuera del '
        'sistema.',
    correccion:
        'Completá los dos datos desde el registro de la devolución. Si no se '
        'puede reconstruir quién la entregó, anulala y volvé a cargarla '
        'completa.',
    severidad: 'alta',
    tipoId: 'texto',
  ),
  'INV30': InvInfo(
    titulo: 'Pago con moneda o tasa incoherente',
    explicacion:
        'Estos pagos tienen tasa de cambio cero, negativa o vacía, monto '
        'original inválido, o están marcados en córdobas con una tasa que no '
        'es 1. Con una tasa mal cargada el monto en córdobas queda multiplicado '
        'o dividido: el cliente paga bien y el sistema registra otra cosa.',
    correccion:
        'Editá el pago con la moneda y la tasa reales del momento del cobro. '
        'Si el cliente pagó en córdobas, la tasa siempre es 1.',
    severidad: 'critica',
    tipoId: 'pago',
  ),
  'INV31': InvInfo(
    titulo: 'Crédito a favor sin su descuento (o al revés)',
    explicacion:
        'El crédito por excedente se escribe en dos lugares a la vez: se '
        'consume el saldo a favor Y se descuenta la cuota. Acá llegó solo una '
        'de las dos mitades. Si quedó el descuento sin consumir el saldo, el '
        'cliente puede usar el mismo crédito una y otra vez; si quedó el '
        'consumo sin descuento, se le comió el crédito sin darle nada.',
    correccion:
        'Mirá el prefijo del identificador para saber qué mitad llegó: '
        '"saldo:" es el consumo, "cargo:" es el descuento. Quitá la mitad '
        'huérfana y volvé a aplicar el crédito desde la cuota para que entren '
        'las dos juntas.',
    severidad: 'critica',
    tipoId: 'texto',
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
