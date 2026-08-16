/// Cálculo contable del cobro — lógica pura, testeable sin DB.
///
/// Centraliza la matemática del vuelto que históricamente tuvo un bug
/// crítico (se guardaba lo entregado como aplicado, inflando el recaudado).
///
/// Invariantes de dinero (ver CLAUDE.md → "Invariantes de dinero"):
///   - aplicado = min(entregado, saldo)  → lo que entra a la caja del ISP
///   - vuelto   = entregado - aplicado   → devuelto al cliente, SIEMPRE en NIO
///   - entregado = aplicado + vuelto
///
/// Todos los montos acá son en CÓRDOBAS (NIO). La conversión USD→NIO se hace
/// ANTES de llamar a estas funciones (entregadoCordobas = entregadoUsd * tasa).
class CobroCalculo {
  const CobroCalculo._();

  /// Resultado del cálculo de un cobro contra un saldo.
  ///
  /// [entregadoCordobas]: lo que el cliente puso en mano, ya convertido a NIO.
  /// [saldoCordobas]: el saldo pendiente de la cuota (o suma de cuotas).
  ///
  /// Trunca el aplicado al saldo: nunca se aplica de más a la cuota. El exceso
  /// es vuelto. Negativos imposibles (clamp defensivo).
  static CobroDistribucion calcular({
    required double entregadoCordobas,
    required double saldoCordobas,
  }) {
    final entregado = entregadoCordobas < 0 ? 0.0 : entregadoCordobas;
    final saldo = saldoCordobas < 0 ? 0.0 : saldoCordobas;
    final aplicado = entregado > saldo ? saldo : entregado;
    final vuelto = entregado - aplicado;
    return CobroDistribucion(
      aplicadoCordobas: aplicado,
      vueltoCordobas: vuelto,
    );
  }

  /// Convierte un monto en la moneda elegida a córdobas.
  /// NIO: la tasa es 1. USD: multiplica por la tasa de conversión.
  static double aCordobas(double monto, double tasa) => monto * tasa;

  /// Reparte un cobro MULTI-cuota. Cada cuota se cobra COMPLETA (su saldo
  /// entra a la caja); el excedente entregado es vuelto —SIEMPRE en NIO— y se
  /// imputa al ÚLTIMO pago del grupo, de modo que en cada fila se cumpla el
  /// invariante `monto_original * tasa ≈ monto_cordobas + vuelto`.
  ///
  /// [saldosCordobas]: saldo pendiente de cada cuota, en NIO, en orden de pago.
  /// [entregadoCordobas]: lo entregado por el cliente, ya convertido a NIO.
  /// [tasa]: tasa de conversión (1.0 para NIO; USD→NIO para USD). Deriva el
  ///   `monto_original` (lo entregado en la moneda original) por fila.
  ///
  /// Devuelve los montos APLICADOS (= saldos, lo que entra a caja), los montos
  /// en moneda ORIGINAL por fila, y el vuelto total (que el repo asigna al
  /// último pago). El vuelto excedente nunca infla `monto_cordobas` (invariante
  /// de dinero #1/#4: recaudado = SUM(monto_cordobas), sin vuelto).
  static CobroDistribucionMulti distribuirMulti({
    required List<double> saldosCordobas,
    required double entregadoCordobas,
    required double tasa,
  }) {
    final montosCordobas =
        saldosCordobas.map((s) => s < 0 ? 0.0 : s).toList();
    final totalSaldo = montosCordobas.fold<double>(0, (a, b) => a + b);
    final entregado = entregadoCordobas < 0 ? 0.0 : entregadoCordobas;
    final vuelto = entregado > totalSaldo ? entregado - totalSaldo : 0.0;
    // Guard defensivo: tasa nunca debería ser ≤0 (es 1.0 o la tasa USD).
    final t = tasa <= 0 ? 1.0 : tasa;

    final montosOriginal = <double>[];
    for (var i = 0; i < montosCordobas.length; i++) {
      final esUltimo = i == montosCordobas.length - 1;
      final cordobasFila = montosCordobas[i] + (esUltimo ? vuelto : 0.0);
      // monto_original = lo entregado para esa fila, en la moneda original.
      // Para NIO (tasa 1) es el mismo monto; para USD divide por la tasa.
      montosOriginal.add(cordobasFila / t);
    }
    return CobroDistribucionMulti(
      montosCordobas: montosCordobas,
      montosOriginal: montosOriginal,
      vueltoCordobas: vuelto,
    );
  }
}

/// Distribución de un cobro: cuánto se aplicó a la cuota y cuánto fue vuelto.
class CobroDistribucion {
  const CobroDistribucion({
    required this.aplicadoCordobas,
    required this.vueltoCordobas,
  });

  /// Lo que entra a la caja del ISP (se guarda en `pagos.monto_cordobas`).
  final double aplicadoCordobas;

  /// Lo devuelto al cliente, siempre en NIO (`pagos.vuelto_cordobas`).
  final double vueltoCordobas;

  /// Lo entregado por el cliente = aplicado + vuelto.
  double get entregadoCordobas => aplicadoCordobas + vueltoCordobas;

  /// True si hubo vuelto (con tolerancia de redondeo).
  bool get tieneVuelto => vueltoCordobas > 0.01;
}

/// Distribución de un cobro multi-cuota (ver [CobroCalculo.distribuirMulti]).
/// Las tres listas/escalares son paralelos al orden de las cuotas de entrada.
class CobroDistribucionMulti {
  const CobroDistribucionMulti({
    required this.montosCordobas,
    required this.montosOriginal,
    required this.vueltoCordobas,
  });

  /// Lo APLICADO a cada cuota (entra a caja) — `pagos.monto_cordobas`.
  final List<double> montosCordobas;

  /// Lo ENTREGADO por fila en la moneda original — `pagos.monto_original`.
  final List<double> montosOriginal;

  /// Vuelto total, SIEMPRE en NIO. El repo lo imputa al último pago del grupo.
  final double vueltoCordobas;
}
