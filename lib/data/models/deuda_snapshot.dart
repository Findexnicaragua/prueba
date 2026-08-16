import 'dart:convert';

/// Foto de la deuda que va a quedar COBRABLE si se aprueba una suspensión o
/// cancelación, tomada en el momento en que se PIDE.
///
/// Por qué se congela: entre que alguien pide cortar el servicio y el admin
/// aprueba pueden pasar horas o días. En el medio el cliente puede pagar (la
/// deuda baja) o pueden correr días de servicio del ciclo en curso (el
/// prorrateo la sube). La tarjeta de aprobación muestra el número EN VIVO —
/// que es el que el sistema realmente va a aplicar — y usa este snapshot para
/// poder decir *por qué* cambió respecto de lo que vio quien lo pidió.
///
/// Guarda `precioMensual` y `diaPago` además del total porque son las dos
/// variables que mueven el cálculo sin que nadie pague nada: un cambio de plan
/// altera el prorrateo, y un cambio de día de pago corre la ventana de servicio
/// (y con ella la etiqueta del mes de cada cuota).
class DeudaSnapshot {
  const DeudaSnapshot({
    required this.total,
    required this.cuotas,
    required this.diaPago,
    required this.precioMensual,
    required this.fecha,
  });

  /// Total cobrable que sobrevive al corte.
  final double total;

  /// Desglose por cuota. Claves tal como las devuelve
  /// `ContratosRepo.previewDeudaSuspension`: `periodo`, `saldo`,
  /// `monto_pagado`, `fecha_vencimiento`, `en_curso` y —solo en la cuota en
  /// curso— `dias_consumidos` / `dias_ciclo`.
  final List<Map<String, dynamic>> cuotas;

  final int? diaPago;
  final double precioMensual;

  /// Fecha con la que se calculó (la misma que usaría el ejecutor ese día).
  final DateTime fecha;

  int get cantidadCuotas => cuotas.length;

  Map<String, dynamic> toJson() => {
        'total': total,
        'cuotas': cuotas,
        'dia_pago': diaPago,
        'precio_mensual': precioMensual,
        'fecha': fecha.toIso8601String(),
      };

  /// Se persiste como TEXTO con el JSON adentro, NO como `jsonb`.
  ///
  /// Precedente: `contratos.cancelacion_deuda_snapshot` nació `jsonb` en 0123 y
  /// hubo que migrarla a `text` en 0126 — el string ya codificado que manda el
  /// cliente entraba como string-escalar y volvía doble-codificado, reventando
  /// con "type 'String' is not a subtype of type 'Map'". Con `text` el valor
  /// viaja tal cual y se decodifica una sola vez, acá.
  String encode() => jsonEncode(toJson());

  /// Tolera null, JSON inválido y el doble-encoding heredado. Nunca tira: una
  /// solicitud vieja (creada antes de esta feature) simplemente no tiene
  /// snapshot, y la tarjeta tiene que saber mostrarse igual.
  static DeudaSnapshot? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      var decoded = jsonDecode(raw);
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is! Map) return null;
      final m = decoded.cast<String, dynamic>();
      final fechaRaw = m['fecha'] as String?;
      if (fechaRaw == null) return null;
      return DeudaSnapshot(
        total: (m['total'] as num?)?.toDouble() ?? 0,
        cuotas: [
          for (final c in (m['cuotas'] as List? ?? const []))
            if (c is Map) c.cast<String, dynamic>(),
        ],
        diaPago: (m['dia_pago'] as num?)?.toInt(),
        precioMensual: (m['precio_mensual'] as num?)?.toDouble() ?? 0,
        fecha: DateTime.parse(fechaRaw),
      );
    } catch (_) {
      return null;
    }
  }
}
