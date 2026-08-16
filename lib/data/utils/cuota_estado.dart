/// Lógica pura del estado de una cuota en función del total pagado y
/// cargos extra. **Espeja exactamente** la función SQL
/// `recalcular_cuota_desde_pagos` (migración 0012/0018/0075/0117) —
/// cualquier cambio acá debe replicarse en el server y viceversa.
///
/// **Por qué extraída a función pura**: facilita testing (sin
/// dependencias de Provider / BD), y permite que múltiples flows del
/// cliente (cobro inmediato, undo de pago, edición de cargo extra)
/// usen la misma fuente de verdad sin duplicar la lógica.
///
/// **Regla**:
///   - Si la cuota está `anulada`, queda `anulada` (no cambia).
///   - `totalReal = max(0, montoCuota + deltaCargosExtra)`.
///     `deltaCargosExtra` puede ser negativo (descuento) — si bajaría
///     el total bajo 0, lo clampeamos a 0 (cuota efectivamente gratis).
///   - `totalReal == 0` → `pagada` (CONDONADA, 0117: una promo/ajuste del
///     100% salda la cuota; si quedara `pendiente` con saldo 0 bloquearía
///     el orden de cobro del contrato para siempre).
///   - `pagadoNuevo <= 0` → `pendiente`.
///   - `pagadoNuevo >= totalReal` → `pagada`.
///   - Cualquier otro caso → `parcial`.
String calcularEstadoCuota({
  required String estadoActual,
  required double montoCuota,
  required double pagadoNuevo,
  required double deltaCargosExtra,
}) {
  if (estadoActual == 'anulada') return 'anulada';
  final totalReal =
      (montoCuota + deltaCargosExtra).clamp(0.0, double.infinity).toDouble();
  // Condonación (0117): comparar en centavos enteros, igual que abajo.
  // Quitar el descuento revierte: totalReal vuelve a >0 y cae a 'pendiente'.
  if ((totalReal * 100).round() <= 0) return 'pagada';
  if (pagadoNuevo <= 0) return 'pendiente';
  // Comparar en centavos enteros. `pagadoNuevo` se suma en Dart (doubles), así
  // que acumula drift de floating point (ej. 333.33 → 333.3299999); el server
  // usa numeric(10,2) exacto. Redondear a centavos mantiene cliente y server
  // alineados (sin flash 'parcial' offline) y, como el dinero es de 2 decimales,
  // no traga un faltante real de 1 centavo (333.32 de 333.33 sigue 'parcial').
  if ((pagadoNuevo * 100).round() >= (totalReal * 100).round()) return 'pagada';
  return 'parcial';
}
