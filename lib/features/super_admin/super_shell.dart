import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:package_info_plus/package_info_plus.dart';

import '../../data/providers/crud_error_provider.dart';
import '../../data/services/rechazos_sync_service.dart';
import '../shared/utils/shell_nav.dart';
import '../shared/utils/sign_out_helper.dart';
import '../shared/widgets/offline_banner.dart';
import '../shared/widgets/update_banner.dart';

/// Shell del panel Super Admin (gestión cross-tenant del SaaS).
/// Visualmente separado del AdminShell para dejar claro que estás "afuera"
/// del tenant — con un AppBar que indica "Super Admin" y un botón para
/// volver al panel admin del tenant System.
class SuperShell extends ConsumerWidget {
  const SuperShell({super.key, required this.child, required this.titulo});

  final Widget child;
  final String titulo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Escuchar errores de CRUD upload para mostrar SnackBar cuando un write
    // local es rechazado por Postgres (trigger, constraint, RLS). Mismo patrón
    // que AdminShell — el super_admin también opera contra la DB (impersonación,
    // toggles de módulos) y necesita feedback si un sync falla.
    ref.listen(crudUploadErrorProvider, (_, next) {
      final error = next.valueOrNull;
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Un cambio en ${etiquetaTablaSync(error.table)} fue rechazado '
                'por el servidor: '
                '${humanizarRechazoSync(error.codigo, error.message)}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    });

    final scheme = Theme.of(context).colorScheme;
    final loc = GoRouterState.of(context).matchedLocation;
    final enTenants = loc == '/super/tenants';
    // En pantallas angostas (mobile) el AppBar se sobrecargaba: título largo
    // ("Super Admin · Tenants") + badge de versión + ícono tenants + ícono
    // logs + logout se superponían. En mobile ocultamos el badge de versión
    // (dato secundario) y dejamos que el título use ellipsis con Flexible.
    final esAngosta = MediaQuery.sizeOf(context).width < 600;
    // Back arrow context-aware:
    //   - /super/tenants/:tid/miembros/:cid → back a /super/tenants/:tid
    //   - /super/tenants/:id                → back a /super/tenants
    //   - /super/tenants y /super/logs (raíz) → back a /admin
    // Sin esto el back siempre iba a /admin desde cualquier profundidad,
    // perdiendo navegación natural entre sub-rutas del panel super.
    final backTarget = _backTargetFor(loc);
    final backTooltip =
        backTarget == '/admin' ? 'Volver al panel' : 'Volver';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: backTooltip,
          // closeModalsAndGo cierra dialogs/sheets abiertos sobre la
          // ruta actual antes de navegar (ej. CredencialesDialog en
          // /super/tenants después de crear un ISP, que queda flotando
          // si el user toca volver sin cerrarlo).
          onPressed: () => context.closeModalsAndGo(backTarget),
        ),
        title: Row(
          children: [
            const Icon(Icons.shield, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Dev · $titulo',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (!esAngosta)
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (_, snap) => snap.hasData
                  ? Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.outline.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('v${snap.data!.version}',
                          style: TextStyle(
                              fontSize: 11,
                              color: scheme.onPrimaryContainer)),
                    )
                  : const SizedBox.shrink(),
            ),
          if (!enTenants)
            IconButton(
              icon: const Icon(Icons.business),
              tooltip: 'Tenants',
              onPressed: () => context.closeModalsAndGo('/super/tenants'),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Cerrar sesión',
            onPressed: () => confirmarSignOut(context),
          ),
        ],
      ),
      body: Column(
        children: [
          const UpdateBanner(),
          // Mismo patrón que los otros 3 shells (audit LOW): el panel super
          // es RPC/Edge (online-only) — sin el banner, la red caída aparecía
          // como errores sueltos por pantalla sin la pista global.
          Expanded(child: OfflineBanner(child: child)),
        ],
      ),
    );
  }
}

/// Determina la ruta del back arrow según la profundidad actual.
///
/// - `/super/tenants/:tid/miembros/:cid` → `/super/tenants/:tid`
///   (detalle miembro → volver al detalle del tenant).
/// - `/super/tenants/:id` → `/super/tenants` (detalle → lista).
/// - Raíces (`/super/tenants`, `/super/logs`) → `/admin` (salida del
///   panel super, volver al admin del tenant System).
String _backTargetFor(String loc) {
  // Más específica primero — el matcher de :tid/miembros debe checkearse
  // antes que el de tenants/:id porque el path es más largo.
  final miembroMatch =
      RegExp(r'^(/super/tenants/[^/]+)/miembros/[^/]+$').firstMatch(loc);
  if (miembroMatch != null) return miembroMatch.group(1)!;
  final tenantMatch = RegExp(r'^/super/tenants/[^/]+$').firstMatch(loc);
  if (tenantMatch != null) return '/super/tenants';
  // Default: raíces de super → salir al panel admin.
  return '/admin';
}
