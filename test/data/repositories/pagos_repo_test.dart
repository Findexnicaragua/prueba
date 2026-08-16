@TestOn('vm')
library;

/// Tests del repositorio de DINERO `PagosRepo` contra una PowerSyncDatabase
/// REAL (SQLite local), no un mock. Estos tests blindan los invariantes de
/// dinero de CLAUDE.md ("Invariantes de dinero") a nivel de la transacción que
/// el cobrador ejecuta offline: qué queda escrito en `pagos`, `recibos` y
/// `cuotas` después de cada flujo de cobro/anulación/edición.
///
/// ─────────────────────────────────────────────────────────────────────────
/// CÓMO CORRER (requiere el core nativo de PowerSync)
/// ─────────────────────────────────────────────────────────────────────────
/// `PowerSyncDatabase` necesita la extensión nativa `powersync-sqlite-core`
/// para abrir el SQLite local. Bajo `flutter test` (Dart VM, sin platform
/// channels) NO se resuelve sola: hay que tener el binario disponible.
///
/// 1. Descargá el binario de tu plataforma desde los releases de
///    `powersync-sqlite-core` (https://github.com/powersync-ja/powersync-sqlite-core/releases)
///    — debe coincidir con el rango que pide `powersync: ^1.10.0`.
///      - Linux:   `libpowersync.so`
///      - macOS:   `libpowersync.dylib`
///      - Windows: `powersync_x64.dll`  (OJO: powersync_core 1.18 carga la
///        extensión con el sufijo de arquitectura, NO `powersync.dll` como dicen
///        los docs viejos. Si tu versión difiere, mirá el nombre en el error
///        "Failed to load dynamic library '<nombre>'" y usá ese.)
///    Atajo recomendado: si `powersync_flutter_libs` ya está en el pub cache,
///    copiá su binario directo (garantiza versión compatible). En Windows:
///    `...\powersync_flutter_libs-<v>\windows\powersync_x64.dll`.
/// 2. Dejalo en la RAÍZ del repo (junto a `pubspec.yaml`) con ese nombre.
///    El harness lo busca ahí por defecto; se puede overridear con la env var
///    `POWERSYNC_CORE_PATH=/ruta/al/binario`.
/// 3. `flutter pub get` (trae `path` + `sqlite3` de dev_dependencies) y luego
///    `flutter test test/data/repositories/pagos_repo_test.dart`.
///
/// Si el binario no está, los tests se SALTAN con un mensaje claro (no fallan
/// en rojo por infraestructura faltante) — ver `_resolveCorePath`.
///
/// Nota de aislamiento: cada test abre su propia DB en un archivo temporal
/// único (carpeta del sistema), seedea su data, y la cierra/borra en tearDown.
/// No hay estado compartido entre tests ni red (la sesión Supabase no está
/// inicializada: el guard de correlativo que llama a `Supabase.instance`
/// cae en su `catch (_)` y usa el MAX(correlativo) LOCAL, que es justo lo que
/// queremos ejercitar).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/pago.dart';
import 'package:isp_billing/data/repositories/contratos_repo.dart';
import 'package:isp_billing/data/repositories/cuotas_repo.dart';
import 'package:isp_billing/data/repositories/pagos_repo.dart';
import 'package:isp_billing/data/utils/colchon_indefinido.dart';
import 'package:isp_billing/data/utils/prorrateo.dart';
import 'package:isp_billing/features/recibo/recibo_cargos.dart';
import 'package:isp_billing/powersync/db.dart' as ps;
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
// Prefijado para evitar cualquier colisión con símbolos re-exportados por
// `powersync.dart` (que re-exporta parte de sqlite_async). Usamos `sq.open` y
// `sq.OperatingSystem` para apuntar la extensión nativa.
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

void main() {
  // ── Resolución del core nativo ────────────────────────────────────────────
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('PagosRepo (saltado: falta powersync-sqlite-core)', () {
      markTestSkipped(
        'No se encontró el binario `powersync-sqlite-core` en la raíz del repo '
        '(ni en \$POWERSYNC_CORE_PATH). Ver instrucciones en la cabecera de '
        'este archivo. Los tests de PagosRepo requieren el SQLite local de '
        'PowerSync para correr.',
      );
    }, skip: true);
    return;
  }

  // Registrar la extensión nativa para TODAS las plataformas que sqlite3 abre.
  // PowerSync usa `open.overrideFor` internamente; acá apuntamos al binario.
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();

  // Helpers de seed/aserción que dependen de la DB del test actual.
  late PowerSyncDatabase db;
  late PagosRepo repo;
  late Directory tmpDir;

  // IDs base reutilizados por test (cada test corre sobre su DB limpia).
  const tenantId = 't-test';
  const cobradorId = 'co-test';
  const prefijo = 'A';
  const planId = 'plan-test';
  const clienteId = 'cli-test';

  setUp(() async {
    // SharedPreferences en memoria y LIMPIO por test: el high-water mark del
    // correlativo (CorrelativoStore) no debe filtrar estado entre tests —
    // cada test arranca con hwm 0, igual que un dispositivo nuevo.
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('pagos_repo_test_');
    final dbPath = p.join(tmpDir.path, 'test_${uuid.v4()}.db');
    db = PowerSyncDatabase(schema: schema, path: dbPath);
    await db.initialize();
    repo = PagosRepo(db: db);

    // Seed mínimo común: tenant/cobrador(con prefijo)/plan/cliente.
    // El cobrador necesita `prefijo_recibo` para el correlativo del recibo.
    await db.execute(
      'INSERT INTO cobradores (id, tenant_id, nombre, rol, prefijo_recibo, activo) '
      "VALUES (?, ?, 'Cobrador Test', 'cobrador', ?, 1)",
      [cobradorId, tenantId, prefijo],
    );
    await db.execute(
      'INSERT INTO planes (id, tenant_id, nombre, tipo, precio_mensual, activo, created_at) '
      "VALUES (?, ?, 'Plan Test', 'fijo', 500, 1, ?)",
      [planId, tenantId, _now()],
    );
    await db.execute(
      'INSERT INTO clientes (id, tenant_id, cobrador_id, nombre, activo, created_at) '
      "VALUES (?, ?, ?, 'Cliente Test', 1, ?)",
      [clienteId, tenantId, cobradorId, _now()],
    );
  });

  tearDown(() async {
    await db.close();
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  // ── Helpers de seed específicos ─────────────────────────────────────────

  /// Crea un contrato y devuelve su id. [duracionMeses] null = indefinido.
  Future<String> seedContrato({
    String? id,
    int diaPago = 5,
    int? duracionMeses,
    String? fechaFin,
  }) async {
    final contratoId = id ?? uuid.v4();
    await db.execute(
      'INSERT INTO contratos (id, tenant_id, cliente_id, cobrador_id, plan_id, '
      'dia_pago, duracion_meses, fecha_fin, estado, created_at) '
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'activo', ?)",
      [
        contratoId, tenantId, clienteId, cobradorId, planId,
        diaPago, duracionMeses, fechaFin, _now(),
      ],
    );
    return contratoId;
  }

  /// Crea una cuota pendiente y devuelve su id.
  /// [monto] es el monto base; estado inicial 'pendiente', pagado 0.
  Future<String> seedCuota({
    required String contratoId,
    double monto = 500,
    String estado = 'pendiente',
    double montoPagado = 0,
    double cargosNeto = 0,
    String periodo = '2026-06',
    String fechaVencimiento = '2026-06-05',
    String? id,
  }) async {
    final cuotaId = id ?? uuid.v4();
    await db.execute(
      'INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, cobrador_id, '
      'periodo, fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        cuotaId, tenantId, contratoId, clienteId, cobradorId,
        periodo, fechaVencimiento, monto, montoPagado, cargosNeto, estado, _now(),
      ],
    );
    return cuotaId;
  }

  /// Inserta un cargo_extra sobre una cuota (reconexión suma, descuento resta).
  Future<void> seedCargo({
    required String cuotaId,
    required String tipo, // 'reconexion' | 'otro' | 'descuento_monto' | ...
    required double monto,
    String? origen, // 'puente' | 'ajuste' | ... (null = sin origen, legacy)
    String? pagoId, // liga el cargo a un pago (puente / cargo automático)
  }) async {
    await db.execute(
      'INSERT INTO cargos_extra (id, tenant_id, cuota_id, cobrador_id, tipo, '
      'monto, descripcion, aplicado_por, aplicado_en, origen, pago_id) '
      "VALUES (?, ?, ?, ?, ?, ?, 'seed', ?, ?, ?, ?)",
      [uuid.v4(), tenantId, cuotaId, cobradorId, tipo, monto, cobradorId,
        _now(), origen, pagoId],
    );
  }

  // ── Helpers de aserción (re-query a la DB) ──────────────────────────────

  Future<Map<String, dynamic>> getCuota(String cuotaId) async {
    final rows = await db.getAll('SELECT * FROM cuotas WHERE id = ?', [cuotaId]);
    expect(rows, hasLength(1), reason: 'cuota $cuotaId debe existir');
    return rows.first;
  }

  Future<Map<String, dynamic>> getPago(String pagoId) async {
    final rows = await db.getAll('SELECT * FROM pagos WHERE id = ?', [pagoId]);
    expect(rows, hasLength(1), reason: 'pago $pagoId debe existir');
    return rows.first;
  }

  Future<Map<String, dynamic>> getReciboDePago(String pagoId) async {
    final rows =
        await db.getAll('SELECT * FROM recibos WHERE pago_id = ?', [pagoId]);
    expect(rows, hasLength(1), reason: 'recibo del pago $pagoId debe existir');
    return rows.first;
  }

  double num2(Object? v) => (v as num).toDouble();

  // ───────────────────────────────────────────────────────────────────────
  // CASO 1 — registrarCobro completo (pago exacto)
  // ───────────────────────────────────────────────────────────────────────
  test('1. cobro completo 500/500: cuota pagada, monto_cordobas=500, '
      'vuelto=0, recibo correlativo 1', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 500, // aplicado (ya separado por CobroCalculo)
      vueltoCordobas: 0,
      moneda: Moneda.nio,
      montoOriginal: 500,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 500);
    expect(cuota['estado'], 'pagada');

    final pago = await getPago(res.pagoId);
    expect(num2(pago['monto_cordobas']), 500); // entra a caja
    expect(num2(pago['vuelto_cordobas']), 0);
    expect(num2(pago['monto_original']), 500);
    expect(num2(pago['tasa_conversion']), 1);
    expect(pago['moneda'], 'NIO');
    expect(pago['anulado'], 0);

    final recibo = await getReciboDePago(res.pagoId);
    expect(recibo['correlativo'], 1);
    expect(recibo['numero_completo'], 'A-00001');
    expect(recibo['anulado'], 0);
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 2 — pago parcial
  // ───────────────────────────────────────────────────────────────────────
  test('2. cobro parcial 300/500: cuota parcial, monto_pagado=300', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 300,
      moneda: Moneda.nio,
      montoOriginal: 300,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 300);
    expect(cuota['estado'], 'parcial');

    final pago = await getPago(res.pagoId);
    expect(num2(pago['monto_cordobas']), 300);
    expect(num2(pago['vuelto_cordobas']), 0);
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 3 — sobrepago / vuelto (invariante #1/#4: recaudado SIN vuelto)
  // ───────────────────────────────────────────────────────────────────────
  test('3. sobrepago: entrega 600 sobre 500 → aplicado=500, vuelto=100, '
      'monto_pagado=500, cuota pagada', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    // El repo recibe ya separado el aplicado/vuelto (lo hace CobroCalculo en
    // la UI). Simulamos entrega de 600: aplicado=500, vuelto=100.
    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 500, // aplicado = saldo (truncado)
      vueltoCordobas: 100, // excedente devuelto
      moneda: Moneda.nio,
      montoOriginal: 600, // lo entregado (NIO, tasa 1)
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    final cuota = await getCuota(cuotaId);
    // monto_pagado SOLO refleja lo aplicado, nunca el vuelto.
    expect(num2(cuota['monto_pagado']), 500);
    expect(cuota['estado'], 'pagada');

    final pago = await getPago(res.pagoId);
    expect(num2(pago['monto_cordobas']), 500, reason: 'recaudado = aplicado');
    expect(num2(pago['vuelto_cordobas']), 100);
    // Invariante #3: monto_original × tasa ≈ monto_cordobas + vuelto.
    expect(
      num2(pago['monto_original']) * num2(pago['tasa_conversion']),
      closeTo(num2(pago['monto_cordobas']) + num2(pago['vuelto_cordobas']), 0.001),
    );
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 4 — USD (vuelto SIEMPRE en NIO; invariante monto_original×tasa)
  // ───────────────────────────────────────────────────────────────────────
  test('4. USD: entrega US\$30 @ 36.6 sobre cuota 500 → monto_original=30, '
      'tasa=36.6, aplicado=500 NIO, vuelto=598 NIO', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    // US$30 @ 36.6 = 1098 NIO entregados; aplicado 500, vuelto 598 (NIO).
    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 500, // aplicado en NIO
      vueltoCordobas: 598, // vuelto en NIO (nunca USD)
      moneda: Moneda.usd,
      montoOriginal: 30, // lo entregado en USD
      tasaConversion: 36.6,
      metodo: MetodoPago.efectivo,
    );

    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 500);
    expect(cuota['estado'], 'pagada');

    final pago = await getPago(res.pagoId);
    expect(pago['moneda'], 'USD');
    expect(num2(pago['monto_original']), 30);
    expect(num2(pago['tasa_conversion']), 36.6);
    expect(num2(pago['monto_cordobas']), 500);
    expect(num2(pago['vuelto_cordobas']), 598);
    // Invariante #3: 30 × 36.6 = 1098 ≈ 500 + 598.
    expect(
      num2(pago['monto_original']) * num2(pago['tasa_conversion']),
      closeTo(num2(pago['monto_cordobas']) + num2(pago['vuelto_cordobas']), 0.001),
    );
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 5 — cargos_extra: el saldo respeta monto + cargos − descuentos
  // ───────────────────────────────────────────────────────────────────────
  // ── Tope contra doble cobro (audit 2026-07-26) ────────────────────────────
  // En producción una cuota de C$1.282 quedó con C$2.564 pagados: dos equipos
  // cobraron con 47 segundos de diferencia y cada uno vio la cuota todavía
  // pendiente. `cobro_calculo` acota contra el saldo que tenía la PANTALLA, no
  // contra el vivo; el tope real vive dentro de la transacción.
  group('tope contra doble cobro', () {
    test('una cuota ya cubierta rechaza un segundo cobro', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(
          contratoId: contratoId, monto: 500, periodo: '2026-06-01');

      await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 500,
        vueltoCordobas: 0,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      // Segundo cobro sobre la misma cuota: antes se sumaba en silencio.
      await expectLater(
        repo.registrarCobro(
          tenantId: tenantId,
          cobradorId: cobradorId,
          prefijoRecibo: prefijo,
          cuotaId: cuotaId,
          montoCordobas: 500,
          vueltoCordobas: 0,
          moneda: Moneda.nio,
          montoOriginal: 500,
          tasaConversion: 1,
          metodo: MetodoPago.efectivo,
        ),
        throwsA(isA<Exception>()),
      );

      final cu = await db.getAll(
          'SELECT monto_pagado FROM cuotas WHERE id = ?', [cuotaId]);
      expect((cu.first['monto_pagado'] as num).toDouble(), 500,
          reason: 'el rechazo no debe dejar rastro del segundo cobro');
    });

    test('un cobro parcial deja cobrar el resto, pero no más', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(
          contratoId: contratoId, monto: 500, periodo: '2026-06-01');

      await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 300,
        vueltoCordobas: 0,
        moneda: Moneda.nio,
        montoOriginal: 300,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      // Los 200 que faltan SÍ entran.
      await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 200,
        vueltoCordobas: 0,
        moneda: Moneda.nio,
        montoOriginal: 200,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      final cu = await db.getAll(
          'SELECT monto_pagado FROM cuotas WHERE id = ?', [cuotaId]);
      expect((cu.first['monto_pagado'] as num).toDouble(), 500);

      // Un centavo más, no.
      await expectLater(
        repo.registrarCobro(
          tenantId: tenantId,
          cobradorId: cobradorId,
          prefijoRecibo: prefijo,
          cuotaId: cuotaId,
          montoCordobas: 100,
          vueltoCordobas: 0,
          moneda: Moneda.nio,
          montoOriginal: 100,
          tasaConversion: 1,
          metodo: MetodoPago.efectivo,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('5. cargos_extra (saldo = monto + cargos − descuentos)', () {
    test('credito_aplicado RESTA en totalACobrar — no sobre-cobra (audit ALTA)',
        () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(
          contratoId: contratoId, monto: 500, periodo: '2026-06-01');
      await seedCargo(cuotaId: cuotaId, tipo: 'credito_aplicado', monto: 200);
      // 500 base − 200 de crédito aplicado = 300. Antes del fix daba 500
      // (el crédito caía en el ELSE y no se restaba) → sobre-cobro.
      expect(await CuotasRepo(db: db).totalACobrar(cuotaId), 300);
    });

    test('reconexión +100: pagar 600 (500 base + 100 cargo) deja cuota pagada '
        'y cargos_neto=100', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await seedCargo(cuotaId: cuotaId, tipo: 'reconexion', monto: 100);

      // Saldo real = 500 + 100 = 600. Cobro completo aplica 600.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 600,
        moneda: Moneda.nio,
        montoOriginal: 600,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['cargos_neto']), 100, reason: 'mirror del trigger neto');
      expect(num2(cuota['monto_pagado']), 600);
      // total real = 500 + 100 = 600 → pagada.
      expect(cuota['estado'], 'pagada');

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 600);
    });

    test('reconexión +100 pero solo paga 500 (base): queda parcial '
        '(faltan los 100 del cargo)', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await seedCargo(cuotaId: cuotaId, tipo: 'reconexion', monto: 100);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 500,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['cargos_neto']), 100);
      expect(num2(cuota['monto_pagado']), 500);
      // total real 600, pagado 500 → parcial.
      expect(cuota['estado'], 'parcial');
      expect(res.reciboId, isNotEmpty);
    });

    test('descuento_monto −100: pagar 400 deja la cuota pagada '
        'y cargos_neto=-100', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await seedCargo(cuotaId: cuotaId, tipo: 'descuento_monto', monto: 100);

      // total real = 500 − 100 = 400.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 400,
        moneda: Moneda.nio,
        montoOriginal: 400,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['cargos_neto']), -100);
      expect(num2(cuota['monto_pagado']), 400);
      expect(cuota['estado'], 'pagada');

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 400);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 6 — registrarCobroMultiple (2 cuotas, vuelto solo al último)
  // ───────────────────────────────────────────────────────────────────────
  test('6. multi-cuota: 2 cuotas del mismo contrato, pago total con vuelto → '
      'ambas pagadas, vuelto solo al ÚLTIMO pago, correlativos consecutivos',
      () async {
    final contratoId = await seedContrato();
    final cuotaA = await seedCuota(contratoId: contratoId, monto: 500);
    final cuotaB = await seedCuota(contratoId: contratoId, monto: 500);

    // Entrega 1200 sobre saldo 1000: aplica 500+500, vuelto 200 al último.
    final res = await repo.registrarCobroMultiple(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaIds: [cuotaA, cuotaB],
      montosCordobas: [500, 500],
      vueltoCordobas: 200,
      moneda: Moneda.nio,
      montosOriginal: [500, 700], // último carga su saldo + el excedente
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    expect(res.esMultiCuota, isTrue);
    expect(res.reciboIds, hasLength(2));
    expect(res.grupoCobro, isNotNull);

    // Ambas cuotas quedan pagadas.
    final ca = await getCuota(cuotaA);
    final cb = await getCuota(cuotaB);
    expect(ca['estado'], 'pagada');
    expect(cb['estado'], 'pagada');
    expect(num2(ca['monto_pagado']), 500);
    expect(num2(cb['monto_pagado']), 500);

    // Los pagos del grupo: el vuelto está SOLO en uno (el último), 0 en el otro.
    final pagosGrupo = await db.getAll(
      'SELECT * FROM pagos WHERE grupo_cobro = ? ORDER BY monto_original ASC',
      [res.grupoCobro],
    );
    expect(pagosGrupo, hasLength(2));
    // Σ monto_cordobas (recaudado) = 1000, SIN el vuelto.
    final recaudado =
        pagosGrupo.fold<double>(0, (a, r) => a + num2(r['monto_cordobas']));
    expect(recaudado, 1000, reason: 'recaudado NO incluye el vuelto (inv #4)');
    // El vuelto total (200) aparece una sola vez.
    final vueltoTotal =
        pagosGrupo.fold<double>(0, (a, r) => a + num2(r['vuelto_cordobas']));
    expect(vueltoTotal, 200);
    final filasConVuelto =
        pagosGrupo.where((r) => num2(r['vuelto_cordobas']) > 0).length;
    expect(filasConVuelto, 1, reason: 'vuelto solo en el último pago');
    // Todos comparten el mismo grupo_cobro.
    expect(pagosGrupo.every((r) => r['grupo_cobro'] == res.grupoCobro), isTrue);

    // Correlativos consecutivos 1 y 2 (sin colisión).
    final recibos = await db.getAll(
      'SELECT correlativo FROM recibos WHERE cobrador_id = ? AND prefijo = ? '
      'ORDER BY correlativo ASC',
      [cobradorId, prefijo],
    );
    expect(recibos.map((r) => r['correlativo']).toList(), [1, 2]);
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 7 — correlativo incremental sin colisión
  // ───────────────────────────────────────────────────────────────────────
  test('7. correlativo: dos cobros secuenciales → recibos 1 y 2', () async {
    final contratoId = await seedContrato();
    final c1 = await seedCuota(contratoId: contratoId, monto: 500);
    final c2 = await seedCuota(contratoId: contratoId, monto: 500);

    final r1 = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: c1,
      montoCordobas: 500,
      moneda: Moneda.nio,
      montoOriginal: 500,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );
    final r2 = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: c2,
      montoCordobas: 500,
      moneda: Moneda.nio,
      montoOriginal: 500,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    final rec1 = await getReciboDePago(r1.pagoId);
    final rec2 = await getReciboDePago(r2.pagoId);
    expect(rec1['correlativo'], 1);
    expect(rec2['correlativo'], 2);
    expect(rec1['numero_completo'], 'A-00001');
    expect(rec2['numero_completo'], 'A-00002');
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 8 — anularPago: restaura cuota, preserva pago (soft delete), recibo anulado
  // ───────────────────────────────────────────────────────────────────────
  test('8. anularPago: restaura monto_pagado/estado, pago preservado '
      '(anulado=1, no borrado), recibo anulado', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 500,
      moneda: Moneda.nio,
      montoOriginal: 500,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    // Pre-condición: cuota pagada.
    var cuota = await getCuota(cuotaId);
    expect(cuota['estado'], 'pagada');
    expect(num2(cuota['monto_pagado']), 500);

    await repo.anularPago(
      pagoId: res.pagoId,
      anuladoPorId: cobradorId,
      motivo: 'error de carga',
    );

    // Cuota restaurada a pendiente con pagado 0.
    cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 0);
    expect(cuota['estado'], 'pendiente');

    // El pago se PRESERVA (audit trail), marcado anulado.
    final pago = await getPago(res.pagoId);
    expect(pago['anulado'], 1);
    expect(pago['anulado_por'], cobradorId);
    expect(pago['motivo_anulacion'], 'error de carga');
    expect(pago['anulado_en'], isNotNull);
    // Sigue existiendo (no se borró).
    final pagoCount =
        await db.getAll('SELECT COUNT(*) AS n FROM pagos WHERE id = ?', [res.pagoId]);
    expect(pagoCount.first['n'], 1);

    // El recibo asociado queda anulado.
    final recibo = await getReciboDePago(res.pagoId);
    expect(recibo['anulado'], 1);
    expect(recibo['anulado_por'], cobradorId);
  });

  // ───────────────────────────────────────────────────────────────────────
  // Mirror offline del color del mapa (clientes.vencimiento_mas_viejo): cada
  // flujo que muta cuotas/estado lo recalcula offline para que el pin cambie
  // al toque (online lo hace el trigger 0150). recalcVmvDeContrato.
  // ───────────────────────────────────────────────────────────────────────
  group('mirror offline vencimiento_mas_viejo (color del mapa)', () {
    Future<Object?> vmv() async => (await db.getAll(
            'SELECT vencimiento_mas_viejo FROM clientes WHERE id = ?',
            [clienteId]))
        .first['vencimiento_mas_viejo'];

    test('cobrar la más vieja avanza el vmv; anular el cobro lo restaura',
        () async {
      final contratoId = await seedContrato(diaPago: 5);
      final jun = await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-06-01', fechaVencimiento: '2026-06-05');
      await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-07-01', fechaVencimiento: '2026-07-05');

      final res = await repo.registrarCobro(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        cuotaId: jun, montoCordobas: 500, moneda: Moneda.nio,
        montoOriginal: 500, tasaConversion: 1, metodo: MetodoPago.efectivo,
      );
      // Cobrada jun → la pendiente más vieja pasa a ser jul.
      expect(await vmv(), '2026-07-05');

      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      // Restaurada jun a pendiente → vuelve a ser la más vieja.
      expect(await vmv(), '2026-06-05');
    });

    test('suspender excluye el contrato → vmv NULL', () async {
      final contratoId = await seedContrato(diaPago: 5);
      await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-06-01', fechaVencimiento: '2026-06-05');
      // Estado previo: el cliente ya tenía su fecha (como tras un cobro/sync).
      await db.execute(
          "UPDATE clientes SET vencimiento_mas_viejo = '2026-06-05' WHERE id = ?",
          [clienteId]);

      await ContratosRepo(db: db).suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 500,
        motivo: 'Viaje',
      );
      // Contrato suspendido → sus cuotas no cuentan → sin cuotas de contrato
      // activo, el vmv del cliente queda NULL.
      expect(await vmv(), isNull);
    });
  });

  test('8b. anularPago sobre uno de un par parcial: queda parcial con el resto',
      () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    // Dos pagos parciales de 250 → cuota pagada (500).
    final p1 = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 250,
      moneda: Moneda.nio,
      montoOriginal: 250,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );
    await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 250,
      moneda: Moneda.nio,
      montoOriginal: 250,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );
    expect((await getCuota(cuotaId))['estado'], 'pagada');

    // Anular el primero → queda 250 pagado → parcial.
    await repo.anularPago(
      pagoId: p1.pagoId,
      anuladoPorId: cobradorId,
      motivo: 'duplicado',
    );
    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 250);
    expect(cuota['estado'], 'parcial');
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 9 — editarPago guard (vuelto>0 o moneda extranjera → excepción)
  // ───────────────────────────────────────────────────────────────────────
  group('9. editarPago guard (no permitido con vuelto / moneda extranjera)', () {
    test('editar pago con vuelto>0 → lanza excepción, no muta', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      // Pago con vuelto (sobrepago 600 sobre 500).
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 500,
        vueltoCordobas: 100,
        moneda: Moneda.nio,
        montoOriginal: 600,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      await expectLater(
        repo.editarPago(
            pagoId: res.pagoId, editadoPorId: cobradorId, montoCordobas: 400),
        throwsA(isA<Exception>()),
      );

      // No mutó: monto sigue 500.
      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 500);
    });

    test('editar pago en moneda extranjera (USD) → lanza excepción', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 500,
        moneda: Moneda.usd,
        montoOriginal: 13.66,
        tasaConversion: 36.6,
        metodo: MetodoPago.efectivo,
      );

      await expectLater(
        repo.editarPago(
            pagoId: res.pagoId, editadoPorId: cobradorId, montoCordobas: 400),
        throwsA(isA<Exception>()),
      );

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 500);
      expect(pago['moneda'], 'USD');
    });

    test('editar pago NIO sin vuelto: SÍ recalcula cuota '
        '(camino feliz, contraste del guard)', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      // Pago parcial 300 (NIO, sin vuelto) → editable.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 300,
        moneda: Moneda.nio,
        montoOriginal: 300,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      expect((await getCuota(cuotaId))['estado'], 'parcial');

      // Subir el monto a 500 → cuota pagada, pago actualizado.
      await repo.editarPago(
          pagoId: res.pagoId, editadoPorId: cobradorId, montoCordobas: 500);

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 500);
      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['monto_pagado']), 500);
      expect(cuota['estado'], 'pagada');
    });

    test('editar pago por ENCIMA del saldo de la cuota → lanza y no muta '
        '(M2: el typo 500→5000 inflaba el recaudado en silencio)', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 300,
        moneda: Moneda.nio,
        montoOriginal: 300,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      // 5000 > total (500) − pagado por otros (0) → rechazado.
      await expectLater(
        repo.editarPago(
            pagoId: res.pagoId, editadoPorId: cobradorId, montoCordobas: 5000),
        throwsA(isA<Exception>()),
      );
      // Nada mutó.
      expect(num2((await getPago(res.pagoId))['monto_cordobas']), 300);
      expect(num2((await getCuota(cuotaId))['monto_pagado']), 300);

      // El máximo exacto (500) SÍ pasa: completa la cuota.
      await repo.editarPago(
          pagoId: res.pagoId, editadoPorId: cobradorId, montoCordobas: 500);
      expect((await getCuota(cuotaId))['estado'], 'pagada');
    });

    test('tope de edición considera cargos_neto y otros pagos de la cuota',
        () async {
      final contratoId = await seedContrato();
      // Cuota 500 + reconexión 100 → total 600.
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await seedCargo(cuotaId: cuotaId, tipo: 'reconexion', monto: 100);

      final p1 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 200,
        moneda: Moneda.nio,
        montoOriginal: 200,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      final p2 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 100,
        moneda: Moneda.nio,
        montoOriginal: 100,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      // Editar p2: máximo = 600 − (300 − 100 de p2... = 200 de p1) = 400.
      await expectLater(
        repo.editarPago(
            pagoId: p2.pagoId, editadoPorId: cobradorId, montoCordobas: 401),
        throwsA(isA<Exception>()),
      );
      await repo.editarPago(
          pagoId: p2.pagoId, editadoPorId: cobradorId, montoCordobas: 400);
      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['monto_pagado']), 600); // 200 + 400 = total
      expect(cuota['estado'], 'pagada');
      expect(p1.pagoId, isNot(p2.pagoId));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // GRUPO — chokepoint oldest-first (#4): no se paga adelantado con viejas
  // pendientes. La RED FINAL en pagos_repo, además de los guards de UX.
  // ───────────────────────────────────────────────────────────────────────
  group('chokepoint oldest-first (#4)', () {
    test('cobrar la 2da cuota con la 1ra pendiente → '
        'CobroFueraDeOrdenException, no muta', () async {
      final contratoId = await seedContrato();
      final mayo = await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-05', fechaVencimiento: '2026-05-05');
      final junio = await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-06', fechaVencimiento: '2026-06-05');

      // Intentar cobrar JUNIO con MAYO pendiente → bloqueado.
      await expectLater(
        repo.registrarCobro(
            tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
            cuotaId: junio, montoCordobas: 500, moneda: Moneda.nio,
            montoOriginal: 500, tasaConversion: 1, metodo: MetodoPago.efectivo),
        throwsA(isA<CobroFueraDeOrdenException>()),
      );
      // No mutó: junio sigue pendiente, sin pago.
      expect((await getCuota(junio))['estado'], 'pendiente');
      expect(
        await db.getAll('SELECT id FROM pagos WHERE cuota_id = ?', [junio]),
        isEmpty,
      );

      // Cobrar MAYO (la más vieja) SÍ pasa; luego JUNIO ya es la más vieja.
      await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: mayo, montoCordobas: 500, moneda: Moneda.nio,
          montoOriginal: 500, tasaConversion: 1, metodo: MetodoPago.efectivo);
      expect((await getCuota(mayo))['estado'], 'pagada');
      await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: junio, montoCordobas: 500, moneda: Moneda.nio,
          montoOriginal: 500, tasaConversion: 1, metodo: MetodoPago.efectivo);
      expect((await getCuota(junio))['estado'], 'pagada');
    });

    test('cargo manual NO está sujeto al orden (se cobra con regular vieja '
        'pendiente)', () async {
      final contratoId = await seedContrato();
      await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-05', fechaVencimiento: '2026-05-05');
      // Cargo manual suelto (tipo_cargo_manual) con la regular de mayo impaga.
      final cargo = await seedCuota(
          contratoId: contratoId, monto: 200,
          periodo: '2026-06', fechaVencimiento: '2026-06-10');
      await db.execute(
          "UPDATE cuotas SET tipo_cargo_manual = 'instalacion' WHERE id = ?",
          [cargo]);

      final res = await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: cargo, montoCordobas: 200, moneda: Moneda.nio,
          montoOriginal: 200, tasaConversion: 1, metodo: MetodoPago.efectivo);
      expect((await getCuota(cargo))['estado'], 'pagada');
      expect(res.reciboId, isNotEmpty);
    });

    test('multi-cobro: saltar la más vieja → bloqueado; contiguo desde la más '
        'vieja → permitido', () async {
      final contratoId = await seedContrato();
      final mayo = await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-05', fechaVencimiento: '2026-05-05');
      final junio = await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-06', fechaVencimiento: '2026-06-05');
      final julio = await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-07', fechaVencimiento: '2026-07-05');

      // Saltar mayo (cobrar junio+julio) → bloqueado.
      await expectLater(
        repo.registrarCobroMultiple(
            tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
            cuotaIds: [junio, julio], montosCordobas: [500, 500],
            moneda: Moneda.nio, montosOriginal: [500, 500],
            tasaConversion: 1, metodo: MetodoPago.efectivo),
        throwsA(isA<CobroFueraDeOrdenException>()),
      );
      expect((await getCuota(junio))['estado'], 'pendiente');

      // Contiguo desde la más vieja (mayo+junio) → permitido; julio intacto.
      final res = await repo.registrarCobroMultiple(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaIds: [mayo, junio], montosCordobas: [500, 500],
          moneda: Moneda.nio, montosOriginal: [500, 500],
          tasaConversion: 1, metodo: MetodoPago.efectivo);
      expect(res.esMultiCuota, isTrue);
      expect((await getCuota(mayo))['estado'], 'pagada');
      expect((await getCuota(junio))['estado'], 'pagada');
      expect((await getCuota(julio))['estado'], 'pendiente');
    });

    test('cuotas de DISTINTOS contratos no se bloquean entre sí', () async {
      final cA = await seedContrato();
      final cB = await seedContrato();
      final aMayo = await seedCuota(
          contratoId: cA, monto: 500,
          periodo: '2026-05', fechaVencimiento: '2026-05-05');
      // Contrato B con una vieja pendiente NO bloquea cobrar la de A.
      await seedCuota(
          contratoId: cB, monto: 500,
          periodo: '2026-04', fechaVencimiento: '2026-04-05');
      final res = await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: aMayo, montoCordobas: 500, moneda: Moneda.nio,
          montoOriginal: 500, tasaConversion: 1, metodo: MetodoPago.efectivo);
      expect((await getCuota(aMayo))['estado'], 'pagada');
      expect(res.reciboId, isNotEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // GRUPO — op_log (rework change log, Fase 1): UN log de INTENCIÓN por objeto,
  // scoped a sus atributos. Cobro/multi-cobro/anulación desde pagos_repo.
  // ───────────────────────────────────────────────────────────────────────
  group('op_log (rework change log)', () {
    Future<List<Map<String, dynamic>>> opLogsDe(
        String entidad, String entidadId) async {
      return db.getAll(
        'SELECT * FROM op_log WHERE entidad = ? AND entidad_id = ? '
        'ORDER BY ocurrido_en ASC',
        [entidad, entidadId],
      );
    }

    Map<String, dynamic> diffDe(Map<String, dynamic> log) =>
        jsonDecode(log['diff'] as String) as Map<String, dynamic>;

    List<Map<String, dynamic>> camposDe(Map<String, dynamic> diff) =>
        (diff['campos'] as List).cast<Map<String, dynamic>>();

    test('cobro simple → 1 op_log en la cuota (estado+saldo, monto+recibo en '
        'resumen, actor real)', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: cuotaId, montoCordobas: 500, moneda: Moneda.nio,
          montoOriginal: 500, tasaConversion: 1, metodo: MetodoPago.efectivo);

      final logs = await opLogsDe('cuotas', cuotaId);
      expect(logs, hasLength(1),
          reason: 'una intención = UN op_log por objeto (no 4-5 filas)');
      final log = logs.first;
      expect(log['tipo_op'], 'cobro');
      expect(log['accion'], 'update');
      expect(log['actor_id'], cobradorId);
      expect(log['actor_label'], 'Cobrador Test');
      final diff = diffDe(log);
      final campos = camposDe(diff);
      final estado = campos.firstWhere((c) => c['campo'] == 'estado');
      expect(estado['antes'], 'pendiente');
      expect(estado['despues'], 'pagada');
      final saldo = campos.firstWhere((c) => c['campo'] == 'saldo');
      expect((saldo['antes'] as num).toDouble(), 500);
      expect((saldo['despues'] as num).toDouble(), 0);
      final resumen = diff['resumen'] as Map<String, dynamic>;
      expect((resumen['monto'] as num).toDouble(), 500);
      expect(resumen['recibo'], 'A-00001');
    });

    test('multi-cobro → 1 op_log por cuota, MISMO op_id (grupoCobro), cada una '
        'con SU recibo', () async {
      final contratoId = await seedContrato();
      final c1 = await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-05', fechaVencimiento: '2026-05-05');
      final c2 = await seedCuota(
          contratoId: contratoId, monto: 500,
          periodo: '2026-06', fechaVencimiento: '2026-06-05');

      final res = await repo.registrarCobroMultiple(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaIds: [c1, c2], montosCordobas: [500, 500], moneda: Moneda.nio,
          montosOriginal: [500, 500], tasaConversion: 1,
          metodo: MetodoPago.efectivo);

      final l1 = await opLogsDe('cuotas', c1);
      final l2 = await opLogsDe('cuotas', c2);
      expect(l1, hasLength(1));
      expect(l2, hasLength(1));
      // Mismo op_id = la intención multi-cobro las agrupa internamente.
      expect(l1.first['op_id'], l2.first['op_id']);
      expect(l1.first['op_id'], res.grupoCobro);
      // Cada cuota conserva SU recibo (no se pierde el correlativo por cuota).
      expect((diffDe(l1.first)['resumen'] as Map)['recibo'], 'A-00001');
      expect((diffDe(l2.first)['resumen'] as Map)['recibo'], 'A-00002');
    });

    test('anular un pago → op_log "anulacion_pago" en la cuota (restaura estado '
        'y saldo) además del log del cobro', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      final res = await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: cuotaId, montoCordobas: 500, moneda: Moneda.nio,
          montoOriginal: 500, tasaConversion: 1, metodo: MetodoPago.efectivo);

      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId,
          motivo: 'error de carga');

      final logs = await opLogsDe('cuotas', cuotaId);
      // Timeline append-only: el cobro + la anulación (no se borra el log viejo).
      expect(logs, hasLength(2));
      final anul = logs.firstWhere((l) => l['tipo_op'] == 'anulacion_pago');
      final diff = diffDe(anul);
      final campos = camposDe(diff);
      final estado = campos.firstWhere((c) => c['campo'] == 'estado');
      expect(estado['antes'], 'pagada');
      expect(estado['despues'], 'pendiente');
      final saldo = campos.firstWhere((c) => c['campo'] == 'saldo');
      expect((saldo['despues'] as num).toDouble(), 500);
      expect((diff['resumen'] as Map)['motivo'], 'error de carga');
    });

    test('editar el MONTO de un pago → op_log "edicion_pago" en la cuota '
        '(monto + estado + saldo antes→después, recibo en resumen)', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      // Cobro parcial 300 → cuota 'parcial'.
      final res = await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: cuotaId, montoCordobas: 300, moneda: Moneda.nio,
          montoOriginal: 300, tasaConversion: 1, metodo: MetodoPago.efectivo);

      // Subir el monto a 500 → cuota 'pagada'.
      await repo.editarPago(
          pagoId: res.pagoId, editadoPorId: cobradorId, montoCordobas: 500);

      final logs = await opLogsDe('cuotas', cuotaId);
      // Append-only: el cobro + la edición (no se borra el log del cobro).
      expect(logs, hasLength(2));
      final ed = logs.firstWhere((l) => l['tipo_op'] == 'edicion_pago');
      expect(ed['accion'], 'update');
      expect(ed['actor_id'], cobradorId);
      expect(ed['actor_label'], 'Cobrador Test');
      final diff = diffDe(ed);
      final campos = camposDe(diff);
      final monto = campos.firstWhere((c) => c['campo'] == 'monto');
      expect((monto['antes'] as num).toDouble(), 300);
      expect((monto['despues'] as num).toDouble(), 500);
      final estado = campos.firstWhere((c) => c['campo'] == 'estado');
      expect(estado['antes'], 'parcial');
      expect(estado['despues'], 'pagada');
      final saldo = campos.firstWhere((c) => c['campo'] == 'saldo');
      expect((saldo['antes'] as num).toDouble(), 200);
      expect((saldo['despues'] as num).toDouble(), 0);
      expect((diff['resumen'] as Map)['recibo'], 'A-00001');
    });

    test('editar SOLO método + notas (sin tocar el monto) → op_log con esos '
        'campos y SIN estado/saldo (la cuota no cambió)', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      final res = await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: cuotaId, montoCordobas: 500, moneda: Moneda.nio,
          montoOriginal: 500, tasaConversion: 1, metodo: MetodoPago.efectivo);

      await repo.editarPago(
        pagoId: res.pagoId, editadoPorId: cobradorId,
        metodo: MetodoPago.transferencia, notas: 'pasó a transferencia',
      );

      final logs = await opLogsDe('cuotas', cuotaId);
      final ed = logs.firstWhere((l) => l['tipo_op'] == 'edicion_pago');
      final campos = camposDe(diffDe(ed));
      final metodo = campos.firstWhere((c) => c['campo'] == 'metodo');
      expect(metodo['antes'], 'efectivo');
      expect(metodo['despues'], 'transferencia');
      final notas = campos.firstWhere((c) => c['campo'] == 'notas');
      expect(notas['despues'], 'pasó a transferencia');
      // No tocó la cuota → no hay estado/saldo en el diff.
      expect(campos.where((c) => c['campo'] == 'estado'), isEmpty);
      expect(campos.where((c) => c['campo'] == 'saldo'), isEmpty);
    });

    test('super_admin edita un pago → op_log con actor "System Admin" '
        '(actor_id NULL, no filtra su nombre real — diseño 0128)', () async {
      final saId = uuid.v4();
      await db.execute(
        'INSERT INTO cobradores (id, tenant_id, nombre, rol, prefijo_recibo, activo) '
        "VALUES (?, ?, 'Rubén Super', 'super_admin', 'SA', 1)",
        [saId, tenantId],
      );
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      final res = await repo.registrarCobro(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          cuotaId: cuotaId, montoCordobas: 300, moneda: Moneda.nio,
          montoOriginal: 300, tasaConversion: 1, metodo: MetodoPago.efectivo);

      // El super_admin (su uid) edita el pago → su nombre NO debe filtrarse.
      await repo.editarPago(
          pagoId: res.pagoId, editadoPorId: saId, montoCordobas: 500);

      final ed = (await opLogsDe('cuotas', cuotaId))
          .firstWhere((l) => l['tipo_op'] == 'edicion_pago');
      expect(ed['actor_id'], isNull);
      expect(ed['actor_label'], 'System Admin');
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // GRUPO — high-water mark del correlativo (audit 2026-06-11, finding #2)
  // ─────────────────────────────────────────────────────────────────────
  group('correlativo: high-water mark local (CorrelativoStore)', () {
    test(
        'anulación sincronizada que borra el último recibo local NO reusa '
        'el número ya impreso', () async {
      final contratoId = await seedContrato();
      final cuota1 = await seedCuota(contratoId: contratoId, monto: 500);
      final cuota2 = await seedCuota(contratoId: contratoId, monto: 500);

      final res1 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuota1,
        montoCordobas: 500,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      expect((await getReciboDePago(res1.pagoId))['correlativo'], 1);

      // El admin anula el recibo en el server: las sync rules (filtran
      // anulado = false) hacen que PowerSync BORRE la fila del SQLite del
      // cobrador. Lo simulamos con un DELETE local directo.
      await db.execute('DELETE FROM recibos WHERE id = ?', [res1.reciboId]);

      // Sin hwm: MAX(correlativo) local = 0 y el piso server es inalcanzable
      // (sin sesión Supabase, como offline) → se reusaría el #1 ya impreso.
      final res2 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuota2,
        montoCordobas: 500,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      final recibo2 = await getReciboDePago(res2.pagoId);
      expect(recibo2['correlativo'], 2,
          reason: 'reusar el #1 duplicaría el número impreso del cliente y '
              'el server rechazaría el INSERT (23505) descartando el recibo');
      expect(recibo2['numero_completo'], 'A-00002');
    });

    test('multi-cuota también persiste el hwm (no reusa tras borrado local)',
        () async {
      final contratoId = await seedContrato();
      final cuota1 = await seedCuota(contratoId: contratoId, monto: 500);
      final cuota2 = await seedCuota(contratoId: contratoId, monto: 500);
      final cuota3 = await seedCuota(contratoId: contratoId, monto: 500);

      final res = await repo.registrarCobroMultiple(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaIds: [cuota1, cuota2],
        montosCordobas: [500, 500],
        moneda: Moneda.nio,
        montosOriginal: [500, 500],
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      // Emitió #1 y #2; el sync remueve ambos (anulación masiva del admin).
      for (final rid in res.reciboIds!) {
        await db.execute('DELETE FROM recibos WHERE id = ?', [rid]);
      }

      final res2 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuota3,
        montoCordobas: 500,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      expect((await getReciboDePago(res2.pagoId))['correlativo'], 3);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // GRUPO — reversión de descuentos al anular (audit 2026-06-11, M3 + 0115)
  // ─────────────────────────────────────────────────────────────────────
  group('anularPago revierte los descuentos del cobro (mirror de 0115)', () {
    test('descuento pronto-pago del cobro anulado se BORRA y el total de la '
        'cuota se restaura', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      // Cobro con descuento automático de 100 → aplica 400 y queda pagada.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 400,
        moneda: Moneda.nio,
        montoOriginal: 400,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
        cargosAuto: [
          CargoAutoInfo(
            cuotaId: cuotaId,
            tipo: 'descuento_monto',
            monto: 100,
            descripcion: 'Descuento pronto pago',
          ),
        ],
      );
      var cuota = await getCuota(cuotaId);
      expect(cuota['estado'], 'pagada');
      expect(num2(cuota['cargos_neto']), -100);

      // El cargo quedó ligado al pago (0115).
      final cargos = await db.getAll(
          'SELECT origen, pago_id FROM cargos_extra WHERE cuota_id = ?',
          [cuotaId]);
      expect(cargos, hasLength(1));
      expect(cargos.first['origen'], 'cobro');
      expect(cargos.first['pago_id'], res.pagoId);

      // Anular: el descuento se borra; total restaurado a 500 y pendiente.
      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      expect(
          await db.getAll(
              'SELECT id FROM cargos_extra WHERE cuota_id = ?', [cuotaId]),
          isEmpty,
          reason: 'el descuento nació con este cobro: anularlo lo revierte');
      cuota = await getCuota(cuotaId);
      expect(cuota['estado'], 'pendiente');
      expect(num2(cuota['monto_pagado']), 0);
      expect(num2(cuota['cargos_neto']), 0);
    });

    test('la RECONEXIÓN del cobro anulado se PRESERVA (se sigue debiendo)',
        () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 600, // 500 + reconexión 100
        moneda: Moneda.nio,
        montoOriginal: 600,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
        cargosAuto: [
          CargoAutoInfo(
            cuotaId: cuotaId,
            tipo: 'reconexion',
            monto: 100,
            descripcion: 'Cargo por reconexión',
          ),
        ],
      );
      expect((await getCuota(cuotaId))['estado'], 'pagada');

      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      final cargos = await db.getAll(
          'SELECT tipo FROM cargos_extra WHERE cuota_id = ?', [cuotaId]);
      expect(cargos, hasLength(1));
      expect(cargos.first['tipo'], 'reconexion');
      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['cargos_neto']), 100); // la deuda de reconexión queda
      expect(cuota['estado'], 'pendiente');
    });

    test('descuento MANUAL diferido del cobro (rediseño 2026-06-11): viaja '
        'con pago_id + motivo, se revierte al anular; el cargo otro queda',
        () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      // El cobro inserta los pendientes de la pantalla: descuento manual
      // (con motivo) + cargo 'otro'. Total: 500 − 50 + 80 = 530.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 530,
        moneda: Moneda.nio,
        montoOriginal: 530,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
        cargosAuto: [
          CargoAutoInfo(
            cuotaId: cuotaId,
            tipo: 'descuento_monto',
            monto: 50,
            descripcion: 'Acuerdo con el cliente',
          ),
          CargoAutoInfo(
            cuotaId: cuotaId,
            tipo: 'otro',
            monto: 80,
            descripcion: 'Cambio de conector',
          ),
        ],
      );
      var cuota = await getCuota(cuotaId);
      expect(cuota['estado'], 'pagada');
      expect(num2(cuota['cargos_neto']), 30); // +80 − 50

      // Ambos quedaron ligados al pago, con su motivo.
      final cargos = await db.getAll(
          'SELECT tipo, origen, pago_id, descripcion FROM cargos_extra '
          'WHERE cuota_id = ? ORDER BY tipo',
          [cuotaId]);
      expect(cargos, hasLength(2));
      for (final c in cargos) {
        expect(c['origen'], 'cobro');
        expect(c['pago_id'], res.pagoId);
        expect((c['descripcion'] as String).isNotEmpty, isTrue);
      }

      // Anular: el descuento manual se revierte (ya no hay "fantasma");
      // el cargo 'otro' se preserva (se sigue debiendo, como reconexión).
      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      final restantes = await db.getAll(
          'SELECT tipo FROM cargos_extra WHERE cuota_id = ?', [cuotaId]);
      expect(restantes, hasLength(1));
      expect(restantes.first['tipo'], 'otro');
      cuota = await getCuota(cuotaId);
      expect(num2(cuota['monto_pagado']), 0);
      expect(num2(cuota['cargos_neto']), 80);
      expect(cuota['estado'], 'pendiente');
    });

    test('descuento histórico SIN pago_id no se toca al anular', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      // Cargo legacy (pre-0115): sin pago_id.
      await seedCargo(cuotaId: cuotaId, tipo: 'descuento_monto', monto: 50);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 450,
        moneda: Moneda.nio,
        montoOriginal: 450,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      expect(
          await db.getAll(
              'SELECT id FROM cargos_extra WHERE cuota_id = ?', [cuotaId]),
          hasLength(1),
          reason: 'el cargo legacy no nació de este cobro: se preserva');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // registrarCambioFecha — cambio de fecha de pago por días (feature C)
  // ───────────────────────────────────────────────────────────────────────
  group('registrarCambioFecha (cambio de fecha por días)', () {
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    // Fechas RELATIVAS a hoy: el filtro de re-fechado es `periodo >= mes actual`,
    // así que el escenario debe ser determinista corra cuando corra el test.
    final hoy = DateTime.now();
    final mesActual = DateTime(hoy.year, hoy.month, 1);
    final mes1 = DateTime(hoy.year, hoy.month + 1, 1);
    final mes2 = DateTime(hoy.year, hoy.month + 2, 1);
    final mes3 = DateTime(hoy.year, hoy.month + 3, 1);
    // "Pagado hasta" el 15 del mes actual (cuota host pagada).
    final pagadoHasta = DateTime(mesActual.year, mesActual.month, 15);

    Future<({String contratoId, String hostId})> seedEscenario(
        {int? duracionMeses}) async {
      final contratoId =
          await seedContrato(diaPago: 15, duracionMeses: duracionMeses);
      final hostId = await seedCuota(
        contratoId: contratoId, monto: 900, estado: 'pagada', montoPagado: 900,
        periodo: ymd(mesActual), fechaVencimiento: ymd(pagadoHasta),
      );
      for (final m in [mes1, mes2, mes3]) {
        await seedCuota(
          contratoId: contratoId, monto: 900,
          periodo: ymd(m),
          fechaVencimiento: ymd(DateTime(m.year, m.month, 15)),
        );
      }
      return (contratoId: contratoId, hostId: hostId);
    }

    test('salto corto (15→30) fijo: NO absorbe, re-fecha futuras, cobra el puente',
        () async {
      final esc = await seedEscenario(duracionMeses: 12);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 30, precioMensual: 900);
      expect(puente.montoPuente, greaterThan(0));

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 30, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), closeTo(puente.montoPuente, 0.001));
      expect(num2(pago['vuelto_cordobas']), 0);
      final recibo = await getReciboDePago(res.pagoId);
      expect(recibo['numero_completo'], 'A-00001');

      final host = await getCuota(esc.hostId);
      expect(host['estado'], 'pagada');
      expect(num2(host['cargos_neto']), closeTo(puente.montoPuente, 0.001));
      expect(num2(host['monto_pagado']), closeTo(900 + puente.montoPuente, 0.001));
      expect(num2(host['monto']), 900, reason: 'monto base NUNCA muta');

      final anuladas = await db.getAll(
          "SELECT id FROM cuotas WHERE contrato_id = ? AND estado = 'anulada'",
          [esc.contratoId]);
      expect(anuladas, isEmpty, reason: 'salto corto no absorbe');

      final futuras = await db.getAll(
          "SELECT fecha_vencimiento FROM cuotas WHERE contrato_id = ? AND estado = 'pendiente' ORDER BY date(periodo)",
          [esc.contratoId]);
      expect(futuras, hasLength(3));
      expect(futuras.first['fecha_vencimiento'], ymd(calcularFechaPago(mes1, 30)));

      final total = await db.getAll(
          'SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ?',
          [esc.contratoId]);
      expect((total.first['n'] as num).toInt(), 4, reason: 'sin cuota de cierre');

      final ct = await db
          .getAll('SELECT dia_pago FROM contratos WHERE id = ?', [esc.contratoId]);
      expect((ct.first['dia_pago'] as num).toInt(), 30);
    });

    test('salto que cruza de mes (15→10) fijo: absorbe 1 + agrega cuota de cierre',
        () async {
      final esc = await seedEscenario(duracionMeses: 12);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 10, precioMensual: 900);

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 10, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      expect(res.pagoId, isNotEmpty);

      final mes1Rows = await db.getAll(
          'SELECT estado, motivo_anulacion, anulada_por FROM cuotas WHERE contrato_id = ? AND periodo = ?',
          [esc.contratoId, ymd(mes1)]);
      expect(mes1Rows.first['estado'], 'anulada');
      expect(mes1Rows.first['anulada_por'], cobradorId);
      expect(mes1Rows.first['motivo_anulacion'], isNotNull);

      final mes2Rows = await db.getAll(
          'SELECT fecha_vencimiento FROM cuotas WHERE contrato_id = ? AND periodo = ?',
          [esc.contratoId, ymd(mes2)]);
      expect(mes2Rows.first['fecha_vencimiento'], ymd(calcularFechaPago(mes2, 10)));

      final mes4 = DateTime(mes3.year, mes3.month + 1, 1);
      final cierre = await db.getAll(
          'SELECT monto, estado FROM cuotas WHERE contrato_id = ? AND periodo = ?',
          [esc.contratoId, ymd(mes4)]);
      expect(cierre, hasLength(1), reason: 'cuota de cierre al final');
      expect(cierre.first['estado'], 'pendiente');
      expect(num2(cierre.first['monto']), 900);

      final activas = await db.getAll(
          "SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ? AND estado <> 'anulada' AND tipo_cargo_manual IS NULL",
          [esc.contratoId]);
      expect((activas.first['n'] as num).toInt(), 4,
          reason: 'absorbe 1 + agrega 1 → conteo activo intacto');

      final ct = await db.getAll(
          'SELECT dia_pago, fecha_fin FROM contratos WHERE id = ?',
          [esc.contratoId]);
      expect((ct.first['dia_pago'] as num).toInt(), 10);
      expect(ct.first['fecha_fin'], isNotNull);
    });

    test('indefinido: absorbe pero NO agrega cuota de cierre (fecha_fin queda null)',
        () async {
      final esc = await seedEscenario(duracionMeses: null);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 10, precioMensual: 900);

      await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 10, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final anuladas = await db.getAll(
          "SELECT id FROM cuotas WHERE contrato_id = ? AND estado = 'anulada'",
          [esc.contratoId]);
      expect(anuladas, hasLength(1));
      final total = await db.getAll(
          'SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ?',
          [esc.contratoId]);
      expect((total.first['n'] as num).toInt(), 4,
          reason: 'indefinido no agrega cierre');
      final ct = await db
          .getAll('SELECT fecha_fin FROM contratos WHERE id = ?', [esc.contratoId]);
      expect(ct.first['fecha_fin'], isNull);
    });

    test('vuelto: si entrega más que el puente, el resto es vuelto en C\$',
        () async {
      final esc = await seedEscenario(duracionMeses: 12);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 30, precioMensual: 900);

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 30, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente + 100,
        tasaConversion: 1, metodo: MetodoPago.efectivo,
      );
      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), closeTo(puente.montoPuente, 0.001));
      expect(num2(pago['vuelto_cordobas']), closeTo(100, 0.001));
      // Invariante #3: entregado × tasa ≈ aplicado + vuelto.
      expect(num2(pago['monto_original']) * num2(pago['tasa_conversion']),
          closeTo(num2(pago['monto_cordobas']) + num2(pago['vuelto_cordobas']), 0.01));
    });

    test('1 mes en mora: cobra la cuota vencida + puente en UN solo recibo',
        () async {
      final mesPrev = DateTime(hoy.year, hoy.month - 1, 1);
      final contratoId = await seedContrato(diaPago: 15, duracionMeses: 12);
      await seedCuota(
        contratoId: contratoId, monto: 900, estado: 'pagada', montoPagado: 900,
        periodo: ymd(mesPrev),
        fechaVencimiento: ymd(DateTime(mesPrev.year, mesPrev.month, 15)),
      );
      // 1 cuota vencida (mes actual). Venció hace 3 días en hora LOCAL (no
      // `.toUtc()`): el repo evalúa vencidas con `date('now','-6h')` (Nicaragua);
      // `.toUtc().subtract(1d)` daba "ayer-UTC" = "hoy-Nicaragua" de tarde y la
      // cuota dejaba de contar como vencida (flake horaria). El margen de 3 días
      // la deja vencida sin ambigüedad a cualquier hora.
      final vencio = DateTime.now().subtract(const Duration(days: 3));
      final vencidaId = await seedCuota(
        contratoId: contratoId, monto: 900,
        periodo: ymd(mesActual), fechaVencimiento: ymd(vencio),
      );

      // pagado-hasta = día 15 del mes actual (período de la vencida) → puente al 30.
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: DateTime(mesActual.year, mesActual.month, 15),
          diaNuevo: 30, precioMensual: 900);
      final total = 900 + puente.montoPuente; // cuota + puente

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: contratoId, diaNuevo: 30, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: total, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      // UN solo recibo; el pago entra a caja por cuota + puente.
      expect(await db.getAll('SELECT id FROM recibos'), hasLength(1));
      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), closeTo(total, 0.01));
      expect(num2(pago['vuelto_cordobas']), 0);
      // La cuota vencida quedó pagada: monto_pagado = cuota+puente; cargos_neto = puente.
      final vencida = await getCuota(vencidaId);
      expect(vencida['estado'], 'pagada');
      expect(num2(vencida['cargos_neto']), closeTo(puente.montoPuente, 0.01));
      expect(num2(vencida['monto_pagado']), closeTo(total, 0.01));
      expect(num2(vencida['monto']), 900, reason: 'la base de la cuota no muta');
      final ct = await db.getAll(
          'SELECT dia_pago FROM contratos WHERE id = ?', [contratoId]);
      expect((ct.first['dia_pago'] as num).toInt(), 30);
    });

    test('2+ cuotas vencidas: bloquea (sería cobro multi-cuota + puente)',
        () async {
      final mesP1 = DateTime(hoy.year, hoy.month - 1, 1);
      final mesP2 = DateTime(hoy.year, hoy.month - 2, 1);
      final contratoId = await seedContrato(diaPago: 15, duracionMeses: 12);
      await seedCuota(
        contratoId: contratoId, monto: 900, estado: 'pagada', montoPagado: 900,
        periodo: ymd(DateTime(hoy.year, hoy.month - 3, 1)),
        fechaVencimiento: ymd(DateTime(hoy.year, hoy.month - 3, 15)),
      );
      // 2 cuotas vencidas (meses -2 y -1, vencidas).
      await seedCuota(
        contratoId: contratoId, monto: 900,
        periodo: ymd(mesP2), fechaVencimiento: ymd(DateTime(mesP2.year, mesP2.month, 15)),
      );
      await seedCuota(
        contratoId: contratoId, monto: 900,
        periodo: ymd(mesP1), fechaVencimiento: ymd(DateTime(mesP1.year, mesP1.month, 15)),
      );

      await expectLater(
        repo.registrarCambioFecha(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          contratoId: contratoId, diaNuevo: 30, precioMensual: 900,
          moneda: Moneda.nio, montoOriginal: 5000, tasaConversion: 1,
          metodo: MetodoPago.efectivo,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await db.getAll('SELECT id FROM pagos'), isEmpty);
      expect(await db.getAll('SELECT id FROM recibos'), isEmpty);
    });

    test('cuota que vence HOY no cuenta como vencida → al día (no 1-mora)',
        () async {
      // hoy local Nicaragua = UTC-6h (igual que date('now','-6 hours')).
      final hoyNic = DateTime.now().toUtc().subtract(const Duration(hours: 6));
      final dia = hoyNic.day;
      final diaNuevo = dia < 27 ? dia + 2 : dia - 2; // ≠ dia, válido
      final mesPrev = DateTime(hoyNic.year, hoyNic.month - 1, 1);
      final contratoId =
          await seedContrato(diaPago: dia, duracionMeses: null);
      final paidId = await seedCuota(
        contratoId: contratoId, monto: 900, estado: 'pagada', montoPagado: 900,
        periodo: ymd(mesPrev),
        fechaVencimiento: ymd(DateTime(mesPrev.year, mesPrev.month, dia)),
      );
      // Cuota que vence HOY (pendiente, no vencida).
      final hoyId = await seedCuota(
        contratoId: contratoId, monto: 900,
        periodo: ymd(DateTime(hoyNic.year, hoyNic.month, 1)),
        fechaVencimiento: ymd(hoyNic),
      );

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: contratoId, diaNuevo: diaNuevo, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: 2000, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      // No bloqueó (la de hoy NO es vencida) y fue al día: el puente cuelga de
      // la última PAGADA (mesPrev), no de la cuota de hoy.
      expect(res.pagoId, isNotEmpty);
      final paid = await getCuota(paidId);
      expect(num2(paid['cargos_neto']), greaterThan(0),
          reason: 'al día → puente sobre la última pagada');
      final hoy = await getCuota(hoyId);
      expect(hoy['estado'], isNot('pagada'),
          reason: 'la cuota que vence hoy NO se cobró (no es la host de 1-mora)');
    });

    test('fix #4: pagadoHasta usa el día nominal (periodo+dia_pago), no la venc shifteada',
        () async {
      // Host con fecha_vencimiento DISTINTA del día nominal (simula el ajuste
      // domingo→lunes u otra divergencia): dia_pago=20 pero la venc quedó en el
      // día 10. pagadoHasta debe salir del nominal (20), no de la venc (10).
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: null);
      await seedCuota(
        contratoId: contratoId, monto: 900, estado: 'pagada', montoPagado: 900,
        periodo: ymd(mesActual),
        fechaVencimiento: ymd(DateTime(mesActual.year, mesActual.month, 10)),
      );
      for (final m in [mes1, mes2]) {
        await seedCuota(
          contratoId: contratoId, monto: 900,
          periodo: ymd(m),
          fechaVencimiento: ymd(DateTime(m.year, m.month, 20)),
        );
      }

      // Nominal: pagadoHasta=20 del mes actual → al 25 = 5 días de puente.
      // (Usar la venc shifteada=10 daría ~15 días → un puente ~3× mayor.)
      final esperado = calcularPuenteCambioFecha(
          pagadoHasta: DateTime(mesActual.year, mesActual.month, 20),
          diaNuevo: 25, precioMensual: 900);
      expect(esperado.diasPuente, 5);

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: contratoId, diaNuevo: 25, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: esperado.montoPuente,
        tasaConversion: 1, metodo: MetodoPago.efectivo,
      );
      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), closeTo(esperado.montoPuente, 0.01),
          reason: 'puente de 5 días (nominal), no ~15 días de la venc shifteada');
    });

    test('fix #5: cambiar al MISMO día de pago lanza y no escribe nada', () async {
      final esc = await seedEscenario(duracionMeses: 12); // dia_pago = 15
      await expectLater(
        repo.registrarCambioFecha(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          contratoId: esc.contratoId, diaNuevo: 15, precioMensual: 900,
          moneda: Moneda.nio, montoOriginal: 1000, tasaConversion: 1,
          metodo: MetodoPago.efectivo,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await db.getAll('SELECT id FROM pagos'), isEmpty);
    });

    test('op_log: cambio de fecha (15→10, fijo) emite 1 entrada por OBJETO con '
        'el MISMO op_id (contrato + host + absorbida + re-fechadas + cierre)',
        () async {
      final esc = await seedEscenario(duracionMeses: 12);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 10, precioMensual: 900);

      await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 10, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      Future<List<Map<String, dynamic>>> oplog(String e, String id) =>
          db.getAll(
              'SELECT * FROM op_log WHERE entidad = ? AND entidad_id = ?',
              [e, id]);
      Map<String, dynamic> diff(Map<String, dynamic> l) =>
          jsonDecode(l['diff'] as String) as Map<String, dynamic>;
      List<Map<String, dynamic>> campos(Map<String, dynamic> d) =>
          (d['campos'] as List).cast<Map<String, dynamic>>();
      Future<String> cuotaPorPeriodo(String periodo) async {
        final r = await db.getAll(
            'SELECT id FROM cuotas WHERE contrato_id = ? AND periodo = ?',
            [esc.contratoId, periodo]);
        return r.first['id'] as String;
      }

      // 1) Contrato: dia_pago 15 → 10.
      final ctLogs = await oplog('contratos', esc.contratoId);
      expect(ctLogs, hasLength(1));
      expect(ctLogs.first['tipo_op'], 'cambio_fecha');
      final opId = ctLogs.first['op_id'] as String;
      final dia = campos(diff(ctLogs.first))
          .firstWhere((c) => c['campo'] == 'dia_pago');
      expect((dia['antes'] as num).toInt(), 15);
      expect((dia['despues'] as num).toInt(), 10);

      // 2) Host: recibió el cobro del puente (recibo en el resumen).
      final hostLogs = await oplog('cuotas', esc.hostId);
      expect(hostLogs, hasLength(1));
      expect(hostLogs.first['op_id'], opId);
      expect((diff(hostLogs.first)['resumen'] as Map)['recibo'], 'A-00001');

      // 3) Absorbida (mes1): estado pendiente → anulada.
      final absLogs = await oplog('cuotas', await cuotaPorPeriodo(ymd(mes1)));
      expect(absLogs, hasLength(1));
      expect(absLogs.first['op_id'], opId);
      expect(
          campos(diff(absLogs.first))
              .firstWhere((c) => c['campo'] == 'estado')['despues'],
          'anulada');

      // 4) Re-fechada (mes2): fecha_vencimiento al día nuevo.
      final refLogs = await oplog('cuotas', await cuotaPorPeriodo(ymd(mes2)));
      expect(refLogs, hasLength(1));
      expect(refLogs.first['op_id'], opId);
      expect(
          campos(diff(refLogs.first))
              .firstWhere((c) => c['campo'] == 'fecha_vencimiento')['despues'],
          ymd(calcularFechaPago(mes2, 10)));

      // 5) Cierre (cuota nueva al final): alta (accion create).
      final mes4 = DateTime(mes3.year, mes3.month + 1, 1);
      final cierreLogs =
          await oplog('cuotas', await cuotaPorPeriodo(ymd(mes4)));
      expect(cierreLogs, hasLength(1));
      expect(cierreLogs.first['op_id'], opId);
      expect(cierreLogs.first['accion'], 'create');

      // Toda la intención comparte el op_id: contrato + host + absorbida +
      // 2 re-fechadas + cierre = 6 entradas (1 por objeto, no fan-out por fila).
      final todas =
          await db.getAll('SELECT id FROM op_log WHERE op_id = ?', [opId]);
      expect(todas, hasLength(6));
    });
  });

  // ── fetchCargosCuotas: scope del puente por pago_id ─────────────────────
  // El recibo debe mostrar SOLO el/los puente(s) del pago de ESE recibo, no
  // todos los puentes acumulados en la cuota por varios cambios de fecha.
  group('fetchCargosCuotas — scope del puente en el recibo', () {
    test('solo el puente del pago del recibo; descuentos siempre', () async {
      ps.db = db; // fetchCargosCuotas usa el global `ps.db`
      final cuotaId = uuid.v4();
      // 2 puentes de 2 cambios de fecha distintos + 1 descuento (sin pago).
      await seedCargo(
          cuotaId: cuotaId, tipo: 'otro', monto: 258.06,
          origen: 'puente', pagoId: 'pago-1');
      await seedCargo(
          cuotaId: cuotaId, tipo: 'otro', monto: 425.81,
          origen: 'puente', pagoId: 'pago-2');
      await seedCargo(
          cuotaId: cuotaId, tipo: 'descuento_monto', monto: 50,
          origen: 'ajuste');

      // Recibo del pago-2: descuento + SOLO el puente de pago-2.
      final p2 = await fetchCargosCuotas([cuotaId], pagoIds: ['pago-2']);
      final puentesP2 = p2.where((c) => c['origen'] == 'puente').toList();
      expect(puentesP2, hasLength(1));
      expect(num2(puentesP2.first['monto']), closeTo(425.81, 0.001));
      expect(p2.any((c) => c['origen'] == 'ajuste'), isTrue,
          reason: 'el descuento (pago_id NULL) se muestra siempre');

      // Sin pagoIds: ningún puente (solo el descuento).
      final sinPago = await fetchCargosCuotas([cuotaId]);
      expect(sinPago.where((c) => c['origen'] == 'puente'), isEmpty);
      expect(sinPago, hasLength(1));
    });
  });

  // ── ContratosRepo.suspenderContrato (Feature A) ─────────────────────────
  group('ContratosRepo.suspenderContrato', () {
    test('fijo: anula futuras, prorratea el mes en curso, deja mora previa y pagadas', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      // Abril pendiente (mora previa), Mayo pagada, Junio pendiente (mes en curso),
      // Julio + Agosto pendientes (futuras).
      final abr = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-04-01',
          fechaVencimiento: '2026-04-20');
      final may = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-05-01',
          fechaVencimiento: '2026-05-20', estado: 'pagada', montoPagado: 900);
      final jun = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20');
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20');
      final ago = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-08-01',
          fechaVencimiento: '2026-08-20');

      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900,
        motivo: 'Solicitud del cliente', notas: 'viaje 2 meses',
      );

      // Contrato suspendido.
      final c = await db.getAll('SELECT estado FROM contratos WHERE id = ?', [contratoId]);
      expect(c.first['estado'], 'suspendido');

      // Mora previa (abril) y pagada (mayo): intactas.
      expect((await getCuota(abr))['estado'], 'pendiente');
      expect(num2((await getCuota(abr))['monto']), 900);
      expect((await getCuota(may))['estado'], 'pagada');
      expect(num2((await getCuota(may))['monto']), 900);

      // Mes EN CURSO (junio, ventana de servicio 20-may→20-jun con día_pago 20):
      // se prorratean los días consumidos del CICLO (20-may→10-jun = 21 días),
      // NO el mes calendario. = 11 días de mayo (900/31) + 10 de junio (900/30)
      // = 319.35 + 300 = 619.35.
      final jc = await getCuota(jun);
      expect(jc['estado'], 'pendiente');
      expect(num2(jc['monto']), closeTo(619.35, 0.01));

      // Futuras (julio, agosto): servicio aún no empezado → anuladas.
      for (final id in [jul, ago]) {
        final q = await getCuota(id);
        expect(q['estado'], 'anulada');
        expect(q['motivo_anulacion'], 'Suspensión temporal');
      }

      // Fila de suspensión + snapshot de deuda sobreviviente (abr 900 + jun 619.35).
      final susp = await db.getAll(
          'SELECT * FROM contrato_suspensiones WHERE contrato_id = ?', [contratoId]);
      expect(susp, hasLength(1));
      expect(susp.first['motivo'], 'Solicitud del cliente');
      expect(susp.first['notas'], 'viaje 2 meses');
      expect(susp.first['suspendido_por'], cobradorId);
      expect(susp.first['reactivado_en'], isNull);
      final snap = jsonDecode(susp.first['deuda_snapshot'] as String) as Map<String, dynamic>;
      expect((snap['total'] as num).toDouble(), closeTo(1519.35, 0.01));
      expect(snap['cuotas'] as List, hasLength(2));
    });

    test('mes en curso PARCIAL: prorratea con clamp y conserva el abono', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      // Junio (mes en curso) con un abono parcial de 200 sobre 900.
      final jun = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20', estado: 'parcial', montoPagado: 200);
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'Viaje',
      );
      // Ventana de servicio 20-may→20-jun (día_pago 20); prorrateo 20-may→10-jun
      // = 21 días = 619.35; abonó 200 → saldo 419.35, sigue parcial.
      final jc = await getCuota(jun);
      expect(jc['estado'], 'parcial');
      expect(num2(jc['monto']), closeTo(619.35, 0.01));
      expect(num2(jc['monto_pagado']), 200, reason: 'el pago no se toca');
      // El snapshot refleja el MISMO saldo cobrable (419.35).
      final susp = await db.getAll(
          'SELECT deuda_snapshot FROM contrato_suspensiones WHERE contrato_id = ?',
          [contratoId]);
      final snap = jsonDecode(susp.first['deuda_snapshot'] as String) as Map<String, dynamic>;
      expect((snap['total'] as num).toDouble(), closeTo(419.35, 0.01));
      // Snapshot enriquecido para el desglose del diálogo/PDF: dia_pago + por-cuota.
      expect((snap['dia_pago'] as num).toInt(), 20);
      final junSnap = (snap['cuotas'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((e) => (e['periodo'] as String).startsWith('2026-06'));
      expect(num2(junSnap['monto_pagado']), 200);
      expect(junSnap['fecha_vencimiento'], isNotNull);
    });

    test('mes en curso PARCIAL sobre-abonado: queda saldada sin reembolso', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      // Abonó 700; el prorrateo del ciclo (20-may→10-jun = 21 días) es 619.35
      // → el abono ya lo cubre → queda saldada, sin reembolso de la diferencia.
      final jun = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20', estado: 'parcial', montoPagado: 700);
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'Viaje',
      );
      final jc = await getCuota(jun);
      expect(jc['estado'], 'pagada', reason: 'el abono cubre el prorrateo');
      expect(num2(jc['monto']), closeTo(700, 0.01), reason: 'clamp al pago, sin reembolso');
      expect(num2(jc['monto_pagado']), 700);
      // Saldo 0 → no entra al snapshot de deuda.
      final susp = await db.getAll(
          'SELECT deuda_snapshot FROM contrato_suspensiones WHERE contrato_id = ?',
          [contratoId]);
      final snap = jsonDecode(susp.first['deuda_snapshot'] as String) as Map<String, dynamic>;
      expect((snap['total'] as num).toDouble(), closeTo(0, 0.01));
    });

    test('futura PARCIAL sobrevive a la suspensión y entra al snapshot', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      // Junio (mes en curso) — se prorratea al suspender; su id no se usa acá.
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20');
      // Julio (futura) con adelanto parcial de 400.
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20', estado: 'parcial', montoPagado: 400);
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'Viaje',
      );
      // Julio NO se anula (tiene pago) → sigue parcial con su saldo (500).
      final jq = await getCuota(jul);
      expect(jq['estado'], 'parcial', reason: 'la parcial futura sobrevive, no se anula');
      expect(num2(jq['monto_pagado']), 400);
      // El snapshot la incluye (jun en curso prorrateado 21 días = 619.35 +
      // jul futura parcial saldo 500 = 1119.35).
      final susp = await db.getAll(
          'SELECT deuda_snapshot FROM contrato_suspensiones WHERE contrato_id = ?',
          [contratoId]);
      final snap = jsonDecode(susp.first['deuda_snapshot'] as String) as Map<String, dynamic>;
      expect((snap['total'] as num).toDouble(), closeTo(1119.35, 0.01));
      expect(snap['cuotas'] as List, hasLength(2));
    });

    test('guard: no se puede suspender un contrato no activo', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20');
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'X',
      );
      // Segundo intento: ya está suspendido → lanza, no muta.
      await expectLater(
        repo.suspenderContrato(
          tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
          fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'X',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── ContratosRepo.cambiarPlan (feature contract-new-feature, modo Próximo ciclo)
  group('ContratosRepo.cambiarPlan', () {
    Future<String> seedPlan(double precio) async {
      final id = uuid.v4();
      await db.execute(
        'INSERT INTO planes (id, tenant_id, nombre, tipo, precio_mensual, activo, created_at) '
        "VALUES (?, ?, 'Plan Nuevo', 'fijo', ?, 1, ?)",
        [id, tenantId, precio, _now()],
      );
      return id;
    }

    Future<double> montoDe(String id) async => ((await db.getAll(
            'SELECT monto FROM cuotas WHERE id = ?', [id]))
        .first['monto'] as num)
        .toDouble();

    test('Próximo ciclo: re-valúa SOLO las futuras; no toca cumplida/en-curso; cambia plan_id', () async {
      final planNuevoId = await seedPlan(800);
      final contratoId = await seedContrato(diaPago: 15, duracionMeses: 12);
      // hoy = 25-jun, día_pago 15 → jun=cumplido(pagada), jul=en_curso, ago/sep=futuro.
      final jun = await seedCuota(
          contratoId: contratoId, periodo: '2026-06', monto: 500,
          estado: 'pagada', montoPagado: 500);
      final jul = await seedCuota(contratoId: contratoId, periodo: '2026-07', monto: 500);
      final ago = await seedCuota(contratoId: contratoId, periodo: '2026-08', monto: 500);
      final sep = await seedCuota(contratoId: contratoId, periodo: '2026-09', monto: 500);

      await ContratosRepo(db: db).cambiarPlan(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        planNuevoId: planNuevoId, precioNuevo: 800, hoy: DateTime(2026, 6, 25),
      );

      expect(await montoDe(jun), 500, reason: 'cumplida no se toca');
      expect(await montoDe(jul), 500, reason: 'en curso no se toca (Próximo ciclo)');
      expect(await montoDe(ago), 800, reason: 'futura → precio nuevo');
      expect(await montoDe(sep), 800, reason: 'futura → precio nuevo');

      final plan = (await db.getAll(
          'SELECT plan_id FROM contratos WHERE id = ?', [contratoId])).first['plan_id'];
      expect(plan, planNuevoId);

      // op_log: 1 fila por cuota re-valuada (ago, sep) + 1 del contrato.
      final ops = await db.getAll(
          "SELECT entidad FROM op_log WHERE tipo_op = 'cambio_plan'");
      expect(ops.length, 3);
    });

    test('clampa la re-valuación a >= lo pagado (no viola monto_pagado<=monto)', () async {
      final planNuevoId = await seedPlan(300); // downgrade
      final contratoId = await seedContrato(diaPago: 15, duracionMeses: 12);
      // futura con abono parcial 450 > precio nuevo 300 → queda en 450 (clamp).
      final ago = await seedCuota(
          contratoId: contratoId, periodo: '2026-08', monto: 500,
          estado: 'pendiente', montoPagado: 450);
      await ContratosRepo(db: db).cambiarPlan(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        planNuevoId: planNuevoId, precioNuevo: 300, hoy: DateTime(2026, 6, 25),
      );
      expect(await montoDe(ago), 450, reason: 'no baja debajo de lo pagado');
    });

    test('bloquea si el cliente ya tiene OTRO contrato activo en el plan destino', () async {
      final planNuevoId = await seedPlan(800);
      final c1 = await seedContrato(diaPago: 15, duracionMeses: 12);
      await db.execute(
        'INSERT INTO contratos (id, tenant_id, cliente_id, cobrador_id, plan_id, '
        "dia_pago, estado, created_at) VALUES (?, ?, ?, ?, ?, 15, 'activo', ?)",
        [uuid.v4(), tenantId, clienteId, cobradorId, planNuevoId, _now()],
      );
      expect(
        () => ContratosRepo(db: db).cambiarPlan(
            tenantId: tenantId, contratoId: c1, cobradorId: cobradorId,
            planNuevoId: planNuevoId, precioNuevo: 800, hoy: DateTime(2026, 6, 25)),
        throwsA(isA<StateError>()),
      );
    });

    test('Hoy upgrade: cargo de la diferencia en la cuota en curso + re-valúa futuras', () async {
      final planNuevoId = await seedPlan(800);
      final contratoId = await seedContrato(diaPago: 15, duracionMeses: 12);
      // hoy 25-jun, día_pago 15 → jul = en curso (host), ago = futura.
      final jul = await seedCuota(contratoId: contratoId, periodo: '2026-07', monto: 500);
      final ago = await seedCuota(contratoId: contratoId, periodo: '2026-08', monto: 500);
      await ContratosRepo(db: db).cambiarPlan(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        planNuevoId: planNuevoId, precioNuevo: 800, hoy: DateTime(2026, 6, 25),
        modoHoy: true, precioViejo: 500,
      );
      // La cuota en curso recibe un cargo = diferencia prorrateada de los 20 días
      // (5×300/30 + 15×300/31 = 195.16).
      final cargosNetoJul = ((await db.getAll(
              'SELECT cargos_neto FROM cuotas WHERE id = ?', [jul]))
          .first['cargos_neto'] as num)
          .toDouble();
      expect(cargosNetoJul, closeTo(195.16, 0.02));
      final cargos =
          await db.getAll('SELECT monto FROM cargos_extra WHERE cuota_id = ?', [jul]);
      expect(cargos.length, 1);
      expect(await montoDe(ago), 800, reason: 'futura re-valuada');
    });

    test('Hoy downgrade: acredita la diferencia en saldos_favor (no toca pagos ni la cuota)', () async {
      final planNuevoId = await seedPlan(300);
      final contratoId = await seedContrato(diaPago: 15, duracionMeses: 12);
      final jul = await seedCuota(contratoId: contratoId, periodo: '2026-07', monto: 500);
      await ContratosRepo(db: db).cambiarPlan(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        planNuevoId: planNuevoId, precioNuevo: 300, hoy: DateTime(2026, 6, 25),
        modoHoy: true, precioViejo: 500,
      );
      final sf = await db.getAll(
          "SELECT monto FROM saldos_favor WHERE tipo = 'acreditado'");
      expect(sf.length, 1);
      expect((sf.first['monto'] as num).toDouble(), closeTo(130.11, 0.02));
      // La cuota en curso NO se modifica (downgrade no baja una cuota; va a crédito).
      expect(await montoDe(jul), 500);
      final cargos =
          await db.getAll('SELECT 1 FROM cargos_extra WHERE cuota_id = ?', [jul]);
      expect(cargos.length, 0);
    });
  });

  // ── ContratosRepo.reactivarContrato (Feature A) ─────────────────────────
  group('ContratosRepo.reactivarContrato', () {
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    test('fijo: revive desde el mes de reactivación hasta fecha_fin, deja el gap anulado', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(
          diaPago: 15, duracionMeses: 12, fechaFin: '2026-10-31');
      final jun = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-15');
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-15');
      final ago = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-08-01',
          fechaVencimiento: '2026-08-15');
      final sep = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-09-01',
          fechaVencimiento: '2026-09-15');
      final oct = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-10-01',
          fechaVencimiento: '2026-10-15');

      // Suspender el 10-jun: junio EN CURSO (ventana 15-may→15-jun) se prorratea
      // a los 26 días consumidos (15-may→10-jun) = 764.52; jul..oct se anulan.
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'Viaje',
      );
      // Reactivar el 8-sep (reinicio limpio): con facturación vencida el 1er ciclo
      // facturado arranca el 8-sep y su cuota vence el mes SIGUIENTE → revive sólo
      // OCT (período >= oct = mesR+1); jul, ago y SEP quedan anuladas (servicio
      // de la pausa, no se cobra).
      await repo.reactivarContrato(
        contratoId: contratoId, cobradorId: cobradorId,
        fechaReactivacion: DateTime(2026, 9, 8), precioMensual: 900,
      );

      // Contrato activo, día re-anclado a 8, fecha_fin intacta.
      final c = await db.getAll(
          'SELECT estado, dia_pago, fecha_fin FROM contratos WHERE id = ?', [contratoId]);
      expect(c.first['estado'], 'activo');
      expect((c.first['dia_pago'] as num).toInt(), 8);
      expect(c.first['fecha_fin'], '2026-10-31', reason: 'la fecha fin NO se estira');

      // Sólo OCT revive (período >= oct = mesR+1): pendiente, monto completo,
      // venc re-fechada con el día nuevo.
      final qOct = await getCuota(oct);
      expect(qOct['estado'], 'pendiente');
      expect(num2(qOct['monto']), 900);
      expect(qOct['fecha_vencimiento'], ymd(calcularFechaPago(DateTime(2026, 10, 1), 8)));
      expect(qOct['anulada_en'], isNull);

      // Jul, ago y SEP: el gap suspendido queda anulado (servicio en la pausa).
      expect((await getCuota(jul))['estado'], 'anulada');
      expect((await getCuota(ago))['estado'], 'anulada');
      expect((await getCuota(sep))['estado'], 'anulada');

      // Junio: prorrateada (ventana 15-may→15-jun, 26 días = 764.52), intacta.
      final jc = await getCuota(jun);
      expect(jc['estado'], 'pendiente');
      expect(num2(jc['monto']), closeTo(764.52, 0.01));

      // Suspensión cerrada.
      final susp = await db.getAll(
          'SELECT reactivado_en, reactivado_por FROM contrato_suspensiones WHERE contrato_id = ?',
          [contratoId]);
      expect(susp.first['reactivado_en'], isNotNull);
      expect(susp.first['reactivado_por'], cobradorId);
    });

    test('indefinido: al reactivar genera el colchón de 3 cuotas desde mesR+1 '
        '(sin fecha_fin)', () async {
      final repo = ContratosRepo(db: db);
      // Indefinido: duración null → fecha_fin null.
      final contratoId = await seedContrato(diaPago: 15);
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-15');
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-15');
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-08-01',
          fechaVencimiento: '2026-08-15');

      // Suspender el 10-jun (jul/ago futuras se anulan; junio se prorratea).
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900,
        motivo: 'Viaje',
      );
      // Reactivar el 8-sep → primer ciclo a facturar = oct. El indefinido debe
      // arrancar con el colchón de 3: oct, nov, dic.
      await repo.reactivarContrato(
        contratoId: contratoId, cobradorId: cobradorId,
        fechaReactivacion: DateTime(2026, 9, 8), precioMensual: 900,
      );

      // Contrato activo, día re-anclado a 8, SIGUE indefinido (fecha_fin null).
      final c = await db.getAll(
          'SELECT estado, dia_pago, fecha_fin FROM contratos WHERE id = ?',
          [contratoId]);
      expect(c.first['estado'], 'activo');
      expect((c.first['dia_pago'] as num).toInt(), 8);
      expect(c.first['fecha_fin'], isNull,
          reason: 'indefinido: nunca se le setea fecha_fin');

      // Colchón de 3 desde oct (mesR+1): pendiente, monto completo, venc día 8.
      for (final periodo in [
        DateTime(2026, 10, 1),
        DateTime(2026, 11, 1),
        DateTime(2026, 12, 1),
      ]) {
        final q = await db.getAll(
            'SELECT estado, monto, fecha_vencimiento FROM cuotas '
            'WHERE contrato_id = ? AND date(periodo) = date(?)',
            [contratoId, ymd(periodo)]);
        expect(q.length, 1, reason: 'existe la cuota de colchón ${ymd(periodo)}');
        expect(q.first['estado'], 'pendiente');
        expect(num2(q.first['monto']), 900);
        expect(q.first['fecha_vencimiento'], ymd(calcularFechaPago(periodo, 8)));
      }
    });

    test('guard: no se puede reactivar un contrato que no está suspendido', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 15, duracionMeses: 12);
      await expectLater(
        repo.reactivarContrato(
          contratoId: contratoId, cobradorId: cobradorId,
          fechaReactivacion: DateTime(2026, 9, 8), precioMensual: 900,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('guard: reactivar el MISMO día de la suspensión lanza (usar Revertir); un día después SÍ', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(
          diaPago: 15, duracionMeses: 12, fechaFin: '2026-10-31');
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-15');
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'X',
      );
      // Mismo día (10-jun) → debe lanzar (nada pasó → Revertir).
      await expectLater(
        repo.reactivarContrato(
          contratoId: contratoId, cobradorId: cobradorId,
          fechaReactivacion: DateTime(2026, 6, 10), precioMensual: 900,
        ),
        throwsA(isA<StateError>()),
      );
      // Un día después (11-jun) sí se puede (mismo mes, ya permitido).
      await repo.reactivarContrato(
        contratoId: contratoId, cobradorId: cobradorId,
        fechaReactivacion: DateTime(2026, 6, 11), precioMensual: 900,
      );
      final c = await db.getAll(
          'SELECT estado, dia_pago FROM contratos WHERE id = ?', [contratoId]);
      expect(c.first['estado'], 'activo');
      expect((c.first['dia_pago'] as num).toInt(), 11);
    });

    test('mismo mes, suspendido ANTES del día de pago: corte intacto + revive desde la reactivación', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(
          diaPago: 20, duracionMeses: 12, fechaFin: '2027-05-31');
      final jun = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20');
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20');
      final ago = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-08-01',
          fechaVencimiento: '2026-08-20');
      // Suspender 10-jun (antes del día 20): junio en_curso → prorrateada (619.35);
      // jul/ago futuras → anuladas.
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'Viaje',
      );
      // Reactivar el 25-jun (MISMO mes) — ahora permitido.
      await repo.reactivarContrato(
        contratoId: contratoId, cobradorId: cobradorId,
        fechaReactivacion: DateTime(2026, 6, 25), precioMensual: 900,
      );
      final c = await db.getAll(
          'SELECT estado, dia_pago FROM contratos WHERE id = ?', [contratoId]);
      expect(c.first['estado'], 'activo');
      expect((c.first['dia_pago'] as num).toInt(), 25);
      // Junio: corte prorrateado intacto.
      final jc = await getCuota(jun);
      expect(jc['estado'], 'pendiente');
      expect(num2(jc['monto']), closeTo(619.35, 0.01));
      // Julio/agosto: revividas COMPLETAS, venc re-fechado al 25 (no sub-cobro).
      final jlc = await getCuota(jul);
      expect(jlc['estado'], 'pendiente');
      expect(num2(jlc['monto']), 900);
      expect(jlc['fecha_vencimiento'],
          ymd(calcularFechaPago(DateTime(2026, 7, 1), 25)));
      expect((await getCuota(ago))['fecha_vencimiento'],
          ymd(calcularFechaPago(DateTime(2026, 8, 1), 25)));
    });

    test('mismo mes, suspendido DESPUÉS del día de pago (sub-caso 4): la cuota de corte se RE-COMPLETA', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(
          diaPago: 20, duracionMeses: 12, fechaFin: '2027-05-31');
      final jun = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20');
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20');
      final ago = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-08-01',
          fechaVencimiento: '2026-08-20');
      // Suspender 25-jun (DESPUÉS del día 20): junio cumplido entera; julio en_curso
      // prorrateada (20→25 jun = 150); agosto futura → anulada.
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 25), precioMensual: 900, motivo: 'Viaje',
      );
      expect(num2((await getCuota(jul))['monto']), closeTo(150, 0.01));
      // Reactivar el 28-jun (MISMO ciclo que el corte de julio).
      await repo.reactivarContrato(
        contratoId: contratoId, cobradorId: cobradorId,
        fechaReactivacion: DateTime(2026, 6, 28), precioMensual: 900,
      );
      final c = await db.getAll(
          'SELECT dia_pago FROM contratos WHERE id = ?', [contratoId]);
      expect((c.first['dia_pago'] as num).toInt(), 28);
      // Junio: cumplido entera intacta.
      expect(num2((await getCuota(jun))['monto']), 900);
      // Julio (corte): RE-COMPLETADA = prorrateo 150 + mes reanudado 900 = 1050,
      // venc re-fechado al 28-jul. NO se sub-cobra el ciclo reanudado.
      final jlc = await getCuota(jul);
      expect(jlc['estado'], 'pendiente');
      expect(num2(jlc['monto']), closeTo(1050, 0.01));
      expect(jlc['fecha_vencimiento'],
          ymd(calcularFechaPago(DateTime(2026, 7, 1), 28)));
      // Agosto: revivida completa, venc 28-ago.
      final agc = await getCuota(ago);
      expect(num2(agc['monto']), 900);
      expect(agc['fecha_vencimiento'],
          ymd(calcularFechaPago(DateTime(2026, 8, 1), 28)));
    });

    test('sub-caso 4: una cuota YA PAGADA en mesRNext NO se re-completa (no sobre-cobra)', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(
          diaPago: 20, duracionMeses: 12, fechaFin: '2027-05-31');
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20');
      // Julio PAGADA por adelantado (monto entero, saldo 0): la suspensión NO la toca.
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20', estado: 'pagada', montoPagado: 900);
      final ago = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-08-01',
          fechaVencimiento: '2026-08-20');
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 25), precioMensual: 900, motivo: 'X',
      );
      // Reactivar 28-jun: mesRNext = julio, donde vive la cuota PAGADA entera.
      await repo.reactivarContrato(
        contratoId: contratoId, cobradorId: cobradorId,
        fechaReactivacion: DateTime(2026, 6, 28), precioMensual: 900,
      );
      // Julio NO se re-completa (monto < precioMensual no se cumple): sigue
      // pagada, monto 900 (NO 1800).
      final jlc = await getCuota(jul);
      expect(jlc['estado'], 'pagada');
      expect(num2(jlc['monto']), 900);
      expect(num2((await getCuota(ago))['monto']), 900);
    });
  });

  // ── ContratosRepo.revertir (deshacer por error) ─────────────────────────
  group('ContratosRepo.revertir (deshacer suspensión/cancelación por error)', () {
    test('revertirSuspension restaura el estado EXACTO previo y reactiva', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      final abr = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-04-01',
          fechaVencimiento: '2026-04-20');
      final jun = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20');
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20');
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'Error',
      );
      // Sanity: junio prorrateada (619.35), julio anulada.
      expect(num2((await getCuota(jun))['monto']), closeTo(619.35, 0.01));
      expect((await getCuota(jul))['estado'], 'anulada');

      await repo.revertirSuspension(
          contratoId: contratoId, cobradorId: cobradorId);

      // Contrato activo de nuevo.
      final c = await db
          .getAll('SELECT estado FROM contratos WHERE id = ?', [contratoId]);
      expect(c.first['estado'], 'activo');
      // Junio: monto ORIGINAL restaurado (no el prorrateo).
      final jc = await getCuota(jun);
      expect(jc['estado'], 'pendiente');
      expect(num2(jc['monto']), 900, reason: 'monto original restaurado');
      // Julio: des-anulada, monto y venc originales.
      final jlc = await getCuota(jul);
      expect(jlc['estado'], 'pendiente');
      expect(jlc['motivo_anulacion'], isNull);
      expect(jlc['anulada_en'], isNull);
      expect(num2(jlc['monto']), 900);
      expect(jlc['fecha_vencimiento'], '2026-07-20');
      // Abril (mora previa): intacta.
      expect((await getCuota(abr))['estado'], 'pendiente');
      // Suspensión cerrada (code-only marker).
      final susp = await db.getAll(
          'SELECT reactivado_en FROM contrato_suspensiones WHERE contrato_id = ?',
          [contratoId]);
      expect(susp.first['reactivado_en'], isNotNull);
    });

    test('revertirCancelacion restaura el estado previo y reactiva', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      final jun = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-06-01',
          fechaVencimiento: '2026-06-20');
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20');
      await repo.cancelarContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaCancelacion: DateTime(2026, 6, 10), precioMensual: 900,
        motivo: 'Error',
      );
      expect((await getCuota(jul))['estado'], 'anulada');

      await repo.revertirCancelacion(
          contratoId: contratoId, cobradorId: cobradorId);

      final c = await db.getAll(
          'SELECT estado, cancelado_en, motivo_cancelacion FROM contratos WHERE id = ?',
          [contratoId]);
      expect(c.first['estado'], 'activo');
      expect(c.first['cancelado_en'], isNull);
      expect(c.first['motivo_cancelacion'], isNull);
      expect(num2((await getCuota(jun))['monto']), 900);
      final jlc = await getCuota(jul);
      expect(jlc['estado'], 'pendiente');
      expect(jlc['motivo_anulacion'], isNull);
    });

    test('guard: si se cobró después de suspender, no se puede revertir', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      final abr = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-04-01',
          fechaVencimiento: '2026-04-20');
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'X',
      );
      // Simular un cobro posterior: cambia el monto_pagado de una cuota viva.
      await db.execute('UPDATE cuotas SET monto_pagado = 300 WHERE id = ?', [abr]);
      await expectLater(
        repo.revertirSuspension(contratoId: contratoId, cobradorId: cobradorId),
        throwsA(isA<StateError>()),
      );
      // No mutó: sigue suspendido.
      final c = await db
          .getAll('SELECT estado FROM contratos WHERE id = ?', [contratoId]);
      expect(c.first['estado'], 'suspendido');
    });

    test('guard: si se aplicó un cargo después de suspender, no se puede revertir', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      final abr = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-04-01',
          fechaVencimiento: '2026-04-20');
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'X',
      );
      // Simular un cargo posterior: sube cargos_neto sin tocar monto_pagado.
      await db.execute('UPDATE cuotas SET cargos_neto = 200 WHERE id = ?', [abr]);
      await expectLater(
        repo.revertirSuspension(contratoId: contratoId, cobradorId: cobradorId),
        throwsA(isA<StateError>()),
      );
    });

    test('revertir un contrato SIN cuotas vivas solo reactiva (no es legacy)', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      // Sin cuotas vivas: el snapshot lleva cuotas_previas = [] (NO es legacy).
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'X',
      );
      await repo.revertirSuspension(
          contratoId: contratoId, cobradorId: cobradorId);
      final c = await db
          .getAll('SELECT estado FROM contratos WHERE id = ?', [contratoId]);
      expect(c.first['estado'], 'activo');
    });

    test('guard: una suspensión sin estado-previo guardado no se puede revertir', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20');
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 6, 10), precioMensual: 900, motivo: 'X',
      );
      // Snapshot viejo (sin cuotas_previas): simula una suspensión pre-feature.
      await db.execute(
          'UPDATE contrato_suspensiones SET deuda_snapshot = ? WHERE contrato_id = ?',
          [jsonEncode({'total': 0, 'cuotas': []}), contratoId]);
      await expectLater(
        repo.revertirSuspension(contratoId: contratoId, cobradorId: cobradorId),
        throwsA(isA<StateError>()),
      );
    });

    test('revertirCancelacion tolera el snapshot DOBLE-codificado (round-trip jsonb)', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      final jul = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-07-01',
          fechaVencimiento: '2026-07-20');
      await repo.cancelarContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaCancelacion: DateTime(2026, 6, 10), precioMensual: 900,
        motivo: 'Error',
      );
      // Simular el round-trip de la columna jsonb: el snapshot vuelve como
      // "{...}" (string codificado adentro de otro string).
      final row = await db.getAll(
          'SELECT cancelacion_deuda_snapshot FROM contratos WHERE id = ?',
          [contratoId]);
      final raw = row.first['cancelacion_deuda_snapshot'] as String;
      await db.execute(
          'UPDATE contratos SET cancelacion_deuda_snapshot = ? WHERE id = ?',
          [jsonEncode(raw), contratoId]);
      // Aun doble-codificado, el decode robusto lo resuelve y revierte.
      await repo.revertirCancelacion(
          contratoId: contratoId, cobradorId: cobradorId);
      final c = await db
          .getAll('SELECT estado FROM contratos WHERE id = ?', [contratoId]);
      expect(c.first['estado'], 'activo');
      expect((await getCuota(jul))['estado'], 'pendiente');
    });
  });

  // ── op_log Fase 3 — ContratosRepo emite 1 entrada por objeto ─────────────
  group('op_log Fase 3 (contratos_repo)', () {
    Future<List<Map<String, dynamic>>> oplog(String e, String id) => db.getAll(
        'SELECT * FROM op_log WHERE entidad = ? AND entidad_id = ?', [e, id]);
    Map<String, dynamic> diffDe(Map<String, dynamic> l) =>
        jsonDecode(l['diff'] as String) as Map<String, dynamic>;
    List<Map<String, dynamic>> camposDe(Map<String, dynamic> d) =>
        (d['campos'] as List).cast<Map<String, dynamic>>();

    test('suspender → op_log "suspension" en el contrato + en la cuota futura '
        'anulada, MISMO op_id', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      final fut = await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-09-01',
          fechaVencimiento: '2026-09-20');

      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 8, 10), precioMensual: 900,
        motivo: 'Solicitud del cliente',
      );

      final ct = await oplog('contratos', contratoId);
      expect(ct, hasLength(1));
      expect(ct.first['tipo_op'], 'suspension');
      expect(ct.first['actor_label'], 'Cobrador Test');
      final opId = ct.first['op_id'] as String;
      final est =
          camposDe(diffDe(ct.first)).firstWhere((c) => c['campo'] == 'estado');
      expect(est['antes'], 'activo');
      expect(est['despues'], 'suspendido');

      final cu = await oplog('cuotas', fut);
      expect(cu, hasLength(1));
      expect(cu.first['op_id'], opId, reason: 'misma intención = mismo op_id');
      expect(cu.first['tipo_op'], 'suspension');
      expect(
          camposDe(diffDe(cu.first))
              .firstWhere((c) => c['campo'] == 'estado')['despues'],
          'anulada');
    });

    test('aplicarCredito → op_log "aplicar_credito" en la cuota (saldo baja, '
        'monto en el resumen)', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 5, duracionMeses: 12);
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await db.execute(
        'INSERT INTO saldos_favor (id, tenant_id, cliente_id, contrato_id, tipo, '
        "monto, creado_por, ocurrido_en) VALUES (?, ?, ?, ?, 'acreditado', 300, ?, ?)",
        [uuid.v4(), tenantId, clienteId, contratoId, cobradorId, _now()],
      );

      final aplicado =
          await repo.aplicarCredito(cuotaId: cuotaId, cobradorId: cobradorId);
      expect(aplicado, closeTo(300, 0.001));

      final ed = (await oplog('cuotas', cuotaId))
          .firstWhere((l) => l['tipo_op'] == 'aplicar_credito');
      final d = diffDe(ed);
      final saldo = camposDe(d).firstWhere((c) => c['campo'] == 'saldo');
      expect((saldo['antes'] as num).toDouble(), 500);
      expect((saldo['despues'] as num).toDouble(), closeTo(200, 0.001));
      expect((d['resumen'] as Map)['monto'], closeTo(300, 0.001));
    });

    test('revertirSuspension → op_log "revertir_suspension" en el contrato '
        '(suspendido → activo)', () async {
      final repo = ContratosRepo(db: db);
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: 12);
      await seedCuota(
          contratoId: contratoId, monto: 900, periodo: '2026-09-01',
          fechaVencimiento: '2026-09-20');
      await repo.suspenderContrato(
        tenantId: tenantId, contratoId: contratoId, cobradorId: cobradorId,
        fechaSuspension: DateTime(2026, 8, 10), precioMensual: 900,
        motivo: 'error',
      );
      await repo.revertirSuspension(
          contratoId: contratoId, cobradorId: cobradorId);

      final rev = (await oplog('contratos', contratoId))
          .firstWhere((l) => l['tipo_op'] == 'revertir_suspension');
      final est =
          camposDe(diffDe(rev)).firstWhere((c) => c['campo'] == 'estado');
      expect(est['antes'], 'suspendido');
      expect(est['despues'], 'activo');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // COLCHÓN de indefinidos (asegurarColchonIndefinido) — espejo offline de
  // generar_cuotas_contrato. Ancla = max(última pagada, mes actual) + 3.
  // ───────────────────────────────────────────────────────────────────────
  group('colchón indefinidos', () {
    // Contrato INDEFINIDO con fecha_inicio (seedContrato no la setea).
    Future<String> seedIndef({
      required String fechaInicio,
      int diaPago = 15,
    }) async {
      final id = uuid.v4();
      await db.execute(
        'INSERT INTO contratos (id, tenant_id, cliente_id, cobrador_id, '
        'plan_id, dia_pago, duracion_meses, fecha_inicio, estado, created_at) '
        "VALUES (?, ?, ?, ?, ?, ?, NULL, ?, 'activo', ?)",
        [id, tenantId, clienteId, cobradorId, planId, diaPago, fechaInicio,
          _now()],
      );
      return id;
    }

    Future<int> asegurar(String contratoId, DateTime ahora) async {
      var creadas = 0;
      await db.writeTransaction((tx) async {
        creadas =
            await asegurarColchonIndefinido(tx, contratoId, ahora: ahora);
      });
      return creadas;
    }

    Future<List<String>> periodos(String contratoId, {String? estado}) async {
      final where = estado == null ? '' : "AND estado = '$estado'";
      final rows = await db.getAll(
        'SELECT periodo FROM cuotas WHERE contrato_id = ? $where '
        'ORDER BY periodo',
        [contratoId],
      );
      return rows.map((r) => r['periodo'] as String).toList();
    }

    test('recién creado este mes → 3 colchón desde el mes siguiente', () async {
      // Instala 2026-06-15 → 1ª cuota jul; hoy jun → colchón jul/ago/sep.
      final id = await seedIndef(fechaInicio: '2026-06-15');
      final creadas = await asegurar(id, DateTime(2026, 6, 20));
      expect(creadas, 3);
      expect(await periodos(id),
          ['2026-07-01', '2026-08-01', '2026-09-01']);
      expect(await periodos(id, estado: 'pendiente'), hasLength(3));
    });

    test('retroactivo (inicia ene 2024) → todas desde feb 2024 hasta hoy + 3',
        () async {
      final id = await seedIndef(fechaInicio: '2024-01-10');
      final creadas = await asegurar(id, DateTime(2026, 6, 20));
      // feb 2024 … sep 2026 (hoy jun + 3) inclusive = 32 cuotas.
      expect(creadas, 32);
      final ps = await periodos(id);
      expect(ps.first, '2024-02-01');
      expect(ps.last, '2026-09-01');
    });

    test('pago por adelantado corre el colchón: 3 DESPUÉS de la última pagada',
        () async {
      // Instala 2026-05-15 → 1ª cuota jun. Hoy jun → jun + 3 colchón = jun..sep.
      final id = await seedIndef(fechaInicio: '2026-05-15');
      await asegurar(id, DateTime(2026, 6, 20));
      expect(await periodos(id), hasLength(4)); // jun, jul, ago, sep

      // Paga las 4 (jun→sep): última pagada = sep.
      await db.execute(
        "UPDATE cuotas SET estado = 'pagada', monto_pagado = monto "
        'WHERE contrato_id = ?',
        [id],
      );

      // Re-asegurar (como hace registrarCobro): ancla = sep → colchón oct/nov/dic.
      final creadas = await asegurar(id, DateTime(2026, 6, 20));
      expect(creadas, 3);
      expect(await periodos(id, estado: 'pendiente'),
          ['2026-10-01', '2026-11-01', '2026-12-01']);
    });

    test('idempotente: segunda corrida no duplica', () async {
      final id = await seedIndef(fechaInicio: '2026-06-15');
      await asegurar(id, DateTime(2026, 6, 20));
      final segunda = await asegurar(id, DateTime(2026, 6, 20));
      expect(segunda, 0);
      expect(await periodos(id), hasLength(3));
    });

    test('fijo y contrato sin fecha_inicio = no-op (0 cuotas)', () async {
      final fijo = await seedContrato(duracionMeses: 12); // fijo
      expect(await asegurar(fijo, DateTime(2026, 6, 20)), 0);
      final sinInicio = await seedContrato(); // indefinido sin fecha_inicio
      expect(await asegurar(sinInicio, DateTime(2026, 6, 20)), 0);
    });

    test('instalación FUTURA → 3 cuotas desde el mes siguiente (piso GREATEST 3)',
        () async {
      // Instala dic-2026, hoy jun-2026 → 1ª cuota ene-2027; el piso garantiza 3
      // (sin él, el loop no correría porque primerMes > ancla+3).
      final id = await seedIndef(fechaInicio: '2026-12-15');
      expect(await asegurar(id, DateTime(2026, 6, 20)), 3);
      expect(await periodos(id), ['2027-01-01', '2027-02-01', '2027-03-01']);
    });

    test('adelanto PARCIAL sobre el colchón corre el ancla (incluye parcial)',
        () async {
      // Instala may → jun..sep. Paga jun/jul/ago full, sep PARCIAL.
      final id = await seedIndef(fechaInicio: '2026-05-15');
      await asegurar(id, DateTime(2026, 6, 20)); // jun,jul,ago,sep
      await db.execute(
        "UPDATE cuotas SET estado='pagada', monto_pagado=monto WHERE "
        'contrato_id=? AND periodo IN '
        "('2026-06-01','2026-07-01','2026-08-01')",
        [id],
      );
      await db.execute(
        "UPDATE cuotas SET estado='parcial', monto_pagado=100 "
        "WHERE contrato_id=? AND periodo='2026-09-01'",
        [id],
      );
      // sep (parcial) corre el ancla → colchón oct/nov/dic.
      expect(await asegurar(id, DateTime(2026, 6, 20)), 3);
      expect(await periodos(id, estado: 'pendiente'),
          ['2026-10-01', '2026-11-01', '2026-12-01']);
    });

    test('indefinido suspendido = no-op (no regenera colchón)', () async {
      final id = await seedIndef(fechaInicio: '2026-06-15');
      await db.execute(
          "UPDATE contratos SET estado='suspendido' WHERE id=?", [id]);
      expect(await asegurar(id, DateTime(2026, 6, 20)), 0);
    });

    // ── 0178: anti-backfill del hueco de una suspensión LARGA ────────────────
    // Estado tras suspender >3 meses y reactivar: el colchón viejo quedó
    // 'anulada' (feb/mar/abr), la reactivación creó el colchón nuevo desde
    // sep/oct/nov, y los meses de la pausa (may/jun/jul/ago) NUNCA se crearon.
    // El generador NO debe materializar ese hueco (serían 'pendiente' con
    // vencimiento pasado = deuda FALSA por meses SIN servicio → viola 0120).
    Future<void> seedCuota(
        String contratoId, String periodo, String estado) async {
      await db.execute(
        'INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, cobrador_id, '
        'periodo, fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, '
        'ocurrido_en) VALUES (?, ?, ?, ?, ?, ?, ?, 500, 0, 0, ?, ?)',
        [uuid.v4(), tenantId, contratoId, clienteId, cobradorId, periodo,
          '${periodo.substring(0, 7)}-15', estado, _now()],
      );
    }

    Future<String> seedIndefConHueco() async {
      // fecha_inicio ene-2026 (primerMes = feb). Suspendido may, reactivado ago.
      final id = await seedIndef(fechaInicio: '2026-01-15');
      for (final m in ['2026-02-01', '2026-03-01', '2026-04-01']) {
        await seedCuota(id, m, 'anulada'); // colchón anulado al suspender
      }
      for (final m in ['2026-09-01', '2026-10-01', '2026-11-01']) {
        await seedCuota(id, m, 'pendiente'); // colchón creado al reactivar (ago→sep+1)
      }
      return id; // HUECO = may, jun, jul, ago (sin fila)
    }

    Future<List<String>> huecoRows(String contratoId) async {
      final rows = await db.getAll(
        'SELECT periodo FROM cuotas WHERE contrato_id=? AND periodo IN '
        "('2026-05-01','2026-06-01','2026-07-01','2026-08-01') ORDER BY periodo",
        [contratoId],
      );
      return rows.map((r) => r['periodo'] as String).toList();
    }

    test('suspensión larga: NO rellena el hueco de meses sin servicio (0178)',
        () async {
      final id = await seedIndefConHueco();
      // Recién reactivado (ago-2026): el colchón ya está 3 adelante (sep/oct/nov).
      final creadas = await asegurar(id, DateTime(2026, 8, 20));
      expect(creadas, 0,
          reason: 'colchón ya presente y el hueco NO se materializa');
      expect(await huecoRows(id), isEmpty,
          reason: 'meses suspendidos (may..ago) siguen sin fila');
      expect(await periodos(id, estado: 'pendiente'),
          ['2026-09-01', '2026-10-01', '2026-11-01']);
      expect(await periodos(id, estado: 'anulada'),
          ['2026-02-01', '2026-03-01', '2026-04-01']);
    });

    test('tras el hueco, el colchón se extiende adelante SIN tocar el hueco',
        () async {
      final id = await seedIndefConHueco();
      // El tiempo avanza a oct → ancla=oct → colchón hasta oct+3=ene-2027,
      // agregando dic-2026 y ene-2027 (sep/oct/nov ya existen). Hueco intacto.
      final creadas = await asegurar(id, DateTime(2026, 10, 20));
      expect(creadas, 2, reason: 'extiende dic-2026 y ene-2027');
      expect(await periodos(id, estado: 'pendiente'), [
        '2026-09-01', '2026-10-01', '2026-11-01', '2026-12-01', '2027-01-01'
      ]);
      expect(await huecoRows(id), isEmpty,
          reason: 'el hueco NUNCA se rellena, ni al extender el colchón');
    });

    test('vencimiento espeja calcularFechaPago (dia_pago=15)', () async {
      final id = await seedIndef(fechaInicio: '2026-06-15', diaPago: 15);
      await asegurar(id, DateTime(2026, 6, 20));
      final v = await db.getAll(
        'SELECT fecha_vencimiento FROM cuotas '
        "WHERE contrato_id=? AND periodo='2026-07-01'",
        [id],
      );
      expect(v.first['fecha_vencimiento'], '2026-07-15');
    });

    test('registrarCobroMultiple sobre 2 indefinidos distintos: ambos '
        'mantienen su colchón', () async {
      final a = await seedIndef(fechaInicio: '2026-05-15');
      final b = await seedIndef(fechaInicio: '2026-05-15');
      await asegurar(a, DateTime(2026, 6, 20)); // a: jun..sep
      await asegurar(b, DateTime(2026, 6, 20)); // b: jun..sep
      Future<String> junDe(String c) async => (await db.getAll(
            "SELECT id FROM cuotas WHERE contrato_id=? AND periodo='2026-06-01'",
            [c]))
          .first['id'] as String;

      await repo.registrarCobroMultiple(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaIds: [await junDe(a), await junDe(b)],
        montosCordobas: [500, 500],
        moneda: Moneda.nio,
        montosOriginal: [500, 500],
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      // El Set contratosAfectados corre el colchón para AMBOS contratos: cada
      // uno conserva >=3 cuotas pendientes futuras tras pagar su jun.
      expect((await periodos(a, estado: 'pendiente')).length,
          greaterThanOrEqualTo(3));
      expect((await periodos(b, estado: 'pendiente')).length,
          greaterThanOrEqualTo(3));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // COBRO PUNTUAL — cuota manual standalone (instalación/multa/anexo/etc.)
  // El cargo de una vez, fuera del ciclo del contrato: contrato_id NULL,
  // tipo_cargo_manual seteado. Se cobra con el MISMO registrarCobro.
  // ───────────────────────────────────────────────────────────────────────
  group('Cobro puntual (cuota manual standalone)', () {
    test('crearCuotaManual: cuota standalone (contrato_id NULL, tipo, '
        'pendiente, pagado 0, cobrador denormalizado) + op_log de alta',
        () async {
      final cuotaRepo = CuotasRepo(db: db);
      final cuotaId = await cuotaRepo.crearCuotaManual(
        tenantId: tenantId,
        clienteId: clienteId,
        tipo: 'instalacion',
        monto: 1500,
        descripcion: 'Instalación + cable',
        creadoPorId: cobradorId,
      );

      final cuota = await getCuota(cuotaId);
      expect(cuota['contrato_id'], isNull, reason: 'standalone: sin contrato');
      expect(cuota['cliente_id'], clienteId);
      expect(cuota['tipo_cargo_manual'], 'instalacion');
      expect(cuota['descripcion'], 'Instalación + cable');
      expect(num2(cuota['monto']), 1500);
      expect(num2(cuota['monto_pagado']), 0);
      expect(num2(cuota['cargos_neto']), 0);
      expect(cuota['estado'], 'pendiente');
      // cobrador_id denormalizado = el del cliente (regla #6 del checklist).
      expect(cuota['cobrador_id'], cobradorId);

      // op_log de ALTA scoped a la cuota (entidad 'cuotas', tipo cobro_puntual).
      final ops = await db.getAll(
        "SELECT * FROM op_log WHERE entidad = 'cuotas' AND entidad_id = ? "
        "AND accion = 'create' AND tipo_op = 'cobro_puntual'",
        [cuotaId],
      );
      expect(ops, hasLength(1), reason: 'una fila op_log de alta');
    });

    test('crearCuotaManual rechaza concepto inválido, monto<=0 y desc vacía',
        () async {
      final cuotaRepo = CuotasRepo(db: db);
      await expectLater(
        cuotaRepo.crearCuotaManual(
            tenantId: tenantId,
            clienteId: clienteId,
            tipo: 'inexistente',
            monto: 100,
            descripcion: 'x',
            creadoPorId: cobradorId),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        cuotaRepo.crearCuotaManual(
            tenantId: tenantId,
            clienteId: clienteId,
            tipo: 'multa',
            monto: 0,
            descripcion: 'x',
            creadoPorId: cobradorId),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        cuotaRepo.crearCuotaManual(
            tenantId: tenantId,
            clienteId: clienteId,
            tipo: 'multa',
            monto: 100,
            descripcion: '   ',
            creadoPorId: cobradorId),
        throwsA(isA<Exception>()),
      );
    });

    test('cobrar una cuota manual: entra a caja (monto_cordobas), emite recibo '
        'y la cuota queda pagada (sin contrato → sin colchón ni oldest-first)',
        () async {
      final cuotaRepo = CuotasRepo(db: db);
      final cuotaId = await cuotaRepo.crearCuotaManual(
        tenantId: tenantId,
        clienteId: clienteId,
        tipo: 'multa',
        monto: 1000,
        descripcion: 'Multa por manipulación de equipo',
        creadoPorId: cobradorId,
      );

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 1000,
        vueltoCordobas: 0,
        moneda: Moneda.nio,
        montoOriginal: 1000,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final cuota = await getCuota(cuotaId);
      expect(cuota['estado'], 'pagada');
      expect(num2(cuota['monto_pagado']), 1000);

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 1000); // plata real a caja (INV4)
      expect(num2(pago['vuelto_cordobas']), 0);
      expect(pago['anulado'], 0);

      final recibo = await getReciboDePago(res.pagoId);
      expect(recibo['anulado'], 0);
    });
  });
}

String _now() => DateTime.now().toUtc().toIso8601String();

/// Busca el binario nativo `powersync-sqlite-core`:
///  1. `$POWERSYNC_CORE_PATH` si está seteada y el archivo existe.
///  2. En la raíz del repo, probando los nombres por plataforma.
/// Devuelve null si no lo encuentra (los tests se saltan en ese caso).
String? _resolveCorePath() {
  final override = Platform.environment['POWERSYNC_CORE_PATH'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return override;
  }
  // La raíz del repo es el cwd cuando se corre `flutter test`.
  final root = Directory.current.path;
  final candidates = <String>[
    p.join(root, 'libpowersync.so'), // Linux
    p.join(root, 'libpowersync.dylib'), // macOS
    p.join(root, 'powersync_x64.dll'), // Windows (powersync_core 1.18, arch-suffix)
    p.join(root, 'powersync_aarch64.dll'), // Windows ARM
    p.join(root, 'libpowersync_x64.so'),
    p.join(root, 'libpowersync_aarch64.so'),
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
