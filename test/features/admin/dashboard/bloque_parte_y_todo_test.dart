@TestOn('vm')
library;

/// El bloque "total y partes" CON LOS NÚMEROS DE PRODUCCIÓN.
///
/// ## Por qué existe, aparte de `resumen_en_telefono_test.dart`
///
/// Ese archivo monta las tarjetas contra el escenario de prueba, y el escenario
/// tiene montos de **cinco dígitos** (`26.800,00 C$`). Telecable Mairena tiene
/// de **siete** (`4.032.022,92 C$`) — 105px contra 60. O sea que el otro test
/// pasa sin ejercitar el caso que rompe (regla 16 del checklist: *un escenario
/// que no siembra lo que producción tiene no prueba lo que creés*).
///
/// Acá el bloque se monta a mano, a 360px, con los números REALES de Mairena
/// que se verificaron contra la base el 2026-09-03. No necesita PowerSync, así
/// que corre siempre.
///
/// Lo que protege:
///   · que nada desborde — `flutter_test` falla solo ante un `RenderFlex`
///     desbordado, y eso NO lo ve `flutter analyze`;
///   · que la letra respete la escala de la app;
///   · que la barra diga lo mismo que los % de las filas.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/bloque_parte_y_todo.dart';
import 'package:isp_billing/features/admin/dashboard/escala_resumen.dart';

/// Los números REALES de Telecable Mairena, verificados contra la base.
const _verde = Color(0xFF1D9E75);
const _rojo = Color(0xFFE24B4A);
const _azul = Color(0xFF185FA5);

void main() {
  /// Monta el bloque con el ancho ÚTIL que la tarjeta le da en un teléfono de
  /// 360px: 312px, medido en el render real (24px de padding a cada lado).
  Future<void> montar(WidgetTester tester, List<Widget> hijos,
      {double ancho = 312}) async {
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: ancho,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch, children: hijos),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Cobertura del ciclo de Mairena, tal cual sale de la base.
  List<Widget> mairena() => const [
        TotalResumen(
          label: 'Cobros',
          color: _azul,
          monto: 4032022.92,
          usuarios: 4434,
          cuotas: 4445,
          segmentos: [
            (fraccion: 0.36, color: _verde),
            (fraccion: 0.64, color: _rojo),
          ],
        ),
        ParteResumen(
          label: 'Recuperado',
          color: _verde,
          monto: 1476822.69,
          usuarios: 1578,
          cuotas: 1585,
          pct: 36,
          abierto: false,
        ),
        ParteResumen(
          label: 'Por recuperar',
          color: _rojo,
          monto: 2555200.23,
          usuarios: 2860,
          cuotas: 2860,
          pct: 64,
          abierto: false,
        ),
      ];

  group('con los montos de siete dígitos de Mairena', () {
    // 🔴 Si algo desborda, `flutter_test` marca el test como fallado solo. Es
    // el único chequeo automático que existe para un layout roto: `analyze` no
    // lo ve y ningún test de datos lo toca.
    testWidgets('🔴 nada desborda a 312px', (tester) async {
      await montar(tester, mairena());
      expect(find.text('Cobros'), findsOneWidget);
      expect(find.text('4.434 usuarios · 4.445 cuotas'), findsOneWidget);
      // Si el `expect` de arriba pasa, el texto se dibujó ENTERO: `find.text`
      // matchea el `data` del widget, no lo que se ve. El desborde lo caza el
      // framework, no este `expect`.
    });

    // 🔴 La condición textual del dueño: *"que los numeros y letras se miren de
    // tamaño consistente con el resto de la app"*.
    testWidgets('🔴 ningún texto por debajo del piso de la escala',
        (tester) async {
      await montar(tester, mairena());
      final tam = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.style?.fontSize ?? 0)
          .where((s) => s > 0)
          .toList();
      expect(tam, isNotEmpty);
      for (final s in tam) {
        expect(s, greaterThanOrEqualTo(TxtResumen.minimo),
            reason: 'hay texto a ${s}px, abajo del piso de '
                '${TxtResumen.minimo}px de TxtResumen');
      }
      // Y ningún `FittedBox`: es el que escalaba el monto al 34%.
      expect(find.byType(FittedBox), findsNothing,
          reason: 'un FittedBox deja que el tamaño dependa del largo del '
              'número, que es exactamente el bug que esto vino a cerrar');
    });

    // La jerarquía: el total manda sobre las partes, y las partes sobre el
    // desglose. Sin esto, con el tiempo los tres terminan del mismo tamaño y
    // el bloque deja de leerse de un vistazo.
    testWidgets('🔴 la jerarquía de tamaños es total > parte > desglose',
        (tester) async {
      await montar(tester, [
        ...mairena(),
        const ParteResumen(
          label: 'venían de mora',
          color: _rojo,
          monto: 288902.55,
          cuotas: 311,
          nivel: 2,
        ),
      ]);
      double mayorDe(Type t) => tester
          .widgetList<Text>(
              find.descendant(of: find.byType(t), matching: find.byType(Text)))
          .map((w) => w.style?.fontSize ?? 0)
          .reduce((a, b) => a > b ? a : b);

      expect(mayorDe(TotalResumen), TxtResumen.gigante);
      // La parte de nivel 0 usa `grande`; la de nivel 2, `cifra`.
      final partes = tester
          .widgetList<Text>(find.descendant(
              of: find.byType(ParteResumen), matching: find.byType(Text)))
          .map((w) => w.style?.fontSize ?? 0)
          .toSet();
      expect(partes.contains(TxtResumen.grande), isTrue,
          reason: 'las partes de nivel 0 tienen que ir en TxtResumen.grande');
      expect(partes.every((s) => s < TxtResumen.gigante), isTrue,
          reason: 'ninguna parte puede competir con el total');
    });
  });

  group('la barra de composición', () {
    List<int> flexDe(WidgetTester tester) => tester
        .widgetList<Expanded>(find.descendant(
            of: find.byType(TotalResumen), matching: find.byType(Expanded)))
        .where((e) => e.child is ColoredBox)
        .map((e) => e.flex)
        .toList();

    // 🔴 La barra tiene que decir lo MISMO que los % de las filas (invariante
    // #10: el mismo número en todas las superficies). Si el 36 y el 64 de las
    // filas dieran una barra de otra proporción, una de las dos miente.
    testWidgets('🔴 los tramos son los % que muestran las filas',
        (tester) async {
      await montar(tester, mairena());
      final f = flexDe(tester);
      expect(f.length, 2, reason: 'tienen que ser los dos tramos');
      expect(f[0], 360, reason: 'el verde es el 36% que dice la fila');
      expect(f[1], 640, reason: 'el rojo es el 64% que dice la fila');
      expect(f.reduce((a, b) => a + b), 1000,
          reason: 'sin canaleta: los dos tramos cubren el total');
    });

    // Cuando el rol no ve montos cobrados (`ocultarRecaudado`) el tramo verde
    // no se dibuja, y lo que queda es canaleta gris. La barra tiene que decir
    // lo mismo que las filas: si la fila "Recuperado" no está, su tramo
    // tampoco.
    testWidgets('sin el tramo verde, el resto queda como canaleta',
        (tester) async {
      await montar(tester, const [
        TotalResumen(
          label: 'Total en mora',
          color: _azul,
          monto: 2555200.23,
          usuarios: 2860,
          cuotas: 2860,
          segmentos: [(fraccion: 0.64, color: _rojo)],
        ),
      ]);
      final f = flexDe(tester);
      expect(f.length, 2, reason: 'el tramo rojo más la canaleta');
      expect(f[0], 640);
      expect(f[1], 360, reason: 'la canaleta completa el 100%');
    });

    // 🔴 LA BARRA SE TIENE QUE VER. Un `ColoredBox` sin hijo toma la altura
    // MINIMA de sus constraints, y un `Row` la da floja: la barra existia, con
    // sus flex correctos, y se dibujaba con altura CERO. Los tests de flex
    // pasaban igual — contaban widgets, no pixeles. Lo encontro el render.
    testWidgets('🔴 los tramos se dibujan con altura real, no cero',
        (tester) async {
      await montar(tester, mairena());
      final cajas = find.descendant(
          of: find.byType(TotalResumen), matching: find.byType(ColoredBox));
      expect(cajas, findsWidgets, reason: 'no se dibujó ningún tramo');
      for (var i = 0; i < cajas.evaluate().length; i++) {
        final r = tester.getRect(cajas.at(i));
        expect(r.height, greaterThan(4),
            reason: 'el tramo $i mide ${r.height}px de alto: la barra está '
                'ahí pero no se ve');
        expect(r.width, greaterThan(0),
            reason: 'el tramo $i no tiene ancho');
      }
      // Y la barra entera ocupa el ancho del bloque, no una fracción.
      final rects = [
        for (var i = 0; i < cajas.evaluate().length; i++)
          tester.getRect(cajas.at(i))
      ];
      final izq = rects.map((r) => r.left).reduce((a, b) => a < b ? a : b);
      final der = rects.map((r) => r.right).reduce((a, b) => a > b ? a : b);
      expect(der - izq, closeTo(312, 1.0),
          reason: 'la barra tiene que cubrir el ancho del bloque');
    });

    // Con el total en cero no hay nada que componer: la barra va entera gris.
    // Antes de esto, un ciclo sin cuotas dibujaba una barra vacía de ancho
    // cero y el bloque se veía roto.
    testWidgets('con el total en cero la barra queda entera gris',
        (tester) async {
      await montar(tester, const [
        TotalResumen(
          label: 'Cobros',
          color: _azul,
          monto: 0,
          usuarios: 0,
          cuotas: 0,
          segmentos: [
            (fraccion: 0, color: _verde),
            (fraccion: 0, color: _rojo),
          ],
        ),
      ]);
      final f = flexDe(tester);
      expect(f, [1000], reason: 'sólo la canaleta, cubriendo todo');
      expect(find.text('0 usuarios · 0 cuotas'), findsOneWidget);
    });
  });

  group('las diferencias de CONTENIDO que se conservan', () {
    // La grilla de mora imprime "—" en los ceros; la de cobertura imprime "0".
    // Es una diferencia de contenido, no de forma, y por eso sobrevive al
    // renderer compartido.
    testWidgets('guionEnCero pone "—" donde la otra pone "0"', (tester) async {
      await montar(tester, const [
        ParteResumen(
          label: 'Recuperado',
          color: _verde,
          monto: 0,
          usuarios: 0,
          cuotas: 0,
          pct: 0,
          guionEnCero: true,
        ),
      ]);
      expect(find.text('— usuarios · — cuotas'), findsOneWidget);
    });

    // "Quién cobró" cuenta COBROS, no cuotas. En la tabla eso lo decía el
    // encabezado de la columna; sin encabezado, lo dice cada renglón.
    testWidgets('unidadConteo dice la palabra correcta', (tester) async {
      await montar(tester, const [
        ParteResumen(
          label: 'Cobrador Test',
          color: _verde,
          monto: 12500,
          cuotas: 7,
          pct: 42,
          unidadConteo: ('cobro', 'cobros'),
        ),
      ]);
      expect(find.text('7 cobros'), findsOneWidget);
    });

    // El singular. Con "1 cuotas" el renglón se lee mal, y es el caso más
    // común en un tenant chico.
    testWidgets('un solo elemento va en singular', (tester) async {
      await montar(tester, const [
        ParteResumen(
          label: 'Recuperado',
          color: _verde,
          monto: 1282,
          usuarios: 1,
          cuotas: 1,
          pct: 3,
        ),
      ]);
      expect(find.text('1 usuario · 1 cuota'), findsOneWidget);
    });

    // El paréntesis de la tabla decía "esta cuota se cuenta en OTRA fila" y
    // había que saber interpretarlo. Con lugar para escribir, se escribe.
    testWidgets('la nota reemplaza al paréntesis', (tester) async {
      await montar(tester, const [
        ParteResumen(
          label: 'con abono parcial',
          color: _rojo,
          monto: 21660,
          cuotas: 48,
          nivel: 2,
          nota: 'ya contadas arriba',
        ),
      ]);
      expect(find.text('ya contadas arriba'), findsOneWidget);
    });
  });
}
