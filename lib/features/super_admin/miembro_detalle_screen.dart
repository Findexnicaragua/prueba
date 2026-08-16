import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/cobrador_admin.dart';
import '../../data/models/cobrador_stats.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/cobrador_helpers.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/chips.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/skeleton.dart';
import '../../data/utils/errores.dart';

/// Pantalla de detalle de un miembro del tenant. Muestra:
///   - Header con info básica (avatar, nombre, email, chips de rol/estado)
///   - Stats: última sesión, clientes asignados, cobrado del mes
///
/// Las acciones (cambiar rol, forzar password, etc.) siguen viviendo en
/// el popup `⋮` de la lista de miembros — esta pantalla es read-only.
/// Más adelante agregamos también acciones cambiar email / borrar acá.
class MiembroDetalleScreen extends ConsumerWidget {
  const MiembroDetalleScreen({
    super.key,
    required this.tenantId,
    required this.cobradorId,
  });

  final String tenantId;
  final String cobradorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Buscamos al miembro en la lista cacheada del tenant — ya está
    // poblada al venir desde la pantalla padre, no requiere RPC extra.
    final miembros = ref.watch(cobradoresTenantProvider(tenantId));
    final statsAsync = ref.watch(cobradorStatsProvider(cobradorId));

    return miembros.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(mensajeErrorHumano(e))),
      data: (lista) {
        final c = lista.where((m) => m.id == cobradorId).firstOrNull;
        if (c == null) {
          return const EmptyState(
            icon: Icons.person_off,
            titulo: 'Miembro no encontrado',
            descripcion: 'Puede haber sido eliminado o cambiado de tenant.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            // Refrescamos también la lista del tenant para que el header
            // no quede stale con datos cacheados después del pull.
            ref.invalidate(cobradoresTenantProvider(tenantId));
            ref.invalidate(cobradorStatsProvider(cobradorId));
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Header(cobrador: c),
              const SizedBox(height: 24),
              Text('Actividad',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              _StatsGrid(stats: statsAsync, cobrador: c),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.cobrador});
  final CobradorAdmin cobrador;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rolColor = _rolColor(scheme, cobrador.rol);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: cobrador.activo
                  ? rolColor.withValues(alpha: 0.15)
                  : scheme.surfaceContainerHighest,
              foregroundColor:
                  cobrador.activo ? rolColor : scheme.outline,
              child: Text(
                initialsFromName(cobrador.nombre),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cobrador.nombre,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    cobrador.email ?? '(sin email)',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                  if (cobrador.telefono != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      cobrador.telefono!,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      // Usamos MetaChip directo (no RolChip) porque queremos
                      // el tinte derivado de rolColor.withAlpha(0.15) que
                      // matchea el avatar de esta pantalla — RolChip usa los
                      // *Container() del scheme, más saturados.
                      MetaChip(
                        label: rolLabel(cobrador.rol),
                        bg: rolColor.withValues(alpha: 0.15),
                        fg: rolColor,
                      ),
                      EstadoChip(cobrador: cobrador),
                      if (cobrador.prefijoRecibo != null)
                        MetaChip(
                          icon: Icons.receipt_long,
                          label: 'Prefijo ${cobrador.prefijoRecibo}',
                          bg: scheme.surfaceContainerHighest,
                          fg: scheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _rolColor(ColorScheme s, String rol) => switch (rol) {
        'super_admin' => s.tertiary,
        'admin' => s.primary,
        // s.secondary es primary al 10% → iniciales del avatar ilegibles.
        'admin_cobranza' => Colors.teal.shade700,
        _ => s.onSurfaceVariant,
      };
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats, required this.cobrador});

  // Tipo concreto (no dynamic) para que el compiler nos avise si el
  // modelo cambia de shape.
  final AsyncValue<CobradorStats?> stats;
  final CobradorAdmin cobrador;

  @override
  Widget build(BuildContext context) {
    return stats.when(
      loading: () => const _StatsSkeleton(),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No se pudieron cargar las stats: $e'),
        ),
      ),
      data: (s) {
        // s puede ser null si el cobrador es super_admin (excluido por
        // la RPC). En ese caso caemos a defaults para que la UI no rompa.
        final lastSignIn = s?.lastSignInAt;
        final clientes = s?.clientesAsignados ?? 0;
        final pagosCount = s?.pagosMesCount ?? 0;
        final pagosTotal = s?.pagosMesTotal ?? 0.0;
        final esCobrador = cobrador.rol == 'cobrador';
        return LayoutBuilder(
          builder: (_, constraints) {
            final wide = constraints.maxWidth > 600;
            // Si lastSignIn ya pasó >30 días, el valor del card muestra
            // la fecha larga — evitamos repetirla en hint.
            final ultimoStr = _ultimoLogin(lastSignIn);
            final lastSignInLejano = lastSignIn != null &&
                DateTime.now().difference(lastSignIn).inDays >= 30;
            final children = [
              _StatCard(
                icon: Icons.schedule,
                label: 'Última sesión',
                valor: ultimoStr,
                hint: lastSignIn == null
                    ? 'Nunca inició sesión'
                    : (lastSignInLejano
                        ? null
                        : Fmt.fechaLarga(lastSignIn)),
              ),
              _StatCard(
                icon: Icons.people_outline,
                label: 'Clientes asignados',
                // Para no-cobradores, no tiene sentido un número 0 —
                // mostramos '—' para distinguirlo de "cobrador con 0".
                valor: esCobrador ? clientes.toString() : '—',
                hint: esCobrador
                    ? 'Activos en su ruta'
                    : 'Sólo aplica al rol cobrador',
              ),
              _StatCard(
                icon: Icons.payments_outlined,
                label: 'Cobrado este mes',
                valor: esCobrador
                    ? 'C\$ ${pagosTotal.toStringAsFixed(2)}'
                    : '—',
                hint: esCobrador
                    ? '$pagosCount cobros'
                    : 'Sólo aplica al rol cobrador',
              ),
            ];
            return wide
                ? Row(
                    children: children
                        .expand((c) => [
                              Expanded(child: c),
                              const SizedBox(width: 12),
                            ])
                        .toList()
                      ..removeLast(),
                  )
                : Column(
                    children: children
                        .expand((c) => [c, const SizedBox(height: 12)])
                        .toList()
                      ..removeLast(),
                  );
          },
        );
      },
    );
  }

  static String _ultimoLogin(DateTime? t) {
    if (t == null) return 'Nunca';
    final raw = DateTime.now().difference(t).inDays;
    final dias = raw < 0 ? 0 : raw;
    if (dias == 0) return 'Hoy';
    if (dias == 1) return 'Ayer';
    if (dias < 30) return 'Hace $dias días';
    return Fmt.fechaLarga(t);
  }
}

class _StatsSkeleton extends StatelessWidget {
  const _StatsSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final wide = constraints.maxWidth > 600;
        Widget item() => const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 100, height: 12),
                    SizedBox(height: 12),
                    SkeletonBox(width: 80, height: 24),
                    SizedBox(height: 6),
                    SkeletonBox(width: 60, height: 11),
                  ],
                ),
              ),
            );
        return wide
            ? Row(
                children: [
                  Expanded(child: item()),
                  const SizedBox(width: 12),
                  Expanded(child: item()),
                  const SizedBox(width: 12),
                  Expanded(child: item()),
                ],
              )
            : Column(
                children: [
                  item(),
                  const SizedBox(height: 12),
                  item(),
                  const SizedBox(height: 12),
                  item(),
                ],
              );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.valor,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String valor;
  /// Hint opcional debajo del valor. Si es null o vacío, no se renderiza
  /// (evita repetir info — ej. fechaLarga ya está en `valor`).
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              valor,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (hint != null && hint!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                hint!,
                style: TextStyle(
                  color: scheme.outline,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
