@TestOn('vm')
library;

/// La tabla de mora vive DENTRO de "Cobertura del ciclo" (2026-09-02).
///
/// **Por qué hace falta un test y no alcanza con mirarlo.** Vivía en la tarjeta
/// de los 6 ciclos con SU PROPIO selector, así que había dos controles de ciclo
/// en el Resumen que podían quedar en meses distintos mirando lo mismo. Rubén
/// la pidió arriba, bajo el selector de Cobertura. Nada de eso lo caza
/// `flutter analyze` ni un test de números: el widget compila y se dibuja
/// igual esté donde esté.
///
/// **Este test FALLA contra el código anterior**, que es lo único que lo vuelve
/// una red y no decoración (AGENTS, lección 15b): antes de la mudanza,
/// `TendenciaCobrosCard` no contenía "Total en mora" por ningún lado.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/cobrador.dart';
import 'package:isp_billing/data/providers/cobrador_provider.dart';
import 'package:isp_billing/features/admin/dashboard/mora_ciclos_card.dart';
import 'package:isp_billing/features/admin/dashboard/tendencia_cobros_card.dart';
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
    test('mora_tabla_en_cobertura (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  // 🔴 Sin esto NO se puede testear si un texto se corta. En un widget test
  // sin fuentes cargadas, Flutter usa una fuente de prueba donde CADA glifo
  // mide `fontSize` × `fontSize`: "Cuotas" mediría 75px a 12,5 contra ~42 de
  // una fuente real. Un test de recorte sobre eso exige columnas del doble y
  // da positivo sobre un layout sano — se intentó, y marcaba hasta "Cuotas".
  //
  // NotoSans es la que la app ya embebe para los PDFs. No es la que Windows
  // usa en pantalla (ahí manda Segoe UI), así que es un PROXY: sirve para
  // saber si un texto entra con holgura o va al límite, no para el pixel.
  setUpAll(() async {
    final f = File('assets/fonts/NotoSans-Regular.ttf');
    if (!f.existsSync()) return;
    final bytes = f.readAsBytesSync();
    await (FontLoader('NotoTest')
          ..addFont(Future.value(ByteData.sublistView(bytes))))
        .load();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mora_tabla_');
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

  Future<void> montar(WidgetTester tester, Widget card,
      {double ancho = 1200}) async {
    tester.view.physicalSize = Size(ancho, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Desmontar ANTES de que el tearDown cierre la base: con los `db.watch`
    // todavía suscritos, `close()` no vuelve nunca.
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
          // Con la fuente real cargada, medir anchos dice algo.
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
          home: Scaffold(body: SingleChildScrollView(child: card)),
        ),
      ));
      for (var i = 0; i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  group('la tabla de mora se mudó a Cobertura del ciclo', () {
    testWidgets('Cobertura la contiene, junto a la suya', (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      // La fila que SOLO existe en la tabla de mora.
      expect(find.text('Total en mora'), findsOneWidget);
      // La que solo existe en la de cobertura: la mudanza SUMA, no reemplaza.
      expect(find.text('Cobros'), findsWidgets);
      // Y las que comparten las DOS tablas aparecen repetidas. Es el choque
      // de vocabulario que obligó a poner encabezados (ver el test de abajo):
      // el `Recuperado` de Cobertura es *de lo que vence este ciclo, cuánto se
      // cobró* y el de Mora es *de lo que cayó en mora, cuánto se rescató*.
      //
      // TRES y no dos: las dos filas más la LEYENDA de la curva, que también
      // dice "Recuperado". El número exacto es a propósito — si algún día
      // aparece una cuarta, es que algo se duplicó sin querer.
      expect(find.text('Recuperado'), findsNWidgets(3));
      expect(find.text('Por recuperar'), findsNWidgets(2));
    });

    testWidgets('los encabezados son lo que las separa', (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      // Sin estos dos, las cuatro filas repetidas no se pueden distinguir.
      expect(find.text('COBERTURA DEL CICLO'), findsOneWidget);
      expect(find.text('COBERTURA DE MORA'), findsOneWidget);
    });

    testWidgets('la tarjeta de los 6 ciclos ya NO tiene la tabla',
        (tester) async {
      await montar(tester, const MoraCiclosCard());
      // `Total en mora` era EXCLUSIVA de la tabla, así que su ausencia prueba
      // la mudanza. `Por recuperar` NO se chequea acá: sigue existiendo como
      // leyenda de color debajo de las barras, y corresponde que siga.
      expect(find.text('Total en mora'), findsNothing);
    });

    testWidgets('su selector mueve la VENTANA, no el ciclo', (tester) async {
      await montar(tester, const MoraCiclosCard());
      // 🔴 Este test decía lo CONTRARIO hasta el 2026-09-02: que la tarjeta no
      // debía tener flechas. La razón era buena —había dos selectores de CICLO
      // en la misma pantalla y podían quedar en meses distintos mirando lo
      // mismo— y sigue valiendo: el ciclo de la TABLA lo manda Cobertura.
      //
      // Lo que volvió es OTRO control: corre la ventana de 6 ciclos de las
      // BARRAS, que Cobertura no gobierna. Rubén lo pidió para poder mirar
      // meses viejos cuando aparece una mora que viene de atrás.
      //
      // Se distingue por lo que MUESTRA: un rango ("Abr – Sep 2026"), no un
      // mes suelto. Si algún día esto vuelve a decir un mes solo, es que
      // alguien reintrodujo el selector de ciclo y el conflicto vuelve.
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.textContaining('–'), findsWidgets,
          reason: 'el rótulo tiene que nombrar los DOS extremos de la ventana');
      // Y la tabla sigue sin volver: es lo que se mudó a Cobertura.
      expect(find.text('Total en mora'), findsNothing);
    });

    testWidgets('la gráfica de los 6 ciclos sobrevive intacta', (tester) async {
      await montar(tester, const MoraCiclosCard());
      // El título y el eje siguen; lo único que se fue es la tabla.
      expect(find.text('Mora del ciclo'), findsOneWidget);
    });
  });

  group('las dos tablas ALINEAN', () {
    // Rubén lo reportó mirando la app: "las tablas no están bien alineadas".
    // Eran DOS corrimientos distintos y ninguno lo caza `analyze`.

    testWidgets('las FILAS de las dos arrancan a la misma altura',
        (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      // Se miden las FILAS y no los encabezados. Los encabezados siempre
      // arrancaron parejos —los dos títulos son la primera línea— y el
      // corrimiento aparecía recién abajo, cuando el subtítulo de mora empujaba
      // su tabla. Medir arriba daba VERDE con el layout torcido: la primera
      // versión de este test pasaba contra el código viejo, que es la
      // definición de test decorativo (AGENTS, lección 15b).
      final a = tester.getTopLeft(find.text('Cobros'));
      final b = tester.getTopLeft(find.text('Total en mora'));
      expect((a.dy - b.dy).abs(), lessThan(1),
          reason: 'si una cabecera mide más alto que la otra, TODAS las filas '
              'de esa tabla se corren. Pasó: con las dos tablas a la mitad de '
              'ancho, "% de las 56 cuotas" envolvía a dos líneas en una y no '
              'en la otra según el largo del número, y eso corría 18px. Lo '
              'cierra `kAltoCabeceraTabla` + maxLines 1 en las dos.');
    });

    testWidgets('y miden lo mismo: los dos tienen subtítulo', (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      // Es lo que garantiza la altura pareja. Sin el de cobertura, el de mora
      // —que lleva los días de gracia— empuja su tabla hacia abajo.
      expect(find.text('de lo que vence en el ciclo'), findsOneWidget);
      expect(find.textContaining('días de gracia'), findsWidgets);
    });

    testWidgets('dentro de cada tabla, todos los rótulos arrancan igual',
        (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      // El chevron aparece solo en las filas desplegables. Si su hueco no se
      // reserva, las filas que NO se abren arrancan 12px a la izquierda y la
      // tabla se lee torcida — que es exactamente lo que se veía.
      double x(Finder f) => tester.getTopLeft(f).dx;

      final recs = find.text('Recuperado');
      final pors = find.text('Por recuperar');
      // Índice 0 = tabla de la izquierda (se construye primero); 1 = la de
      // mora. Se verifica por posición para no depender del orden de armado.
      final recIzq = x(recs.at(0)) < x(recs.at(1)) ? recs.at(0) : recs.at(1);
      final recDer = x(recs.at(0)) < x(recs.at(1)) ? recs.at(1) : recs.at(0);
      final porIzq = x(pors.at(0)) < x(pors.at(1)) ? pors.at(0) : pors.at(1);
      final porDer = x(pors.at(0)) < x(pors.at(1)) ? pors.at(1) : pors.at(0);

      // COBERTURA: `Cobros` no se abre, las otras dos sí.
      expect((x(find.text('Cobros')) - x(recIzq)).abs(), lessThan(1),
          reason: 'Cobros (sin chevron) tiene que arrancar donde Recuperado');
      expect((x(recIzq) - x(porIzq)).abs(), lessThan(1));

      // MORA: `Total en mora` y (con este escenario) `Recuperado` no se abren.
      expect((x(find.text('Total en mora')) - x(recDer)).abs(), lessThan(1),
          reason: 'Total en mora tiene que arrancar donde Recuperado');
      expect((x(recDer) - x(porDer)).abs(), lessThan(1),
          reason: 'y donde Por recuperar, que SÍ trae chevron');
    });
  });

  group('los encabezados no compiten por el ancho', () {
    // Rubén lo fotografió: "Usuar…", "% de las 56 cu…", "% de 23.575,0…".
    // La causa: con las dos tablas lado a lado cada una mide la mitad, y el
    // `maxLines: 1` que alineó las cabeceras corta en vez de envolver.
    //
    // 🔴 NO se testea "no se corta" midiendo anchos, y la razón importa: en un
    // widget test SIN fuentes reales cada glifo mide `fontSize` × `fontSize`,
    // así que "Cuotas" mide 75px acá contra ~42 en la app. Un test de recorte
    // exigiría columnas casi del doble y fallaría sobre un layout sano. Se
    // intentó y daba positivo hasta con "Cuotas".
    //
    // Lo que SÍ se puede fijar es la causa: que el encabezado largo no vuelva,
    // y que las cuatro columnas tengan el reparto que las hace entrar.

    testWidgets('ningún encabezado sale cortado', (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      // `didExceedMaxLines` es la verdad del render: con `maxLines: 1` se
      // enciende exactamente cuando el texto no entró y se puso la elipsis.
      // Esto es lo que Rubén fotografió: "Usuar…", "% de las 56 cu…".
      for (final t in ['Usuarios', 'Cuotas', '%', 'Monto']) {
        final f = find.text(t);
        for (var i = 0; i < f.evaluate().length; i++) {
          expect(tester.renderObject<RenderParagraph>(f.at(i)).didExceedMaxLines,
              isFalse,
              reason: 'el encabezado "$t" #$i sale cortado');
        }
      }
    });

    testWidgets('el % dice solo "%" en las dos tablas', (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      // La frase larga era la que empujaba a las otras dos columnas.
      expect(find.textContaining('% de las'), findsNothing);
      expect(find.textContaining('% de C\$'), findsNothing);
      expect(find.text('%'), findsNWidgets(2));
    });

    testWidgets('las cuatro columnas reparten 1-1-1-2', (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      double w(Finder f) => tester.getSize(f).width;
      final usuarios = w(find.text('Usuarios').at(0));
      final cuotas = w(find.text('Cuotas').at(0));
      final pct = w(find.text('%').at(0));
      final monto = w(find.text('Monto').at(0));
      // Las tres de conteo, iguales; el monto, el doble. Es lo que le da a
      // "Usuarios" el ancho que antes se llevaba la frase del %.
      expect((usuarios - cuotas).abs(), lessThan(1));
      expect((cuotas - pct).abs(), lessThan(1));
      expect(monto, greaterThan(usuarios * 1.9),
          reason: 'el monto necesita el doble: aloja "2.958.190,00 C\$"');
    });

    testWidgets('y la de mora reparte igual', (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      double w(Finder f) => tester.getSize(f).width;
      // Las dos tablas tienen que dar las mismas columnas, o lado a lado se
      // leen como dos grillas distintas.
      expect((w(find.text('Usuarios').at(0)) - w(find.text('Usuarios').at(1)))
          .abs(), lessThan(1));
      expect((w(find.text('Cuotas').at(0)) - w(find.text('Cuotas').at(1)))
          .abs(), lessThan(1));
    });
  });

  group('responsive: lado a lado en PC, apiladas en el teléfono', () {
    testWidgets('en 1200px las dos tablas comparten fila', (tester) async {
      await montar(tester, const TendenciaCobrosCard(), ancho: 1200);
      // Se miden los ENCABEZADOS y no las filas: son únicos por tabla, así
      // que no hay ambigüedad con los rótulos repetidos.
      final cobertura = tester.getTopLeft(find.text('COBERTURA DEL CICLO'));
      final mora = tester.getTopLeft(find.text('COBERTURA DE MORA'));
      // Misma fila = la de mora está a la DERECHA, no debajo.
      expect(mora.dx, greaterThan(cobertura.dx),
          reason: 'la tabla de mora tiene que ir al costado');
      expect((mora.dy - cobertura.dy).abs(), lessThan(2),
          reason: 'y arrancar a la misma altura');
    });

    testWidgets('en 380px una va abajo de la otra', (tester) async {
      await montar(tester, const TendenciaCobrosCard(), ancho: 380);
      final cobertura = tester.getTopLeft(find.text('COBERTURA DEL CICLO'));
      final mora = tester.getTopLeft(find.text('COBERTURA DE MORA'));
      expect(mora.dy, greaterThan(cobertura.dy),
          reason: 'en el teléfono la de mora va DEBAJO');
      expect((mora.dx - cobertura.dx).abs(), lessThan(2),
          reason: 'y alineada con ella, no corrida');
    });

    testWidgets('en 380px nada se desborda', (tester) async {
      await montar(tester, const TendenciaCobrosCard(), ancho: 380);
      expect(tester.takeException(), isNull);
    });
  });
}
