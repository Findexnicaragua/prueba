enum MetodoPago {
  efectivo,
  transferencia,
  deposito,
  tarjeta;

  static MetodoPago fromString(String s) => switch (s) {
        'efectivo' => MetodoPago.efectivo,
        'transferencia' => MetodoPago.transferencia,
        'deposito' => MetodoPago.deposito,
        'tarjeta' => MetodoPago.tarjeta,
        _ => MetodoPago.efectivo,
      };

  String get value => name;

  String get label => switch (this) {
        MetodoPago.efectivo => 'Efectivo',
        MetodoPago.transferencia => 'Transferencia',
        MetodoPago.deposito => 'Depósito',
        MetodoPago.tarjeta => 'Tarjeta',
      };

  bool get requiereComprobante =>
      this == MetodoPago.transferencia ||
      this == MetodoPago.deposito ||
      this == MetodoPago.tarjeta;
}

enum Moneda {
  nio,
  usd;

  static Moneda fromString(String s) => s == 'USD' ? Moneda.usd : Moneda.nio;

  String get value => switch (this) {
        Moneda.nio => 'NIO',
        Moneda.usd => 'USD',
      };

  String get symbol => switch (this) {
        Moneda.nio => 'C\$',
        Moneda.usd => 'US\$',
      };
}

class Pago {
  const Pago({
    required this.id,
    required this.tenantId,
    required this.cuotaId,
    required this.cobradorId,
    required this.montoCordobas,
    this.vueltoCordobas = 0,
    required this.moneda,
    required this.montoOriginal,
    required this.tasaConversion,
    required this.metodo,
    this.referencia,
    this.fotoComprobantePath,
    this.lat,
    this.lng,
    this.notas,
    required this.fechaPago,
    required this.anulado,
    this.anuladoEn,
    this.anuladoPor,
    this.motivoAnulacion,
    this.grupoCobro,
    this.clientLocalId,
  });

  final String id;
  final String tenantId;
  final String cuotaId;
  final String cobradorId;
  /// Monto APLICADO a la cuota (lo que entra a la caja del ISP).
  /// Para un cobro con vuelto, esto = entregado - vuelto.
  final double montoCordobas;
  /// Vuelto que se le devolvió al cliente (en córdobas).
  /// Si > 0, significa que el cliente entregó más de lo que debía.
  final double vueltoCordobas;
  final Moneda moneda;
  final double montoOriginal;
  final double tasaConversion;
  final MetodoPago metodo;
  final String? referencia;
  final String? fotoComprobantePath;
  final double? lat;
  final double? lng;
  final String? notas;
  final DateTime fechaPago;
  final bool anulado;
  final DateTime? anuladoEn;
  final String? anuladoPor;
  final String? motivoAnulacion;
  final String? grupoCobro;
  final String? clientLocalId;

  /// Lo que el cliente físicamente entregó en mano (aplicado + vuelto).
  double get entregadoCordobas => montoCordobas + vueltoCordobas;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Pago &&
          other.id == id &&
          other.tenantId == tenantId &&
          other.cuotaId == cuotaId &&
          other.cobradorId == cobradorId &&
          other.montoCordobas == montoCordobas &&
          other.vueltoCordobas == vueltoCordobas &&
          other.moneda == moneda &&
          other.montoOriginal == montoOriginal &&
          other.tasaConversion == tasaConversion &&
          other.metodo == metodo &&
          other.referencia == referencia &&
          other.fotoComprobantePath == fotoComprobantePath &&
          other.lat == lat &&
          other.lng == lng &&
          other.notas == notas &&
          other.fechaPago == fechaPago &&
          other.anulado == anulado &&
          other.anuladoEn == anuladoEn &&
          other.anuladoPor == anuladoPor &&
          other.motivoAnulacion == motivoAnulacion &&
          other.grupoCobro == grupoCobro &&
          other.clientLocalId == clientLocalId;

  // Object.hash admite hasta 20 args posicionales; Pago tiene 22 campos,
  // así que usamos Object.hashAll (acepta un Iterable sin tope).
  @override
  int get hashCode => Object.hashAll([
        id,
        tenantId,
        cuotaId,
        cobradorId,
        montoCordobas,
        vueltoCordobas,
        moneda,
        montoOriginal,
        tasaConversion,
        metodo,
        referencia,
        fotoComprobantePath,
        lat,
        lng,
        notas,
        fechaPago,
        anulado,
        anuladoEn,
        anuladoPor,
        motivoAnulacion,
        grupoCobro,
        clientLocalId,
      ]);

  factory Pago.fromRow(Map<String, dynamic> row) => Pago(
        id: row['id'] as String,
        tenantId: row['tenant_id'] as String,
        cuotaId: row['cuota_id'] as String,
        cobradorId: row['cobrador_id'] as String,
        montoCordobas: (row['monto_cordobas'] as num).toDouble(),
        // Defensivo: rows legacy (pre-migración 0061) no tienen la columna.
        // En ese caso, vuelto = 0 (asumimos que no hubo vuelto histórico).
        vueltoCordobas: (row['vuelto_cordobas'] as num? ?? 0).toDouble(),
        moneda: Moneda.fromString(row['moneda'] as String),
        montoOriginal: (row['monto_original'] as num).toDouble(),
        tasaConversion: (row['tasa_conversion'] as num).toDouble(),
        metodo: MetodoPago.fromString(row['metodo'] as String),
        referencia: row['referencia'] as String?,
        fotoComprobantePath: row['foto_comprobante_path'] as String?,
        lat: (row['lat'] as num?)?.toDouble(),
        lng: (row['lng'] as num?)?.toDouble(),
        notas: row['notas'] as String?,
        fechaPago: DateTime.parse(row['fecha_pago'] as String),
        anulado: (row['anulado'] as int? ?? 0) == 1,
        anuladoEn: row['anulado_en'] != null
            ? DateTime.parse(row['anulado_en'] as String)
            : null,
        anuladoPor: row['anulado_por'] as String?,
        motivoAnulacion: row['motivo_anulacion'] as String?,
        grupoCobro: row['grupo_cobro'] as String?,
        clientLocalId: row['client_local_id'] as String?,
      );
}
