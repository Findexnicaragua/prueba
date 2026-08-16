import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/shared/widgets/filtro_multi_dropdown.dart';

/// Widget test del FiltroMultiDropdown (componente central del rework de
/// filtros). Cubre: render del chip, apertura del panel, y que deseleccionar
/// una opción emite el set correcto + el contador de filtro parcial.
void main() {
  const opts = [
    FiltroOpcion(id: 'a', label: 'Ana'),
    FiltroOpcion(id: 'b', label: 'Beto'),
    FiltroOpcion(id: 'c', label: 'Carla'),
  ];

  Widget wrap(Set<String> sel, ValueChanged<Set<String>> onChanged) =>
      MaterialApp(
        home: Scaffold(
          body: FiltroMultiDropdown(
            icon: Icons.person,
            hint: 'Cobrador',
            opciones: opts,
            seleccionados: sel,
            onChanged: onChanged,
          ),
        ),
      );

  testWidgets('renderiza el chip con el hint', (tester) async {
    await tester.pumpWidget(wrap(const {'a', 'b', 'c'}, (_) {}));
    expect(find.text('Cobrador'), findsOneWidget);
  });

  testWidgets('todo seleccionado = sin filtro → no muestra contador', (tester) async {
    await tester.pumpWidget(wrap(const {'a', 'b', 'c'}, (_) {}));
    // El badge de conteo (3) no debe aparecer cuando están todos.
    expect(find.text('3'), findsNothing);
  });

  testWidgets('filtro parcial muestra el contador', (tester) async {
    await tester.pumpWidget(wrap(const {'a'}, (_) {}));
    expect(find.text('1'), findsOneWidget); // 1 de 3 seleccionados
  });

  testWidgets('abrir el panel y deseleccionar una opción emite el set', (tester) async {
    Set<String>? emitido;
    await tester.pumpWidget(wrap(const {'a', 'b', 'c'}, (s) => emitido = s));

    // Abrir el panel (tap en el chip).
    await tester.tap(find.text('Cobrador'));
    await tester.pumpAndSettle();

    // Las opciones del panel aparecen.
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Beto'), findsOneWidget);

    // Deseleccionar 'Ana' → emite {b, c}.
    await tester.tap(find.text('Ana'));
    await tester.pumpAndSettle();
    expect(emitido, equals({'b', 'c'}));
  });
}
