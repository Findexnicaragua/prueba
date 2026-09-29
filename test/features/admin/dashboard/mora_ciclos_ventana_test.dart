@TestOn('vm')
library;

/// La ventana de "Mora del ciclo": el encabezado y las BARRAS tienen que
/// nombrar los mismos seis meses.
///
/// ## El bug que este test existe para cazar (audit 2026-09-03)
///
/// La tarjeta ganó un selector de ventana (◀ ▶) el 2026-09-02. El stream que
/// baja los datos, el rótulo del rango y el Excel se armaban con `_mesFin`
/// (= el ancla `_mesHoy` MÁS el desplazamiento del selector). El armado de las
/// barras se quedó en `_mesHoy`, el ancla fija:
///
/// ```dart
/// final ciclos = CicloMora.deFilas(snap.data,
///     anioFin: _anioHoy,
///     mesFin: _mesHoy,   // ← el bug: debía ser _mesFin
///     ...);
/// ```
///
/// Efecto: se aprieta ◀, el encabezado dice "Mar – Ago" y el Excel baja
/// Mar–Ago, pero las barras siguen dibujando Abr–Sep con la última en cero.
/// Tres ventanas distintas en una sola tarjeta. La línea del Excel (:401) ya
/// llevaba un comentario explicando por qué ahí no podía ir `_mesHoy` — se
/// arregló esa y quedó mintiendo la gráfica de al lado.
///
/// ## 🔴 Por qué ESTE test falla contra el código viejo (regla 15b)
///
/// Un test que no distingue el ANTES del DESPUÉS es decoración. Este compara
/// el encabezado contra las etiquetas del eje X **después de mover el
/// selector**:
///
///   · Con `mesFin: _mesFin` (arreglado) el encabezado dice "Mar – Ago" y las
///     barras dicen mar…ago. Coinciden → PASA.
///   · Con `mesFin: _mesHoy` (viejo) el encabezado dice "Mar – Ago" y las
///     barras siguen en abr…sep. NO coinciden → FALLA.
///
/// No compara contra meses hardcodeados —eso ataría el test al calendario del
/// día que se corre— sino las DOS superficies entre sí, que es exactamente el
/// invariante que se rompió.
///
/// Un test de unidad sobre `CicloMora.deFilas` NO habría servido: esa función
/// siempre hizo lo correcto con lo que le pasaban. El defecto estaba en el
/// LLAMADOR, así que hay que montar el widget y tocar la flecha.
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
import 'package:isp_billing/data/utils/periodo_dashboard.dart'
    show kMesesCortosPeriodo;
import 'package:isp_billing/features/admin/dashboard/mora_ciclos_card.dart';
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
    test('mora_ciclos_ventana (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  setUpAll(() async {
    // Sin fuente cargada, cada glifo mide fontSize × fontSize y cualquier
    // medición de layout miente. Acá sólo se leen textos, pero se carga igual
    // para que el render sea el mismo que en las otras tarjetas.
    final f = File('assets/fonts/NotoSans-Regular.ttf');
    if (!f.existsSync()) return;
    await (FontLoader('NotoTest')
          ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync()))))
        .load();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mora_ciclos_');
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

  Future<void> montar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
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
          supportedLocales: const [Locale('es', 'NI'), Locale('es'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const Scaffold(
              body: SingleChildScrollView(child: MoraCiclosCard())),
        ),
      ));
      // `pumpAndSettle` NO sirve: los `db.watch` de PowerSync mantienen el
      // frame loop vivo y la espera se agota siempre. Se bombea a mano.
      for (var i = 0; i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  Future<void> bombear(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Los seis rótulos del eje X, en el orden en que se dibujan.
  List<String> mesesDeLasBarras(WidgetTester tester) => find
      .byWidgetPredicate(
          (w) => w is Text && kMesesCortosPeriodo.contains(w.data))
      .evaluate()
      .map((e) => (e.widget as Text).data!)
      .toList();

  /// "Abr – Sep 2026" → ['abr', 'sep']. El encabezado nombra los DOS extremos.
  List<String> mesesDelEncabezado(WidgetTester tester) {
    final t = find
        .byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('–'))
        .evaluate()
        .map((e) => (e.widget as Text).data!)
        .firstWhere((s) => s.contains('–'));
    return t
        .split('–')
        .map((s) => s.trim().toLowerCase())
        .map((s) => s.length >= 3 ? s.substring(0, 3) : s)
        .toList();
  }

  group('el encabezado y las barras nombran la MISMA ventana', () {
    testWidgets('al abrir, sin tocar nada', (tester) async {
      await montar(tester);
      final barras = mesesDeLasBarras(tester);
      expect(barras, hasLength(6),
          reason: 'la gráfica dibuja 6 ciclos; se encontraron ${barras.length}');

      final cab = mesesDelEncabezado(tester);
      expect(barras.first, cab.first,
          reason: 'el encabezado empieza en ${cab.first} y la primera barra '
              'es ${barras.first}');
      expect(barras.last, cab.last,
          reason: 'el encabezado termina en ${cab.last} y la última barra '
              'es ${barras.last}');
    });

    testWidgets('🔴 después de apretar ◀ — el caso que fallaba', (tester) async {
      await montar(tester);
      final barrasAntes = mesesDeLasBarras(tester);
      final cabAntes = mesesDelEncabezado(tester);

      final atras = find.byIcon(Icons.chevron_left);
      expect(atras, findsOneWidget);
      final boton = tester.widget<IconButton>(
          find.ancestor(of: atras, matching: find.byType(IconButton)).first);
      expect(boton.onPressed, isNotNull,
          reason: 'la flecha de retroceder está deshabilitada: el escenario no '
              'tiene datos suficientemente viejos para mover la ventana');

      await tester.tap(atras, warnIfMissed: false);
      await bombear(tester);

      final barrasDespues = mesesDeLasBarras(tester);
      final cabDespues = mesesDelEncabezado(tester);

      // 1) El encabezado SÍ se movió (esto pasaba también con el bug).
      expect(cabDespues, isNot(equals(cabAntes)),
          reason: 'el encabezado no se movió al apretar la flecha');

      // 2) 🔴 Y las barras se movieron CON él. Con `mesFin: _mesHoy` esta
      // expectativa falla: las barras quedan idénticas a `barrasAntes`.
      expect(barrasDespues, isNot(equals(barrasAntes)),
          reason: 'las barras siguen dibujando los mismos meses '
              '($barrasAntes) mientras el encabezado ya dice $cabDespues: la '
              'gráfica no siguió al selector');

      // 3) Y coinciden entre sí, que es el invariante de verdad.
      expect(barrasDespues.first, cabDespues.first,
          reason: 'encabezado empieza en ${cabDespues.first}, primera barra '
              '${barrasDespues.first}');
      expect(barrasDespues.last, cabDespues.last,
          reason: 'encabezado termina en ${cabDespues.last}, última barra '
              '${barrasDespues.last}');
    });

    testWidgets('y al volver con ▶ queda como al principio', (tester) async {
      await montar(tester);
      final barrasAntes = mesesDeLasBarras(tester);

      await tester.tap(find.byIcon(Icons.chevron_left), warnIfMissed: false);
      await bombear(tester);
      await tester.tap(find.byIcon(Icons.chevron_right), warnIfMissed: false);
      await bombear(tester);

      expect(mesesDeLasBarras(tester), barrasAntes,
          reason: 'ir y volver tiene que dejar la ventana donde estaba');
    });
  });
}
