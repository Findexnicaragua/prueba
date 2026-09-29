@TestOn('vm')
library;

/// "Estado actual", RENDERIZADA.
///
/// El test de al lado prueba que los números cierren. Éste prueba que se vean
/// y que entren.
///
/// **La tarjeta volvió a ser una GRILLA DE CUADRADITOS el 2026-09-02**, que es
/// como está en producción. Entre el 2026-09-01 y esa fecha fue una lista de
/// renglones (`rótulo + hint + cuotas · monto · %`) que además se había comido
/// a "Distribución de cuotas"; el dueño pidió deshacer las dos cosas. Estos
/// tests se reescribieron con ella: los que verificaban los renglones y su
/// plata medían un diseño que ya no existe.
///
/// Lo que sigue importando es lo mismo: que las cuatro métricas lleguen a la
/// pantalla y que nada desborde en un teléfono de campo.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/estado_actual_card.dart';
import 'package:isp_billing/powersync/db.dart' as ps;
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;

import 'escenario_seed.dart';

void main() {
  String? core;
  for (final n in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    if (File(n).existsSync()) core = File(n).absolute.path;
  }
  if (core == null) {
    test('estado_actual_ui (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('estado_ui_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
    await db.initialize();
    await sembrarEscenario(db);
    ps.db = db;
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> montar(WidgetTester tester, {double ancho = 1200}) async {
    tester.view.physicalSize = Size(ancho, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Desmontar ANTES de que el tearDown cierre la base: si los `db.watch`
    // siguen suscritos, `close()` no vuelve nunca.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(
          locale: Locale('es', 'NI'),
          supportedLocales: [Locale('es', 'NI'), Locale('es'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: SingleChildScrollView(child: EstadoActualCard()),
          ),
        ),
      ));
      for (var i = 0; i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  group('Estado actual', () {
    testWidgets('las cuatro métricas llegan a la pantalla', (tester) async {
      await montar(tester);

      expect(find.text('Estado actual'), findsOneWidget);
      expect(find.text('Clientes activos'), findsOneWidget);
      expect(find.text('Cuotas por cobrar'), findsOneWidget);
      expect(find.text('En mora'), findsOneWidget);
      // El cuarto es CONDICIONAL: sólo si hay cuotas suspendidas. El escenario
      // tiene, así que acá tiene que estar.
      expect(find.text('De eso, suspendido'), findsOneWidget);
    });

    testWidgets('lo que ya NO muestra vive en "Distribución de cuotas"',
        (tester) async {
      await montar(tester);
      // Estos tres renglones eran de la versión fusionada. Si vuelven a
      // aparecer acá es que alguien rehizo la fusión sin querer, y entonces el
      // Resumen muestra la misma partición dos veces en dos formas distintas.
      expect(find.text('Al día'), findsNothing);
      expect(find.text('En gracia'), findsNothing);
      expect(find.text('Por cobrar'), findsNothing,
          reason: 'el rótulo de la grilla es "Cuotas por cobrar"');
    });

    testWidgets('las tres métricas de plata traen su monto', (tester) async {
      await montar(tester);
      // "Clientes activos" es un conteo de personas y NO lleva monto: es la
      // única de las cuatro sin sub-línea. Las otras tres sí, y perder una
      // columna de la consulta se vería exactamente así — el número arriba y
      // el renglón de plata vacío.
      final montos = find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').contains('C\$'));
      expect(montos, findsNWidgets(3),
          reason: 'por cobrar, en mora y suspendido llevan monto; '
              '"Clientes activos" no');
    });

    // 360 px es el ancho de los teléfonos de campo. Acá el riesgo no es el
    // renglón largo (ya no hay renglones) sino el `childAspectRatio` de la
    // grilla: con 4.0 y con 3.0 el contenido del cuadradito no entraba y
    // desbordaba por abajo (está medido en el comentario de `_Kpis`).
    testWidgets('TELÉFONO (360 px): entra sin desbordar', (tester) async {
      await montar(tester, ancho: 360);

      expect(find.text('Clientes activos'), findsOneWidget);
      expect(find.text('En mora'), findsOneWidget);
      // `tester.takeException` devuelve el error de layout si hubo overflow:
      // sin esto el test pasa igual y el teléfono muestra la franja amarilla.
      expect(tester.takeException(), isNull);
    });
  });
}
