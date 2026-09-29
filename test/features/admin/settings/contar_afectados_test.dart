/// El conteo de "registros afectados" del historial de Operaciones.
///
/// `data_ops_log.afectados` es un jsonb libre: además de los contadores por
/// entidad, varios productores meten ahí un dato de PLATA o un metadato. Sumar
/// todo lo numérico da un disparate — y no es hipotético: la fila
/// `limpieza_cuaderno_telenet_2026_08` que está en producción hoy muestra
/// "59692 registros afectados" en vez de 97, porque suma los córdobas.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/settings/data_ops_screen.dart';

void main() {
  group('contarAfectados', () {
    test('el caso REAL de producción: no suma los córdobas como registros', () {
      // Copia textual de `afectados` de la fila
      // `limpieza_cuaderno_telenet_2026_08` (Telenet, 2026-08-21).
      final fila = <String, dynamic>{
        'lotes': ['A', 'B', 'C', 'D'],
        'total': 59595.51, // ← córdobas, NO registros
        'cuotas': 70,
        'contratos': 27,
      };
      expect(contarAfectados(fila), 97,
          reason: '70 cuotas + 27 contratos. Antes daba 59692.');
    });

    test('baja_deuda: `total` son córdobas', () {
      expect(
          contarAfectados(<String, dynamic>{
            'cuotas': 6,
            'contratos': 2,
            'total': 10257.00,
            'motivo': 'Servicio no prestado',
          }),
          8);
    });

    test('pago_historico: `monto` son córdobas', () {
      expect(
          contarAfectados(<String, dynamic>{
            'pagos': 1,
            'recibos': 1,
            'monto': 1282.00,
            'fecha': '2026-08-23',
            'comprobante': 'AC-00042',
          }),
          2);
    });

    test('cuota_estado: `saldo` son córdobas', () {
      expect(
          contarAfectados(<String, dynamic>{
            'cuotas': 1,
            'saldo': 513.00,
            'motivo': 'Anulada por baja',
          }),
          1);
    });

    test('corregir_invariantes: `total` es redundante (ya es la suma) y '
        '`op_id` es texto', () {
      expect(
          contarAfectados(<String, dynamic>{
            'INV14': 2,
            'INV2': 1,
            'INV3': 0,
            'INV17': 0,
            'total': 3,
            'op_id': 'b3f1c2d4-0000-4000-8000-000000000000',
          }),
          3,
          reason: 'sin el filtro daría 6: el doble exacto');
    });

    test('las operaciones que solo llevan contadores no se ven afectadas', () {
      // limpiar_cliente, tal cual está en producción.
      expect(
          contarAfectados(<String, dynamic>{
            'pagos': 4,
            'cargos': 0,
            'cuotas': 22,
            'recibos': 4,
            'contratos': 1,
            'historial': 5,
            'suspensiones': 0,
          }),
          36);
      expect(
          contarAfectados(<String, dynamic>{'recibos': 101, 'restantes': 0}),
          101);
      expect(contarAfectados(<String, dynamic>{'clientes': 4}), 4);
    });

    test('mapa vacío y valores no numéricos', () {
      expect(contarAfectados(<String, dynamic>{}), 0);
      expect(
          contarAfectados(<String, dynamic>{'lotes': ['A'], 'label': 'x'}), 0);
    });
  });
}
