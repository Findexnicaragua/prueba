import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/router.dart';
import '../../data/providers/crud_error_provider.dart';
import '../../data/providers/sync_status_provider.dart';
import '../../data/providers/tickets_alerta_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/rechazos_sync_service.dart';
import '../shared/utils/shell_nav.dart';
import '../shared/widgets/offline_banner.dart';
import '../shared/widgets/update_banner.dart';

/// Shell móvil-first del técnico (Fase 3B): bottom-nav con 3 destinos
/// (Mis tickets · Mapa · Perfil). Offline-first como el shell del cobrador.
/// Las pantallas de detalle (ticket) se pushean fuera del shell con su back.
class TecnicoShell extends ConsumerWidget {
  const TecnicoShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(crudUploadErrorProvider, (_, next) {
      final error = next.valueOrNull;
      if (error != null && context.mounted) {
        // Mensaje humano; el detalle queda persistido en Perfil (audit #5).
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Un cambio en ${etiquetaTablaSync(error.table)} fue rechazado '
                'por el servidor: '
                '${humanizarRechazoSync(error.codigo, error.message)}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: 'VER',
              onPressed: () {
                // El SnackBar vive 8s: el shell pudo desmontarse (signOut).
                if (context.mounted) context.go('/tecnico/perfil');
              },
            ),
          ),
        );
      }
    });

    final empresaNombre = ref.watch(appSettingsProvider).empresaNombre;
    final titulo = ShellTitleScope.of(context) ??
        (empresaNombre.isNotEmpty ? empresaNombre : 'CRM');
    return Scaffold(
      appBar: AppBar(
        title: Text(titulo, overflow: TextOverflow.ellipsis),
        actions: const [_SyncIndicator(), SizedBox(width: 8)],
      ),
      body: Column(
        children: [
          const UpdateBanner(),
          Expanded(child: OfflineBanner(child: child)),
        ],
      ),
      bottomNavigationBar: const _TecnicoBottomNav(),
    );
  }
}

class _SyncIndicator extends ConsumerWidget {
  const _SyncIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final scheme = Theme.of(context).colorScheme;
    return status.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (_, __) => Icon(Icons.error_outline, color: scheme.error),
      data: (s) {
        final connected = s?.connected ?? false;
        final busy = (s?.downloading ?? false) || (s?.uploading ?? false);
        final color = !connected
            ? scheme.error
            : busy
                ? scheme.tertiary
                : scheme.primary;
        final icon = !connected
            ? Icons.cloud_off
            : busy
                ? Icons.cloud_sync
                : Icons.cloud_done;
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Tooltip(
            message: !connected
                ? 'Sin conexión'
                : busy
                    ? 'Sincronizando'
                    : 'Sincronizado',
            child: Icon(icon, color: color),
          ),
        );
      },
    );
  }
}

class _TecnicoBottomNav extends StatelessWidget {
  const _TecnicoBottomNav();

  static const _rutas = ['/tecnico', '/tecnico/mapa', '/tecnico/perfil'];

  int _indexFor(String path) {
    if (path.startsWith('/tecnico/mapa')) return 1;
    if (path.startsWith('/tecnico/perfil')) return 2;
    return 0; // Mis tickets ('/tecnico' y pushes sin tab propia).
  }

  @override
  Widget build(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    return NavigationBar(
      selectedIndex: _indexFor(path),
      onDestinationSelected: (i) => context.closeModalsAndGo(_rutas[i]),
      destinations: const [
        NavigationDestination(
          icon: _MisTicketsIcon(icon: Icons.confirmation_number_outlined),
          selectedIcon: _MisTicketsIcon(icon: Icons.confirmation_number),
          label: 'Mis tickets',
        ),
        NavigationDestination(
          icon: Icon(Icons.map_outlined),
          selectedIcon: Icon(Icons.map),
          label: 'Mapa',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Perfil',
        ),
      ],
    );
  }
}

/// Ícono de "Mis tickets" con badge = cantidad de tickets EN RIESGO (por vencer +
/// vencidos) asignados al técnico. Derivado client-side de la cuenta regresiva del
/// SLA → se actualiza offline. Sin riesgo (0) → ícono pelado.
class _MisTicketsIcon extends ConsumerWidget {
  const _MisTicketsIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(ticketsEnRiesgoCountProvider).valueOrNull ?? 0;
    final base = Icon(icon);
    if (n == 0) return base;
    return Badge(label: Text('$n'), child: base);
  }
}
