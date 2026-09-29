@TestOn('vm')
library;

/// El Resumen A ANCHO DE TELÉFONO (360px).
///
/// ## Por qué existe este archivo
///
/// Los bugs que el dueño reportó el 2026-09-02 y el 2026-09-03 —las dos tablas
/// inconsistentes, el monto ilegible, la barra de mora que no abre el globo—
/// **salieron todos de probar sólo en PC**. Hasta el test que se escribió para
/// el globo medía a 1200px, donde el bug no se ejercita (regla 15b del
/// checklist: un test que no distingue el ANTES del DESPUÉS es decoración).
///
/// Así que este archivo mide **siempre a 360px**, que es el teléfono real donde
/// se reportó, y cada `expect` marcado 🔴 tiene que fallar contra el código
/// viejo.
///
/// ## Qué se prueba de la forma nueva
///
/// Abajo de `kAnchoTablaCompleta` las tablas dejan de ser grilla y pasan a
/// "el total arriba y sus partes abajo" (ver `bloque_parte_y_todo.dart`). Lo
/// que hay que proteger no es el dibujo sino las tres condiciones que el dueño
/// puso:
///   1. **toda la información** — el total, cada parte, su %, sus conteos;
///   2. **las mismas dos tablas** (más "Quién cobró"), con la MISMA forma;
///   3. **la letra al tamaño del resto de la app** — nada por debajo de
///      `TxtResumen.minimo`, y el monto en su rol, nunca escalado.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/cobrador.dart';
import 'package:isp_billing/data/providers/cobrador_provider.dart';
import 'package:isp_billing/features/admin/dashboard/bloque_parte_y_todo.dart';
import 'package:isp_billing/features/admin/dashboard/escala_resumen.dart';
import 'package:isp_billing/features/admin/dashboard/mora_ciclos_card.dart';
import 'package:isp_billing/features/admin/dashboard/quien_cobro_card.dart';
import 'package:isp_billing/features/admin/dashboard/tendencia_cobros_card.dart';
import 'package:isp_billing/powersync/db.dart' as ps;
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;

import 'escenario_seed.dart';

/// El ancho del teléfono donde se reportaron los bugs.
const double kTelefono = 360;

void main() {
  String? core;
  for (final n in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    if (File(n).existsSync()) core = File(n).absolute.path;
  }
  if (core == null) {
    test('resumen_en_telefono (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  Future<void> abrir() async {
    tmp = await Directory.systemTemp.createTemp('telefono_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
    await db.initialize();
    await sembrarEscenario(db);
    ps.db = db;
  }

  Future<void> cerrar() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }

  // El tenant TIENE que ser el del escenario. "Quién cobró" filtra por
  // `co.tenant_id = ?` tomándolo del cobrador actual, así que con un tenant
  // inventado su tabla nunca se dibuja y decía "No hubo cobros en este ciclo"
  // — el test habría "probado" el estado vacío creyendo que probaba la tabla
  // (regla 16: un escenario que no siembra lo que producción tiene no prueba
  // lo que creés).
  const yo = Cobrador(
    id: '11111111-1111-1111-1111-111111111111',
    tenantId: tenantEscenario,
    nombre: 'Admin',
    rol: 'admin',
    activo: true,
  );

  /// Monta una tarjeta del Resumen al ancho pedido y espera a sus streams.
  Future<void> montar(WidgetTester tester, Widget tarjeta,
      {double ancho = kTelefono}) async {
    tester.view.physicalSize = Size(ancho, 3000);
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
      await tester.pumpWidget(ProviderScope(
        overrides: [
          cobradorActualProvider.overrideWith((ref) => Stream.value(yo)),
        ],
        child: MaterialApp(
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
          home: Scaffold(body: SingleChildScrollView(child: tarjeta)),
        ),
      ));
      for (var i = 0; i < 18; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  Future<void> asentar(WidgetTester tester, [int vueltas = 10]) =>
      tester.runAsync(() async {
        for (var i = 0; i < vueltas; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await tester.pump();
        }
      });

  /// Los tamaños de letra que un bloque dibuja de verdad.
  List<double> tamanos(WidgetTester tester, Finder de) => tester
      .widgetList<Text>(find.descendant(of: de, matching: find.byType(Text)))
      .map((t) => t.style?.fontSize ?? 0)
      .where((s) => s > 0)
      .toList();

  group('las dos tablas de Cobertura, en el teléfono', () {
    setUp(abrir);
    tearDown(cerrar);

    // 🔴 EL BUG DE FONDO: a 360px la tabla tiene 312px y las cinco columnas
    // necesitan 287 sólo de números y separadores. El `FittedBox` resolvía el
    // faltante achicando el monto al 34% — 4,8px, que es lo que el dueño
    // fotografió. Ninguna variante de la GRILLA lo arregla; hay que cambiar de
    // forma.
    //
    // Contra el código viejo `TotalResumen` no existe y este `expect` da 0.
    testWidgets('🔴 las DOS pasan a "total y partes", con el MISMO widget',
        (tester) async {
      await montar(tester, const TendenciaCobrosCard());

      // Los dos titulares: uno por tabla, y de la misma clase.
      expect(find.byType(TotalResumen), findsNWidgets(2),
          reason: 'tienen que ser las DOS tablas, con el mismo widget: es lo '
              'único que impide que vuelvan a divergir');
      expect(
          find.descendant(
              of: find.byType(TotalResumen), matching: find.text('Cobros')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(TotalResumen),
              matching: find.text('Total en mora')),
          findsOneWidget);

      // Y las partes de las dos, también con el mismo widget.
      for (final rotulo in ['Recuperado', 'Por recuperar']) {
        expect(
            find.descendant(
                of: find.byType(ParteResumen), matching: find.text(rotulo)),
            findsNWidgets(2),
            reason: '"$rotulo" tiene que estar en las dos tablas y dibujado '
                'por ParteResumen');
      }
    });

    // 🔴 LA CONDICIÓN QUE EL DUEÑO PUSO: *"que en la pantalla de un telefono se
    // miren los numeros y letras de tamaño consistente con el resto de la
    // app"*. Se mide contra la escala real, no a ojo.
    testWidgets('🔴 nada se dibuja por debajo de la escala de la app',
        (tester) async {
      await montar(tester, const TendenciaCobrosCard());

      final t = [
        ...tamanos(tester, find.byType(TotalResumen)),
        ...tamanos(tester, find.byType(ParteResumen)),
      ];
      expect(t, isNotEmpty, reason: 'no se dibujó ningún bloque');
      expect(t.reduce(math.min), greaterThanOrEqualTo(TxtResumen.minimo),
          reason: 'hay texto por debajo del piso de la escala '
              '(${TxtResumen.minimo}px). Es lo que este cambio vino a arreglar');
      // El titular usa el rol de número protagonista. Si alguien lo baja, el
      // monto vuelve a competir con su propio rótulo.
      expect(tamanos(tester, find.byType(TotalResumen)).reduce(math.max),
          TxtResumen.gigante,
          reason: 'el monto del total tiene que ir en TxtResumen.gigante');

      // Y NINGÚN `FittedBox` adentro de los bloques: es el que escalaba el
      // monto al 34%. Mientras no exista, el tamaño de la letra no puede
      // depender del largo del número.
      expect(
          find.descendant(
              of: find.byType(TotalResumen), matching: find.byType(FittedBox)),
          findsNothing,
          reason: 'volvió a aparecer un FittedBox: el monto puede encogerse');
      expect(
          find.descendant(
              of: find.byType(ParteResumen), matching: find.byType(FittedBox)),
          findsNothing);
    });

    // 🔴 La barra dice lo MISMO que el % de las filas (invariante #10: el
    // mismo número en todas las superficies). Si divergen, una está mintiendo.
    testWidgets('🔴 la barra de composición cubre el 100% del total',
        (tester) async {
      await montar(tester, const TendenciaCobrosCard());

      // Los `flex` de la barra van por MIL. Los de la barra son los que
      // envuelven un `ColoredBox`; el `Expanded` del rótulo no.
      final flex = tester
          .widgetList<Expanded>(find.descendant(
              of: find.byType(TotalResumen).first,
              matching: find.byType(Expanded)))
          .where((e) => e.child is ColoredBox)
          .map((e) => e.flex)
          .toList();
      expect(flex, isNotEmpty, reason: 'no se dibujó la barra');
      expect(flex.reduce((a, b) => a + b), 1000,
          reason: 'los tramos de la barra más la canaleta tienen que dar el '
              '100%: si no, la barra no representa el total');
    });

    // El encabezado de columnas no tiene sentido sin columnas: cada renglón
    // dice qué es su número ("4.434 usuarios · 4.445 cuotas").
    testWidgets('🔴 no queda cabecera de columnas flotando', (tester) async {
      await montar(tester, const TendenciaCobrosCard());
      expect(find.text('Usuarios'), findsNothing,
          reason: 'la cabecera de columnas quedó dibujada sobre bloques');
      expect(find.text('Monto'), findsNothing);
    });

    // CONTRAPRUEBA: en PC no cambia nada. Sin esto, el arreglo podría estar
    // cambiando también el monitor del dueño.
    testWidgets('a 1200px siguen siendo tabla, con su cabecera',
        (tester) async {
      await montar(tester, const TendenciaCobrosCard(), ancho: 1200);
      expect(find.byType(TotalResumen), findsNothing,
          reason: 'en PC la tabla de cinco columnas entra y se queda');
      expect(find.byType(ParteResumen), findsNothing);
      expect(find.text('Usuarios'), findsWidgets);
    });
  });

  group('"Quién cobró" — la TERCERA tabla, en el teléfono', () {
    setUp(abrir);
    tearDown(cerrar);

    // 🔴 La encontró el barrido de superficies, no el reporte: es una tercera
    // tabla con la misma estructura (Total cobrado + una fila por cobrador) y
    // llevaba el criterio del 2026-08-29 —ocultar el % y sacarle el "C$" al
    // monto—, que es justo el que se rechazó.
    testWidgets('🔴 también pasa a "total y partes"', (tester) async {
      await montar(tester, const QuienCobroCard());
      expect(
          find.descendant(
              of: find.byType(TotalResumen),
              matching: find.text('Total cobrado')),
          findsOneWidget,
          reason: '"Quién cobró" se quedó con su propio modo teléfono');
      // Su conteo son COBROS, no cuotas: en la tabla lo decía el encabezado de
      // la columna, y el bloque no tiene encabezado.
      expect(find.textContaining('cobros'), findsWidgets,
          reason: 'el renglón de apoyo tiene que decir la palabra del conteo');
    });

    testWidgets('a 1200px sigue siendo tabla', (tester) async {
      await montar(tester, const QuienCobroCard(), ancho: 1200);
      expect(find.byType(TotalResumen), findsNothing);
      expect(find.text('% del total'), findsOneWidget);
    });
  });

  group('la gráfica de mora de 6 ciclos, en el teléfono', () {
    setUp(abrir);
    tearDown(cerrar);

    // 🔴 EL BUG: el globo de las barras sólo respondía a `onHover`. El
    // `onTapUp` se había sacado el 2026-09-02 porque navegaba a un ciclo, y al
    // sacarlo quedó SOLO el hover — que en Android no existe. El dueño lo
    // reportó dos veces: *"al pulsar una barra no aparece el tooltip"*.
    testWidgets('🔴 tocar una barra abre el globo', (tester) async {
      await montar(tester, const MoraCiclosCard());

      // El globo lo delata su segunda línea, que no existe en ningún otro lado
      // de la tarjeta. "Mora del ciclo" NO sirve de ancla: es el título y está
      // dibujado con globo o sin globo (así este test pasaba en falso).
      Finder globo() => find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data == 'Ciclo en curso' || w.data == 'Ciclo cerrado'));
      expect(globo(), findsNothing,
          reason: 'el globo no puede estar abierto antes de tocar nada');

      // El área de las barras. Se ancla al '0' del eje Y —abajo a la izquierda
      // de la gráfica— y se entra 60px a la derecha, que ya es la primera
      // columna: el eje mide 56 y hay 6 de separación. Tapping a ojo sobre el
      // centro de la tarjeta cae en el selector de ciclo.
      final cero = tester.getRect(find.text('0').first);
      await tester.tapAt(Offset(cero.right + 60, cero.center.dy - 20));
      await asentar(tester);

      expect(globo(), findsOneWidget,
          reason: 'tocar una barra tiene que abrir el globo: en un teléfono no '
              'hay hover y era la única forma de llegar al desglose');

      // Y ALTERNA: sin `onExit` en Android, si el tap no cerrara, el globo
      // quedaría clavado tapando la gráfica.
      await tester.tapAt(Offset(cero.right + 60, cero.center.dy - 20));
      await asentar(tester);
      expect(globo(), findsNothing,
          reason: 'tocar la misma barra otra vez tiene que cerrar el globo');
    });

    // 🔴 EL BUG QUE ESTE ARCHIVO ENCONTRÓ DE PASO: adentro del globo, cada
    // renglón es "rótulo · número" con `spaceBetween` y NADA flexible. Con un
    // monto de siete dígitos el `Row` desborda y el número se PINTA FUERA de
    // la caja del globo, encima de la gráfica.
    //
    // No dependía del ancho de pantalla: el globo medía 208 fijos, así que
    // pasaba también en PC. Contra el código viejo este test revienta con "A
    // RenderFlex overflowed by 122 pixels on the right" — `flutter_test` falla
    // solo ante un desborde de layout. `flutter analyze` no lo ve.
    testWidgets('🔴 el globo no desborda por dentro', (tester) async {
      await montar(tester, const MoraCiclosCard());

      // Con el MOUSE, no con el tap: así este test también se puede correr
      // contra el código viejo, donde el tap no abría nada. Lo que se prueba
      // es el CONTENIDO del globo, que es el mismo por los dos caminos.
      final gesto = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesto.addPointer(location: Offset.zero);
      addTearDown(gesto.removePointer);

      final cero = tester.getRect(find.text('0').first);
      var abiertos = 0;
      // Las 6 columnas, una por una: el desborde depende del LARGO del monto
      // de cada ciclo, así que mirando una sola se puede caer justo en la corta.
      for (var i = 0; i < 6; i++) {
        await gesto
            .moveTo(Offset(cero.right + 20 + i * 40, cero.center.dy - 30));
        await asentar(tester, 3);
        if (find
            .byWidgetPredicate((w) =>
                w is Text &&
                (w.data == 'Ciclo en curso' || w.data == 'Ciclo cerrado'))
            .evaluate()
            .isNotEmpty) {
          abiertos++;
        }
      }
      expect(abiertos, greaterThan(2),
          reason: 'el hover no abrió el globo en suficientes columnas: el test '
              'estaría pasando sin medir nada');
    });
  });

  group('el globo de la curva de cobros, en el teléfono', () {
    setUp(abrir);
    tearDown(cerrar);

    // Este NO cazó un bug: pasa también contra el código viejo, porque el
    // recorte que el dueño fotografió lo había arreglado el cambio de orden de
    // pintado del 2026-09-03. Queda como guardia de regresión, y se dice acá
    // para que nadie lo lea como si hubiera encontrado algo.
    testWidgets('el globo entra entero en la tarjeta', (tester) async {
      await montar(tester, const TendenciaCobrosCard());

      final tarjeta = tester.getRect(find.byType(TendenciaCobrosCard));
      // Se abre con el TAP, que es el camino del teléfono. La zona de la curva
      // se ancla a su propio título, que está justo encima: la gráfica mide
      // 180 de alto y arranca 8px abajo del rótulo.
      final rotulo =
          tester.getRect(find.textContaining('Recuperado acumulado').first);
      final y = rotulo.bottom + 90;

      // SE PRUEBAN VARIOS DÍAS, no uno. El globo cambia de alto según el día
      // —uno sin cobros son tres renglones; uno con mora, seis— y de posición
      // según dónde cae su punto. Midiendo un solo día el test daría verde
      // justo en el día corto (regla 15b). Sólo la parte TRANSCURRIDA del
      // ciclo: `_onTap` no selecciona nada más allá de `_diasConDatos`.
      var probados = 0;
      for (final f in [
        0.06, 0.10, 0.14, 0.18, 0.22, 0.26,
        0.30, 0.34, 0.38, 0.42, 0.46, 0.50,
      ]) {
        await tester.tapAt(Offset(tarjeta.left + tarjeta.width * f, y));
        await asentar(tester, 4);

        // El globo SIEMPRE trae este renglón, tenga o no cobros ese día. Se
        // anclaba en `' de '` y era un falso verde: eso matchea también el
        // subtítulo "de lo que vence en el ciclo", que está siempre dibujado.
        final dentro = find.text('Acumulado del ciclo');
        if (dentro.evaluate().isEmpty) continue;
        probados++;

        // El rectángulo del GLOBO ENTERO —su `IgnorePointer`—, no el de un
        // renglón suelto: lo que se sale por abajo es el último, y midiendo
        // uno del medio el test daría verde con el globo desbordado.
        final globo = tester.getRect(find
            .ancestor(of: dentro.first, matching: find.byType(IgnorePointer))
            .first);
        expect(globo.bottom, lessThanOrEqualTo(tarjeta.bottom + 0.5),
            reason: 'el globo se sale por abajo de la tarjeta: termina en '
                '${globo.bottom.toStringAsFixed(0)} y la tarjeta en '
                '${tarjeta.bottom.toStringAsFixed(0)}');
        expect(globo.right, lessThanOrEqualTo(tarjeta.right + 0.5),
            reason: 'el globo se sale por la derecha');
        expect(globo.left, greaterThanOrEqualTo(tarjeta.left - 0.5),
            reason: 'el globo se sale por la izquierda');
      }
      expect(probados, greaterThan(6),
          reason: 'el tap no abrió el globo en suficientes días: el test '
              'estaría pasando sin medir nada');
    });
  });
}
