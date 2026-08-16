import 'package:flutter/material.dart';

/// Estado VISUAL de una cuota (color + categoría por fecha de vencimiento) —
/// fuente ÚNICA de verdad para TODA la app (mapa, lista de cobros, cuotas
/// admin, detalle de contrato, lista de clientes). Antes la derivación estaba
/// copiada/hardcodeada en 4+ lugares con criterios y colores distintos.
///
/// OJO: NO confundir con `cuota_estado.dart` (`calcularEstadoCuota`), que es el
/// estado PERSISTIDO en DB según el dinero pagado (pendiente/parcial/pagada/
/// anulada). Esto es solo presentación: cómo se PINTA una cuota no finalizada.
///
/// Precedencia (cuota más urgente de un cliente):
/// mora > gracia > hoy > proxima > fueraDeRango > sinDeuda.
enum CuotaEstadoVisual {
  /// Venció hace MÁS de los días de gracia.
  mora,

  /// Venció pero sigue DENTRO del período de gracia.
  gracia,

  /// Vence exactamente HOY (hora Nicaragua).
  hoy,

  /// Vence en el FUTURO, dentro del rango de días visibles del setting.
  proxima,

  /// Vence en el futuro, MÁS ALLÁ del rango visible. Se oculta al cobrador;
  /// el admin la puede revelar con "Ver todo".
  fueraDeRango,

  /// Sin cuotas pendientes — nada que cobrar.
  sinDeuda,
}

/// Paleta de colores por estado, configurable por tenant vía el setting
/// `cobranza.colores_estados` (map JSONB `{mora,gracia,hoy,proxima}` → "#RRGGBB").
/// Si una clave falta o es inválida, cae al default correspondiente.
@immutable
class ColoresEstados {
  const ColoresEstados({
    required this.mora,
    required this.gracia,
    required this.hoy,
    required this.proxima,
  });

  final Color mora;
  final Color gracia;
  final Color hoy;
  final Color proxima;

  /// Defaults acordados con Rubén: mora=rojo, gracia=ámbar, hoy=azul,
  /// proxima=morado. El ámbar (0xFFB45309) coincide con el que ya usaba el mapa.
  static const ColoresEstados defaults = ColoresEstados(
    mora: Color(0xFFDC2626),
    gracia: Color(0xFFB45309),
    hoy: Color(0xFF2563EB),
    proxima: Color(0xFF7C3AED),
  );

  /// Gris neutro para "sin deuda" cuando el admin la revela. NO verde por
  /// pedido explícito (el verde sugiere "pagado / saldado").
  static const Color sinDeudaColor = Color(0xFF9CA3AF);

  /// Color del estado. `fueraDeRango` = morado atenuado; `sinDeuda` = gris.
  Color color(CuotaEstadoVisual estado) => switch (estado) {
        CuotaEstadoVisual.mora => mora,
        CuotaEstadoVisual.gracia => gracia,
        CuotaEstadoVisual.hoy => hoy,
        CuotaEstadoVisual.proxima => proxima,
        // Fuera de rango = "no disponible" (aún no cobrable) → gris, igual que
        // sin-deuda. Pedido de Rubén (NO morado atenuado).
        CuotaEstadoVisual.fueraDeRango => sinDeudaColor,
        CuotaEstadoVisual.sinDeuda => sinDeudaColor,
      };

  /// Construye desde el JSON crudo del setting (map clave→hex). Tolera null,
  /// valores no-string y hex inválidos cayendo al default por clave.
  factory ColoresEstados.fromJson(Map<dynamic, dynamic>? json) {
    Color pick(String k, Color def) {
      final v = json?[k];
      return (v is String ? colorFromHex(v) : null) ?? def;
    }

    return ColoresEstados(
      mora: pick('mora', defaults.mora),
      gracia: pick('gracia', defaults.gracia),
      hoy: pick('hoy', defaults.hoy),
      proxima: pick('proxima', defaults.proxima),
    );
  }

  Map<String, String> toJson() => {
        'mora': hexFromColor(mora),
        'gracia': hexFromColor(gracia),
        'hoy': hexFromColor(hoy),
        'proxima': hexFromColor(proxima),
      };

  ColoresEstados copyWith({
    Color? mora,
    Color? gracia,
    Color? hoy,
    Color? proxima,
  }) =>
      ColoresEstados(
        mora: mora ?? this.mora,
        gracia: gracia ?? this.gracia,
        hoy: hoy ?? this.hoy,
        proxima: proxima ?? this.proxima,
      );
}

/// Deriva el estado visual de una cuota NO finalizada (pendiente/parcial) a
/// partir de los días desde el vencimiento. Fuente ÚNICA usada por el mapa y por
/// los badges (lista de cobros, detalle de contrato) — para que clasifiquen
/// igual: dentro del rango = próxima (morado), más allá = fuera de rango (gris).
///
/// [diasFromVence] = hoy − fecha_vencimiento (hora Nicaragua). Positivo = ya
/// venció; 0 = vence hoy; negativo = vence en el futuro.
CuotaEstadoVisual estadoVisualCuota({
  required int diasFromVence,
  required int diasGracia,
  required int diasVisibles,
}) {
  if (diasFromVence > diasGracia) return CuotaEstadoVisual.mora;
  if (diasFromVence > 0) return CuotaEstadoVisual.gracia;
  if (diasFromVence == 0) return CuotaEstadoVisual.hoy;
  // Futuro: dentro del rango configurado = próxima; más allá = fuera de rango.
  if (-diasFromVence <= diasVisibles) return CuotaEstadoVisual.proxima;
  return CuotaEstadoVisual.fueraDeRango;
}

/// "#RRGGBB" (o "RRGGBB", o "#AARRGGBB") → Color. Null si el formato es inválido.
Color? colorFromHex(String hex) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final value = int.tryParse(h, radix: 16);
  return value == null ? null : Color(value);
}

/// Color → "#RRGGBB" (sin alpha; los colores de estado son opacos).
String hexFromColor(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// Swatches predefinidos para el picker de Ajustes (sin dependencias externas).
const List<Color> kPaletaColoresEstados = [
  Color(0xFFDC2626), // rojo
  Color(0xFFEA580C), // naranja
  Color(0xFFB45309), // ámbar
  Color(0xFFCA8A04), // amarillo / oro
  Color(0xFF16A34A), // verde
  Color(0xFF0D9488), // teal
  Color(0xFF2563EB), // azul
  Color(0xFF4F46E5), // índigo
  Color(0xFF7C3AED), // morado
  Color(0xFFDB2777), // rosa / magenta
  Color(0xFF6B7280), // gris
  Color(0xFF111827), // casi negro
];
