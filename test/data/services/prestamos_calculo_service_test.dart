import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/services/prestamos_calculo_service.dart';

void main() {
  group('PrestamosCalculoService - Interés Fijo (Microfinanzas Flat)', () {
    test('Calcula correctamente préstamo mensual flat (C\$ 10,000 al 10% mensual, 12 cuotas)', () {
      final res = PrestamosCalculoService.calcular(
        monto: 10000,
        tasaInteres: 10,
        plazoCuotas: 12,
        frecuencia: FrecuenciaPago.mensual,
        metodo: MetodoCalculo.interesFijo,
        fechaInicio: DateTime(2026, 10, 1),
        fechaPrimerPago: DateTime(2026, 11, 1),
        tasaEsMensual: true,
      );

      // Interés mensual: 10,000 * 10% = 1,000 por mes
      // Total interés: 1,000 * 12 = 12,000
      // Total a pagar: 22,000
      // Cuota mensual: 22,000 / 12 = 1,833.3333...
      expect(res.totalInteres, closeTo(12000.0, 0.01));
      expect(res.totalPagar, closeTo(22000.0, 0.01));
      expect(res.montoCuota, closeTo(1833.33, 0.01));
      expect(res.cronograma.length, 12);

      // Invariante de amortización: suma de capital == monto inicial
      final sumCapital = res.cronograma.fold<double>(0.0, (acc, c) => acc + c.capital);
      expect(sumCapital, closeTo(10000.0, 0.01));

      // Saldo final debe llegar a 0
      expect(res.cronograma.last.saldoRestante, closeTo(0.0, 0.01));
    });

    test('Calcula correctamente préstamo quincenal flat (C\$ 6,000 al 5% mensual, 4 quincenas)', () {
      final res = PrestamosCalculoService.calcular(
        monto: 6000,
        tasaInteres: 5,
        plazoCuotas: 4,
        frecuencia: FrecuenciaPago.quincenal,
        metodo: MetodoCalculo.interesFijo,
        fechaInicio: DateTime(2026, 10, 1),
        tasaEsMensual: true,
      );

      // Factor quincenal en meses = 0.5
      // Interés por quincena = 6,000 * 5% * 0.5 = 150
      // Total interés en 4 quincenas = 150 * 4 = 600
      // Total a pagar = 6,600
      // Cuota por quincena = 6,600 / 4 = 1,650
      expect(res.totalInteres, closeTo(600.0, 0.01));
      expect(res.totalPagar, closeTo(6600.0, 0.01));
      expect(res.montoCuota, closeTo(1650.0, 0.01));
      expect(res.cronograma.length, 4);
    });
  });

  group('PrestamosCalculoService - Cuota Nivelada (Francés)', () {
    test('Calcula amortización francesa correctamente (C\$ 10,000 al 2% mensual, 12 meses)', () {
      final res = PrestamosCalculoService.calcular(
        monto: 10000,
        tasaInteres: 2,
        plazoCuotas: 12,
        frecuencia: FrecuenciaPago.mensual,
        metodo: MetodoCalculo.cuotaNivelada,
        fechaInicio: DateTime(2026, 10, 1),
        fechaPrimerPago: DateTime(2026, 11, 1),
        tasaEsMensual: true,
      );

      // En método francés:
      // Cuota nivelada constante: ~945.60
      expect(res.montoCuota, closeTo(945.60, 0.1));
      expect(res.cronograma.length, 12);

      // Invariante de amortización: suma de capital == monto inicial
      final sumCapital = res.cronograma.fold<double>(0.0, (acc, c) => acc + c.capital);
      expect(sumCapital, closeTo(10000.0, 0.01));

      // El saldo restante final es 0
      expect(res.cronograma.last.saldoRestante, closeTo(0.0, 0.01));

      // El interés decrece en cada período
      expect(res.cronograma.first.interes > res.cronograma.last.interes, isTrue);
      // El capital amortizado crece en cada período
      expect(res.cronograma.first.capital < res.cronograma.last.capital, isTrue);
    });
  });

  group('PrestamosCalculoService - Fechas de cronograma', () {
    test('Genera fechas secuenciales correctamente según frecuencia semanal', () {
      final inicio = DateTime(2026, 10, 1);
      final primerPago = DateTime(2026, 10, 8);

      final res = PrestamosCalculoService.calcular(
        monto: 5000,
        tasaInteres: 5,
        plazoCuotas: 4,
        frecuencia: FrecuenciaPago.semanal,
        metodo: MetodoCalculo.interesFijo,
        fechaInicio: inicio,
        fechaPrimerPago: primerPago,
      );

      expect(res.cronograma[0].fechaVencimiento, DateTime(2026, 10, 8));
      expect(res.cronograma[1].fechaVencimiento, DateTime(2026, 10, 15));
      expect(res.cronograma[2].fechaVencimiento, DateTime(2026, 10, 22));
      expect(res.cronograma[3].fechaVencimiento, DateTime(2026, 10, 29));
    });
  });
}
