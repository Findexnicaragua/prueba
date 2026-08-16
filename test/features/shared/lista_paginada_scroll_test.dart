import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/shared/widgets/lista_paginada_scroll.dart';

/// Tests del componente estándar de lista paginada. El diseño por callbacks
/// ([construirStream]/[construirConteo]) permite probar TODA la mecánica con
/// streams falsos, sin PowerSync ni DB.

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

List<Map<String, dynamic>> _filas(int n) =>
    List.generate(n, (i) => {'id': 'r$i', 'nombre': 'Fila $i'});

void main() {
  testWidgets('primera carga: spinner hasta la primera emisión', (tester) async {
    final stream = StreamController<List<Map<String, dynamic>>>();
    final conteo = StreamController<int>();
    await tester.pumpWidget(_wrap(ListaPaginadaScroll(
      construirStream: (_) => stream.stream,
      construirConteo: () => conteo.stream,
      itemBuilder: (_, r) => Text(r['nombre'] as String),
      filtroKey: 'a',
    )));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Fila 0'), findsNothing);

    await stream.close();
    await conteo.close();
  });

  testWidgets('renderiza la página y DESCARTA la fila-extra (sentinela hay-más)',
      (tester) async {
    final stream = StreamController<List<Map<String, dynamic>>>();
    final conteo = StreamController<int>();
    await tester.pumpWidget(_wrap(ListaPaginadaScroll(
      construirStream: (_) => stream.stream,
      construirConteo: () => conteo.stream,
      itemBuilder: (_, r) => Text(r['nombre'] as String),
      filtroKey: 'a',
      tamPagina: 3,
      headerBuilder: (total) => Text('total ${total ?? '...'}'),
    )));

    conteo.add(10);
    stream.add(_filas(4)); // tamPagina+1 → 4 emitidas, 3 deben renderizar
    await tester.pump();

    expect(find.text('Fila 0'), findsOneWidget);
    expect(find.text('Fila 2'), findsOneWidget);
    // La 4ta fila es el sentinela de "hay más" → NO se muestra.
    expect(find.text('Fila 3'), findsNothing);
    // El contador toma el COUNT(*) real, no las filas cargadas.
    expect(find.text('total 10'), findsOneWidget);

    await stream.close();
    await conteo.close();
  });

  testWidgets('página vacía: muestra el widget `vacio`', (tester) async {
    final stream = StreamController<List<Map<String, dynamic>>>();
    final conteo = StreamController<int>();
    await tester.pumpWidget(_wrap(ListaPaginadaScroll(
      construirStream: (_) => stream.stream,
      construirConteo: () => conteo.stream,
      itemBuilder: (_, r) => Text(r['nombre'] as String),
      filtroKey: 'a',
      vacio: const Text('SIN-RESULTADOS'),
    )));

    conteo.add(0);
    stream.add(const []);
    await tester.pump();

    expect(find.text('SIN-RESULTADOS'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await stream.close();
    await conteo.close();
  });

  testWidgets('cambiar filtroKey resetea a spinner y re-suscribe', (tester) async {
    final a = StreamController<List<Map<String, dynamic>>>.broadcast();
    final ca = StreamController<int>.broadcast();
    final b = StreamController<List<Map<String, dynamic>>>.broadcast();
    final cb = StreamController<int>.broadcast();
    addTearDown(() {
      a.close();
      ca.close();
      b.close();
      cb.close();
    });

    var filtro = 'a';
    late StateSetter setExterno;
    await tester.pumpWidget(_wrap(StatefulBuilder(
      builder: (context, setState) {
        setExterno = setState;
        return ListaPaginadaScroll(
          construirStream: (_) => filtro == 'a' ? a.stream : b.stream,
          construirConteo: () => filtro == 'a' ? ca.stream : cb.stream,
          itemBuilder: (_, r) => Text(r['nombre'] as String),
          filtroKey: filtro,
        );
      },
    )));

    ca.add(2);
    a.add(_filas(2));
    await tester.pump();
    expect(find.text('Fila 0'), findsOneWidget);

    // Cambia el filtro → reset → spinner (b aún no emitió, no se ven filas viejas).
    setExterno(() => filtro = 'b');
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Fila 0'), findsNothing);

    // b emite → nuevas filas del filtro nuevo.
    cb.add(1);
    b.add([
      {'id': 'x', 'nombre': 'Nuevo'}
    ]);
    await tester.pump();
    expect(find.text('Nuevo'), findsOneWidget);
  });
}
