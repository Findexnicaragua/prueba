import 'package:flutter/material.dart';

import '../../../data/models/cobrador_admin.dart';
import '../../../data/utils/cobrador_helpers.dart';

/// Chip "atómico" usado por el panel super_admin. Originalmente vivía
/// como `_Chip` en miembro_detalle; lo extraemos para que tenant_modulos
/// y futuras pantallas no dupliquen el styling.
///
/// Mantenemos la API mínima: fondo, foreground y un ícono opcional. La
/// decisión de qué color usar la toma el caller (rolColor del scheme,
/// etc.) — el chip no decide.
class MetaChip extends StatelessWidget {
  const MetaChip({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
    this.icon,
    this.padding =
        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  });

  final String label;
  final Color bg;
  final Color fg;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Chip de rol con colores derivados del scheme. Equivale al `_RolChip`
/// que vivía en tenant_modulos_screen.
class RolChip extends StatelessWidget {
  const RolChip({super.key, required this.rol});
  final String rol;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (rol) {
      'super_admin' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      'admin' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'admin_cobranza' =>
        (scheme.secondaryContainer, scheme.onSecondaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    // vertical:2 — parity con el `_RolChip` original (1px menos que el
    // default de MetaChip, que está calibrado para el header del detalle).
    return MetaChip(
      label: rolLabel(rol),
      bg: bg,
      fg: fg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    );
  }
}

/// Chip de estado del cobrador (activo / invitación pendiente / inactivo).
/// Cada estado se diferencia por ícono además del color para no romper
/// WCAG 1.4.1 (color como único medio de información).
class EstadoChip extends StatelessWidget {
  const EstadoChip({super.key, required this.cobrador});
  final CobradorAdmin cobrador;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, icon, bg, fg) = !cobrador.activo
        ? (
            'Inactivo',
            Icons.block,
            scheme.surfaceContainerHighest,
            scheme.onSurfaceVariant,
          )
        : cobrador.invitacionPendiente
            ? (
                'Invitación pendiente',
                Icons.schedule_send,
                scheme.surfaceContainerHighest,
                scheme.onSurfaceVariant,
              )
            : (
                'Activo',
                Icons.check_circle,
                scheme.primaryContainer,
                scheme.onPrimaryContainer,
              );
    return MetaChip(
      label: label,
      icon: icon,
      bg: bg,
      fg: fg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    );
  }
}
