import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/cobro_calculo.dart';

/// Tests de la matemática del cobro/vuelto. Esta es la lógica que tuvo el
/// bug crítico de contabilidad (se guardaba lo entregado como aplicado,
/// inflando el recaudado del contrato). Estos tests blindan los invariantes
/// de dinero documentados en CLAUDE.md.
void main() {
  group('CobroCalculo.calcular — pago exacto', () {
    test('entregado == saldo → aplicado=saldo, vuelto=0', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 500,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 500);
      expect(d.vueltoCordobas, 0);
      expect(d.tieneVuelto, isFalse);
      expect(d.entregadoCordobas, 500);
    });
  });

  group('CobroCalculo.calcular — pago con vuelto (el bug histórico)', () {
    test('cuota 500, cliente entrega 1000 → aplicado=500, vuelto=500', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 1000,
        saldoCordobas: 500,
      );
      // CRÍTICO: aplicado NO debe ser 1000 (ese era el bug que inflaba
      // el recaudado del contrato).
      expect(d.aplicadoCordobas, 500);
      expect(d.vueltoCordobas, 500);
      expect(d.tieneVuelto, isTrue);
      // Invariante: entregado = aplicado + vuelto.
      expect(d.entregadoCordobas, 1000);
    });

    test('cuota 500, cliente entrega 600 → aplicado=500, vuelto=100', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 600,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 500);
      expect(d.vueltoCordobas, 100);
    });
  });

  group('CobroCalculo.calcular — pago parcial (sin vuelto)', () {
    test('cuota 500, cliente entrega 300 → aplicado=300, vuelto=0', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 300,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 300);
      expect(d.vueltoCordobas, 0);
      expect(d.tieneVuelto, isFalse);
    });
  });

  group('CobroCalculo.calcular — multi-cuota (saldo agregado)', () {
    test('2 cuotas de 500 = saldo 1000, entrega 1200 → aplicado=1000, vuelto=200', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 1200,
        saldoCordobas: 1000,
      );
      expect(d.aplicadoCordobas, 1000);
      expect(d.vueltoCordobas, 200);
    });
  });

  group('CobroCalculo.aCordobas — conversión de moneda', () {
    test('NIO: tasa 1 → mismo monto', () {
      expect(CobroCalculo.aCordobas(500, 1), 500);
    });

    test('USD: 30 dólares a tasa 36.6 → 1098 córdobas', () {
      expect(CobroCalculo.aCordobas(30, 36.6), closeTo(1098, 0.001));
    });
  });

  group('CobroCalculo — USD con vuelto (regla: vuelto siempre en NIO)', () {
    test('cliente paga US\$30 (tasa 36.6) a cuota de 500 → aplicado=500, vuelto=598 NIO', () {
      final entregadoNio = CobroCalculo.aCordobas(30, 36.6); // 1098
      final d = CobroCalculo.calcular(
        entregadoCordobas: entregadoNio,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 500);
      // El vuelto se calcula y entrega en córdobas, nunca en dólares.
      expect(d.vueltoCordobas, closeTo(598, 0.001));
    });
  });

  group('CobroCalculo — guards defensivos', () {
    test('entregado negativo → clamp a 0', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: -100,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 0);
      expect(d.vueltoCordobas, 0);
    });

    test('saldo negativo → clamp a 0, todo es vuelto', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 500,
        saldoCordobas: -50,
      );
      expect(d.aplicadoCordobas, 0);
      expect(d.vueltoCordobas, 500);
    });

    test('saldo 0 (cuota ya pagada) → todo es vuelto', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 500,
        saldoCordobas: 0,
      );
      expect(d.aplicadoCordobas, 0);
      expect(d.vueltoCordobas, 500);
    });
  });

  group('CobroCalculo — invariante entregado = aplicado + vuelto (siempre)', () {
    test('se cumple en una batería de combinaciones', () {
      final casos = <List<double>>[
        [100, 100], [100, 50], [50, 100], [0, 100], [100, 0],
        [1234.56, 1000], [999.99, 1000], [1000, 999.99],
      ];
      for (final c in casos) {
        final d = CobroCalculo.calcular(
          entregadoCordobas: c[0],
          saldoCordobas: c[1],
        );
        final entregadoEsperado = c[0] < 0 ? 0.0 : c[0];
        expect(d.aplicadoCordobas + d.vueltoCordobas,
            closeTo(entregadoEsperado, 0.001),
            reason: 'entregado=${c[0]} saldo=${c[1]}');
        // aplicado nunca excede el saldo.
        final saldoMax = (c[1] < 0 ? 0.0 : c[1]) + 0.001;
        expect(d.aplicadoCordobas, lessThanOrEqualTo(saldoMax));
        // nunca negativos.
        expect(d.aplicadoCordobas, greaterThanOrEqualTo(0));
        expect(d.vueltoCordobas, greaterThanOrEqualTo(0));
      }
    });
  });

  group('CobroCalculo.distribuirMulti — reparto multi-cuota (NIO)', () {
    test('exacto: 3 cuotas de 500, entrega 1500 → cada una 500, vuelto 0', () {
      final d = CobroCalculo.distribuirMulti(
        saldosCordobas: [500, 500, 500],
        entregadoCordobas: 1500,
        tasa: 1,
      );
      expect(d.montosCordobas, [500, 500, 500]);
      expect(d.vueltoCordobas, 0);
      // En NIO sin vuelto, lo entregado por fila == lo aplicado.
      expect(d.montosOriginal, [500, 500, 500]);
    });

    test('con vuelto: 2 cuotas de 500, entrega 1200 → vuelto 200 en el último', () {
      final d = CobroCalculo.distribuirMulti(
        saldosCordobas: [500, 500],
        entregadoCordobas: 1200,
        tasa: 1,
      );
      // CRÍTICO: aplicado = saldos completos; el vuelto NO infla monto_cordobas.
      expect(d.montosCordobas, [500, 500]);
      expect(d.vueltoCordobas, 200);
      // El último pago carga su saldo + el excedente entregado (NIO, tasa 1).
      expect(d.montosOriginal, [500, 700]);
    });

    test('saldos desparejos [300, 500], entrega 800 → aplica 300 y 500, vuelto 0', () {
      final d = CobroCalculo.distribuirMulti(
        saldosCordobas: [300, 500],
        entregadoCordobas: 800,
        tasa: 1,
      );
      expect(d.montosCordobas, [300, 500]);
      expect(d.vueltoCordobas, 0);
    });
  });

  group('CobroCalculo.distribuirMulti — multi-cuota en USD (vuelto SIEMPRE en NIO)', () {
    test('exacto: 2 cuotas de 500 (total 1000), tasa 36.6 → vuelto ~0', () {
      const entregadoUsd = 1000 / 36.6; // entregado justo
      final d = CobroCalculo.distribuirMulti(
        saldosCordobas: [500, 500],
        entregadoCordobas: CobroCalculo.aCordobas(entregadoUsd, 36.6),
        tasa: 36.6,
      );
      expect(d.montosCordobas, [500, 500]);
      expect(d.vueltoCordobas, closeTo(0, 0.001));
      // monto_original (USD) por fila = saldo / tasa.
      expect(d.montosOriginal[0], closeTo(500 / 36.6, 0.001));
      expect(d.montosOriginal[1], closeTo(500 / 36.6, 0.001));
    });

    test('cliente entrega US\$30 (1098 NIO) por 2 cuotas de 500 → vuelto 98 NIO', () {
      final d = CobroCalculo.distribuirMulti(
        saldosCordobas: [500, 500],
        entregadoCordobas: CobroCalculo.aCordobas(30, 36.6), // 1098
        tasa: 36.6,
      );
      expect(d.montosCordobas, [500, 500]);
      // El vuelto se da en córdobas, nunca en dólares.
      expect(d.vueltoCordobas, closeTo(98, 0.001));
      // Último pago: monto_original = (500 + 98) / 36.6 en USD.
      expect(d.montosOriginal[0], closeTo(500 / 36.6, 0.001));
      expect(d.montosOriginal[1], closeTo((500 + 98) / 36.6, 0.001));
      // La suma de monto_original (USD) ≈ lo entregado (US$30).
      final sumaUsd = d.montosOriginal.reduce((a, b) => a + b);
      expect(sumaUsd, closeTo(30, 0.001));
    });
  });

  group('CobroCalculo.distribuirMulti — invariantes de dinero', () {
    test('recaudado (Σ monto_cordobas) NUNCA incluye el vuelto', () {
      final d = CobroCalculo.distribuirMulti(
        saldosCordobas: [500, 500, 500],
        entregadoCordobas: 2000, // 500 de más
        tasa: 1,
      );
      expect(d.montosCordobas.reduce((a, b) => a + b), 1500);
      expect(d.vueltoCordobas, 500);
    });

    test('por pago: monto_original * tasa ≈ monto_cordobas + vuelto (batería NIO+USD)', () {
      final casos = <Map<String, dynamic>>[
        {'saldos': [500.0, 500.0], 'entregado': 1000.0, 'tasa': 1.0},
        {'saldos': [500.0, 500.0], 'entregado': 1300.0, 'tasa': 1.0},
        {'saldos': [400.0, 600.0, 250.0], 'entregado': 1464.0, 'tasa': 36.6},
        {'saldos': [1234.56], 'entregado': 2000.0, 'tasa': 36.6},
      ];
      for (final c in casos) {
        final saldos = (c['saldos'] as List).cast<double>();
        final tasa = c['tasa'] as double;
        final d = CobroCalculo.distribuirMulti(
          saldosCordobas: saldos,
          entregadoCordobas: c['entregado'] as double,
          tasa: tasa,
        );
        for (var i = 0; i < saldos.length; i++) {
          final esUltimo = i == saldos.length - 1;
          final vueltoFila = esUltimo ? d.vueltoCordobas : 0.0;
          expect(d.montosOriginal[i] * tasa,
              closeTo(d.montosCordobas[i] + vueltoFila, 0.01),
              reason: 'caso $c, fila $i');
        }
        // recaudado = Σ saldos (sin vuelto).
        expect(d.montosCordobas.reduce((a, b) => a + b),
            closeTo(saldos.fold<double>(0, (a, b) => a + b), 0.001));
      }
    });
  });
}
