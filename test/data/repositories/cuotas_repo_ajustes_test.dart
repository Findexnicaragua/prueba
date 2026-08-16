@TestOn('vm')
library;

/// Tests de los DESCUENTOS y CARGOS del admin
/// (`CuotasRepo.aplicarAjuste/aplicarCargo/cargosDeCuota/quitarCargo`,
/// Sprint 2 0115 + rediseño 0117) contra una PowerSyncDatabase REAL. Mismo
/// harness que `pagos_repo_test.dart` (ver instrucciones del core nativo
/// en la cabecera de ese archivo).
///
/// Qué blindan: el principio rector "un ajuste es una fila de cargos_extra,
/// NUNCA se muta cuotas.monto" + el mirror local de neto/estado + la
/// reversión con rastro + la protección de los cargos nacidos de un pago.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/repositories/cuotas_repo.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('CuotasRepo ajustes (saltado: falta powersync-sqlite-core)', () {
      markTestSkipped(
          'Falta el binario powersync-sqlite-core en la raíz del repo.');
    }, skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();
  late PowerSyncDatabase db;
  late CuotasRepo repo;
  late Directory tmpDir;

  const tenantId = 't-test';
  const adminId = 'adm-test';
  const cobradorId = 'co-test';
  const clienteId = 'cli-test';
  const contratoId = 'ct-test';

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('cuotas_repo_test_');
    db = PowerSyncDatabase(
        schema: schema, path: p.join(tmpDir.path, 'test_${uuid.v4()}.db'));
    await db.initialize();
    repo = CuotasRepo(db: db);

    await db.execute(
      'INSERT INTO cobradores (id, tenant_id, nombre, rol, activo) '
      "VALUES (?, ?, 'Admin Test', 'admin', 1)",
      [adminId, tenantId],
    );
    await db.execute(
      'INSERT INTO contratos (id, tenant_id, cliente_id, cobrador_id, '
      "dia_pago, estado, created_at) VALUES (?, ?, ?, ?, 5, 'activo', ?)",
      [contratoId, tenantId, clienteId, cobradorId, _now()],
    );
  });

  tearDown(() async {
    await db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<String> seedCuota({
    double monto = 800,
    double montoPagado = 0,
    String estado = 'pendiente',
  }) async {
    final id = uuid.v4();
    await db.execute(
      'INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, '
      'cobrador_id, periodo, fecha_vencimiento, monto, monto_pagado, '
      'cargos_neto, estado, created_at) '
      "VALUES (?, ?, ?, ?, ?, '2026-06', '2026-06-05', ?, ?, 0, ?, ?)",
      [id, tenantId, contratoId, clienteId, cobradorId, monto, montoPagado,
          estado, _now()],
    );
    return id;
  }

  Future<Map<String, dynamic>> getCuota(String id) async =>
      (await db.getAll('SELECT * FROM cuotas WHERE id = ?', [id])).first;

  double num2(Object? v) => (v as num).toDouble();

  test('ajuste por monto: inserta cargo origen=ajuste con motivo, espeja '
      'cargos_neto y NO toca cuotas.monto', () async {
    final cuotaId = await seedCuota(monto: 800);
    await repo.aplicarAjuste(
      tenantId: tenantId,
      cuotaId: cuotaId,
      esPorcentaje: false,
      valor: 120,
      motivo: 'Sin servicio 5 días',
      aplicadoPorId: adminId,
    );

    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto']), 800, reason: 'el monto NUNCA se muta');
    expect(num2(cuota['cargos_neto']), -120);
    expect(cuota['estado'], 'pendiente');

    final cargos = await db
        .getAll('SELECT * FROM cargos_extra WHERE cuota_id = ?', [cuotaId]);
    expect(cargos, hasLength(1));
    expect(cargos.first['origen'], 'ajuste');
    expect(cargos.first['tipo'], 'descuento_monto');
    expect(cargos.first['descripcion'], 'Sin servicio 5 días');
    expect(cargos.first['aplicado_por'], adminId);
  });

  test('ajuste porcentual calcula sobre el monto base y guarda el %',
      () async {
    final cuotaId = await seedCuota(monto: 800);
    await repo.aplicarAjuste(
      tenantId: tenantId,
      cuotaId: cuotaId,
      esPorcentaje: true,
      valor: 20,
      motivo: 'Compensación corte general',
      aplicadoPorId: adminId,
    );
    final cargos = await db
        .getAll('SELECT * FROM cargos_extra WHERE cuota_id = ?', [cuotaId]);
    expect(num2(cargos.first['monto']), 160); // 20% de 800
    expect(num2(cargos.first['porcentaje']), 20);
    expect(num2((await getCuota(cuotaId))['cargos_neto']), -160);
  });

  test('ajuste que completa el saldo de una PARCIAL la deja pagada (mirror '
      'de estado)', () async {
    final cuotaId =
        await seedCuota(monto: 500, montoPagado: 300, estado: 'parcial');
    await repo.aplicarAjuste(
      tenantId: tenantId,
      cuotaId: cuotaId,
      esPorcentaje: false,
      valor: 200,
      motivo: 'Sin servicio medio mes',
      aplicadoPorId: adminId,
    );
    final cuota = await getCuota(cuotaId);
    expect(cuota['estado'], 'pagada'); // total 300 == pagado 300
    expect(num2(cuota['cargos_neto']), -200);
  });

  test('validaciones: sin motivo, valor 0, >100%, excede saldo, cuota '
      'pagada → lanzan y no mutan', () async {
    final cuotaId = await seedCuota(monto: 500);

    Future<void> esperaError(Future<void> Function() fn) =>
        expectLater(fn(), throwsA(isA<Exception>()));

    await esperaError(() => repo.aplicarAjuste(
        tenantId: tenantId, cuotaId: cuotaId, esPorcentaje: false,
        valor: 100, motivo: '   ', aplicadoPorId: adminId));
    await esperaError(() => repo.aplicarAjuste(
        tenantId: tenantId, cuotaId: cuotaId, esPorcentaje: false,
        valor: 0, motivo: 'x', aplicadoPorId: adminId));
    await esperaError(() => repo.aplicarAjuste(
        tenantId: tenantId, cuotaId: cuotaId, esPorcentaje: true,
        valor: 120, motivo: 'x', aplicadoPorId: adminId));
    await esperaError(() => repo.aplicarAjuste(
        tenantId: tenantId, cuotaId: cuotaId, esPorcentaje: false,
        valor: 600, motivo: 'x', aplicadoPorId: adminId)); // > saldo 500

    final pagada = await seedCuota(monto: 500, montoPagado: 500,
        estado: 'pagada');
    await esperaError(() => repo.aplicarAjuste(
        tenantId: tenantId, cuotaId: pagada, esPorcentaje: false,
        valor: 100, motivo: 'x', aplicadoPorId: adminId));

    expect(
        await db.getAll(
            "SELECT id FROM cargos_extra WHERE origen = 'ajuste'"),
        isEmpty);
  });

  test('quitarCargo revierte: borra el cargo y restaura neto/estado',
      () async {
    final cuotaId =
        await seedCuota(monto: 500, montoPagado: 300, estado: 'parcial');
    await repo.aplicarAjuste(
      tenantId: tenantId,
      cuotaId: cuotaId,
      esPorcentaje: false,
      valor: 200,
      motivo: 'Sin servicio',
      aplicadoPorId: adminId,
    );
    expect((await getCuota(cuotaId))['estado'], 'pagada');

    final ajustes = await repo.cargosDeCuota(cuotaId);
    expect(ajustes, hasLength(1));

    await repo.quitarCargo(
        cargoId: ajustes.first['id'] as String, aplicadoPorId: adminId);
    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['cargos_neto']), 0);
    expect(cuota['estado'], 'parcial'); // vuelve a deber 200
    expect(await repo.cargosDeCuota(cuotaId), isEmpty);

    // Idempotente: quitar de nuevo es no-op.
    await repo.quitarCargo(
        cargoId: ajustes.first['id'] as String, aplicadoPorId: adminId);
  });

  test('quitarCargo NO borra un crédito aplicado (origen=credito) — PROTEGIDO '
      '(crítico \$: sino destruía el saldo a favor del cliente)', () async {
    final cuotaId = await seedCuota(monto: 800);
    final creditoId = uuid.v4();
    // Simula un crédito aplicado: cargos_extra origen='credito' tipo=
    // 'credito_aplicado' (lo inserta aplicarCredito, ligado 1-a-1 a una fila
    // '-' de saldos_favor via FK cargo_id ON DELETE SET NULL).
    await db.execute(
      'INSERT INTO cargos_extra (id, tenant_id, cuota_id, cobrador_id, '
      'aplicado_por, tipo, monto, origen, descripcion, ocurrido_en) '
      "VALUES (?, ?, ?, ?, ?, 'credito_aplicado', 100, 'credito', "
      "'Crédito por excedente', ?)",
      [creditoId, tenantId, cuotaId, cobradorId, adminId, _now()],
    );
    // Intentar quitarlo por el flujo de basura → debe ser NO-OP (protegido):
    // el WHERE de quitarCargo excluye origen='credito'.
    await repo.quitarCargo(cargoId: creditoId, aplicadoPorId: adminId);
    // El cargo de crédito SIGUE presente (no se destruyó el saldo a favor).
    final rows =
        await db.getAll('SELECT id FROM cargos_extra WHERE id = ?', [creditoId]);
    expect(rows, hasLength(1),
        reason: 'un crédito aplicado NO se borra por quitarCargo');
  });

  // ── PROMOS (rediseño 2026-06-11): mismo riel que los ajustes, con
  // origen='promo'. Blindan que la etiqueta viaja a la DB, que el sheet
  // las lista junto a los ajustes y que quitar también las cubre. ──

  test('promo: inserta cargo origen=promo y cargosDeCuota la lista con su '
      'origen', () async {
    final cuotaId = await seedCuota(monto: 800);
    await repo.aplicarAjuste(
      tenantId: tenantId,
      cuotaId: cuotaId,
      esPorcentaje: true,
      valor: 50,
      motivo: 'Promo 3 meses a mitad de precio',
      aplicadoPorId: adminId,
      origen: 'promo',
    );

    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto']), 800, reason: 'el monto NUNCA se muta');
    expect(num2(cuota['cargos_neto']), -400);

    final items = await repo.cargosDeCuota(cuotaId);
    expect(items, hasLength(1));
    expect(items.first['origen'], 'promo');
    expect(num2(items.first['monto'] as num), 400);
  });

  test('quitarCargo también revierte promos (origen IN ajuste/promo)',
      () async {
    final cuotaId = await seedCuota(monto: 500);
    await repo.aplicarAjuste(
      tenantId: tenantId,
      cuotaId: cuotaId,
      esPorcentaje: false,
      valor: 250,
      motivo: 'Promo aniversario',
      aplicadoPorId: adminId,
      origen: 'promo',
    );
    final items = await repo.cargosDeCuota(cuotaId);
    await repo.quitarCargo(
        cargoId: items.first['id'] as String, aplicadoPorId: adminId);
    expect(await repo.cargosDeCuota(cuotaId), isEmpty);
    expect(num2((await getCuota(cuotaId))['cargos_neto']), 0);
  });

  test('promo del 100% CONDONA: la cuota queda pagada (saldo 0, sin plata) '
      'y quitarla la reabre — espejo de 0117', () async {
    final cuotaId = await seedCuota(monto: 800);
    await repo.aplicarAjuste(
      tenantId: tenantId,
      cuotaId: cuotaId,
      esPorcentaje: true,
      valor: 100,
      motivo: 'Mes gratis por promo',
      aplicadoPorId: adminId,
      origen: 'promo',
    );
    var cuota = await getCuota(cuotaId);
    expect(cuota['estado'], 'pagada',
        reason: 'total real 0 → condonada; si quedara pendiente con saldo 0 '
            'bloquearía el orden de cobro del contrato');
    expect(num2(cuota['monto_pagado']), 0, reason: 'no entró plata');
    expect(num2(cuota['cargos_neto']), -800);

    // Quitar la promo revierte la condonación.
    final items = await repo.cargosDeCuota(cuotaId);
    await repo.quitarCargo(
        cargoId: items.first['id'] as String, aplicadoPorId: adminId);
    cuota = await getCuota(cuotaId);
    expect(cuota['estado'], 'pendiente');
    expect(num2(cuota['cargos_neto']), 0);
  });

  test('origen inválido (ni ajuste ni promo) lanza y no muta', () async {
    final cuotaId = await seedCuota(monto: 500);
    await expectLater(
        repo.aplicarAjuste(
          tenantId: tenantId,
          cuotaId: cuotaId,
          esPorcentaje: false,
          valor: 100,
          motivo: 'x',
          aplicadoPorId: adminId,
          origen: 'cobro',
        ),
        throwsA(isA<Exception>()));
    expect(
        await db.getAll('SELECT id FROM cargos_extra WHERE cuota_id = ?',
            [cuotaId]),
        isEmpty);
  });

  // ── CARGOS del admin (rediseño 2026-06-12): reconexión/otro se aplican
  // desde el sheet del contrato, sin pago_id, y se pueden quitar. ──

  test('aplicarCargo reconexión: sube cargos_neto, sin pago_id, y '
      'quitarCargo lo revierte', () async {
    final cuotaId = await seedCuota(monto: 500);
    await repo.aplicarCargo(
      tenantId: tenantId,
      cuotaId: cuotaId,
      tipo: 'reconexion',
      monto: 100,
      aplicadoPorId: adminId,
    );
    var cuota = await getCuota(cuotaId);
    expect(num2(cuota['cargos_neto']), 100);
    expect(cuota['estado'], 'pendiente');

    final cargos = await repo.cargosDeCuota(cuotaId);
    expect(cargos, hasLength(1));
    expect(cargos.first['tipo'], 'reconexion');
    expect(cargos.first['origen'], 'cobro');
    expect(cargos.first['pago_id'], isNull);
    expect(cargos.first['descripcion'], 'Cargo por reconexión');

    await repo.quitarCargo(
        cargoId: cargos.first['id'] as String, aplicadoPorId: adminId);
    cuota = await getCuota(cuotaId);
    expect(num2(cuota['cargos_neto']), 0);
    expect(await repo.cargosDeCuota(cuotaId), isEmpty);
  });

  test('aplicarCargo valida: tipo inválido, monto 0, otro sin descripción, '
      'cuota pagada → lanzan', () async {
    final cuotaId = await seedCuota(monto: 500);
    Future<void> esperaError(Future<void> Function() fn) =>
        expectLater(fn(), throwsA(isA<Exception>()));

    await esperaError(() => repo.aplicarCargo(
        tenantId: tenantId, cuotaId: cuotaId, tipo: 'descuento_monto',
        monto: 50, aplicadoPorId: adminId));
    await esperaError(() => repo.aplicarCargo(
        tenantId: tenantId, cuotaId: cuotaId, tipo: 'otro',
        monto: 0, descripcion: 'x', aplicadoPorId: adminId));
    await esperaError(() => repo.aplicarCargo(
        tenantId: tenantId, cuotaId: cuotaId, tipo: 'otro',
        monto: 50, aplicadoPorId: adminId));
    final pagada =
        await seedCuota(monto: 500, montoPagado: 500, estado: 'pagada');
    await esperaError(() => repo.aplicarCargo(
        tenantId: tenantId, cuotaId: pagada, tipo: 'reconexion',
        monto: 50, aplicadoPorId: adminId));

    expect(await db.getAll('SELECT id FROM cargos_extra'), isEmpty);
  });

  test('quitarCargo NO toca cargos nacidos de un pago (pago_id) ni de '
      'liquidación', () async {
    final cuotaId = await seedCuota(monto: 500, montoPagado: 100,
        estado: 'parcial');
    // Descuento nacido de un cobro (pago_id) — protegido.
    final delCobro = uuid.v4();
    await db.execute(
      'INSERT INTO cargos_extra (id, tenant_id, cuota_id, cobrador_id, '
      'tipo, monto, descripcion, aplicado_por, aplicado_en, '
      'client_local_id, ocurrido_en, origen, pago_id) '
      "VALUES (?, ?, ?, ?, 'descuento_monto', 25, 'Descuento pronto pago', "
      "?, ?, ?, ?, 'cobro', ?)",
      [delCobro, tenantId, cuotaId, cobradorId, cobradorId, _now(),
          uuid.v4(), _now(), uuid.v4()],
    );
    // Descuento de liquidación — protegido.
    final deLiquidacion = uuid.v4();
    await db.execute(
      'INSERT INTO cargos_extra (id, tenant_id, cuota_id, cobrador_id, '
      'tipo, monto, descripcion, aplicado_por, aplicado_en, '
      'client_local_id, ocurrido_en, origen) '
      "VALUES (?, ?, ?, ?, 'descuento_monto', 30, 'Saldo cancelado', "
      "?, ?, ?, ?, 'liquidacion')",
      [deLiquidacion, tenantId, cuotaId, cobradorId, cobradorId, _now(),
          uuid.v4(), _now()],
    );

    await repo.quitarCargo(cargoId: delCobro, aplicadoPorId: adminId);
    await repo.quitarCargo(cargoId: deLiquidacion, aplicadoPorId: adminId);
    expect(await repo.cargosDeCuota(cuotaId), hasLength(2),
        reason: 'ambos protegidos: se revierten anulando el pago / nunca');
  });

  // Regresión del audit 2026-06-28 (F1): aplicar/quitar cargos y descuentos
  // del admin DEBEN dejar rastro en op_log scoped a la cuota. Antes no emitían
  // nada — un movimiento de plata sin historial, y quitarCargo era un DELETE
  // mudo pese a que el diálogo promete "queda registrado en el historial".
  test('op_log: aplicar y quitar cargo/descuento dejan rastro en la cuota',
      () async {
    final cuotaId = await seedCuota(monto: 500);
    await repo.aplicarAjuste(
        tenantId: tenantId, cuotaId: cuotaId, esPorcentaje: false,
        valor: 100, motivo: 'Sin servicio', aplicadoPorId: adminId);
    await repo.aplicarCargo(
        tenantId: tenantId, cuotaId: cuotaId, tipo: 'reconexion',
        monto: 80, aplicadoPorId: adminId);

    var logs = await db.getAll(
        'SELECT tipo_op, actor_label FROM op_log '
        "WHERE entidad = 'cuotas' AND entidad_id = ?",
        [cuotaId]);
    expect(logs.map((r) => r['tipo_op']),
        containsAll(['descuento_cuota', 'cargo_cuota']));
    expect(logs.first['actor_label'], 'Admin Test',
        reason: 'el actor se resuelve del cobrador que lo aplicó');

    final cargo = (await repo.cargosDeCuota(cuotaId))
        .firstWhere((c) => c['tipo'] == 'reconexion');
    await repo.quitarCargo(
        cargoId: cargo['id'] as String, aplicadoPorId: adminId);
    logs = await db.getAll(
        "SELECT tipo_op FROM op_log WHERE entidad = 'cuotas' AND entidad_id = ?",
        [cuotaId]);
    expect(logs.map((r) => r['tipo_op']), contains('quitar_cargo_cuota'),
        reason: 'quitar un cargo debe dejar rastro (antes era DELETE mudo)');
  });
}

String _now() => DateTime.now().toUtc().toIso8601String();

String? _resolveCorePath() {
  final override = Platform.environment['POWERSYNC_CORE_PATH'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return override;
  }
  final root = Directory.current.path;
  for (final c in [
    p.join(root, 'libpowersync.so'),
    p.join(root, 'libpowersync.dylib'),
    p.join(root, 'powersync_x64.dll'),
    p.join(root, 'powersync_aarch64.dll'),
  ]) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
