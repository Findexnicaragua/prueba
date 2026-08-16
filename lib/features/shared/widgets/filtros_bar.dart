import 'package:flutter/material.dart';

import 'filtro_multi_dropdown.dart';

/// Convierte filas (`id`/`nombre`, opcional un campo de grupo) a [FiltroOpcion].
/// Filas con `id` null se ignoran. Promueve el `_opciones` que vivía duplicado
/// en cobros y clientes → fuente única de la conversión rows→opciones.
List<FiltroOpcion> opcionesDesdeRows(
  List<Map<String, dynamic>> rows, {
  String idKey = 'id',
  String labelKey = 'nombre',
  String? grupoKey,
}) {
  final out = <FiltroOpcion>[];
  for (final r in rows) {
    final id = r[idKey] as String?;
    if (id == null) continue;
    out.add(FiltroOpcion(
      id: id,
      label: (r[labelKey] as String?) ?? id,
      grupo: grupoKey == null ? null : r[grupoKey] as String?,
    ));
  }
  return out;
}

/// Una dimensión de filtro de la barra. El consumidor SOLO declara qué filtra y
/// guarda un `Set<String>?` ([seleccion]); la barra aplica la convención
/// canónica "todo o nada marcado = sin filtrar (null)" y le devuelve el valor YA
/// canonizado por [onChanged]. Así ninguna pantalla reimplementa la regla
/// `s.isEmpty || s.length >= total ? null : s` (que vivía copiada en cobros).
class FiltroDim {
  const FiltroDim({
    required this.icon,
    required this.hint,
    required this.opciones,
    required this.seleccion,
    required this.onChanged,
    this.buscarHint,
  });

  final IconData icon;
  final String hint;
  final List<FiltroOpcion> opciones;

  /// Selección actual. `null` = sin filtrar (= todo seleccionado en el dropdown).
  final Set<String>? seleccion;

  /// Recibe la nueva selección YA canonizada: `null` cuando quedó todo/nada
  /// marcado (sin filtrar), o el `Set` parcial.
  final ValueChanged<Set<String>?> onChanged;
  final String? buscarHint;
}

/// Barra de filtros estándar de la app (continuidad de Clientes/Cobros).
///
/// Una fila de chips [FiltroMultiDropdown] (uno por [FiltroDim]) + un botón
/// "Limpiar (N)" que aparece solo cuando hay filtros activos. Canoniza:
///
/// - **"todo/nada = sin filtrar (null)"** (decisión Rubén 2026-06-19): un ítem
///   nuevo aparece solo, y deseleccionar todo nunca da lista vacía.
/// - **contador de activos** (incluye [activosExtra] para filtros fuera de la
///   barra, ej. un segmented control) → el "(N)" del botón.
/// - **scroll horizontal** de los chips si no entran, con "Limpiar" siempre fijo
///   a la derecha (no se va de pantalla con muchos filtros).
class FiltrosBar extends StatelessWidget {
  const FiltrosBar({
    super.key,
    required this.dimensiones,
    this.trailing = const [],
    this.onLimpiar,
    this.activosExtra = 0,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 4),
  });

  final List<FiltroDim> dimensiones;

  /// Chips extra al final de la fila (ej. un filtro que no es multi-dropdown).
  final List<Widget> trailing;

  /// Resetea todos los filtros. Si es null, no se muestra el botón "Limpiar".
  final VoidCallback? onLimpiar;

  /// Filtros activos que NO están en [dimensiones] (ej. un segmented control
  /// aparte) → se suman al "(N)" del botón Limpiar.
  final int activosExtra;

  final EdgeInsetsGeometry padding;

  int get _activos =>
      dimensiones
          .where((d) => d.seleccion != null && d.seleccion!.isNotEmpty)
          .length +
      activosExtra;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activos = _activos;
    return Container(
      color: scheme.surface,
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < dimensiones.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    _dropdown(dimensiones[i]),
                  ],
                  for (final w in trailing) ...[const SizedBox(width: 8), w],
                ],
              ),
            ),
          ),
          if (activos > 0 && onLimpiar != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: TextButton.icon(
                icon: const Icon(Icons.filter_alt_off, size: 18),
                label: Text('Limpiar ($activos)'),
                onPressed: onLimpiar,
              ),
            ),
        ],
      ),
    );
  }

  Widget _dropdown(FiltroDim d) {
    final allIds = d.opciones.map((o) => o.id).toSet();
    return FiltroMultiDropdown(
      icon: d.icon,
      hint: d.hint,
      buscarHint: d.buscarHint,
      opciones: d.opciones,
      // null = sin filtrar = todo marcado en el dropdown.
      seleccionados: d.seleccion ?? allIds,
      // Convención canónica: todo o nada marcado = sin filtrar (null). El
      // consumidor recibe el valor ya canonizado (no reimplementa la regla).
      onChanged: (s) =>
          d.onChanged(s.isEmpty || s.length >= allIds.length ? null : s),
    );
  }
}
