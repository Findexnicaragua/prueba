import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/deuda_snapshot.dart';

/// La deuda congelada al pedir una suspensión/cancelación viaja como TEXTO con
/// JSON adentro. Ese camino ya rompió una vez en este proyecto
/// (`contratos.cancelacion_deuda_snapshot`, jsonb en 0123 → text en 0126: el
/// valor volvía doble-codificado y reventaba con "type 'String' is not a subtype
/// of type 'Map'"), así que acá se blinda el ida y vuelta.
void main() {
  DeudaSnapshot muestra() => DeudaSnapshot(
        total: 1539.0,
        cuotas: [
          {
            'periodo': '2026-04-15T00:00:00.000',
            'saldo': 513.0,
            'monto_pagado': 0.0,
            'fecha_vencimiento': '2026-05-15T00:00:00.000',
            'en_curso': false,
          },
          {
            'periodo': '2026-06-15T00:00:00.000',
            'saldo': 513.0,
            'monto_pagado': 120.5,
            'fecha_vencimiento': '2026-07-15T00:00:00.000',
            'en_curso': true,
            'dias_consumidos': 12,
            'dias_ciclo': 30,
          },
        ],
        diaPago: 15,
        precioMensual: 513.0,
        fecha: DateTime.utc(2026, 8, 9, 18, 30),
      );

  group('DeudaSnapshot', () {
    test('el ida y vuelta conserva total, cuotas, día de pago, precio y fecha',
        () {
      final d = DeudaSnapshot.decode(muestra().encode());
      expect(d, isNotNull);
      expect(d!.total, 1539.0);
      expect(d.cantidadCuotas, 2);
      expect(d.diaPago, 15);
      expect(d.precioMensual, 513.0);
      expect(d.fecha, DateTime.utc(2026, 8, 9, 18, 30));
    });

    test('conserva las claves del desglose que la UI necesita para el prorrateo',
        () {
      final d = DeudaSnapshot.decode(muestra().encode())!;
      final enCurso = d.cuotas.firstWhere((c) => c['en_curso'] == true);
      expect(enCurso['dias_consumidos'], 12);
      expect(enCurso['dias_ciclo'], 30);
      expect(enCurso['monto_pagado'], 120.5);
      // `periodo` tiene que sobrevivir parseable: la fila del desglose hace
      // DateTime.parse sobre él para rotular el mes de servicio.
      expect(() => DateTime.parse(enCurso['periodo'] as String), returnsNormally);
    });

    test('sobrevive al DOBLE-ENCODING (el bug de 0123→0126)', () {
      // Lo que llegaría si alguna capa serializa un valor ya serializado.
      final doble = jsonEncode(muestra().encode());
      final d = DeudaSnapshot.decode(doble);
      expect(d, isNotNull, reason: 'un string-escalar no debe perder el snapshot');
      expect(d!.total, 1539.0);
      expect(d.cantidadCuotas, 2);
    });

    test('devuelve null sin tirar ante null, vacío o basura', () {
      // Las solicitudes creadas ANTES de esta feature no tienen snapshot: la
      // tarjeta las tiene que poder mostrar igual, sin la comparación.
      expect(DeudaSnapshot.decode(null), isNull);
      expect(DeudaSnapshot.decode(''), isNull);
      expect(DeudaSnapshot.decode('   '), isNull);
      expect(DeudaSnapshot.decode('no soy json'), isNull);
      expect(DeudaSnapshot.decode('[1,2,3]'), isNull);
      // JSON válido pero sin `fecha`: incompleto, no se puede comparar contra
      // el recálculo en vivo → se descarta entero en vez de mostrar medio dato.
      expect(DeudaSnapshot.decode('{"total": 100}'), isNull);
    });

    test('sin cuotas es un snapshot válido: significa "no queda deuda"', () {
      final vacio = DeudaSnapshot(
        total: 0,
        cuotas: const [],
        diaPago: 1,
        precioMensual: 400,
        fecha: DateTime.utc(2026, 8, 9),
      );
      final d = DeudaSnapshot.decode(vacio.encode());
      expect(d, isNotNull);
      expect(d!.total, 0);
      expect(d.cantidadCuotas, 0);
    });

    test('tolera un contrato sin día de pago sin perder el resto', () {
      final sinDia = DeudaSnapshot(
        total: 200,
        cuotas: const [],
        diaPago: null,
        precioMensual: 200,
        fecha: DateTime.utc(2026, 8, 9),
      );
      final d = DeudaSnapshot.decode(sinDia.encode());
      expect(d, isNotNull);
      expect(d!.diaPago, isNull);
      expect(d.total, 200);
    });
  });
}
