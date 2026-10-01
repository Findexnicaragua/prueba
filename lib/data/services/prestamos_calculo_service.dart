import 'dart:math';

/// Frecuencia de cobro para microfinanzas y préstamos.
enum FrecuenciaPago {
  diario('Diario', 1, 'día'),
  semanal('Semanal', 7, 'semana'),
  quincenal('Quincenal', 15, 'quincena'),
  mensual('Mensual', 30, 'mes'),
  bimensual('Bimensual', 60, '2 meses');

  const FrecuenciaPago(this.etiqueta, this.diasAprox, this.periodo);
  final String etiqueta;
  final int diasAprox;
  final String periodo;

  static FrecuenciaPago fromString(String? val) {
    if (val == null) return FrecuenciaPago.mensual;
    for (final f in FrecuenciaPago.values) {
      if (f.name.toLowerCase() == val.toLowerCase()) return f;
    }
    return FrecuenciaPago.mensual;
  }
}

/// Método de amortización de préstamos.
enum MetodoCalculo {
  interesFijo(
    'Interés Fijo (Microfinanzas)',
    'El interés se calcula de forma fija por período sobre el capital prestado. Estándar en microcréditos.',
  ),
  cuotaNivelada(
    'Cuota Nivelada (Francés)',
    'Amortización bancaria tradicional. Las cuotas son idénticas pero el interés decrece con el saldo.',
  );

  const MetodoCalculo(this.titulo, this.descripcion);
  final String titulo;
  final String descripcion;

  static MetodoCalculo fromString(String? val) {
    if (val == null) return MetodoCalculo.interesFijo;
    for (final m in MetodoCalculo.values) {
      if (m.name.toLowerCase() == val.toLowerCase() ||
          (val == 'interes_fijo' && m == MetodoCalculo.interesFijo) ||
          (val == 'cuota_nivelada' && m == MetodoCalculo.cuotaNivelada)) {
        return m;
      }
    }
    return MetodoCalculo.interesFijo;
  }
}

/// Representa una cuota proyectada en el cronograma de amortización.
class CuotaCronograma {
  const CuotaCronograma({
    required this.numero,
    required this.fechaVencimiento,
    required this.cuota,
    required this.capital,
    required this.interes,
    required this.saldoRestante,
  });

  final int numero;
  final DateTime fechaVencimiento;
  final double cuota;
  final double capital;
  final double interes;
  final double saldoRestante;

  Map<String, dynamic> toMap() => {
        'numero': numero,
        'fechaVencimiento': fechaVencimiento.toIso8601String().substring(0, 10),
        'cuota': cuota,
        'capital': capital,
        'interes': interes,
        'saldoRestante': saldoRestante,
      };
}

/// Resultado global del cálculo financiero de un préstamo.
class ResultadoCalculoPrestamo {
  const ResultadoCalculoPrestamo({
    required this.montoPrestado,
    required this.tasaInteres,
    required this.tasaEsMensual,
    required this.frecuencia,
    required this.plazoCuotas,
    required this.metodo,
    required this.moneda,
    required this.fechaInicio,
    required this.fechaPrimerPago,
    required this.montoCuota,
    required this.totalInteres,
    required this.totalPagar,
    required this.cronograma,
  });

  final double montoPrestado;
  final double tasaInteres;
  final bool tasaEsMensual;
  final FrecuenciaPago frecuencia;
  final int plazoCuotas;
  final MetodoCalculo metodo;
  final String moneda;
  final DateTime fechaInicio;
  final DateTime fechaPrimerPago;
  final double montoCuota;
  final double totalInteres;
  final double totalPagar;
  final List<CuotaCronograma> cronograma;

  DateTime get fechaUltimaCuota => cronograma.isNotEmpty
      ? cronograma.last.fechaVencimiento
      : fechaPrimerPago;
}

/// Servicio desacoplado y puro para cálculos de microfinanzas y préstamos.
class PrestamosCalculoService {
  const PrestamosCalculoService._();

  /// Sugiere la fecha de la primera cuota según la fecha de inicio y frecuencia.
  static DateTime sugerirPrimerPago(DateTime fechaInicio, FrecuenciaPago frecuencia) {
    switch (frecuencia) {
      case FrecuenciaPago.diario:
        final sig = fechaInicio.add(const Duration(days: 1));
        return sig.weekday == DateTime.sunday ? sig.add(const Duration(days: 1)) : sig;
      case FrecuenciaPago.semanal:
        return fechaInicio.add(const Duration(days: 7));
      case FrecuenciaPago.quincenal:
        return fechaInicio.add(const Duration(days: 15));
      case FrecuenciaPago.mensual:
        return DateTime(fechaInicio.year, fechaInicio.month + 1, fechaInicio.day);
      case FrecuenciaPago.bimensual:
        return DateTime(fechaInicio.year, fechaInicio.month + 2, fechaInicio.day);
    }
  }

  /// Calcula la fecha de una cuota i basada en la fecha del primer pago y frecuencia.
  static DateTime calcularFechaCuota(DateTime fechaPrimerPago, FrecuenciaPago frecuencia, int index) {
    if (index == 0) return fechaPrimerPago;
    switch (frecuencia) {
      case FrecuenciaPago.diario:
        var fecha = fechaPrimerPago;
        var diasAgregados = 0;
        while (diasAgregados < index) {
          fecha = fecha.add(const Duration(days: 1));
          if (fecha.weekday != DateTime.sunday) {
            diasAgregados++;
          }
        }
        return fecha;
      case FrecuenciaPago.semanal:
        return fechaPrimerPago.add(Duration(days: 7 * index));
      case FrecuenciaPago.quincenal:
        return fechaPrimerPago.add(Duration(days: 15 * index));
      case FrecuenciaPago.mensual:
        return DateTime(
          fechaPrimerPago.year,
          fechaPrimerPago.month + index,
          fechaPrimerPago.day,
        );
      case FrecuenciaPago.bimensual:
        return DateTime(
          fechaPrimerPago.year,
          fechaPrimerPago.month + (index * 2),
          fechaPrimerPago.day,
        );
    }
  }

  /// Ejecuta el cálculo completo del préstamo y genera su cronograma de cuotas.
  static ResultadoCalculoPrestamo calcular({
    required double monto,
    required double tasaInteres,
    required int plazoCuotas,
    required FrecuenciaPago frecuencia,
    required MetodoCalculo metodo,
    required DateTime fechaInicio,
    DateTime? fechaPrimerPago,
    String moneda = 'NIO',
    bool tasaEsMensual = true,
  }) {
    if (monto <= 0 || plazoCuotas <= 0) {
      return ResultadoCalculoPrestamo(
        montoPrestado: monto,
        tasaInteres: tasaInteres,
        tasaEsMensual: tasaEsMensual,
        frecuencia: frecuencia,
        plazoCuotas: plazoCuotas,
        metodo: metodo,
        moneda: moneda,
        fechaInicio: fechaInicio,
        fechaPrimerPago: fechaPrimerPago ?? sugerirPrimerPago(fechaInicio, frecuencia),
        montoCuota: 0,
        totalInteres: 0,
        totalPagar: monto,
        cronograma: const [],
      );
    }

    final pPago = fechaPrimerPago ?? sugerirPrimerPago(fechaInicio, frecuencia);
    final tasaDecimal = tasaInteres / 100.0;

    double totalInteres = 0.0;
    double montoCuota = 0.0;
    final cronograma = <CuotaCronograma>[];

    if (metodo == MetodoCalculo.interesFijo) {
      double factorFrecuenciaEnMeses = 1.0;
      switch (frecuencia) {
        case FrecuenciaPago.diario:
          factorFrecuenciaEnMeses = 1.0 / 30.0;
          break;
        case FrecuenciaPago.semanal:
          factorFrecuenciaEnMeses = 7.0 / 30.0;
          break;
        case FrecuenciaPago.quincenal:
          factorFrecuenciaEnMeses = 0.5;
          break;
        case FrecuenciaPago.mensual:
          factorFrecuenciaEnMeses = 1.0;
          break;
        case FrecuenciaPago.bimensual:
          factorFrecuenciaEnMeses = 2.0;
          break;
      }

      final interesPorPeriodo = tasaEsMensual
          ? monto * tasaDecimal * factorFrecuenciaEnMeses
          : (monto * tasaDecimal) / plazoCuotas;

      totalInteres = interesPorPeriodo * plazoCuotas;
      final totalPagar = monto + totalInteres;
      montoCuota = totalPagar / plazoCuotas;
      final capitalPorCuota = monto / plazoCuotas;

      double saldo = totalPagar;
      for (int i = 0; i < plazoCuotas; i++) {
        saldo = max(0.0, saldo - montoCuota);
        cronograma.add(
          CuotaCronograma(
            numero: i + 1,
            fechaVencimiento: calcularFechaCuota(pPago, frecuencia, i),
            cuota: montoCuota,
            capital: capitalPorCuota,
            interes: interesPorPeriodo,
            saldoRestante: saldo,
          ),
        );
      }

      return ResultadoCalculoPrestamo(
        montoPrestado: monto,
        tasaInteres: tasaInteres,
        tasaEsMensual: tasaEsMensual,
        frecuencia: frecuencia,
        plazoCuotas: plazoCuotas,
        metodo: metodo,
        moneda: moneda,
        fechaInicio: fechaInicio,
        fechaPrimerPago: pPago,
        montoCuota: montoCuota,
        totalInteres: totalInteres,
        totalPagar: totalPagar,
        cronograma: cronograma,
      );
    } else {
      double r = tasaDecimal;
      if (tasaEsMensual) {
        switch (frecuencia) {
          case FrecuenciaPago.diario:
            r = tasaDecimal / 30.0;
            break;
          case FrecuenciaPago.semanal:
            r = (tasaDecimal * 12.0) / 52.0;
            break;
          case FrecuenciaPago.quincenal:
            r = tasaDecimal / 2.0;
            break;
          case FrecuenciaPago.mensual:
            r = tasaDecimal;
            break;
          case FrecuenciaPago.bimensual:
            r = tasaDecimal * 2.0;
            break;
        }
      }

      if (r <= 0) {
        montoCuota = monto / plazoCuotas;
      } else {
        montoCuota = monto * (r * pow(1 + r, plazoCuotas)) / (pow(1 + r, plazoCuotas) - 1);
      }

      double saldoCapital = monto;
      double acumuladoInteres = 0.0;

      for (int i = 0; i < plazoCuotas; i++) {
        final interesCuota = saldoCapital * r;
        final capitalCuota = montoCuota - interesCuota;
        saldoCapital = max(0.0, saldoCapital - capitalCuota);
        acumuladoInteres += interesCuota;

        cronograma.add(
          CuotaCronograma(
            numero: i + 1,
            fechaVencimiento: calcularFechaCuota(pPago, frecuencia, i),
            cuota: montoCuota,
            capital: capitalCuota,
            interes: interesCuota,
            saldoRestante: saldoCapital,
          ),
        );
      }

      totalInteres = acumuladoInteres;
      final totalPagar = monto + totalInteres;

      return ResultadoCalculoPrestamo(
        montoPrestado: monto,
        tasaInteres: tasaInteres,
        tasaEsMensual: tasaEsMensual,
        frecuencia: frecuencia,
        plazoCuotas: plazoCuotas,
        metodo: metodo,
        moneda: moneda,
        fechaInicio: fechaInicio,
        fechaPrimerPago: pPago,
        montoCuota: montoCuota,
        totalInteres: totalInteres,
        totalPagar: totalPagar,
        cronograma: cronograma,
      );
    }
  }
}
