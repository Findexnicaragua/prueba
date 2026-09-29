@TestOn('vm')
library;

/// Que las cifras del Resumen formen UNA COLUMNA, a cualquier ancho.
///
/// Nace de un reporte del dueño con capturas (2026-09-01): *"no está bien
/// alineada la información, como que el formato visual no tiene boundaries y se
/// va out of bounds… ¿podemos revisar que el UI y UX sea muy bien
/// responsive?"*. En "Estado actual" a 1900px las cifras terminaban en **siete
/// bordes derechos distintos** y se leían como texto suelto flotando.
///
/// ## Por qué un test y no una mirada
///
/// La desalineación no rompe nada: no hay excepción, no hay overflow, el widget
/// se dibuja. `flutter analyze` no la ve y ningún test de datos tampoco. Sólo
/// se nota mirando, y a un ancho concreto — el de la PC del dueño, no el que
/// usa el resto de los tests.
///
/// ## La regla que verifica
///
/// Los bordes DERECHOS de todas las cifras de una tarjeta tienen que coincidir.
/// Se permite más de uno sólo por el redondeo del layout (medio pixel), no por
/// diseño.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/estado_actual_card.dart';
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
    test('alineacion (saltado: falta powersync-sqlite-core)', () {}, skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('alin_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
    await db.initialize();
    await sembrarEscenario(db);
    ps.db = db;
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> montar(WidgetTester tester, double ancho) async {
    tester.view.physicalSize = Size(ancho, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
            body: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: EstadoActualCard(),
            ),
          ),
        ),
      ));
      for (var i = 0; i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  // ── ESTADO ACTUAL ────────────────────────────────────────────────────
  //
  // 🔴 ACÁ HABÍA otro test, y su desaparición merece explicación porque el
  // invariante que medía sigue siendo válido para el resto del Resumen.
  //
  // Medía que TODAS las cifras de "Estado actual" terminaran en el MISMO borde
  // derecho. Tenía sentido cuando la tarjeta era una LISTA DE RENGLONES
  // (rótulo + hint + "cuotas · monto · %"): ahí las cifras están una debajo de
  // otra y desalinearlas se lee como texto flotando. Fue el reporte del dueño
  // del 2026-09-01 —siete bordes distintos a 1900px— y lo causaba un
  // `Flexible` y un `Expanded` hermanos en el mismo `Row` (regla #15).
  //
  // El 2026-09-02 el dueño pidió volver al estilo de producción, y ahí la
  // tarjeta es una GRILLA de cuadraditos: cada cifra vive en su propia celda,
  // y sus bordes derechos NO tienen por qué coincidir — coinciden por columna,
  // que es cosa del `GridView`, no del layout de cada tarjeta. Exigirle una
  // sola columna a una grilla es medir la propiedad equivocada: fallaría
  // siempre sobre un layout sano.
  //
  // El invariante NO se perdió: sigue vivo abajo para el globo de Cobertura,
  // que sí es una lista de renglones. Lo que se reemplaza acá es la propiedad
  // que SÍ manda en una grilla — cuántas columnas arma a cada ancho, que es de
  // donde salen los desbordes.
  for (final caso in const [
    (360.0, 1, 'teléfono de campo'),
    (800.0, 2, 'ventana a medias'),
    (1900.0, 3, 'la PC del dueño'),
  ]) {
    testWidgets(
        'Estado actual: ${caso.$2} columna(s) a ${caso.$1.toInt()}px '
        '(${caso.$3})', (tester) async {
      await montar(tester, caso.$1);

      // TODOS los `Card` de la pantalla son KPIs: "Estado actual" NO se
      // envuelve en uno —devuelve un `Column` con el encabezado suelto—, que
      // es como está en producción. Saltear el primero creyendo que es el
      // contenedor descuenta un KPI y hace que la cuenta de columnas dé uno
      // de menos a cada ancho (pasó al escribir este test).
      final cuadros = find.byType(Card).evaluate().toList();
      expect(cuadros.length, 4,
          reason: 'los cuatro KPIs: clientes, por cobrar, en mora y '
              'suspendido (el escenario tiene cuotas suspendidas, así que el '
              'cuarto se dibuja)');

      // Cuántos comparten el borde SUPERIOR del primero = ancho de la grilla.
      final tops = cuadros
          .map((e) => tester.getRect(find.byWidget(e.widget)).top.round())
          .toList();
      final primeraFila = tops.where((t) => t == tops.first).length;

      expect(primeraFila, caso.$2,
          reason: 'la grilla arma $primeraFila columna(s) a '
              '${caso.$1.toInt()}px y tendría que armar ${caso.$2}. Los cortes '
              'son >=900 para 3 y >=500 para 2 (`_Kpis`).');

      // Y que nada desborde: el `childAspectRatio` de la grilla es la causa
      // clásica — con 4.0 y con 3.0 el contenido no entraba (ver `_Kpis`).
      expect(tester.takeException(), isNull);
    });
  }

  // ── EL GLOBO DE COBERTURA ────────────────────────────────────────────
  //
  // Tiene el MISMO defecto y se dio por bueno mirando una captura donde no se
  // notaba: sus tres renglones parecían alineados porque los rótulos medían
  // parecido. Con "a tiempo" (corto) y "venían de mora" (largo) en la misma
  // tabla, cada `Flexible` se queda con un hueco distinto y las columnas de
  // cuotas y de monto se corren uno respecto del otro.
  //
  // Mirar una captura NO es verificar. Esto se mide.

  Future<void> montarCobertura(WidgetTester tester, double ancho) async {
    tester.view.physicalSize = Size(ancho, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
            body: SingleChildScrollView(child: TendenciaCobrosCard()),
          ),
        ),
      ));
      for (var i = 0; i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  // LA PRUEBA TIENE QUE SER ENTRE DÍAS, NO DENTRO DE UNO.
  //
  // La primera versión miraba un solo día y daba verde con el layout ROTO. El
  // motivo: con `Flexible` + `Expanded`, si los montos son LARGOS el rótulo se
  // satura a su cuota y las tres filas miden igual — alineadas por casualidad.
  // Con montos cortos (los de la captura del dueño: 425 y 800) no satura, cada
  // rótulo mide su natural y la columna de cuotas se corre.
  //
  // O sea que la alineación dependía del CONTENIDO. Por eso se compara la
  // columna entre días DISTINTOS del mismo ciclo, que es justo donde el
  // contenido cambia de largo.
  // DOS anchos, y el angosto es el que importa: a 1400px el gráfico mide ~1300
  // y el globo 250, así que entra en cualquier posición y el bug no se ejercita
  // — con ese ancho solo, el test daba verde CON el layout roto. A 400px el
  // gráfico mide ~300 y salirse es forzoso salvo que se lo acote.
  for (final ancho in [1400.0, 400.0]) {
  testWidgets('el globo a ${ancho.toInt()}px: forma columna y NO se sale',
      (tester) async {
    await montarCobertura(tester, ancho);

    // Al ciclo anterior, que es el que tiene días con mora.
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.chevron_left).first);
      for (var i = 0; i < 14; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });

    // El lienzo se reconoce por su ALTO (180 = `chartHeight`); buscarlo como
    // "el más ancho" da un fondo de pantalla completa.
    var lienzo = Rect.zero;
    for (final e in find.byType(CustomPaint).evaluate()) {
      final r = tester.getRect(find.byWidget(e.widget));
      if ((r.height - 180).abs() < 1 && r.width > lienzo.width) lienzo = r;
    }
    expect(lienzo.width, greaterThan(200),
        reason: 'no se encontró el lienzo del gráfico');

    // La alineación es DENTRO de cada globo: el globo entero se mueve con el
    // día (está pegado a su punto en la curva), así que comparar posiciones
    // absolutas entre días da 31 valores distintos y no prueba nada. Lo que
    // tiene que valer es que, en UN globo, todos los montos terminen en el
    // mismo x y todas las cuotas también.
    final fallas = <String>[];
    var diasVistos = 0;

    for (var i = 0; i < 31; i++) {
      await tester.runAsync(() async {
        final x = lienzo.left + 55 + (lienzo.width - 60) * (i + 0.5) / 31;
        await tester.tapAt(Offset(x, lienzo.center.dy));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      });
      // El globo está abierto si se ve el acumulado, que sale siempre.
      if (find.text('Acumulado del ciclo').evaluate().isEmpty) continue;
      diasVistos++;

      final montos = <int>{};
      final cuotas = <int>{};
      for (final e in find.byType(Text).evaluate()) {
        final t = e.widget as Text;
        final d = t.data ?? '';
        final r = tester.getRect(find.byWidget(t));
        // Sólo lo de adentro del globo, que flota sobre el gráfico.
        if (r.top < lienzo.top - 40 || r.top > lienzo.bottom) continue;
        if (d.endsWith(r'C$')) {
          montos.add(r.right.round());
        } else if (RegExp(r'^[0-9]+$').hasMatch(d)) {
          cuotas.add(r.right.round());
        }
      }
      // EL GLOBO NO SE PUEDE SALIR DEL GRAFICO. Es lo que el dueno vio
      // recortado: se posicionaba con `left` o con `right` y ninguno de los
      // dos acota, asi que en los dias cerca de un borde se dibujaba fuera de
      // la tarjeta (el Stack tiene `clipBehavior: Clip.none`).
      //
      // Se mide sobre el CONTENIDO del globo, no sobre su caja: la caja es un
      // Container sin key y hay varios; sus textos alcanzan, porque si el
      // globo se sale, su texto se sale con el.
      for (final e in find.byType(Text).evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        if (r.top < lienzo.top - 40 || r.top > lienzo.bottom) continue;
        if (r.left < lienzo.left - 1) {
          fallas.add('día $i: el globo se sale por la IZQUIERDA '
              '(${r.left.toStringAsFixed(0)} < ${lienzo.left.toStringAsFixed(0)})');
          break;
        }
        if (r.right > lienzo.right + 1) {
          fallas.add('día $i: el globo se sale por la DERECHA '
              '(${r.right.toStringAsFixed(0)} > ${lienzo.right.toStringAsFixed(0)})');
          break;
        }
      }
      if (montos.length > 1) {
        fallas.add('día $i: los montos terminan en ${montos.length} lugares '
            '($montos)');
      }
      if (cuotas.length > 1) {
        fallas.add('día $i: las cuotas terminan en ${cuotas.length} lugares '
            '($cuotas)');
      }
    }

    expect(diasVistos, greaterThan(2),
        reason: 'se abrieron $diasVistos globos: muy pocos para comparar');

    expect(fallas, isEmpty,
        reason: 'el globo no forma columna en ${fallas.length} casos. Síntoma '
            'de un `Flexible` que mide su CONTENIDO en vez de su cuota, así '
            'que la alineación depende del largo de los textos — ver '
            '`_tablaGlobo`, que la resuelve con `IntrinsicColumnWidth`. '
            '${fallas.take(6).join(' · ')}');
    expect(tester.takeException(), isNull);
  });
  }
}