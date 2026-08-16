/// Matemática pura del arqueo / cierre por cobrador. **Única fuente** para el
/// PDF (`reporte_arqueo_pdf.dart`) y el Excel (`reportes_admin_screen.dart`),
/// así no se duplica ni se desincroniza la lógica de dinero.
///
/// Todos los montos en córdobas salvo [efectivoUsd] (US$ físicos, informativo).
///
/// **Invariante clave**: `equivalenteTotalC == ingresoTotal − devoluciones`
/// (0127: las devoluciones de saldo a favor en efectivo bajan ambos lados),
/// salvo data de pago corrupta. El efectivo USD se valúa a [efectivoUsdEquiv] = `monto_cordobas +
/// vuelto_cordobas` (= `monto_original × tasa_conversion`, invariante #3), o sea
/// a la tasa de CADA cobro, NO a la tasa de hoy. Por eso el arqueo cuadra aunque
/// la tasa USD haya cambiado entre el cobro y el cierre.
class ArqueoCalculo {
  const ArqueoCalculo({
    required this.efectivoUsd,
    required this.efectivoUsdEquiv,
    required this.efectivoNio,
    required this.efectivoVuelto,
    required this.transferencia,
    required this.deposito,
    required this.tarjeta,
    required this.ingresoTotal,
    this.devoluciones = 0,
  });

  /// US$ físicos recibidos (monto_original). Solo informativo.
  final double efectivoUsd;

  /// Equivalente en C$ del efectivo USD a la tasa de cada cobro
  /// (`SUM(monto_cordobas + vuelto_cordobas)` de los pagos efectivo en USD).
  final double efectivoUsdEquiv;

  /// C$ físicos recibidos en efectivo (monto_original de pagos NIO).
  final double efectivoNio;

  /// C$ devueltos al cliente (vuelto de TODOS los pagos efectivo, USD y NIO).
  final double efectivoVuelto;

  final double transferencia;
  final double deposito;
  final double tarjeta;

  /// Recaudado contable: `SUM(monto_cordobas)` de los pagos no anulados (BRUTO,
  /// antes de devoluciones).
  final double ingresoTotal;

  /// Devoluciones de saldo a favor pagadas en efectivo (crédito por excedente,
  /// 0127): plata que SALIÓ de la caja en el período. Se resta del efectivo C$.
  final double devoluciones;

  static double _d(Map<String, dynamic> r, String k) =>
      ((r[k] as num?) ?? 0).toDouble();

  factory ArqueoCalculo.fromRow(Map<String, dynamic> r) => ArqueoCalculo(
        efectivoUsd: _d(r, 'efectivo_usd'),
        efectivoUsdEquiv: _d(r, 'efectivo_usd_equiv'),
        efectivoNio: _d(r, 'efectivo_nio'),
        efectivoVuelto: _d(r, 'efectivo_vuelto'),
        transferencia: _d(r, 'transferencia'),
        deposito: _d(r, 'deposito'),
        tarjeta: _d(r, 'tarjeta'),
        ingresoTotal: _d(r, 'ingreso_total'),
        devoluciones: _d(r, 'devoluciones'),
      );

  /// Córdobas físicos netos en la gaveta: lo recibido en C$ menos TODO el vuelto
  /// entregado (el vuelto de pagos USD también sale de la caja en córdobas) menos
  /// las DEVOLUCIONES de saldo a favor pagadas en efectivo (0127). Puede dar
  /// negativo si el cobrador solo tomó pagos USD / hizo devoluciones.
  double get efectivoNetoC => efectivoNio - efectivoVuelto - devoluciones;

  /// Gran total en córdobas (NETO de devoluciones). Cuadra con
  /// `ingresoTotal − devoluciones`: el −vuelto del neto se compensa con el
  /// +vuelto incluido en [efectivoUsdEquiv]; las devoluciones bajan ambos lados.
  double get equivalenteTotalC =>
      efectivoNetoC + efectivoUsdEquiv + transferencia + deposito + tarjeta;
}
