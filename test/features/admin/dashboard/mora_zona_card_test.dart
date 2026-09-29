@TestOn('vm')
library;

/// "Recuperación por cobrador y comunidad", RENDERIZADA.
///
/// La tarjeta volvió al diseño de PRODUCCIÓN el 2026-09-02 por pedido del
/// dueño: una lista de tres niveles —cobrador → comunidad → desglose por monto
/// de cuota— en vez de la tabla con columnas `Cuotas | % del total | Monto`
/// más el gráfico de barras que tuvo durante el rework.
///
/// **Por qué hace falta un test y no alcanza con mirarlo.** La tarjeta no tenía
/// NINGUNO: el cambio de forma no rompe nada que `flutter analyze` vea, y los
/// tres niveles se pueden romper de a uno sin que la pantalla falle — deja de
/// aparecer un renglón y listo.
///
/// 🔴 **Carga NotoSans a propósito.** Sin fuente, Flutter usa una donde cada
/// glifo mide `fontSize` × `fontSize`, así que "1.935.251,44 C$ · 2516 cuotas"
/// mide ~406px en el test contra ~200 reales, y el chequeo de desborde da
/// positivo sobre un layout sano. Pasó con esta misma tarjeta: la primera
/// medición reportó 70px de desborde a 360px que no existían. Es un PROXY —en
/// Windows la pantalla usa Segoe UI— y sirve para saber si entra con holgura,
/// no para el pixel.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/cobrador.dart';
import 'package:isp_billing/data/providers/cobrador_provider.dart';
import 'package:isp_billing/features/admin/dashboard/mora_zona_card.dart';
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
    test('mora_zona_card (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  setUpAll(() async {
    final f = File('assets/fonts/NotoSans-Regular.ttf');
    if (!f.existsSync()) return;
    await (FontLoader('NotoTest')
          ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync()))))
        .load();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mora_zona_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
    await db.initialize();
    await sembrarEscenario(db);
    ps.db = db;
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const yo = Cobrador(
    id: '11111111-1111-1111-1111-111111111111',
    tenantId: 't-mora-ui',
    nombre: 'Admin',
    rol: 'admin',
    activo: true,
  );

  Future<void> montar(WidgetTester tester, {double ancho = 1200}) async {
    tester.view.physicalSize = Size(ancho, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Desmontar ANTES de que el tearDown cierre la base: con los `db.watch`
    // suscritos, `close()` no vuelve nunca.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          cobradorActualProvider.overrideWith((ref) => Stream.value(yo)),
        ],
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'NotoTest'),
          locale: const Locale('es', 'NI'),
          supportedLocales: const [
            Locale('es', 'NI'),
            Locale('es'),
            Locale('en')
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const Scaffold(
              body: SingleChildScrollView(child: MoraZonaCard())),
        ),
      ));
      for (var i = 0; i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  /// Abre la tarjeta (arranca COLAPSADA, como en producción) y después TODO lo
  /// plegable que haya adentro. Es donde el texto es más largo, o sea donde un
  /// desborde aparecería.
  /// Se guía por la FLECHA ▸, que sólo existe cuando algo está cerrado.
  ///
  /// El intento anterior recorría los `InkWell` y llevaba un set de "ya
  /// tocados" por instancia de widget. No funciona: Flutter recrea los widgets
  /// en cada build, así que ninguno se reconocía como visto y cada pasada
  /// re-tocaba lo ya abierto, cerrándolo. Con la flecha no hay ambigüedad —
  /// mientras quede una, queda algo por abrir.
  Future<void> abrirTodo(WidgetTester tester) async {
    // `pumpAndSettle` NO sirve acá: los `db.watch` de PowerSync mantienen el
    // frame loop vivo y la espera se agota siempre. Se bombea a mano.
    Future<void> bombear() async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    // 1) La tarjeta. Su encabezado es el primer `InkWell` del árbol.
    if (find.byType(InkWell).evaluate().isNotEmpty) {
      await tester.tap(find.byType(InkWell).first, warnIfMissed: false);
      await bombear();
    }

    // 2) Cada comunidad con desglose, de a una, hasta que no quede ninguna
    // cerrada. El tope evita un loop infinito si algo dejara de responder.
    for (var i = 0; i < 40; i++) {
      final cerradas = find.byIcon(Icons.chevron_right);
      if (cerradas.evaluate().isEmpty) return;
      await tester.tap(cerradas.first, warnIfMissed: false);
      await bombear();
    }
  }

  group('el diseño de producción, no el del rework', () {
    testWidgets('el título y los dos filtros', (tester) async {
      await montar(tester);
      expect(find.text('Recuperación por cobrador y comunidad'), findsOneWidget);
      expect(find.text('Toda la mora'), findsOneWidget);
      expect(find.text('Vencidas del período'), findsOneWidget);
    });

    testWidgets('NO quedó nada de la versión de tabla', (tester) async {
      await montar(tester);
      // El encabezado de columnas era la marca de la versión que el dueño
      // pidió deshacer. Si vuelve a aparecer es que alguien rehizo la tabla.
      expect(find.text('% del total'), findsNothing);
      expect(find.text('Total en mora'), findsNothing,
          reason: 'era la fila madre de la tabla; en producción el total va '
              'en el encabezado de la tarjeta');
    });

    testWidgets('sin botón de Excel', (tester) async {
      await montar(tester);
      expect(find.byIcon(Icons.file_download_outlined), findsNothing);
    });
  });

  group('los tres niveles', () {
    testWidgets('el desglose por monto sale al tocar la comunidad',
        (tester) async {
      await montar(tester);
      // Cerrado, el tercer nivel no existe.
      expect(find.textContaining('×'), findsNothing);
      await abrirTodo(tester);
      expect(find.textContaining('×'), findsWidgets,
          reason: 'el desglose dice "MONTO × N cuotas"');
    });

    testWidgets('TODAS las comunidades se pueden abrir', (tester) async {
      await montar(tester);
      // Abrir sólo la tarjeta, no las comunidades.
      await tester.tap(find.byType(InkWell).first, warnIfMissed: false);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Una fila de COMUNIDAD termina en el conteo pelado ("5.690,00 C$ · 8");
      // la de COBRADOR termina en la palabra ("23.535,00 C$ · 34 cuotas"). Es
      // lo que las distingue sin depender de la jerarquía de widgets.
      final comunidades = find
          .byWidgetPredicate((w) =>
              w is Text &&
              (w.data ?? '').contains(' · ') &&
              !(w.data ?? '').endsWith('cuota') &&
              !(w.data ?? '').endsWith('cuotas'))
          .evaluate()
          .length;
      expect(comunidades, greaterThan(0), reason: 'no se listó ninguna');

      // 🔴 EL BUG QUE ESTE TEST EXISTE PARA CAZAR (2026-09-02): hubo una
      // versión que ocultaba la flecha cuando la comunidad tenía UN SOLO
      // tramo, con el argumento de que abrirla repetiría la fila. Es falso: la
      // fila dice el total y la cantidad, nunca el monto UNITARIO. Rubén lo
      // reportó como *"no sé de cuánto es la cantidad de las que consiste"*.
      expect(find.byIcon(Icons.chevron_right).evaluate().length, comunidades,
          reason: 'hay $comunidades comunidades y no todas tienen flecha: una '
              'fila sin flecha se lee como "acá no hay nada más"');
    });

    testWidgets('cada desglose trae su línea de verificación', (tester) async {
      await montar(tester);
      await abrirTodo(tester);
      expect(find.textContaining('Coincide:'), findsWidgets,
          reason: 'el dueño la pidió para poder verificar el número sin '
              'sacar la calculadora (2026-08-28)');
    });
  });

  group('entra en la pantalla', () {
    for (final ancho in [360.0, 800.0, 1900.0]) {
      testWidgets('a ${ancho.toInt()}px, con TODO abierto', (tester) async {
        await montar(tester, ancho: ancho);
        await abrirTodo(tester);
        expect(tester.takeException(), isNull,
            reason: 'la tarjeta desborda a ${ancho.toInt()}px');
      });
    }

    testWidgets('las cifras de cobrador forman UNA columna', (tester) async {
      await montar(tester);
      // Un solo `Expanded` y del lado izquierdo (regla #15): la cifra de la
      // derecha cae siempre en el mismo borde, mida lo que mida el nombre.
      // Con un `Flexible` hermano, cada fila terminaría en un borde distinto
      // según el largo del texto de al lado.
      final derechas = <double>{};
      for (final e in find.textContaining(' cuotas').evaluate()) {
        derechas
            .add(tester.getRect(find.byWidget(e.widget)).right.roundToDouble());
      }
      expect(derechas.length, lessThanOrEqualTo(1),
          reason: 'las cifras de cobrador terminan en ${derechas.length} '
              'bordes distintos: $derechas');
    });
  });
}
