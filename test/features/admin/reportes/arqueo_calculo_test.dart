import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/reportes/arqueo_calculo.dart';

/// Tests de la matemática del arqueo / cierre por cobrador. La propiedad
/// central: **`equivalenteTotalC == ingresoTotal`** siempre que los pagos
/// respeten el invariante #3 (`monto_original × tasa = monto_cordobas +
/// vuelto`), SIN importar la tasa USD actual. Esto blinda el bug que se
/// arregló: antes el equivalente usaba `efectivo_usd × tasa_de_hoy` y se
/// descuadraba del ingreso cuando la tasa cambiaba entre el cobro y el arqueo.
void main() {
  group('ArqueoCalculo — reconciliación equivalente == ingreso', () {
    test('mix NIO efectivo + USD efectivo + transferencia cuadra', () {
      // Pago 1: NIO efectivo. Cuota 500, cliente entrega 600 → vuelto 100.
      //   monto_cordobas=500, vuelto=100, monto_original=600 (NIO, tasa 1).
      // Pago 2: USD efectivo. Cuota 1000, US$30 a tasa 36.6 = 1098 entregado →
      //   aplicado 1000, vuelto 98. monto_original=30, monto_cordobas=1000.
      // Pago 3: transferencia 700.
      const a = ArqueoCalculo(
        efectivoUsd: 30, // US$ físicos (informativo)
        efectivoUsdEquiv: 1000 + 98, // monto_cordobas + vuelto de los USD
        efectivoNio: 600, // monto_original de los NIO
        efectivoVuelto: 100 + 98, // vuelto de TODOS los efectivo
        transferencia: 700,
        deposito: 0,
        tarjeta: 0,
        ingresoTotal: 500 + 1000 + 700, // SUM(monto_cordobas)
      );

      expect(a.efectivoNetoC, 600 - 198); // 402: C$ físicos netos en gaveta
      expect(a.equivalenteTotalC, 2200);
      expect(a.equivalenteTotalC, a.ingresoTotal);
    });

    test('el equivalente NO depende de la tasa actual (el bug arreglado)', () {
      // Mismo pago USD del caso anterior: US$30 cobrados a tasa 36.6 → 1098 C$.
      const a = ArqueoCalculo(
        efectivoUsd: 30,
        efectivoUsdEquiv: 1098, // tasa histórica del cobro, ya en córdobas
        efectivoNio: 0,
        efectivoVuelto: 0,
        transferencia: 0,
        deposito: 0,
        tarjeta: 0,
        ingresoTotal: 1098,
      );

      // ArqueoCalculo usa el equivalente histórico → cuadra con el ingreso.
      expect(a.equivalenteTotalC, 1098);
      expect(a.equivalenteTotalC, a.ingresoTotal);

      // El bug viejo habría hecho `efectivoUsd * tasaActual`. Con una tasa de
      // hoy distinta (37.0) habría dado 30*37 = 1110 ≠ 1098 → descuadre. Lo
      // demostramos para dejar claro qué se evitó.
      const tasaActualDistinta = 37.0;
      final equivalenteBuggy = a.efectivoUsd * tasaActualDistinta;
      expect(equivalenteBuggy, isNot(equals(a.ingresoTotal)));
    });

    test('solo efectivo NIO sin USD: neto == ingreso', () {
      const a = ArqueoCalculo(
        efectivoUsd: 0,
        efectivoUsdEquiv: 0,
        efectivoNio: 1500, // entregó 1500 por una cuota de 1300
        efectivoVuelto: 200,
        transferencia: 0,
        deposito: 0,
        tarjeta: 0,
        ingresoTotal: 1300,
      );
      expect(a.efectivoNetoC, 1300);
      expect(a.equivalenteTotalC, a.ingresoTotal);
    });

    test('solo USD efectivo con vuelto NIO: efectivoNeto negativo pero cuadra',
        () {
      // Cobrador toma 1 pago US$30 efectivo (cuota 1000, vuelto 98 córdobas),
      // cero pagos NIO. El vuelto sale de la gaveta de córdobas → efectivoNeto
      // negativo, pero el equivalente total sigue cuadrando con el ingreso.
      const a = ArqueoCalculo(
        efectivoUsd: 30,
        efectivoUsdEquiv: 1098,
        efectivoNio: 0,
        efectivoVuelto: 98,
        transferencia: 0,
        deposito: 0,
        tarjeta: 0,
        ingresoTotal: 1000,
      );
      expect(a.efectivoNetoC, -98); // real: la oficina reembolsa el cambio
      expect(a.equivalenteTotalC, 1000);
      expect(a.equivalenteTotalC, a.ingresoTotal);
    });

    test('fromRow lee las claves de la query del arqueo', () {
      final a = ArqueoCalculo.fromRow(<String, dynamic>{
        'efectivo_usd': 30,
        'efectivo_usd_equiv': 1098,
        'efectivo_nio': 600,
        'efectivo_vuelto': 198,
        'transferencia': 700,
        'deposito': 0,
        'tarjeta': 0,
        'ingreso_total': 2200,
      });
      expect(a.equivalenteTotalC, 2200);
      expect(a.equivalenteTotalC, a.ingresoTotal);
    });
  });
}
