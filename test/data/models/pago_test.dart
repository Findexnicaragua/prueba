import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/pago.dart';

/// Tests del modelo Pago — foco en el campo vuelto_cordobas (migración 0061)
/// y la compatibilidad con rows legacy que no lo tienen.
void main() {
  Map<String, dynamic> baseRow() => {
        'id': 'p1',
        'tenant_id': 't1',
        'cuota_id': 'c1',
        'cobrador_id': 'co1',
        'monto_cordobas': 500.0,
        'moneda': 'NIO',
        'monto_original': 500.0,
        'tasa_conversion': 1.0,
        'metodo': 'efectivo',
        'fecha_pago': '2026-05-28T10:00:00.000Z',
        'anulado': 0,
      };

  group('Pago.fromRow — vuelto_cordobas', () {
    test('lee vuelto_cordobas cuando está presente', () {
      final row = baseRow()
        ..['monto_cordobas'] = 500.0
        ..['vuelto_cordobas'] = 500.0;
      final pago = Pago.fromRow(row);
      expect(pago.montoCordobas, 500);
      expect(pago.vueltoCordobas, 500);
      // entregado = aplicado + vuelto.
      expect(pago.entregadoCordobas, 1000);
    });

    test('row legacy sin vuelto_cordobas → default 0 (no crashea)', () {
      final row = baseRow();
      expect(row.containsKey('vuelto_cordobas'), isFalse);
      final pago = Pago.fromRow(row);
      expect(pago.vueltoCordobas, 0);
      expect(pago.entregadoCordobas, 500);
    });

    test('vuelto_cordobas null explícito → default 0', () {
      final row = baseRow()..['vuelto_cordobas'] = null;
      final pago = Pago.fromRow(row);
      expect(pago.vueltoCordobas, 0);
    });
  });

  group('Pago.entregadoCordobas', () {
    test('sin vuelto: entregado = aplicado', () {
      final pago = Pago.fromRow(baseRow());
      expect(pago.entregadoCordobas, pago.montoCordobas);
    });

    test('USD con vuelto: monto_original preserva lo entregado en USD', () {
      final row = baseRow()
        ..['moneda'] = 'USD'
        ..['monto_original'] = 30.0 // US$30 entregados
        ..['tasa_conversion'] = 36.6
        ..['monto_cordobas'] = 500.0 // aplicado a la cuota
        ..['vuelto_cordobas'] = 598.0; // 1098 - 500
      final pago = Pago.fromRow(row);
      expect(pago.montoOriginal, 30);
      // Invariante: monto_original * tasa ≈ aplicado + vuelto.
      expect(pago.montoOriginal * pago.tasaConversion,
          closeTo(pago.montoCordobas + pago.vueltoCordobas, 0.001));
    });
  });
}
