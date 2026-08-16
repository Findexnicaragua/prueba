import 'package:flutter/material.dart';

/// Muestra un dialog "¿Descartar cambios sin guardar?" centralizado.
///
/// Retorna `true` si el user confirma descartar (puede continuar el pop /
/// la navegación), `false` o `null` si cancela (debe permanecer).
///
/// Se dispara desde dos vías:
///   1. `PopScope.onPopInvokedWithResult` del form — intercepta browser
///      back, hardware back, botón Cancelar imperativo.
///   2. `closeModalsAndGoGuarded` del shell — intercepta tap de sidebar
///      con form dirty (porque `context.go` no dispara PopScope).
///
/// **Por qué "Seguir editando" es FilledButton y "Descartar" TextButton**:
/// estándar de UX para diálogos destructivos. La acción segura (preservar
/// el trabajo) es la primaria visual; la destructiva (perder cambios) es
/// secundaria. Evita pérdida accidental por Enter del teclado o tap rápido.
/// "Descartar" lleva color `error` para reforzar que es destructiva.
///
/// `barrierDismissible: false`: tap fuera no dismissea — sería una pérdida
/// silenciosa de datos en mobile donde tocar al lado del dialog es fácil.
Future<bool?> confirmDiscardChanges(BuildContext context) {
  final colorScheme = Theme.of(context).colorScheme;
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('¿Descartar cambios?'),
      content: const Text(
        'Tenés cambios sin guardar. Si salís se pierden.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: TextButton.styleFrom(foregroundColor: colorScheme.error),
          child: const Text('Descartar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Seguir editando'),
        ),
      ],
    ),
  );
}
