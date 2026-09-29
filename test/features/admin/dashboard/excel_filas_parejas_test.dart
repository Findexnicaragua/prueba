@TestOn('vm')
library;

/// Que ninguna fila de un Excel tenga más o menos celdas que sus encabezados.
///
/// Los archivos con secciones arman su fila de cierre A MANO, con un `''` por
/// cada columna hasta la que lleva el número. Agregar una columna y olvidar el
/// `''` **no rompe nada**: el archivo se genera, se abre, y el subtotal aparece
/// una casilla corrida. Nadie se entera hasta que alguien suma a mano.
///
/// La validación vive en `LibroExcel.desparejas()` y salta con un `assert` al
/// construir el libro. Estos tests prueban que la validación SIRVE — o sea que
/// dice que sí cuando está bien y que **no** cuando está mal. Sin el segundo,
/// una validación que siempre devuelve "todo bien" pasaría igual.

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_export.dart';
import 'package:isp_billing/features/admin/reportes/excel/reporte_excel.dart';

void main() {
  LibroExcel libro({
    required List<String> headers,
    List<List<Object?>> filas = const [],
    List<SeccionExcel>? secciones,
    List<Object?>? total,
  }) =>
      LibroExcel(
        fileName: 'prueba.xlsx',
        hojaNombre: 'Hoja',
        headers: headers,
        filas: filas,
        secciones: secciones,
        total: total,
      );

  test('un libro parejo no reporta nada', () {
    final l = libro(
      headers: const ['A', 'B', 'C'],
      filas: const [
        ['1', '2', '3'],
        ['4', '5', '6'],
      ],
      total: const ['TOTAL', '', 9],
    );
    expect(l.desparejas(), isEmpty);
  });

  test('caza una fila de cierre a la que le falta una celda', () {
    // El caso real: se agrega una columna a los encabezados y el subtotal
    // sigue con los `''` de antes.
    final l = libro(
      headers: const ['Cobrador', 'Cliente', 'Vence', 'Estado', 'Saldo'],
      secciones: [
        const SeccionExcel(
          titulo: 'Juan',
          filas: [
            ['Juan', 'PB-01', '10/08', 'pendiente', 500],
          ],
          // Le falta un '' — el 500 va a caer bajo "Estado".
          subtotal: ['Subtotal Juan', '', '', 500],
        ),
      ],
    );

    final malas = l.desparejas();
    expect(malas, hasLength(1));
    expect(malas.first, contains('subtotal'));
    expect(malas.first, contains('4 celdas para 5 columnas'),
        reason: 'el mensaje tiene que decir los dos números, para que quien lo '
            'lea sepa cuántos `\'\'` agregar');
  });

  test('caza también las filas de datos y el TOTAL', () {
    final l = libro(
      headers: const ['A', 'B', 'C'],
      filas: const [
        ['1', '2', '3'],
        ['4', '5'],
      ],
      total: const ['TOTAL', '', '', 'de más'],
    );
    expect(l.desparejas(), hasLength(2));
  });

  // Y la otra mitad, que es la que hace que esto valga: el `assert` de
  // `bytes()` tiene que TUMBAR el libro desparejo en debug. Una validación que
  // nadie consulta es una función muerta.
  test('construir un libro desparejo revienta en debug', () {
    final l = libro(
      headers: const ['A', 'B', 'C'],
      total: const ['TOTAL', 9],
    );
    expect(() => l.bytes(), throwsA(isA<StateError>()));
  });
}
