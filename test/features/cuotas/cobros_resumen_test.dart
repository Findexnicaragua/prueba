@TestOn('vm')
library;

/// Tests de la query de RESUMEN de la lista de Cobros (Opción 2) contra el
/// SQLite REAL de PowerSync. Blindan el invariante de dinero #10 de la pantalla:
/// el `total_cobrable` del resumen (agregado en SQL con ROW_NUMBER) DEBE dar
/// idéntico a la suma del detalle (cuota más antigua por contrato), y la cuota
/// "más vieja del cliente" (para el "Pagar" colapsado) debe ser la correcta.
///
/// Usa EXACTAMENTE las queries que corre la app (`cobros_query.dart`), así el
/// test no puede "driftear" del SQL de producción.
///
/// Requiere el binario nativo `powersync_x64.dll` en la raíz del repo (igual que
/// `pagos_repo_test.dart`). Sin él, se SALTA.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/cuotas/cobros_query.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('cobros_resumen (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();
  late PowerSyncDatabase db;
  late Directory tmpDir;
  const tenantId = 't-test';

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('cobros_resumen_');
    db = PowerSyncDatabase(
        schema: schema, path: p.join(tmpDir.path, '${uuid.v4()}.db'));
    await db.initialize();
  });

  tearDown(() async {
    await db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<void> seedCliente(String id,
      {String? cobradorId,
      String codigo = 'C',
      int activo = 1}) async {
    await db.execute(
      'INSERT INTO clientes (id, tenant_id, cobrador_id, nombre, codigo, activo) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [id, tenantId, cobradorId, 'Cliente $id', codigo, activo],
    );
  }

  Future<void> seedContrato(String id, String clienteId,
      {String estado = 'activo'}) async {
    await db.execute(
      'INSERT INTO contratos (id, tenant_id, cliente_id, dia_pago, estado, created_at) '
      "VALUES (?, ?, ?, 5, ?, '2026-01-01')",
      [id, tenantId, clienteId, estado],
    );
  }

  Future<String> seedCuota({
    required String clienteId,
    String? contratoId,
    required String venc,
    required String periodo,
    double monto = 500,
    double pagado = 0,
    double cargosNeto = 0,
    String estado = 'pendiente',
    String? tipoCargoManual,
    String? id,
  }) async {
    final cid = id ?? uuid.v4();
    await db.execute(
      'INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, periodo, '
      'fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, tipo_cargo_manual) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [cid, tenantId, contratoId, clienteId, periodo, venc, monto, pagado,
        cargosNeto, estado, tipoCargoManual],
    );
    return cid;
  }

  // Saldo canónico, idéntico a `_saldoCanonico` de la app (clamp >= 0).
  double saldo(Map<String, dynamic> r) {
    final s = (r['monto'] as num).toDouble() +
        (r['cargos_neto'] as num? ?? 0).toDouble() -
        (r['monto_pagado'] as num? ?? 0).toDouble();
    return s < 0 ? 0.0 : s;
  }

  // Agrupa el detalle por contrato (cuota más antigua) — replica en el test la
  // misma lógica oldest-per-contract — y devuelve la suma de saldos + el conteo.
  ({double total, int n, String oldestId}) detalleAgregado(
      List<Map<String, dynamic>> rows) {
    int cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
      final c = (a['fecha_vencimiento'] as String)
          .compareTo(b['fecha_vencimiento'] as String);
      return c != 0
          ? c
          : (a['periodo'] as String).compareTo(b['periodo'] as String);
    }

    final masVieja = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      final key = (r['contrato_id'] as String?) ?? 'm:${r['id']}';
      final cur = masVieja[key];
      if (cur == null || cmp(r, cur) < 0) masVieja[key] = r;
    }
    final lineas = masVieja.values.toList()..sort(cmp);
    final total = lineas.fold<double>(0, (a, r) => a + saldo(r));
    return (total: total, n: lineas.length, oldestId: lineas.first['id'] as String);
  }

  Future<List<Map<String, dynamic>>> resumen(
      {CobrosFiltro filtro = CobrosFiltro.verTodo,
      String? cobradorId,
      String? comunidadId}) async {
    final (sql, params) = cobrosResumenQuery(
      filtro: filtro,
      diasGracia: 5,
      diasVisibles: 7,
      cobradorIds: cobradorId == null ? null : {cobradorId},
      comunidadIds: comunidadId == null ? null : {comunidadId},
    );
    return db.getAll(sql, params);
  }

  Future<List<Map<String, dynamic>>> detalle(String clienteId,
      {CobrosFiltro filtro = CobrosFiltro.verTodo}) async {
    final (sql, params) = cobrosDetalleQuery(clienteId,
        filtro: filtro, diasGracia: 5, diasVisibles: 7);
    return db.getAll(sql, params);
  }

  // Lista PLANA (Feature 1): una fila por contrato (cuota más vieja).
  Future<List<Map<String, dynamic>>> flat(
      {CobrosFiltro filtro = CobrosFiltro.verTodo,
      String? cobradorId,
      String? comunidadId}) async {
    final (sql, params) = cobrosFlatQuery(
      filtro: filtro,
      diasGracia: 5,
      diasVisibles: 7,
      cobradorIds: cobradorId == null ? null : {cobradorId},
      comunidadIds: comunidadId == null ? null : {comunidadId},
    );
    return db.getAll(sql, params);
  }

  // Deuda FUERA DE RUTA (recuperación): cancelados/suspendidos, oldest por
  // contrato, sin chips de fecha.
  Future<List<Map<String, dynamic>>> fueraDeRuta(
      {String? cobradorId, String? comunidadId}) async {
    final (sql, params) = cobrosFueraDeRutaQuery(
      cobradorIds: cobradorId == null ? null : {cobradorId},
      comunidadIds: comunidadId == null ? null : {comunidadId},
    );
    return db.getAll(sql, params);
  }

  test('resumen agrega oldest-per-contract: total = suma del detalle, '
      'n_lineas y cuota más vieja correctos', () async {
    await seedCliente('C1', cobradorId: 'co1');
    await seedContrato('A', 'C1');
    await seedContrato('B', 'C1');
    // Contrato A: mayo (más vieja, saldo 500) + junio (no cuenta).
    final mayId = await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-05-05', periodo: '2026-05',
        monto: 500);
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-06-05', periodo: '2026-06',
        monto: 500);
    // Contrato B: junio con cargo + parcial → saldo 800+100-200 = 700.
    await seedCuota(
        clienteId: 'C1', contratoId: 'B', venc: '2026-06-10', periodo: '2026-06',
        monto: 800, pagado: 200, cargosNeto: 100, estado: 'parcial');
    // Cargo manual suelto (sin contrato) → su propia línea, saldo 150.
    await seedCuota(
        clienteId: 'C1', contratoId: null, venc: '2026-06-01', periodo: '2026-06',
        monto: 150, tipoCargoManual: 'reconexion');

    final rows = await resumen();
    expect(rows, hasLength(1));
    final r = rows.first;
    expect((r['total_cobrable'] as num).toDouble(), 1350); // 500+700+150
    expect((r['n_lineas'] as num).toInt(), 3);
    expect(r['peor_vence'], '2026-05-05');
    expect(r['oldest_cuota_id'], mayId,
        reason: 'la cuota más vieja del cliente es la de mayo del contrato A');

    // Consistencia #10: el total del resumen DEBE dar igual que la suma del
    // detalle (oldest-per-contract), calculada independientemente en Dart.
    final det = detalleAgregado(await detalle('C1'));
    expect((r['total_cobrable'] as num).toDouble(), closeTo(det.total, 0.001));
    expect((r['n_lineas'] as num).toInt(), det.n);
    expect(r['oldest_cuota_id'], det.oldestId);
  });

  test('ordena por vencimiento más urgente y separa por cliente', () async {
    await seedCliente('C1', codigo: 'C1');
    await seedContrato('A', 'C1');
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-05-05', periodo: '2026-05',
        monto: 500);
    await seedCliente('C2', codigo: 'C2');
    await seedContrato('Z', 'C2');
    await seedCuota(
        clienteId: 'C2', contratoId: 'Z', venc: '2026-04-01', periodo: '2026-04',
        monto: 300);

    final rows = await resumen();
    expect(rows.map((r) => r['cliente_id']).toList(), ['C2', 'C1'],
        reason: 'C2 (abr) más urgente que C1 (may) → primero');
    expect((rows[0]['total_cobrable'] as num).toDouble(), 300);
    expect((rows[1]['total_cobrable'] as num).toDouble(), 500);
  });

  test('saldo clampeado a >= 0 (descuento mayor que el monto)', () async {
    await seedCliente('C1');
    await seedContrato('A', 'C1');
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-06-05', periodo: '2026-06',
        monto: 100, cargosNeto: -150); // -50 → clamp 0
    final rows = await resumen();
    expect(rows, hasLength(1));
    expect((rows.first['total_cobrable'] as num).toDouble(), 0);
  });

  test('filtro admin por cobrador deja solo sus clientes', () async {
    await seedCliente('C1', cobradorId: 'co1');
    await seedContrato('A', 'C1');
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-05-05', periodo: '2026-05');
    await seedCliente('C2', cobradorId: 'co2');
    await seedContrato('B', 'C2');
    await seedCuota(
        clienteId: 'C2', contratoId: 'B', venc: '2026-05-05', periodo: '2026-05');

    final soloCo1 = await resumen(cobradorId: 'co1');
    expect(soloCo1.map((r) => r['cliente_id']), ['C1']);

    // "Sin cobrador": un cliente con cobrador_id NULL.
    await seedCliente('C3', cobradorId: null);
    await seedContrato('D', 'C3');
    await seedCuota(
        clienteId: 'C3', contratoId: 'D', venc: '2026-05-05', periodo: '2026-05');
    final sinCobrador = await resumen(cobradorId: kSinCobradorFiltro);
    expect(sinCobrador.map((r) => r['cliente_id']), ['C3']);
  });

  test('excluye clientes inactivos y contratos no-activos', () async {
    await seedCliente('Cact');
    await seedContrato('A', 'Cact');
    await seedCuota(
        clienteId: 'Cact', contratoId: 'A', venc: '2026-05-05', periodo: '2026-05');
    // Cliente inactivo → fuera.
    await seedCliente('Cinact', activo: 0);
    await seedContrato('B', 'Cinact');
    await seedCuota(
        clienteId: 'Cinact', contratoId: 'B', venc: '2026-05-05', periodo: '2026-05');
    // Contrato suspendido → fuera (su cuota no cuenta).
    await seedCliente('Csusp');
    await seedContrato('S', 'Csusp', estado: 'suspendido');
    await seedCuota(
        clienteId: 'Csusp', contratoId: 'S', venc: '2026-05-05', periodo: '2026-05');

    final rows = await resumen();
    expect(rows.map((r) => r['cliente_id']), ['Cact']);
  });

  test('el watch del resumen REFIRE al pagar una cuota (CTE+window detecta '
      'las tablas → la lista no queda congelada)', () async {
    await seedCliente('C1');
    await seedContrato('A', 'C1');
    final cid = await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-05-05', periodo: '2026-05',
        monto: 500);
    final (sql, params) = cobrosResumenQuery(
        filtro: CobrosFiltro.verTodo, diasGracia: 5, diasVisibles: 7);

    final emisiones = <List<Map<String, dynamic>>>[];
    final sub = db.watch(sql, parameters: params).listen(emisiones.add);
    await Future<void>.delayed(const Duration(milliseconds: 400)); // 1ra emisión
    expect(emisiones.last, hasLength(1));
    expect((emisiones.last.first['total_cobrable'] as num).toDouble(), 500);

    // Pagar la cuota → estado 'pagada' → el cliente debe salir del resumen.
    await db.execute(
        "UPDATE cuotas SET monto_pagado = 500, estado = 'pagada' WHERE id = ?",
        [cid]);
    await Future<void>.delayed(const Duration(milliseconds: 600)); // re-emisión
    await sub.cancel();

    expect(emisiones.length, greaterThanOrEqualTo(2),
        reason: 'el watch debe re-emitir al cambiar cuotas');
    expect(emisiones.last, isEmpty,
        reason: 'cuota pagada → cliente sin nada por cobrar → fuera');
  });

  test('oldest_cuota_id es DETERMINISTA en empate de venc entre contratos '
      '(desempata por periodo, no arbitrario)', () async {
    await seedCliente('C1');
    await seedContrato('A', 'C1');
    await seedContrato('B', 'C1');
    // Dos contratos cuya cuota más vieja vence el MISMO día, distinto periodo.
    // Inserto el periodo MÁS NUEVO primero (para tentar a un bare-column a
    // elegirlo). El desempate correcto es el periodo MÁS VIEJO (abril).
    await seedCuota(
        clienteId: 'C1', contratoId: 'B', venc: '2026-05-15', periodo: '2026-05',
        monto: 400, id: 'cuota-mayo');
    final abrId = await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-05-15', periodo: '2026-04',
        monto: 500, id: 'cuota-abril');

    final rows = await resumen();
    expect(rows, hasLength(1));
    expect(rows.first['oldest_cuota_id'], abrId,
        reason: 'en empate de venc, la más vieja es la de periodo menor');
    // Y coincide con la primera del detalle (que desempata por periodo ASC).
    final det = detalleAgregado(await detalle('C1'));
    expect(rows.first['oldest_cuota_id'], det.oldestId);
  });

  test('el watch refire ante cambios en tablas secundarias (etiquetas)',
      () async {
    await seedCliente('C1');
    await seedContrato('A', 'C1');
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-05-05', periodo: '2026-05',
        monto: 500);
    final (sql, params) = cobrosResumenQuery(
        filtro: CobrosFiltro.verTodo, diasGracia: 5, diasVisibles: 7);

    final emisiones = <List<Map<String, dynamic>>>[];
    final sub = db.watch(sql, parameters: params).listen(emisiones.add);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(emisiones.last.first['etiquetas_concat'], isNull);

    // Asignar una etiqueta → el watch debe re-emitir con la etiqueta.
    await db.execute(
        'INSERT INTO etiquetas (id, tenant_id, nombre, color, icono) '
        "VALUES ('e1', ?, 'VIP', '#FAEEDA', 'star')",
        [tenantId]);
    await db.execute(
        'INSERT INTO cliente_etiquetas (id, tenant_id, cliente_id, etiqueta_id) '
        "VALUES ('ce1', ?, 'C1', 'e1')",
        [tenantId]);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await sub.cancel();

    expect(emisiones.length, greaterThanOrEqualTo(2),
        reason: 'el watch debe re-emitir al asignar una etiqueta');
    expect(emisiones.last.first['etiquetas_concat'], contains('VIP'));
  });

  test('vencidas_count/vencido_total cuentan TODAS las cuotas vencidas del '
      'cliente (no solo la más vieja por contrato)', () async {
    await seedCliente('C1');
    await seedContrato('A', 'C1');
    // 3 cuotas del MISMO contrato, todas vencidas (fechas LEJANAS para no
    // depender del reloj del runner). El resumen muestra 1 línea cobrable-ahora
    // (la más vieja) pero vencidas_count debe contar las 3.
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2020-01-05', periodo: '2020-01',
        monto: 500);
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2020-02-05', periodo: '2020-02',
        monto: 500);
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2020-03-05', periodo: '2020-03',
        monto: 500);

    final rows = await resumen();
    expect(rows, hasLength(1));
    final r = rows.first;
    expect((r['n_lineas'] as num).toInt(), 1,
        reason: 'una línea (la más vieja por contrato)');
    expect((r['total_cobrable'] as num).toDouble(), 500,
        reason: 'cobrable ahora = la más vieja');
    expect((r['vencidas_count'] as num).toInt(), 3,
        reason: 'las 3 cuotas vencidas del cliente');
    expect((r['vencido_total'] as num).toDouble(), 1500,
        reason: '3 x 500 vencido');
  });

  test('flat: UNA fila por contrato (cuota más vieja) con grupo_count/saldo; '
      'Σ saldo del cliente = total_cobrable del resumen (#10)', () async {
    await seedCliente('C1', cobradorId: 'co1');
    await seedContrato('A', 'C1');
    await seedContrato('B', 'C1');
    // Contrato A: mayo (más vieja, 500) + junio (500) → grupo_count 2, saldo 1000.
    final mayId = await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-05-05', periodo: '2026-05',
        monto: 500);
    await seedCuota(
        clienteId: 'C1', contratoId: 'A', venc: '2026-06-05', periodo: '2026-06',
        monto: 500);
    // Contrato B: una cuota con cargo + parcial → saldo 800+100-200 = 700.
    await seedCuota(
        clienteId: 'C1', contratoId: 'B', venc: '2026-06-10', periodo: '2026-06',
        monto: 800, pagado: 200, cargosNeto: 100, estado: 'parcial');
    // Cargo manual suelto → su propia fila, saldo 150.
    final manualId = await seedCuota(
        clienteId: 'C1', contratoId: null, venc: '2026-06-01', periodo: '2026-06',
        monto: 150, tipoCargoManual: 'reconexion');

    final filas = await flat();
    // Una fila por contrato (A, B) + el cargo manual = 3 filas (no 1 por cliente).
    expect(filas, hasLength(3));

    Map<String, dynamic> filaDe(String? ctId) =>
        filas.firstWhere((r) => r['contrato_id'] == ctId);

    final fa = filaDe('A');
    expect(fa['id'], mayId, reason: 'fila de A = su cuota más vieja (mayo)');
    expect(saldo(fa), 500);
    expect((fa['grupo_count'] as num).toInt(), 2, reason: 'A: mayo + junio');
    expect((fa['grupo_saldo'] as num).toDouble(), 1000);
    expect(fa['dia_pago'], 5);

    final fb = filaDe('B');
    expect(saldo(fb), 700, reason: '800 + 100 - 200');
    expect((fb['grupo_count'] as num).toInt(), 1);

    final fm = filaDe(null);
    expect(fm['id'], manualId);
    expect(saldo(fm), 150);
    expect(fm['tipo_cargo_manual'], 'reconexion');

    // Orden por vencimiento ASC: mayo(A) < jun-01(manual) < jun-10(B).
    expect(filas.map((r) => r['id']).toList(), [mayId, manualId, fb['id']]);

    // Consistencia #10: la suma de las filas planas del cliente DEBE dar igual
    // que el total_cobrable del resumen (oldest-per-contract).
    final sumaFlat = filas.fold<double>(0, (a, r) => a + saldo(r));
    expect(sumaFlat, 1350); // 500 + 700 + 150
    final res = await resumen();
    expect(res, hasLength(1));
    expect((res.first['total_cobrable'] as num).toDouble(),
        closeTo(sumaFlat, 0.001),
        reason: 'Σ filas planas = total_cobrable del resumen');
  });

  test('flat: excluye inactivos/contratos no-activos y respeta filtro cobrador',
      () async {
    await seedCliente('Cact', cobradorId: 'co1');
    await seedContrato('A', 'Cact');
    await seedCuota(
        clienteId: 'Cact', contratoId: 'A', venc: '2026-05-05', periodo: '2026-05');
    await seedCliente('Cinact', activo: 0);
    await seedContrato('B', 'Cinact');
    await seedCuota(
        clienteId: 'Cinact', contratoId: 'B', venc: '2026-05-05', periodo: '2026-05');
    await seedCliente('Csusp', cobradorId: 'co2');
    await seedContrato('S', 'Csusp', estado: 'suspendido');
    await seedCuota(
        clienteId: 'Csusp', contratoId: 'S', venc: '2026-05-05', periodo: '2026-05');

    final rows = await flat();
    expect(rows.map((r) => r['cliente_id']), ['Cact']);
    final soloCo1 = await flat(cobradorId: 'co1');
    expect(soloCo1.map((r) => r['cliente_id']), ['Cact']);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Fuera de ruta (recuperación): toggle "Ver fuera de ruta" (2026-07-01).
  // ───────────────────────────────────────────────────────────────────────────

  test('fueraDeRuta: SOLO cancelados/suspendidos (una fila por contrato, oldest) '
      'con estado_contrato; excluye activos y cargos manuales', () async {
    await seedCliente('C1', cobradorId: 'co1');
    // Activo → NO aparece en fuera de ruta (vive en la lista activa).
    await seedContrato('ACT', 'C1');
    await seedCuota(
        clienteId: 'C1', contratoId: 'ACT', venc: '2026-05-05', periodo: '2026-05',
        monto: 500);
    // Suspendido → aparece; 2 cuotas → oldest (abril) + grupo_count 2.
    await seedContrato('SUS', 'C1', estado: 'suspendido');
    final abrId = await seedCuota(
        clienteId: 'C1', contratoId: 'SUS', venc: '2026-04-05', periodo: '2026-04',
        monto: 300);
    await seedCuota(
        clienteId: 'C1', contratoId: 'SUS', venc: '2026-05-05', periodo: '2026-05',
        monto: 300);
    // Cancelado → aparece; 1 cuota con cargo + parcial → saldo 400+50-100 = 350.
    await seedContrato('CAN', 'C1', estado: 'cancelado');
    await seedCuota(
        clienteId: 'C1', contratoId: 'CAN', venc: '2026-03-10', periodo: '2026-03',
        monto: 400, pagado: 100, cargosNeto: 50, estado: 'parcial');
    // Cargo manual suelto (sin contrato) → NO es fuera de ruta.
    await seedCuota(
        clienteId: 'C1', contratoId: null, venc: '2026-02-01', periodo: '2026-02',
        monto: 150, tipoCargoManual: 'reconexion');

    final rows = await fueraDeRuta();
    expect(rows, hasLength(2), reason: 'solo SUS + CAN (no ACT ni el manual)');
    expect(rows.map((r) => r['contrato_id']).toSet(), {'SUS', 'CAN'});

    Map<String, dynamic> filaDe(String ct) =>
        rows.firstWhere((r) => r['contrato_id'] == ct);

    final sus = filaDe('SUS');
    expect(sus['id'], abrId, reason: 'fila del suspendido = su cuota más vieja');
    expect(sus['estado_contrato'], 'suspendido');
    expect((sus['grupo_count'] as num).toInt(), 2);
    expect((sus['grupo_saldo'] as num).toDouble(), 600);
    expect(saldo(sus), 300);

    final can = filaDe('CAN');
    expect(can['estado_contrato'], 'cancelado');
    expect(saldo(can), 350, reason: '400 + 50 - 100');
    expect((can['grupo_count'] as num).toInt(), 1);

    // Orden por vencimiento ASC: CAN(mar) antes que SUS(abr).
    expect(rows.map((r) => r['contrato_id']).toList(), ['CAN', 'SUS']);
  });

  test('fueraDeRuta: ignora los chips de fecha (trae TODA la deuda viva, incluso '
      'no vencida) y excluye cuotas pagadas/anuladas', () async {
    await seedCliente('C1');
    await seedContrato('SUS', 'C1', estado: 'suspendido');
    // Cuota futura (no vencida) → igual entra (recuperación ignora la fecha).
    await seedCuota(
        clienteId: 'C1', contratoId: 'SUS', venc: '2099-01-05', periodo: '2099-01',
        monto: 500);
    // Cuota pagada → NO entra.
    await seedCuota(
        clienteId: 'C1', contratoId: 'SUS', venc: '2026-01-05', periodo: '2026-01',
        monto: 500, pagado: 500, estado: 'pagada');
    // Cuota anulada → NO entra.
    await seedCuota(
        clienteId: 'C1', contratoId: 'SUS', venc: '2026-02-05', periodo: '2026-02',
        monto: 500, estado: 'anulada');

    final rows = await fueraDeRuta();
    expect(rows, hasLength(1));
    expect((rows.first['grupo_count'] as num).toInt(), 1,
        reason: 'solo la pendiente cuenta (pagada/anulada fuera)');
    expect(rows.first['periodo'], '2099-01');
  });

  test('fueraDeRuta: excluye clientes inactivos y respeta el filtro cobrador',
      () async {
    await seedCliente('C1', cobradorId: 'co1');
    await seedContrato('S1', 'C1', estado: 'suspendido');
    await seedCuota(
        clienteId: 'C1', contratoId: 'S1', venc: '2026-05-05', periodo: '2026-05');
    await seedCliente('C2', cobradorId: 'co2');
    await seedContrato('S2', 'C2', estado: 'cancelado');
    await seedCuota(
        clienteId: 'C2', contratoId: 'S2', venc: '2026-05-05', periodo: '2026-05');
    // Cliente inactivo con deuda cancelada → fuera (Cobros no cobra inactivos).
    await seedCliente('Cinact', activo: 0);
    await seedContrato('S3', 'Cinact', estado: 'cancelado');
    await seedCuota(
        clienteId: 'Cinact', contratoId: 'S3', venc: '2026-05-05', periodo: '2026-05');

    final todos = await fueraDeRuta();
    expect(todos.map((r) => r['cliente_id']).toSet(), {'C1', 'C2'});

    final soloCo1 = await fueraDeRuta(cobradorId: 'co1');
    expect(soloCo1.map((r) => r['cliente_id']), ['C1']);
  });
}

String? _resolveCorePath() {
  final env = Platform.environment['POWERSYNC_CORE_PATH'];
  if (env != null && File(env).existsSync()) return env;
  for (final name in [
    'powersync_x64.dll',
    'libpowersync.so',
    'libpowersync.dylib',
  ]) {
    final candidate = p.join(Directory.current.path, name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
