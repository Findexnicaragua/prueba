import 'package:flutter/material.dart';

/// Mensaje grande centrado para listas vacías.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.titulo,
    this.descripcion,
    this.accion,
  });

  final IconData icon;
  final String titulo;
  final String? descripcion;
  final Widget? accion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: scheme.outline),
            const SizedBox(height: 16),
            Text(titulo,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center),
            if (descripcion != null) ...[
              const SizedBox(height: 8),
              Text(descripcion!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            if (accion != null) ...[
              const SizedBox(height: 24),
              accion!,
            ],
          ],
        ),
      ),
    );
  }
}
