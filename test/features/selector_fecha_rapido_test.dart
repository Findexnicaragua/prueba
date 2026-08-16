import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/shared/widgets/selector_fecha_rapido.dart';

/// El selector de fecha "rápido" reemplaza al `showDatePicker` nativo para que
/// tocar un día lo APLIQUE de una, sin botones OK/Cancelar (pedido de los
/// dueños, 2026-07-31). Estos tests fijan las dos promesas: no hay botones, y
/// el toque de un día cierra devolviendo esa fecha.
void main() {
  Future<DateTime?> abrir(WidgetTester tester,
      {required DateTime inicial}) async {
    DateTime? resultado;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              resultado = await elegirFechaRapida(
                context,
                initialDate: inicial,
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
                helpText: 'Elegí la fecha',
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    return resultado;
  }

  testWidgets('no muestra botones OK ni Cancelar', (tester) async {
    await abrir(tester, inicial: DateTime(2026, 7, 15));
    expect(find.text('OK'), findsNothing);
    expect(find.text('Cancelar'), findsNothing);
    expect(find.text('CANCEL'), findsNothing);
    // El calendario sí está en pantalla (el helpText).
    expect(find.text('Elegí la fecha'), findsOneWidget);
  });

  testWidgets('tocar un día lo aplica y cierra el diálogo', (tester) async {
    await abrir(tester, inicial: DateTime(2026, 7, 15));

    // El calendario abre en julio 2026. Tocar el día 22.
    await tester.tap(find.text('22'));
    await tester.pumpAndSettle();

    // El diálogo se cerró (no queda el calendario) sin ningún botón extra.
    expect(find.text('Elegí la fecha'), findsNothing);
  });

  testWidgets('la fecha devuelta es la del día tocado', (tester) async {
    late DateTime? resultado;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              resultado = await elegirFechaRapida(
                context,
                initialDate: DateTime(2026, 7, 15),
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9'));
    await tester.pumpAndSettle();

    expect(resultado, DateTime(2026, 7, 9));
  });

  testWidgets('un initialDate fuera de rango no rompe (se clampa)',
      (tester) async {
    // initial 2015 con firstDate 2020 → CalendarDatePicker lanzaría; el helper
    // lo clampa. Solo verificamos que abre sin excepción.
    final r = await abrir(tester, inicial: DateTime(2015, 1, 1));
    expect(r, isNull); // no se tocó nada aún
    expect(tester.takeException(), isNull);
  });
}
