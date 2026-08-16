import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/tendencia_cobros_card.dart';

/// La curva de tendencia agrupaba los pagos de FUERA de la ventana (pre-pagos y
/// pagos tardíos) en el día 0 / último día, inflando el tooltip "Del día" hasta
/// 5× y mintiendo la fecha (audit 2026-08-01). `construirSerieTendencia` los
/// separa en `baseline` (pre-ciclo) y `tail` (post-ciclo), dejando los días
/// del período con su valor REAL. Estos tests fijan esa precisión.
void main() {
  // Período agosto = [15 jul, 15 ago). 31 días. inicio = 15 jul.
  final inicio = DateTime(2026, 7, 15);
  final fin = DateTime(2026, 8, 15);

  group('separación pre-ciclo / en-ventana / post-ciclo', () {
    test('un pre-pago NO se cuenta como "del día 0": va al baseline', () {
      final s = construirSerieTendencia([
        const FilaDiaria('2026-02-03', 157736, 190), // pre-ciclo (feb)
        const FilaDiaria('2026-07-15', 41433, 50), // día 0 real
      ], inicio, fin, 1);
      expect(s.baseline, 157736);
      expect(s.montoPorDia[0], 41433); // "Del día" del 15 jul = SOLO lo real
      expect(s.qtyPorDia[0], 50);
      expect(s.acumulados.first, 157736 + 41433); // arranca sobre la base
      expect(s.granTotal, 157736 + 41433);
    });

    test('un pago tardío no infla el "Del día", pero SÍ cierra el acumulado',
        () {
      // Período cerrado: dc = 31 días completos.
      final s = construirSerieTendencia([
        const FilaDiaria('2026-07-20', 100000, 10), // en ventana (día 5)
        const FilaDiaria('2026-08-25', 618777, 696), // post-ciclo (tardío)
      ], inicio, fin, 31);
      expect(s.tail, 618777);
      expect(s.montoPorDia[30] ?? 0, 0); // "Del día" del último día NO se infla
      expect(s.montoPorDia[5], 100000);
      // El acumulado del ÚLTIMO día CIERRA en el total (tail plegado) → la curva
      // termina en el "Recuperado" de la tabla, no colgando.
      expect(s.acumulados.last, s.granTotal);
      expect(s.acumulados.last, 100000 + 618777);
    });
  });

  group('el total SIEMPRE cuadra con la suma de todos los pagos', () {
    test('base + en-ventana + tail = suma cruda = fin de la curva', () {
      final filas = [
        const FilaDiaria('2026-06-01', 5000, 3), // pre
        const FilaDiaria('2026-07-15', 1000, 1), // día 0
        const FilaDiaria('2026-07-16', 2000, 2), // día 1
        const FilaDiaria('2026-08-20', 3000, 4), // post
      ];
      final s = construirSerieTendencia(filas, inicio, fin, 31);
      final sumaCruda = filas.fold<double>(0, (a, f) => a + f.monto.toDouble());
      expect(s.granTotal, sumaCruda);
      expect(s.baseline + s.tail + (s.montoPorDia.values.fold<double>(0, (a, b) => a + b)),
          sumaCruda);
      // La curva TERMINA en ese total (lo que el dueño necesita ver).
      expect(s.acumulados.last, sumaCruda);
    });
  });

  group('el acumulado es monótono y arranca en la base', () {
    test('nunca baja y el primer punto ya incluye el baseline', () {
      final s = construirSerieTendencia([
        const FilaDiaria('2026-05-10', 8000, 5), // pre
        const FilaDiaria('2026-07-15', 1000, 1),
        const FilaDiaria('2026-07-17', 2000, 1), // día 2 (16 vacío)
        const FilaDiaria('2026-07-18', 500, 1), // día 3
      ], inicio, fin, 4);
      expect(s.acumulados.length, 4);
      expect(s.acumulados[0], 8000 + 1000); // base + día 0
      expect(s.acumulados[1], 9000); // día 1 vacío, no sube
      expect(s.acumulados[2], 11000);
      expect(s.acumulados[3], 11500);
      for (var i = 1; i < s.acumulados.length; i++) {
        expect(s.acumulados[i], greaterThanOrEqualTo(s.acumulados[i - 1]));
      }
    });
  });

  group('casos borde', () {
    test('sin pagos: todo en cero', () {
      final s = construirSerieTendencia([], inicio, fin, 5);
      expect(s.baseline, 0);
      expect(s.tail, 0);
      expect(s.granTotal, 0);
      expect(s.acumulados, [0, 0, 0, 0, 0]);
    });

    test('solo pre-pagos (mes que se pagó todo por adelantado)', () {
      final s = construirSerieTendencia(
          [const FilaDiaria('2026-01-01', 5000, 2)], inicio, fin, 3);
      expect(s.baseline, 5000);
      expect(s.granTotal, 5000);
      // La curva es una recta en el nivel de la base — nada "del día".
      expect(s.acumulados, [5000, 5000, 5000]);
      expect(s.montoPorDia.isEmpty, true);
    });
  });
}
