import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/shared/widgets/filtro_multi_dropdown.dart';
import 'package:isp_billing/features/shared/widgets/filtros_bar.dart';

/// Tests del segundo estándar de listas: la barra de filtros. Canoniza la regla
/// "todo/nada marcado = sin filtrar (null)" y el botón "Limpiar (N)".

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('opcionesDesdeRows', () {
    test('ignora id null, usa el id como label de fallback y mapea el grupo', () {
      final ops = opcionesDesdeRows(
        [
          {'id': 'a', 'nombre': 'Alfa', 'muni': 'M1'},
          {'id': null, 'nombre': 'Fantasma'},
          {'id': 'b', 'nombre': null},
        ],
        grupoKey: 'muni',
      );

      expect(ops.length, 2); // la fila con id null se descarta
      expect(ops[0].id, 'a');
      expect(ops[0].label, 'Alfa');
      expect(ops[0].grupo, 'M1');
      expect(ops[1].id, 'b');
      expect(ops[1].label, 'b'); // label null → fallback al id
      expect(ops[1].grupo, isNull);
    });
  });

  group('FiltrosBar', () {
    const opciones = [
      FiltroOpcion(id: 'a', label: 'Alfa'),
      FiltroOpcion(id: 'b', label: 'Beta'),
      FiltroOpcion(id: 'c', label: 'Gamma'),
    ];

    testWidgets('todo/nada marcado canoniza a null; parcial entrega el Set',
        (tester) async {
      Object? capturado = 'sin-llamar';
      await tester.pumpWidget(_wrap(FiltrosBar(
        dimensiones: [
          FiltroDim(
            icon: Icons.label_outline,
            hint: 'Tipo',
            opciones: opciones,
            seleccion: null, // arranca sin filtrar = todo marcado
            onChanged: (s) => capturado = s,
          ),
        ],
      )));

      // Abrir el dropdown.
      await tester.tap(find.text('Tipo'));
      await tester.pump();

      // "Ninguno" → set vacío → canoniza a null.
      await tester.tap(find.text('Ninguno'));
      await tester.pump();
      expect(capturado, isNull);

      // "Todos" → set completo → también canoniza a null (no es un filtro).
      await tester.tap(find.text('Todos'));
      await tester.pump();
      expect(capturado, isNull);

      // Apagar 'Alfa' partiendo de "todos" → parcial {b, c}.
      await tester.tap(find.text('Alfa'));
      await tester.pump();
      expect(capturado, equals({'b', 'c'}));
    });

    testWidgets('"Limpiar (N)" suma dimensiones activas + activosExtra y dispara onLimpiar',
        (tester) async {
      var limpiado = false;
      await tester.pumpWidget(_wrap(FiltrosBar(
        dimensiones: [
          FiltroDim(
            icon: Icons.label_outline,
            hint: 'Tipo',
            opciones: opciones,
            seleccion: {'a'}, // activa (parcial)
            onChanged: (_) {},
          ),
        ],
        activosExtra: 1, // ej. un segmented control aparte
        onLimpiar: () => limpiado = true,
      )));

      expect(find.text('Limpiar (2)'), findsOneWidget); // 1 dim + 1 extra
      await tester.tap(find.text('Limpiar (2)'));
      await tester.pump();
      expect(limpiado, isTrue);
    });

    testWidgets('sin filtros activos NO muestra "Limpiar"', (tester) async {
      await tester.pumpWidget(_wrap(FiltrosBar(
        dimensiones: [
          FiltroDim(
            icon: Icons.label_outline,
            hint: 'Tipo',
            opciones: opciones,
            seleccion: null, // sin filtrar
            onChanged: (_) {},
          ),
        ],
        onLimpiar: () {},
      )));

      expect(find.textContaining('Limpiar'), findsNothing);
    });

    testWidgets('la búsqueda del dropdown es acento-insensible (foldBusqueda)',
        (tester) async {
      await tester.pumpWidget(_wrap(FiltrosBar(
        dimensiones: [
          FiltroDim(
            icon: Icons.person_outline,
            hint: 'Cobrador',
            opciones: const [
              FiltroOpcion(id: '1', label: 'Núñez'),
              FiltroOpcion(id: '2', label: 'Pérez'),
            ],
            seleccion: null,
            onChanged: (_) {},
          ),
        ],
      )));

      await tester.tap(find.text('Cobrador'));
      await tester.pump();

      // Tipear SIN acentos encuentra el ítem CON acentos (antes fallaba).
      await tester.enterText(find.byType(TextField), 'nunez');
      await tester.pump();
      expect(find.text('Núñez'), findsOneWidget);
      expect(find.text('Pérez'), findsNothing);
    });
  });
}
