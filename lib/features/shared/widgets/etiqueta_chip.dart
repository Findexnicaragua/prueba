import 'package:flutter/material.dart';

import '../../../data/utils/cuota_estado_visual.dart' show colorFromHex;
import '../../../data/utils/icono_helpers.dart';

/// Separadores del `etiquetas_concat` de las queries de lista (GROUP_CONCAT):
/// code 31 entre campos de una etiqueta, code 30 entre etiquetas. Son
/// caracteres de control → no colisionan con nombres/colores/iconos. Se
/// computan con `fromCharCode` (no como literal) para no meter bytes de
/// control invisibles en el source. Deben coincidir con `char(31)`/`char(30)`
/// de las queries SQL.
final String kEtiquetaFieldSep = String.fromCharCode(31);
final String kEtiquetaRecordSep = String.fromCharCode(30);

/// Pastilla visual de una etiqueta de cliente (P5). Construible desde los
/// valores crudos (nombre/color hex/clave de icono) que vienen joineados en
/// las queries de las listas, sin tener que materializar el modelo.
///
/// Mismo lenguaje visual que los mini-chips de las tarjetas: color de la
/// etiqueta a alpha bajo de fondo + icono y texto del color pleno.
class EtiquetaChip extends StatelessWidget {
  const EtiquetaChip({
    super.key,
    required this.nombre,
    required this.colorHex,
    required this.iconoKey,
    this.dense = false,
  });

  final String nombre;
  final String colorHex;
  final String iconoKey;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(colorHex) ?? const Color(0xFF6B7280);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconoEtiqueta(iconoKey), size: dense ? 12 : 14, color: color),
          const SizedBox(width: 4),
          Text(
            nombre,
            style: TextStyle(
              color: color,
              fontSize: dense ? 11 : 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Parsea el `etiquetas_concat` de las queries de lista a una lista de chips.
/// Devuelve `[]` si la columna es null/vacía.
List<EtiquetaChip> etiquetaChipsDesdeConcat(Object? concat, {bool dense = true}) {
  if (concat is! String || concat.isEmpty) return const [];
  final chips = <EtiquetaChip>[];
  for (final rec in concat.split(kEtiquetaRecordSep)) {
    final parts = rec.split(kEtiquetaFieldSep);
    if (parts.length < 3) continue;
    chips.add(EtiquetaChip(
      nombre: parts[0],
      colorHex: parts[1],
      iconoKey: parts[2],
      dense: dense,
    ));
  }
  return chips;
}
