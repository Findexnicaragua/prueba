@TestOn('vm')
library;

/// El panel del filtro multi-selección **entra en la pantalla**.
///
/// ## El bug que este test existe para cazar (2026-09-03)
///
/// El panel se anclaba SIEMPRE por la izquierda del chip, con hasta 340px de
/// ancho y sin mirar dónde estaba el chip. En Android, con el chip **"Plan"**
/// —que es el ÚLTIMO de la barra de Cobros, o sea el más a la derecha— el
/// panel arrancaba cerca del borde y se cortaba: los usuarios veían
/// "COMBO INTER…" y "2.014,00 C$ · 1 clie…".
///
/// Los chips de Cobrador y Zona nunca lo mostraron **porque están a la
/// izquierda** y ahí sobra lugar. Por eso el bug apareció recién cuando se
/// agregó un cuarto chip: no era del chip nuevo, era del componente compartido.
///
/// Es la misma lección del globo de la curva de cobros, el mismo día: **anclar
/// sin acotar**. Un widget anclado a otro no se queda dentro de la pantalla
/// solo.
///
/// ## Por qué se prueba a 360px con el chip a la derecha
///
/// Es el caso que rompe. A 1200px el panel entra en cualquier posición y el
/// test pasaría con el bug puesto — sería decoración (regla 15b).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/shared/widgets/filtro_multi_dropdown.dart';

void main() {
  // Etiquetas largas de verdad: son los nombres reales de Telecable Mairena,
  // que es donde se reportó. Con etiquetas cortas el panel no se estira y el
  // desborde no aparece.
  final opciones = <FiltroOpcion>[
    const FiltroOpcion(
        id: '1',
        label: 'COMBO INTERNET+CATV 20MB',
        grupo: 'Combo',
        subtitulo: '1.282,00 C\$ · 1.751 clientes'),
    const FiltroOpcion(
        id: '2',
        label: 'COMBO INTERNET+CATV 100MB',
        grupo: 'Combo',
        subtitulo: '3.662,00 C\$ · 1 cliente'),
    const FiltroOpcion(
        id: '3',
        label: 'INTERNT+CATV (Hotel)',
        grupo: 'Combo',
        subtitulo: '2.197,00 C\$ · 1 cliente'),
  ];

  /// Monta el chip PEGADO AL BORDE DERECHO, que es donde vive "Plan".
  Future<void> montar(WidgetTester tester, double ancho) async {
    tester.view.physicalSize = Size(ancho, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            const Spacer(),
            FiltroMultiDropdown(
              icon: Icons.wifi_tethering,
              hint: 'Plan',
              buscarHint: 'Buscar plan…',
              opciones: opciones,
              seleccionados: opciones.map((o) => o.id).toSet(),
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// El panel abierto. Se lo reconoce por el `Material` con elevación que
  /// envuelve al buscador — el `TextField` sólo existe adentro del panel.
  Rect rectDelPanel(WidgetTester tester) {
    final campo = find.byType(TextField);
    expect(campo, findsOneWidget, reason: 'el panel no se abrió');
    final material = find
        .ancestor(of: campo, matching: find.byType(Material))
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        // El Material del panel es el más chico que contiene al buscador: los
        // de arriba son el Scaffold y el MaterialApp, que ocupan todo.
        .reduce((a, b) => a.width <= b.width ? a : b);
    return material;
  }

  group('el panel del filtro entra en la pantalla', () {
    testWidgets('🔴 a 360px con el chip pegado a la derecha', (tester) async {
      await montar(tester, 360);
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();

      final panel = rectDelPanel(tester);
      expect(panel.right, lessThanOrEqualTo(360.0 + 0.5),
          reason: 'el panel se sale por la DERECHA: termina en '
              '${panel.right.toStringAsFixed(1)} y la pantalla mide 360. Es lo '
              'que los usuarios ven como "COMBO INTER…" cortado');
      expect(panel.left, greaterThanOrEqualTo(-0.5),
          reason: 'el panel se sale por la IZQUIERDA al voltearlo');
      expect(panel.width, greaterThan(150),
          reason: 'quedó tan angosto que no se puede leer nada');
    });

    testWidgets('a 1200px, donde entra de sobra, no cambia nada',
        (tester) async {
      // Contraprueba: el arreglo no debe encoger el panel donde había lugar.
      await montar(tester, 1200);
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();

      final panel = rectDelPanel(tester);
      expect(panel.right, lessThanOrEqualTo(1200.0 + 0.5));
      expect(panel.width, greaterThan(240),
          reason: 'con espacio de sobra el panel debe usar su ancho normal');
    });
  });
}
