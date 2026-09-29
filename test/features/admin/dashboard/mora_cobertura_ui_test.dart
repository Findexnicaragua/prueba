@TestOn('vm')
library;

/// Las cuatro líneas de mora de "Cobertura del ciclo", RENDERIZADAS.
///
/// El test de al lado (`mora_cobertura_test.dart`) prueba que los números
/// cierren. Éste prueba que **lleguen a la pantalla**: un cambio que compila y
/// no se pinta es indistinguible de un cambio que no se hizo, y ya pasó en esta
/// misma tarjeta (2026-08-11, el dueño reportó "no hubo ningún cambio visual").
///
/// Y prueba lo otro que importa: que las líneas **arranquen cerradas**. El
/// intento anterior de meter mora acá se sacó porque agregaba ruido a una
/// tarjeta que se mira de un vistazo.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
// `Table` existe en Flutter y en PowerSync (el schema). Sin alias,
// `find.byType(Table)` no compila por ambiguedad.
import 'package:flutter/widgets.dart' as w show Table;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/cobrador.dart';
import 'package:isp_billing/data/providers/cobrador_provider.dart';
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
    test('mora_cobertura_ui (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  Future<void> abrir() async {
    tmp = await Directory.systemTemp.createTemp('mora_ui_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
    await db.initialize();
    await sembrarEscenario(db);
    ps.db = db;
  }

  Future<void> cerrar() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }

  /// Monta la tarjeta sola, al ancho pedido, y espera a sus streams.
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

    const yo = Cobrador(
      id: '11111111-1111-1111-1111-111111111111',
      tenantId: 't-mora-ui',
      nombre: 'Admin',
      rol: 'admin',
      activo: true,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          cobradorActualProvider.overrideWith((ref) => Stream.value(yo)),
        ],
        child: const MaterialApp(
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

  /// Abre un desplegable por su rótulo y deja asentar los streams.
  ///
  /// El `.first` no es capricho: "Recuperado" aparece DOS veces en la tarjeta
  /// —la fila de la tabla y la leyenda de la gráfica— y un finder ambiguo
  /// falla. La tabla se dibuja antes, así que la primera es la fila.
  Future<void> abrirFila(WidgetTester tester, String rotulo) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(rotulo).first);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  /// Retrocede un ciclo con el chevron de la tarjeta.
  ///
  /// Hace falta porque en el ciclo POR DEFECTO del escenario no hay ninguna
  /// cuota cobrada en mora — sólo impaga. La fila "venían de mora" no se dibuja
  /// ahí, y eso es correcto: el código viejo la dibujaba igual, con un 0
  /// adentro, porque su condición era "hay algo recuperado", no "hay mora".
  Future<void> cicloAnterior(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.chevron_left).first);
      for (var i = 0; i < 14; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }
    });
  }

  group('las líneas de mora en Cobertura', () {
    setUp(abrir);
    tearDown(cerrar);

    testWidgets('no se ven hasta que se abre la fila madre', (tester) async {
      await montar(tester);
      // La tarjeta abre en tres filas. La mora vive DOS niveles adentro, así
      // que no puede estar antes de desplegar nada.
      expect(find.text('venían de mora'), findsNothing);
      expect(find.text('en mora'), findsNothing);
    });

    // LA MORA VIVE ADENTRO DEL MOMENTO (2026-09-01). Antes colgaba de
    // "Recuperado" como hermana de los tres momentos y se llegaba con UN clic;
    // ahora hace falta abrir el momento, igual que para "con abono parcial".
    // Es el precio de que los momentos sean la jerarquía principal, que es lo
    // que pidió el dueño.
    testWidgets('la mora aparece al abrir el MOMENTO, no antes',
        (tester) async {
      await montar(tester);

      await cicloAnterior(tester);
      await abrirFila(tester, 'Recuperado');
      // Los momentos sí, la mora todavía no.
      expect(find.text('en el ciclo'), findsOneWidget);
      expect(find.text('venían de mora'), findsNothing);

      await abrirFila(tester, 'en el ciclo');
      expect(find.text('venían de mora'), findsOneWidget);
    });

    // Y ESTO ES EL DATO, no una omisión: en el escenario las cuotas de "antes"
    // y "después del ciclo" NO estuvieron en mora —pagaron fuera de la ventana
    // pero dentro de la gracia de su propia cuota— así que su renglón rojo no
    // se dibuja. Con la fila única de antes eso era invisible.
    testWidgets('un momento sin mora no dibuja el renglón rojo',
        (tester) async {
      await montar(tester);
      await cicloAnterior(tester);
      await abrirFila(tester, 'Recuperado');
      await abrirFila(tester, 'antes del ciclo');

      // Se abrió, pero sin línea de mora: la única que hay sigue siendo la de
      // "en el ciclo", que todavía está cerrada.
      expect(find.text('venían de mora'), findsNothing);
    });

    testWidgets('en "Por recuperar" la mora cuelga de cada línea',
        (tester) async {
      await montar(tester);
      await abrirFila(tester, 'Por recuperar');

      // Acá NO hace falta un segundo clic: las dos líneas no tienen chevron
      // propio, así que su mora se ve de una.
      expect(find.text('sin ningún pago'), findsOneWidget);
      expect(find.text('en mora'), findsWidgets,
          reason: 'cada línea con mora trae su renglón');
      // Las filas de complemento se fueron con la mudanza.
      expect(find.text('todavía en plazo'), findsNothing);
    });

    // 360 px es el ancho de los teléfonos de campo. La mudanza agregó un nivel
    // de sangría a las filas de mora, que es justo donde esto desborda.
    testWidgets('TELÉFONO (360 px): las filas de mora entran', (tester) async {
      await montar(tester, ancho: 360);
      await cicloAnterior(tester);
      await abrirFila(tester, 'Recuperado');
      await abrirFila(tester, 'en el ciclo');
      await abrirFila(tester, 'Por recuperar');

      expect(find.text('venían de mora'), findsOneWidget);
      expect(find.text('en mora'), findsWidgets);
      expect(tester.takeException(), isNull,
          reason: 'la sangría de más desbordó el renglón');
    });

    // ── La gráfica ────────────────────────────────────────────────────
    // La tabla y la curva son dos superficies distintas: que las filas lleguen
    // a la tabla no dice NADA sobre si la curva roja se dibujó. Eso no se puede
    // afirmar con un `find` —un `CustomPainter` no deja texto— pero su leyenda
    // sí, y la leyenda sólo se arma cuando la tarjeta decidió que hay mora que
    // pintar (`hayMora`, el mismo flag que alimenta al painter).
    testWidgets('la leyenda anuncia las dos referencias de mora',
        (tester) async {
      await montar(tester);

      expect(find.text('Recuperado de mora'), findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Text &&
              (w.data ?? '').startsWith('Cayó en mora · ') &&
              (w.data ?? '').endsWith('C\$')),
          findsOneWidget);
    });

    // EL GLOBO, CON EL MOUSE ENCIMA. Sin esto sólo estaba probado que NO
    // aparece sin hover, que es la mitad barata: un globo que directamente no
    // se dibuja pasaría los dos tests de "no aparece" y ninguno lo cazaría. Ya
    // pasó una vez que el dueño mirara el globo y no fuera lo que esperaba.
    //
    // No se sabe de antemano QUÉ día del ciclo tuvo mora, así que se tocan
    // todos hasta encontrarlo. Si ninguno lo muestra, el test falla diciendo
    // exactamente eso — que también sería un bug.
    testWidgets('al tocar un día con mora, el globo lo parte en dos mitades',
        (tester) async {
      await montar(tester);
      await cicloAnterior(tester);

      // El lienzo del gráfico se reconoce por su ALTO: 180px, el
      // `chartHeight` de la tarjeta. Buscarlo por "el más ancho" no sirve —hay
      // 9 CustomPaint en la pantalla y el más ancho es un fondo de 1200x2400,
      // así que los taps caían en el medio de la nada.
      var lienzo = Rect.zero;
      for (final e in find.byType(CustomPaint).evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        if ((r.height - 180).abs() < 1 && r.width > lienzo.width) lienzo = r;
      }
      expect(lienzo.width, greaterThan(200),
          reason: 'no se encontró el lienzo del gráfico (alto 180)');

      var encontrado = false;
      for (var i = 0; i < 31 && !encontrado; i++) {
        await tester.runAsync(() async {
          // Barre el ancho útil, salteando la franja del eje Y (50px).
          final x = lienzo.left + 55 + (lienzo.width - 60) * (i + 0.5) / 31;
          await tester.tapAt(Offset(x, lienzo.center.dy));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        });
        // 'a tiempo' sólo existe en el globo; 'venían de mora' también es un
        // rótulo de la TABLA, así que solo no alcanzaría para saber que el
        // globo se abrió.
        encontrado = find.text('a tiempo').evaluate().isNotEmpty;
      }

      expect(encontrado, isTrue,
          reason: 'ningún día del ciclo mostró el reparto de mora en el globo');
      // Las tres filas de la suma, juntas: las dos mitades y su total.
      expect(find.text('a tiempo'), findsOneWidget);
      expect(find.text('cobradas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el globo trae el ACUMULADO de mora, sangrado y alineado',
        (tester) async {
      await montar(tester);
      await cicloAnterior(tester);

      var lienzo = Rect.zero;
      for (final e in find.byType(CustomPaint).evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        if ((r.height - 180).abs() < 1 && r.width > lienzo.width) lienzo = r;
      }
      expect(lienzo.width, greaterThan(200));

      // Se busca un día donde YA haya acumulado de mora. Barre de derecha a
      // izquierda: el acumulado sólo crece, así que los días del final son los
      // que seguro lo tienen.
      var abierto = false;
      for (var i = 30; i >= 0 && !abierto; i--) {
        await tester.runAsync(() async {
          final x = lienzo.left + 55 + (lienzo.width - 60) * (i + 0.5) / 31;
          await tester.tapAt(Offset(x, lienzo.center.dy));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        });
        abierto = find.text('de eso, de mora').evaluate().isNotEmpty;
      }
      expect(abierto, isTrue,
          reason: 'ningún día mostró el acumulado de mora en el globo');

      // El rótulo dice "Acumulado del ciclo" desde el 2026-09-02: el total
      // pasó al PIE del globo y el "del ciclo" refuerza que cierra ESTE ciclo
      // y que lo que va debajo (cobros de otros ciclos) no le pertenece.
      //
      // 1) SANGRADO. Es lo que dice "esto está ADENTRO de Acumulado" en vez de
      // "esto se suma a Acumulado". Sin la sangría el renglón se lee como un
      // monto aparte, y sumarlo contaría esa plata dos veces.
      final xMora = tester.getRect(find.text('de eso, de mora')).left;
      final xAcum = tester.getRect(find.text('Acumulado del ciclo')).left;
      expect(xMora, greaterThan(xAcum),
          reason: 'el renglón de mora tiene que ir corrido a la derecha');

      // 2) FORMATEADO Y ALINEADO — pedido explícito de Rubén al aprobarlo.
      // Todas las cifras de plata del globo terminan en el MISMO borde. Lo
      // garantiza el `Table` con `IntrinsicColumnWidth`, y este test lo fija:
      // si alguien vuelve a armar el globo con `Row`s, las columnas pasan a
      // depender del largo del texto y se corren (ya pasó, 2026-09-01).
      final tabla = find.ancestor(
          of: find.text('Acumulado del ciclo'), matching: find.byType(w.Table));
      expect(tabla, findsOneWidget);
      final bordes = <int>{};
      for (final e in find
          .descendant(of: tabla, matching: find.byType(Text))
          .evaluate()) {
        final d = (e.widget as Text).data ?? '';
        if (!d.contains(r'C$')) continue;
        bordes.add(tester.getRect(find.byWidget(e.widget)).right.round());
      }
      expect(bordes.length, 1,
          reason: 'las cifras del globo terminan en ${bordes.length} bordes '
              'distintos: $bordes');

      // 3) Y con su conteo de cuotas, que es lo que Rubén eligió.
      expect(find.descendant(of: tabla, matching: find.text('')), findsWidgets,
          reason: 'la celda de cuotas del "Acumulado" va vacía');
      expect(tester.takeException(), isNull);
    });

    testWidgets('el ACUMULADO cierra abajo: lo que suma va arriba y lo '
        'ajeno abajo', (tester) async {
      // Pedido de Ruben (2026-09-02): *"el acumulado es la constante del
      // ciclo, y como en los recibos que hasta el final sale el total, lo
      // mismo quiero para el acumulado"*.
      //
      // No es cosmetico. El acumulado del ULTIMO dia ya incluye el tail
      // (`acum[last] += tail`), asi que tenerlo ARRIBA del sumando dibujaba la
      // suma al reves. Y `de otros ciclos` NO suma -son cuotas de otro ciclo-
      // por eso va DEBAJO del total, separado.
      await montar(tester);
      await cicloAnterior(tester);

      var lienzo = Rect.zero;
      for (final e in find.byType(CustomPaint).evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        if ((r.height - 180).abs() < 1 && r.width > lienzo.width) lienzo = r;
      }
      expect(lienzo.width, greaterThan(200));

      // El ULTIMO dia es el unico que puede traer 'Despues del ciclo'.
      var visto = false;
      for (var i = 30; i >= 0 && !visto; i--) {
        await tester.runAsync(() async {
          final x = lienzo.left + 55 + (lienzo.width - 60) * (i + 0.5) / 31;
          await tester.tapAt(Offset(x, lienzo.center.dy));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        });
        visto = find.text('Despues del ciclo').evaluate().isNotEmpty ||
            find.text('Después del ciclo').evaluate().isNotEmpty;
      }

      final acum = find.text('Acumulado del ciclo');
      expect(acum, findsOneWidget);
      final yAcum = tester.getRect(acum).top;

      if (visto) {
        final tail = find.text('Después del ciclo');
        expect(tester.getRect(tail).top, lessThan(yAcum),
            reason: 'lo cobrado despues del ciclo SUMA al acumulado: va '
                'arriba de el');
      }
      final otros = find.text('de otros ciclos');
      if (otros.evaluate().isNotEmpty) {
        expect(tester.getRect(otros).top, greaterThan(yAcum),
            reason: 'lo de otros ciclos NO suma, asi que va DEBAJO del total');
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('la mora del día no se muestra sin pasar el mouse',
        (tester) async {
      await montar(tester);
      // El globo parte el día en "a tiempo" / "venían de mora" / "cobradas", y
      // eso es de UN día. Que aparezca sin hover sería el bug opuesto: un dato
      // de un día suelto mostrándose siempre.
      //
      // Se busca 'a tiempo' y no 'venían de mora', que también es un rótulo de
      // la TABLA: un finder que matchea dos superficies distintas no prueba
      // nada sobre ninguna.
      expect(find.text('a tiempo'), findsNothing);
      expect(find.text('cobradas'), findsNothing);
    });

    // 🔴 EL BUG QUE ESTE TEST EXISTE PARA CAZAR (2026-09-03). El dueño mandó
    // una captura donde la leyenda ("Cayó en mora · 341.128,00 C\$") se leía
    // ATRAVESANDO el globo, y lo reportó como que el fondo era transparente.
    // No era transparencia: el globo mide ~196px contra los 180 del gráfico,
    // se desbordaba hacia abajo, y la leyenda —que era hermana POSTERIOR en la
    // Column de afuera— se pintaba encima. En Flutter gana el hermano de
    // después.
    //
    // El arreglo fue meter la leyenda DENTRO del mismo `Stack` que el globo,
    // como parte del primer hijo, para que el globo quede último y tape en vez
    // de ser tapado. Este test fija esa estructura: si alguien vuelve a sacar
    // la leyenda del Stack, el bug vuelve sin que nada más lo note — no lo caza
    // `flutter analyze` ni ningún test de datos, sólo se ve mirando.
    testWidgets('la leyenda vive DENTRO del Stack del globo, no después',
        (tester) async {
      await montar(tester);

      // Se busca por 'Meta del ciclo', que SÓLO existe en la leyenda.
      // `find.text('Recuperado')` no sirve: matchea también una fila de la
      // TABLA, y esa sí vive fuera del Stack — el test daba rojo con el bug ya
      // arreglado. Es el error que este mismo archivo advierte más arriba.
      final leyenda = find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').startsWith('Meta del ciclo'));
      expect(leyenda, findsOneWidget,
          reason: 'no se encontró la leyenda del gráfico');

      // El Stack que envuelve al gráfico se reconoce por tener
      // `clipBehavior: Clip.none` — es el único de la tarjeta que lo usa, y es
      // justamente lo que deja al globo salirse de los 180px.
      final stacksDeLaLeyenda = find
          .ancestor(of: leyenda.first, matching: find.byType(Stack))
          .evaluate()
          .map((e) => e.widget as Stack)
          .where((st) => st.clipBehavior == Clip.none)
          .toList();

      expect(stacksDeLaLeyenda, isNotEmpty,
          reason: 'la leyenda quedó FUERA del Stack del gráfico: se va a '
              'pintar encima del globo otra vez');
    });
  });
}
