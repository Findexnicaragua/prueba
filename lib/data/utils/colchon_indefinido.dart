import 'package:uuid/uuid.dart';

import 'prorrateo.dart';

const _uuid = Uuid();

String _fechaOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _primerDiaMes(DateTime d) => DateTime(d.year, d.month, 1);

/// 1° día del mes resultante de sumar [n] meses a [base] (DateTime normaliza el
/// overflow de meses → no hay día inválido).
DateTime _sumarMeses(DateTime base, int n) =>
    DateTime(base.year, base.month + n, 1);

/// Garantiza el "colchón" de un contrato INDEFINIDO activo: cuotas `pendiente`
/// contiguas desde el mes siguiente al inicio del contrato hasta
/// `max(última cuota pagada, mes actual) + 3 meses`.
///
/// Es el ESPEJO OFFLINE de la función server `generar_cuotas_contrato` (0142):
/// los triggers/cron de Postgres NO corren en el SQLite local de PowerSync, así
/// que sin esto un indefinido creado o cobrado offline queda sin cuotas por
/// cobrar hasta sincronizar. Corre DENTRO de la transacción del cliente (al
/// crear el contrato y al cobrar). El server queda como red de convergencia:
/// el guard por período (≡ `ON CONFLICT (contrato_id, periodo) DO NOTHING`)
/// evita choques y duplicados.
///
/// El ancla es `max(última pagada, mes actual)` — por eso un pago POR
/// ADELANTADO corre el colchón: siempre quedan 3 cuotas pendientes después de
/// la última pagada, supere o no el mes corriente.
///
/// No-op (devuelve 0) si el contrato no existe, no está `activo`, no es
/// indefinido (`duracion_meses` no nulo) o su plan no tiene precio. Idempotente:
/// sólo inserta los períodos faltantes. [ahora] es inyectable para tests;
/// default = hoy en hora de Nicaragua (UTC-6, sin DST). Devuelve cuántas creó.
Future<int> asegurarColchonIndefinido(
  dynamic tx,
  String contratoId, {
  DateTime? ahora,
}) async {
  final c = await tx.getOptional(
    '''
    SELECT tenant_id, cliente_id, cobrador_id, plan_id, dia_pago,
           fecha_inicio, duracion_meses, estado
      FROM contratos WHERE id = ?
    ''',
    [contratoId],
  );
  if (c == null) return 0;
  if (c['estado'] != 'activo') return 0;
  if (c['duracion_meses'] != null) return 0; // sólo indefinidos

  final plan = await tx.getOptional(
    'SELECT precio_mensual FROM planes WHERE id = ?',
    [c['plan_id']],
  );
  final precio = (plan?['precio_mensual'] as num?)?.toDouble();
  if (precio == null) return 0; // sin precio no se puede generar

  final fechaInicioStr = c['fecha_inicio'] as String?;
  if (fechaInicioStr == null) return 0; // sin fecha de inicio no hay períodos

  final tenantId = c['tenant_id'] as String;
  final clienteId = c['cliente_id'] as String;
  final cobradorId = c['cobrador_id'] as String?;
  final diaPago = (c['dia_pago'] as num?)?.toInt() ?? 1;
  final fechaInicio = DateTime.parse(fechaInicioStr);

  // Mes de vencimiento de la 1ª cuota = mes siguiente a la instalación.
  // Se ancla a fecha_inicio (NO a fecha_primer_cobro: 0074 revirtió ese
  // anclaje y dejó fecha_primer_cobro solo para display) → idéntico al server.
  final primerMes = _sumarMeses(_primerDiaMes(fechaInicio), 1);

  // Mes actual en hora de Nicaragua (UTC-6, sin DST) — el límite de mes lo
  // define el wall-clock local, no UTC.
  final hoyNi = ahora ?? DateTime.now().toUtc().subtract(const Duration(hours: 6));
  final mesActual = DateTime(hoyNi.year, hoyNi.month, 1);

  // Última cuota con ALGÚN pago (pagada o parcial): el colchón se ancla a la
  // más nueva entre ésta y el mes actual → un adelanto, AUN PARCIAL, corre el
  // colchón (siempre 3 después de la última con pago). Una cuota anulada NO es
  // 'pagada'/'parcial' → no infla el ancla.
  final pagadaRow = await tx.getOptional(
    'SELECT MAX(periodo) AS ult FROM cuotas '
    "WHERE contrato_id = ? AND estado IN ('pagada', 'parcial')",
    [contratoId],
  );
  final ultStr = pagadaRow?['ult'] as String?;
  final ultimaConPago =
      ultStr == null ? null : _primerDiaMes(DateTime.parse(ultStr));

  var ancla = mesActual;
  if (ultimaConPago != null && ultimaConPago.isAfter(ancla)) {
    ancla = ultimaConPago;
  }
  // Hasta `ancla + 3` (3 de colchón), con PISO de 3 períodos desde el primer
  // mes (espeja GREATEST(3,…) del server 0148): garantiza >=3 cuotas aun si la
  // instalación es FUTURA (primerMes > ancla → sin el piso, el loop no correría).
  final desdeAncla = _sumarMeses(ancla, 3);
  final pisoPrimerMes = _sumarMeses(primerMes, 2); // primerMes, +1, +2 = 3
  final ultimoMes = pisoPrimerMes.isAfter(desdeAncla) ? pisoPrimerMes : desdeAncla;

  // Períodos ya existentes (1 sola query) para no duplicar (≡ ON CONFLICT) y
  // para calcular el PISO anti-backfill.
  final existentes = await tx.getAll(
    'SELECT periodo FROM cuotas WHERE contrato_id = ?',
    [contratoId],
  );
  // PISO = mes SIGUIENTE a la cuota existente más nueva (de CUALQUIER estado).
  // Si el contrato YA tiene cuotas, NUNCA se rellenan períodos interiores
  // anteriores a ese piso: el único hueco interior posible en un indefinido lo
  // deja una SUSPENSIÓN larga (meses sin servicio entre la pausa y la
  // reactivación) y esos meses NO se facturan (invariante 0120). Sin el piso, el
  // loop arrancaba en `primerMes` y materializaba el hueco como 'pendiente' con
  // vencimiento pasado = deuda FALSA por meses sin servicio. En generación
  // inicial (0 cuotas) el piso queda en `primerMes` → comportamiento intacto.
  // Robusto: `reactivarContrato` siempre crea el colchón desde `mesR+1`, así que
  // el máximo existente cae DESPUÉS del hueco → el piso lo salta sí o sí.
  // (Espejo server: migración 0178.)
  final yaHay = <String>{};
  var piso = primerMes;
  for (final r in existentes) {
    final pe = _primerDiaMes(DateTime.parse(r['periodo'] as String));
    yaHay.add(_fechaOnly(pe));
    final siguiente = _sumarMeses(pe, 1);
    if (siguiente.isAfter(piso)) piso = siguiente;
  }

  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  var creadas = 0;
  for (var p = primerMes; !p.isAfter(ultimoMes); p = _sumarMeses(p, 1)) {
    if (p.isBefore(piso)) continue; // anti-backfill del hueco de suspensión
    final pStr = _fechaOnly(p);
    if (yaHay.contains(pStr)) continue;
    final vencStr = _fechaOnly(calcularFechaPago(p, diaPago));
    await tx.execute(
      '''
      INSERT INTO cuotas (
        id, tenant_id, contrato_id, cliente_id, cobrador_id, periodo,
        fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, ocurrido_en
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 'pendiente', ?)
      ''',
      [
        _uuid.v4(),
        tenantId,
        contratoId,
        clienteId,
        cobradorId,
        pStr,
        vencStr,
        precio,
        ocurridoEn,
      ],
    );
    creadas++;
  }
  return creadas;
}

/// Mirror offline de `clientes.vencimiento_mas_viejo` (Opción 2 — el color del
/// mapa). Recalcula la fecha de la cuota pendiente/parcial MÁS VIEJA del cliente
/// DUEÑO de [contratoId], desde TODAS sus cuotas (otros contratos + manuales),
/// con el MISMO criterio de contrato activo que el server. Online lo hace el
/// trigger `recalc_vencimiento_mas_viejo` (0150); esto es para que el pin del
/// mapa cambie de color al cobrar SIN internet, sin esperar la sincronización.
/// No-op si el contrato no existe local.
Future<void> recalcVmvDeContrato(dynamic tx, String contratoId) async {
  await tx.execute(
    '''
    UPDATE clientes SET vencimiento_mas_viejo = (
      SELECT MIN(cu.fecha_vencimiento) FROM cuotas cu
       WHERE cu.cliente_id = clientes.id
         AND cu.estado IN ('pendiente', 'parcial')
         AND COALESCE((SELECT ct.estado FROM contratos ct
                         WHERE ct.id = cu.contrato_id), 'activo') = 'activo'
    )
    WHERE id = (SELECT cliente_id FROM contratos WHERE id = ?)
    ''',
    [contratoId],
  );
}
