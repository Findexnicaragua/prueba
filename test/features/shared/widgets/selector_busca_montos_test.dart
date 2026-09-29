@TestOn('vm')
library;

/// Encontrar un ítem por su MONTO, se escriba con separador de miles o sin él.
///
/// Existe por un reporte del ISP: "hay planes que no aparecen al cambiar de
/// plan". No faltaba ninguno — el usuario tipeaba `1282` y la lista quedaba
/// vacía, porque el nombre mostrado es "COMBO INTERNET+CATV 20MB · 1.282,00 C$"
/// y el punto del separador de miles parte el substring. Concluía, con razón,
/// que el plan no estaba.
///
/// Muerde justo donde más duele: en Mairena 18 de 25 planes comparten nombre
/// (7 se llaman "CATV"), así que el precio es LO ÚNICO que los distingue — y
/// era lo único que no se podía buscar.
///
/// LA REGLA QUE FIJA ESTE TEST: si el ítem muestra un monto formateado, se
/// encuentra tanto tipeando `1282` como `1.282`. Aplica a TODO selector que
/// muestre plata, no solo a planes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/shared/widgets/selector_buscable.dart';

/// Abre el selector con [opciones] y devuelve el helper para tipear y contar.
Future<void> _abrir(
  WidgetTester tester,
  List<OpcionSelector<String>> opciones,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => elegirConBuscador<String>(
            context,
            titulo: 'Elegí el plan nuevo',
            hint: 'Buscar plan...',
            opciones: opciones,
          ),
          child: const Text('abrir'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

/// Los tres planes del caso real: dos comparten nombre y solo los separa el
/// precio.
final _planes = <OpcionSelector<String>>[
  const OpcionSelector(
      valor: 'a',
      nombre: 'COMBO INTERNET+CATV 20MB · 1.282,00 C\$',
      subtitulo: '1.758 contratos activos',
      textoBusqueda: '1282'),
  const OpcionSelector(
      valor: 'b',
      nombre: 'COMBO INTERNET+CATV 20MB · 2.197,00 C\$',
      subtitulo: '2 contratos activos',
      textoBusqueda: '2197'),
  const OpcionSelector(
      valor: 'c',
      nombre: 'CATV · 513,00 C\$',
      subtitulo: '2.106 contratos activos',
      textoBusqueda: '513'),
];

void main() {
  Future<void> tipear(WidgetTester t, String q) async {
    await t.enterText(find.byType(TextField).first, q);
    await t.pumpAndSettle();
  }

  group('buscar por monto', () {
    testWidgets('SIN separador de miles: `1282` encuentra "1.282,00"',
        (tester) async {
      await _abrir(tester, _planes);
      await tipear(tester, '1282');
      expect(find.textContaining('1.282,00'), findsOneWidget,
          reason: 'es la forma en que el usuario dice el precio en voz alta');
      expect(find.textContaining('2.197,00'), findsNothing);
    });

    testWidgets('CON separador: `1.282` sigue encontrándolo', (tester) async {
      await _abrir(tester, _planes);
      await tipear(tester, '1.282');
      expect(find.textContaining('1.282,00'), findsOneWidget,
          reason: 'la variante nueva no puede romper la búsqueda literal');
    });

    testWidgets('el monto DISTINGUE dos planes de igual nombre',
        (tester) async {
      // El caso que originó todo: sin poder buscar por precio, los dos "COMBO
      // INTERNET+CATV 20MB" son indistinguibles.
      await _abrir(tester, _planes);
      await tipear(tester, '2197');
      expect(find.textContaining('2.197,00'), findsOneWidget);
      expect(find.textContaining('1.282,00'), findsNothing);
    });

    testWidgets('el subtítulo con el conteo se pinta', (tester) async {
      // Es la seña que resuelve el empate cuando el nombre se repite.
      await _abrir(tester, _planes);
      await tipear(tester, 'catv 513');
      expect(find.text('2.106 contratos activos'), findsOneWidget);
    });

    testWidgets('buscar por nombre sigue andando, en cualquier orden',
        (tester) async {
      await _abrir(tester, _planes);
      await tipear(tester, 'catv combo');
      expect(find.textContaining('COMBO INTERNET+CATV'), findsNWidgets(2),
          reason: 'los tokens matchean en cualquier orden');
    });
  });
}
