import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/router.dart' show ShellTitleScope;
import '../../../data/repositories/settings_repo.dart';
import '../../shared/utils/shell_nav.dart';
import '../../shared/widgets/offline_banner.dart';
import '../../shared/widgets/update_banner.dart';

/// Shell del rol `admin_tickets` (admin de soporte): bottom-nav móvil-first con
/// Tickets · Mapa · Perfil. Ve TODOS los tickets del tenant + clientes (sin
/// cobranza/dinero — su bucket de sync no baja cuotas/pagos). Mismo patrón que
/// el shell del técnico; el detalle/form/tipos del ticket se pushean fuera del
/// shell con su propio back.
class AdminTicketsShell extends ConsumerWidget {
  const AdminTicketsShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empresaNombre = ref.watch(appSettingsProvider).empresaNombre;
    final titulo = ShellTitleScope.of(context) ??
        (empresaNombre.isNotEmpty ? empresaNombre : 'CRM');
    return Scaffold(
      appBar: AppBar(title: Text(titulo, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          const UpdateBanner(),
          Expanded(child: OfflineBanner(child: child)),
        ],
      ),
      bottomNavigationBar: const _AdminTicketsBottomNav(),
    );
  }
}

class _AdminTicketsBottomNav extends StatelessWidget {
  const _AdminTicketsBottomNav();

  static const _rutas = [
    '/admin-tickets',
    '/admin-tickets/mapa',
    '/admin-tickets/perfil',
  ];

  int _indexFor(String path) {
    if (path.startsWith('/admin-tickets/mapa')) return 1;
    if (path.startsWith('/admin-tickets/perfil')) return 2;
    return 0; // Tickets ('/admin-tickets' y pushes sin tab propia).
  }

  @override
  Widget build(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    return NavigationBar(
      selectedIndex: _indexFor(path),
      onDestinationSelected: (i) => context.closeModalsAndGo(_rutas[i]),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.confirmation_number_outlined),
          selectedIcon: Icon(Icons.confirmation_number),
          label: 'Tickets',
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
