import 'package:flutter/material.dart';

/// Botón (i) + diálogo explicativo para cada gráfica del dashboard.
///
/// El admin del tenant necesita saber QUÉ mide y QUÉ filtra cada sección (caja
/// vs cobertura vs mora vs foto-de-ahora) para no confundir, por ejemplo, el
/// KPI "Hoy" (caja: todo lo que entró) con el "Del día" de la tendencia
/// (cobertura: solo lo que cubre este período). Cada gráfica declara su
/// [InfoGrafica] y el diálogo la muestra con scroll interno (las que tienen
/// muchos filtros/opciones se leen scrolleando, no se cortan).
class InfoGrafica {
  const InfoGrafica({
    required this.titulo,
    required this.eje,
    this.opciones = const [],
    this.incluye = const [],
    this.noIncluye = const [],
    this.nota,
  });

  /// Nombre de la gráfica (el mismo que su encabezado).
  final String titulo;

  /// Qué mide, en una frase. Ej: "Eje: caja. La plata que entró…".
  final String eje;

  /// Opciones interactivas de la gráfica (navegar período, cambiar rango,
  /// switch, chips) con la expectativa de cada una. Vacío si no tiene.
  final List<InfoOpcion> opciones;

  /// Qué entra en el cálculo.
  final List<String> incluye;

  /// Qué se excluye.
  final List<String> noIncluye;

  /// Aclaración final opcional (ej. por qué difiere de otra gráfica).
  final String? nota;
}

/// Una opción interactiva de una gráfica, con qué esperar al usarla.
class InfoOpcion {
  const InfoOpcion(this.nombre, this.detalle);
  final String nombre;
  final String detalle;
}

/// Ícono (i) que abre el diálogo explicativo de [info]. Se cuelga del
/// encabezado de cada gráfica.
class InfoGraficaBoton extends StatelessWidget {
  const InfoGraficaBoton(this.info, {super.key, this.color});
  final InfoGrafica info;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: const Icon(Icons.info_outline, size: 19),
      color: color ?? scheme.primary,
      visualDensity: VisualDensity.compact,
      tooltip: 'Qué mide y qué filtra',
      onPressed: () => mostrarInfoGrafica(context, info),
    );
  }
}

/// Abre el diálogo explicativo. Público para engancharlo también desde un
/// encabezado propio (KPIs sin card individual).
Future<void> mostrarInfoGrafica(BuildContext context, InfoGrafica info) {
  final scheme = Theme.of(context).colorScheme;
  const verde = Color(0xFF1D9E75);
  // Ancho seguro: en Android (pantalla angosta) 400 desbordaría el diálogo.
  final anchoPantalla = MediaQuery.of(context).size.width;
  final ancho = anchoPantalla - 80 < 400 ? anchoPantalla - 80 : 400.0;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      title: Row(
        children: [
          Icon(Icons.info_outline, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(info.titulo,
                style: Theme.of(context).textTheme.titleMedium),
          ),
        ],
      ),
      content: SizedBox(
        width: ancho,
        // ConstrainedBox + scroll: si los filtros hacen el texto largo, se lee
        // scrolleando en vez de cortarse o desbordar en pantallas chicas.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 380),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Eje (qué mide) — bloque tintado.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(info.eje,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: scheme.onSurface)),
                ),
                if (info.opciones.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _tituloSeccion(context, Icons.tune, 'Opciones de la gráfica',
                      scheme.onSurface),
                  const SizedBox(height: 6),
                  for (final o in info.opciones)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(o.nombre,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(o.detalle,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.4,
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ),
                ],
                if (info.incluye.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _tituloSeccion(context, Icons.check, 'Incluye', verde),
                  const SizedBox(height: 4),
                  for (final l in info.incluye) _bullet(context, l),
                ],
                if (info.noIncluye.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _tituloSeccion(context, Icons.close, 'No incluye',
                      scheme.error),
                  const SizedBox(height: 4),
                  for (final l in info.noIncluye) _bullet(context, l),
                ],
                if (info.nota != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lightbulb_outline,
                            size: 16, color: scheme.outline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(info.nota!,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.4,
                                  color: scheme.onSurfaceVariant)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    ),
  );
}

Widget _tituloSeccion(
    BuildContext context, IconData icon, String texto, Color color) {
  return Row(
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 6),
      Text(texto,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: color)),
    ],
  );
}

Widget _bullet(BuildContext context, String texto) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(bottom: 3, left: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('•',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(texto,
              style: TextStyle(
                  fontSize: 13, height: 1.45, color: scheme.onSurfaceVariant)),
        ),
      ],
    ),
  );
}
