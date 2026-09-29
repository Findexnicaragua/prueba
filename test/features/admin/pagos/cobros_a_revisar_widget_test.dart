@TestOn('vm')
library;

/// "Cobros a revisar" RENDERIZADA de verdad, en teléfono y en PC.
///
/// Por qué existe: la migración `0264` mandó a esta pantalla TODO duplicado
/// —también el idéntico— y la tarjeta sumó recibo, cobrador, moneda y vuelto.
/// Son cuatro datos más en una tarjeta que ya estaba llena, y el ancho donde
/// eso revienta (360 px) no aparece en ninguna captura de escritorio: el
/// 2026-08-29 se encontraron así cuatro overflows del Resumen que en las
/// capturas del dueño se veían perfectos.
///
/// El overflow de Flutter es un error de RENDER: no lo caza `analyze`, no lo
/// cazan los tests de números, y en release ni siquiera pinta la franja
/// amarilla — simplemente el texto queda cortado o invisible. Acá sí se cae,
/// porque `tester` convierte cualquier overflow en una excepción del test.
///
/// El escenario es el del mockup que se le mostró al dueño: dos cobros del
/// MISMO monto y el MISMO día que sin embargo son distinguibles —uno pagó en
/// dólares sin vuelto, el otro en córdobas con vuelto— cada uno con su
/// correlativo. Es exactamente el caso que `0264` dejó de resolver solo.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/cobrador.dart';
import 'package:isp_billing/data/providers/cobrador_provider.dart';
import 'package:isp_billing/data/utils/formatters.dart';
import 'package:isp_billing/features/admin/pagos/cobros_a_revisar_screen.dart';
import 'package:isp_billing/powersync/db.dart' as ps;
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;

const _tenant = 't-revisar';
const _admin = '11111111-1111-1111-1111-111111111111';
const _cobrador2 = '22222222-2222-2222-2222-222222222222';
const _cuota = 'cu-000000000000000000000000000001';

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('SALTADO: falta powersync_x64.dll', () {}, skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  late PowerSyncDatabase db;
  late Directory tmpDir;

  Future<void> abrirDb() async {
    tmpDir = await Directory.systemTemp.createTemp('revisar_widget_');
    db = PowerSyncDatabase(
        schema: schema, path: p.join(tmpDir.path, 'test.db'));
    await db.initialize();
    ps.db = db;

    await db.execute(
        'INSERT INTO cobradores (id, tenant_id, nombre, rol, activo) '
        'VALUES (?, ?, ?, ?, 1)',
        [_admin, _tenant, 'Responsable de Cartera', 'admin']);
    await db.execute(
        'INSERT INTO cobradores (id, tenant_id, nombre, rol, activo) '
        'VALUES (?, ?, ?, ?, 1)',
        [_cobrador2, _tenant, 'Juan Díaz', 'cobrador']);
    await db.execute(
        'INSERT INTO clientes (id, tenant_id, codigo, nombre, activo) '
        "VALUES ('cl-1', ?, 'CF0190', 'Daysi María Soza Zamora', 1)",
        [_tenant]);
    await db.execute(
        'INSERT INTO contratos (id, tenant_id, cliente_id, estado, dia_pago) '
        "VALUES ('ct-1', ?, 'cl-1', 'activo', 20)",
        [_tenant]);
    await db.execute(
        'INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, periodo, '
        'monto, cargos_neto, monto_pagado, estado, fecha_vencimiento) '
        "VALUES (?, ?, 'ct-1', 'cl-1', '2026-08-01', 513, 0, 513, 'pagada', "
        "'2026-08-20')",
        [_cuota, _tenant]);

    // ── Los DOS cobros: mismo monto, mismo día, recibos distintos ──────────
    // Este par es justo el que hasta 0264 el server resolvia solo. Y se siembra
    // como pasa DE VERDAD: el que llega primero ENTRA y cuenta
    // (`monto_pagado` = 513); el segundo excede el total y queda en cuarentena.
    // Sembrar los dos en cuarentena daria una cuota con `monto_pagado` que no
    // se corresponde con ningun pago vivo — un estado que el trigger del server
    // no puede producir, y el test estaria probando un mundo que no existe.
    // (a) Pago en DOLARES, sin vuelto. ENTRO (cuenta en la caja).
    await db.execute(
        'INSERT INTO pagos (id, tenant_id, cuota_id, cobrador_id, '
        'monto_cordobas, vuelto_cordobas, moneda, monto_original, '
        'tasa_conversion, metodo, fecha_pago, fecha_cobro, anulado, '
        'en_revision, revision_motivo) '
        "VALUES ('pg-a', ?, ?, ?, 513, 0, 'USD', 15, 34.2, 'efectivo', "
        "'2026-08-04 14:20:00', '2026-08-04', 0, 0, NULL)",
        [_tenant, _cuota, _admin]);
    // (b) Pago en CORDOBAS, con vuelto. Llego DESPUES -> cuarentena.
    await db.execute(
        'INSERT INTO pagos (id, tenant_id, cuota_id, cobrador_id, '
        'monto_cordobas, vuelto_cordobas, moneda, monto_original, '
        'tasa_conversion, metodo, fecha_pago, fecha_cobro, anulado, '
        'en_revision, revision_motivo) '
        "VALUES ('pg-b', ?, ?, ?, 513, 7, 'NIO', 520, 1, 'efectivo', "
        "'2026-08-04 09:05:00', '2026-08-04', 0, 1, ?)",
        [
          _tenant,
          _cuota,
          _cobrador2,
          'Cobro idéntico: mismo monto y mismo día que otro cobro de esta '
              'cuota. Preguntá al cliente qué recibo tiene y elegí ése.'
        ]);

    await db.execute(
        'INSERT INTO recibos (id, tenant_id, pago_id, cobrador_id, prefijo, '
        'correlativo, numero_completo, anulado) '
        "VALUES ('rc-a', ?, 'pg-a', ?, 'MAI', 412, 'MAI-00412', 0)",
        [_tenant, _admin]);
    await db.execute(
        'INSERT INTO recibos (id, tenant_id, pago_id, cobrador_id, prefijo, '
        'correlativo, numero_completo, anulado) '
        "VALUES ('rc-b', ?, 'pg-b', ?, 'JD', 87, 'JD-00087', 0)",
        [_tenant, _admin]);
  }

  Future<void> cerrarDb() async {
    await db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  }

  /// Monta la pantalla real al ancho pedido y abre el detalle de la cuota.
  ///
  /// `runAsync` no es opcional: los `db.watch` de la pantalla programan timers
  /// reales, y en la zona del reloj falso del test las consultas nunca
  /// terminan (la pantalla queda en su estado vacío y el test pasaría por el
  /// motivo equivocado).
  Future<void> montar(WidgetTester tester, double ancho) async {
    tester.view.physicalSize = Size(ancho, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    const cobrador = Cobrador(
      id: _admin,
      tenantId: _tenant,
      nombre: 'Responsable de Cartera',
      rol: 'admin',
      activo: true,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          cobradorActualProvider.overrideWith((ref) => Stream.value(cobrador)),
        ],
        child: const MaterialApp(
          locale: Locale('es', 'NI'),
          supportedLocales: [Locale('es', 'NI'), Locale('es'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: CobrosARevisarScreen()),
        ),
      ));
      for (var i = 0; i < 14; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  /// Abre el detalle de la cuota (el sheet con las tarjetas de cada cobro).
  ///
  /// El disparador es el ActionChip del mes, no el nombre del cliente: el
  /// nombre es solo el encabezado del grupo y no es tappable.
  Future<void> abrirDetalle(WidgetTester tester) async {
    expect(find.textContaining('Daysi'), findsWidgets,
        reason: 'la cuota en cuarentena tiene que aparecer en la lista');
    final chip = find.byType(ActionChip);
    expect(chip, findsWidgets, reason: 'el chip del mes abre el detalle');
    await tester.runAsync(() async {
      await tester.tap(chip.first);
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  group('Cobros a revisar — se ve entero y dice lo que hay que saber', () {
    setUp(abrirDb);
    tearDown(cerrarDb);

    // 360 px es el ancho real de los teléfonos de campo. Un overflow acá es
    // texto invisible en producción, y en release ni siquiera avisa.
    testWidgets('TELÉFONO (360 px): sin overflow, y se ven los cuatro datos '
        'que distinguen un recibo del otro', (tester) async {
      await montar(tester, 360);
      await abrirDetalle(tester);

      // Los correlativos: es POR ESTO que la decisión es humana.
      expect(find.textContaining('MAI-00412'), findsOneWidget);
      expect(find.textContaining('JD-00087'), findsOneWidget);
      // Quién cobró cada uno.
      expect(find.textContaining('Juan Díaz'), findsWidgets);
      // La moneda y el vuelto: mismo importe aplicado, entrega distinta.
      expect(find.textContaining('Entregó'), findsNWidgets(2));
      expect(find.textContaining('34.20'), findsOneWidget,
          reason: 'la tasa solo se muestra cuando hubo conversión');
      expect(find.textContaining('sin vuelto'), findsOneWidget);
      // El monto se compara con el MISMO formateador que usa la pantalla:
      // hardcodear "C$7.00" es adivinar el locale (es_NI) y el test se cae por
      // el separador decimal en vez de por lo que viene a medir.
      expect(find.textContaining(Fmt.cordobas(7)), findsOneWidget,
          reason: 'el vuelto en cordobas distingue este recibo del otro');
      expect(find.textContaining(Fmt.monto(15, 'USD')), findsOneWidget,
          reason: 'lo ENTREGADO en su moneda original');
      // El motivo que escribe el server desde 0264.
      expect(find.textContaining('Preguntá al cliente'), findsWidgets);
    });

    testWidgets('PC (1400 px): también entero', (tester) async {
      await montar(tester, 1400);
      await abrirDetalle(tester);
      expect(find.textContaining('MAI-00412'), findsOneWidget);
      expect(find.textContaining('Entregó'), findsNWidgets(2));
    });

    // El ancho más angosto que Flutter considera un teléfono. Si sobrevive
    // acá, sobrevive en cualquier equipo de la flota.
    testWidgets('TELÉFONO CHICO (320 px): sigue sin romperse', (tester) async {
      await montar(tester, 320);
      await abrirDetalle(tester);
      expect(find.textContaining('MAI-00412'), findsOneWidget);
    });
  });
}

String? _resolveCorePath() {
  for (final name in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    final f = File(name);
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}
