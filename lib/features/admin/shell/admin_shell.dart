import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/router.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/crud_error_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/providers/inventario_alerta_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/providers/sync_status_provider.dart';
import '../../../data/providers/tickets_alerta_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/repositories/solicitudes_repo.dart';
import '../../../data/services/rechazos_sync_service.dart';
import '../../shared/widgets/app_version_label.dart';
import '../../shared/widgets/impersonation_banner.dart';
import '../../shared/widgets/update_banner.dart';
import '../../auth/cambiar_password_dialog.dart';
import '../../shared/utils/shell_nav.dart';
import '../../../data/providers/form_dirty_provider.dart';
import '../../shared/utils/sign_out_helper.dart';
import '../../shared/widgets/confirm_discard_dialog.dart';
import '../../shared/widgets/offline_banner.dart';
import '../pagos/cobros_a_revisar_screen.dart' show cobrosARevisarCountProvider;

/// Shell del admin/admin_cobranza/admin_usuarios. El menú es una **galería de inicio**
/// (`MenuGaleriaScreen` en `/admin`): tarjetas con ícono de color por sección.
/// Ya NO hay panel lateral (rail/drawer). Cada sección abre con un botón
/// "← Menú" en la barra superior que vuelve a la galería. El grupo
/// "Administración" abre una sub-galería (`/admin/administracion`). El avatar de
/// la barra superior despliega nombre/rol + Cambiar contraseña + Cerrar sesión.
class AdminShell extends ConsumerWidget {
  const AdminShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Escuchar errores de CRUD upload para mostrar SnackBar cuando un
    // write local es rechazado por Postgres (trigger, constraint, RLS).
    ref.listen(crudUploadErrorProvider, (_, next) {
      final error = next.valueOrNull;
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.table == 'clientes' &&
                      error.message.toString().toLowerCase().contains('codigo')
                  ? 'Código de cliente duplicado: otro cliente ya usa ese '
                      'código. Editá el cliente y asignale uno distinto.'
                  : 'Un cambio en ${etiquetaTablaSync(error.table)} fue '
                      'rechazado por el servidor: '
                      '${humanizarRechazoSync(error.codigo, error.message)}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    });

    final location = GoRouterState.of(context).matchedLocation;
    // El título se deriva de la ruta: `ShellTitleScope` NO sirve acá (el
    // AdminShell está POR ENCIMA del `_titled` del hijo → `.of(context)` da
    // null y TODAS las pantallas mostraban "Panel admin", haciendo que el Centro
    // pareciera el home). Fallback al scope y luego al genérico (audit 2026-06-29).
    final titulo =
        _tituloFor(location) ?? ShellTitleScope.of(context) ?? 'Panel admin';
    final impersonating =
        ref.watch(impersonatedTenantIdProvider).valueOrNull != null;
    final back = _backTargetFor(location);

    final Widget bodyContent = OfflineBanner(child: child);
    final Widget bodyWithBanners = Column(
      children: [
        const UpdateBanner(),
        if (impersonating) const ImpersonationBanner(),
        Expanded(child: bodyContent),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        leading: back != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Menú',
                onPressed: () => _onBackPressed(context, ref, back),
              )
            : null,
        title: Text(titulo, overflow: TextOverflow.ellipsis),
        actions: const [
          _SyncIndicator(),
          SizedBox(width: 4),
          _AvatarMenu(),
          SizedBox(width: 8),
        ],
      ),
      body: bodyWithBanners,
    );
  }
}

/// Handler del back de la barra del shell.
///
/// CLAVE (audit live 2026-06-30): el AdminShell NO se reconstruye al PUSHear una
/// ruta hija (form/detalle) → su `matchedLocation` queda en el PADRE, así que NO
/// se puede distinguir un form pusheado por la ruta (el intento con
/// `_hasFormGuard(location)` nunca disparaba porque `location` era el padre → el
/// back perdía los cambios del form SIN preguntar, en TODOS los forms). Y
/// `context.pop()` de go_router es DECLARATIVO: tampoco dispara el `PopScope` del
/// form (verificado en vivo). Por eso el shell hace el guard él mismo:
///
///   - Si hay algo PUSHeado encima (`context.canPop()`) y un form tiene cambios
///     sin guardar (los forms sincronizan `_dirty` a `formDirtyProvider`, mismo
///     patrón que `closeModalsAndGoGuarded` de las cards), preguntar "¿descartar?"
///     y recién ahí `context.pop()` (cierra el form/detalle y vuelve a su padre).
///   - Si no hay nada que popear (sección BASE alcanzada por `go`), navegar con
///     `go` al padre que da [back].
Future<void> _onBackPressed(
    BuildContext context, WidgetRef ref, String back) async {
  if (context.canPop()) {
    if (ref.read(formDirtyProvider)) {
      final descartar = await confirmDiscardChanges(context);
      if (descartar != true || !context.mounted) return;
      ref.read(formDirtyProvider.notifier).state = false;
    }
    if (!context.mounted) return;
    context.pop();
    return;
  }
  if (!context.mounted) return;
  context.closeModalsAndGo(back);
}

/// A dónde vuelve el botón "← Menú" según la ruta actual. `null` = estamos en la
/// galería de inicio (`/admin`) → sin botón. Sub-rutas (detalle/edición) vuelven
/// a su listado; las sub-secciones de Administración vuelven a la sub-galería;
/// el resto vuelve al menú.
String? _backTargetFor(String loc) {
  if (loc == '/admin' || loc == '/admin/') return null;
  // Sub-rutas profundas → su listado padre.
  const subParents = <String, String>{
    '/admin/clientes/': '/admin/clientes',
    '/admin/contratos/': '/admin/contratos',
    '/admin/tickets/': '/admin/tickets',
    // Detalle de incidente (/:id) → la lista de incidentes (navegado con go).
    '/admin/incidentes/': '/admin/incidentes',
    // Catálogo (/catalogo) y ficha de equipo (/equipo/:id) → la vista de inventario.
    '/admin/inventario/': '/admin/inventario',
    // "Campos del historial" vuelve a Configuración, no al home (audit 2026-06-30).
    '/admin/settings/': '/admin/settings',
  };
  for (final e in subParents.entries) {
    if (loc.startsWith(e.key)) return e.value;
  }
  // Sub-secciones del grupo Cobranza → su sub-galería.
  const cobranzaChildren = <String>{
    '/admin/centro-cobranza',
    '/admin/cobros',
    '/admin/avisos',
    '/admin/pagos',
    '/admin/cobros-a-revisar',
  };
  if (cobranzaChildren.contains(loc)) return '/admin/cobranza';
  // Sub-secciones del grupo Administración → la sub-galería.
  const adminChildren = <String>{
    '/admin/cobradores',
    '/admin/planes',
    '/admin/geografia',
    '/admin/red',
    '/admin/etiquetas',
  };
  if (adminChildren.contains(loc)) return '/admin/administracion';
  // Resto de secciones → la galería de inicio.
  return '/admin';
}

/// Título de la pantalla por su ruta. Se deriva de la location (igual que
/// `_backTargetFor`) porque `ShellTitleScope` queda por DEBAJO del shell. Hay
/// que mantenerlo en sync con los `_titled(...)` del router. Las pantallas de
/// detalle (`clientes/:id`, `contratos/:id`) tienen Scaffold/AppBar propio → no
/// se mapean acá. Devuelve null si la ruta no está mapeada (→ fallback genérico).
String? _tituloFor(String loc) {
  const exact = <String, String>{
    '/admin': 'Panel admin',
    '/admin/resumen': 'Resumen',
    '/admin/cobranza': 'Cobranza',
    '/admin/administracion': 'Administración',
    '/admin/cobros': 'Cobros',
    '/admin/avisos': 'Avisos',
    '/admin/centro-cobranza': 'Centro de cobranza',
    '/admin/clientes': 'Clientes',
    '/admin/clientes/nuevo': 'Nuevo cliente',
    '/admin/rutas': 'Rutas',
    '/admin/contratos': 'Contratos',
    '/admin/contratos/nuevo': 'Nuevo contrato',
    '/admin/planes': 'Planes',
    '/admin/cobradores': 'Cobradores',
    '/admin/pagos': 'Pagos',
    '/admin/cobros-a-revisar': 'Cobros a revisar',
    '/admin/mapa': 'Mapa',
    '/admin/reportes': 'Reportes',
    '/admin/geografia': 'Geografía',
    '/admin/red': 'Red',
    '/admin/etiquetas': 'Etiquetas',
    '/admin/inventario': 'Inventario',
    '/admin/inventario/catalogo': 'Catálogo de inventario',
    '/admin/tickets': 'Tickets',
    '/admin/tickets/tipos': 'Tipos de ticket',
    '/admin/tickets/nuevo': 'Nuevo ticket',
    '/admin/incidentes': 'Incidentes',
    '/admin/settings': 'Configuración',
    '/admin/settings/historial-campos': 'Campos del historial',
  };
  final t = exact[loc];
  if (t != null) return t;
  // Sub-rutas parametrizadas que sí usan `_titled`.
  if (loc.startsWith('/admin/clientes/') && loc.endsWith('/editar')) {
    return 'Editar cliente';
  }
  if (loc.startsWith('/admin/inventario/equipo/')) return 'Equipo';
  if (loc.startsWith('/admin/tickets/')) return 'Ticket';
  if (loc.startsWith('/admin/incidentes/')) return 'Incidente';
  return null;
}

class _SyncIndicator extends ConsumerWidget {
  const _SyncIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final scheme = Theme.of(context).colorScheme;
    return status.when(
      loading: () => const SizedBox(
          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, __) => Icon(Icons.error_outline, color: scheme.error),
      data: (s) {
        final connected = s?.connected ?? false;
        final activo = (s?.downloading ?? false) || (s?.uploading ?? false);
        final color = !connected ? scheme.error : (activo ? scheme.tertiary : scheme.primary);
        final icon = !connected ? Icons.cloud_off : (activo ? Icons.cloud_sync : Icons.cloud_done);
        return Tooltip(
          message: !connected ? 'Sin conexión' : (activo ? 'Sincronizando' : 'Sincronizado'),
          child: Icon(icon, color: color),
        );
      },
    );
  }
}

/// Avatar de la barra superior: despliega nombre/rol + Cambiar contraseña +
/// Cerrar sesión + versión. Reemplaza el header que vivía en el panel lateral.
class _AvatarMenu extends ConsumerWidget {
  const _AvatarMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final nombre = cobrador?.nombre ?? '—';
    final rol = cobrador?.rol ?? '—';
    final rechazos = ref.watch(rechazosSyncProvider).valueOrNull ?? const [];
    return PopupMenuButton<String>(
      tooltip: 'Cuenta',
      offset: const Offset(0, 48),
      icon: CircleAvatar(
        radius: 16,
        backgroundColor: scheme.primary,
        child: Text(_initials(nombre),
            style: TextStyle(color: scheme.onPrimary, fontSize: 13)),
      ),
      onSelected: (v) {
        switch (v) {
          case 'perfil':
            // `push` y no `go`: `/perfil` NO vive dentro del ShellRoute admin
            // —tiene Scaffold y AppBar propios— así que la regla #12 del
            // checklist (las rutas DEL shell se navegan con `go`) no aplica.
            // Con push el volver funciona solo.
            context.push('/perfil');
          case 'password':
            context.closeModalsThenRun(
                () => mostrarCambiarPasswordDialog(context));
          case 'logout':
            confirmarSignOut(context);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(nombre,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              Text(_rolDisplay(rol),
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        // Mi perfil FALTABA en el shell admin: existía solo en el del cobrador,
        // así que admin, admin_cobranza, admin_usuarios y lectura no tenían
        // NINGUNA forma de llegar. Ahí vive "Cambios sin sincronizar", el único
        // registro permanente de un write que el server rechazó — el shell solo
        // muestra un aviso de 6 segundos, y si se te pasa, el dato se pierde
        // para siempre. El badge naranja aparece únicamente cuando hay alguno.
        PopupMenuItem<String>(
          value: 'perfil',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: const Text('Mi perfil'),
            trailing: rechazos.isEmpty
                ? null
                : Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade700,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${rechazos.length}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'password',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.lock_outline),
            title: Text('Cambiar contraseña'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'logout',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Cerrar sesión'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          enabled: false,
          child: Center(child: AppVersionLabel()),
        ),
      ],
    );
  }
}

String _initials(String s) {
  final parts = s.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return '—';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

String _rolDisplay(String rol) => switch (rol) {
      'admin' => 'Administrador',
      'admin_cobranza' => 'Admin de cobranza',
      'admin_usuarios' => 'Admin de usuarios',
      'admin_tickets' => 'Admin de tickets',
      'coordinador' => 'Coordinador técnico',
      'cobrador' => 'Cobrador',
      'tecnico' => 'Técnico',
      'super_admin' => 'Dev',
      'lectura' => 'Solo lectura',
      _ => rol,
    };

// ── Menú: galería de inicio ────────────────────────────────────────────────

/// Items del menú del panel admin. Render como GALERÍA (tarjetas con ícono de
/// color). Dos cards son GRUPOS (`children` no vacío → card abre su sub-galería
/// vía [SubGaleriaScreen], como funciona hoy): "Cobranza" (Centro/Cobros/Avisos/
/// Pagos) y "Administración" (Personal/Planes/Geografía/Red/Etiquetas). El color
/// es el del ícono en la card.
const _adminMenu = [
  _MenuItem(Icons.space_dashboard, 'Resumen', '/admin/resumen',
      color: Color(0xFF185FA5)),
  _MenuItem(Icons.groups, 'Clientes', '/admin/clientes',
      color: Color(0xFF0F6E56)),
  _MenuItem(Icons.approval, 'Solicitudes', '/admin/solicitudes',
      color: Color(0xFFB45309), adminOnly: true),
  _MenuItem(Icons.alt_route, 'Rutas', '/admin/rutas', color: Color(0xFF534AB7)),
  // Grupo "Cobranza": card en el home → sub-galería (/admin/cobranza) con Centro,
  // Cobros, Avisos y Pagos. Junta el flujo de cobranza en UN botón (audit UX
  // 2026-06-30): antes eran 4 cards sueltas que se sentían repetidas. cobranza:true
  // → visible para admin y admin_cobranza; el gating de cada hijo se respeta adentro.
  _MenuItem(Icons.payments, 'Cobranza', '/admin/cobranza',
      color: Color(0xFF0F766E), cobranza: true,
      subtitulo: 'centro · cobros · avisos', children: [
    _MenuItem(Icons.checklist, 'Centro de cobranza', '/admin/centro-cobranza',
        color: Color(0xFF0F766E), cobranza: true, subtitulo: 'qué hacer hoy'),
    _MenuItem(Icons.point_of_sale, 'Cobros', '/admin/cobros',
        color: Color(0xFF3B6D11), subtitulo: 'registrá pagos'),
    _MenuItem(Icons.notifications_active, 'Avisos', '/admin/avisos',
        color: Color(0xFFA32D2D), subtitulo: 'avisá a morosos',
        cobranza: true, settingKey: 'cobranza.avisos_habilitado'),
    _MenuItem(Icons.receipt_long, 'Pagos', '/admin/pagos',
        color: Color(0xFF854F0B), adminOnly: true,
        settingKey: 'cobranza.pantalla_pagos', superRespetaSetting: true),
    // Sin `adminOnly`: admin_cobranza TIENE que poder resolver los duplicados
    // (decisión de Rubén 2026-07-31). Sin setting: no es una pantalla opcional,
    // es la única forma de enterarse de que hay plata descuadrada.
    _MenuItem(Icons.rule, 'Cobros a revisar', '/admin/cobros-a-revisar',
        color: Color(0xFFA32D2D), cobranza: true,
        subtitulo: 'cobrados de más'),
  ]),
  _MenuItem(Icons.tune, 'Administración', '/admin/administracion',
      color: Color(0xFF5F5E5A), adminOnly: true,
      subtitulo: 'personal · planes · red', children: [
    _MenuItem(Icons.badge, 'Personal', '/admin/cobradores',
        color: Color(0xFF0F6E56), adminOnly: true),
    _MenuItem(Icons.wifi, 'Planes', '/admin/planes',
        color: Color(0xFF185FA5), adminOnly: true),
    _MenuItem(Icons.location_city, 'Geografía', '/admin/geografia',
        color: Color(0xFF3B6D11), adminOnly: true),
    _MenuItem(Icons.hub, 'Red', '/admin/red',
        color: Color(0xFF534AB7), adminOnly: true),
    _MenuItem(Icons.sell, 'Etiquetas', '/admin/etiquetas',
        color: Color(0xFF993556), adminOnly: true),
  ]),
  _MenuItem(Icons.inventory_2, 'Inventario', '/admin/inventario',
      color: Color(0xFF0F6E56), adminOnly: true, moduloKey: 'inventario'),
  _MenuItem(Icons.support_agent, 'Tickets', '/admin/tickets',
      color: Color(0xFF993556), adminOnly: true, moduloKey: 'tickets'),
  _MenuItem(Icons.cell_tower, 'Incidentes', '/admin/incidentes',
      color: Color(0xFFA32D2D), adminOnly: true, moduloKey: 'tickets'),
  _MenuItem(Icons.insert_chart, 'Reportes', '/admin/reportes',
      color: Color(0xFF993C1D)),
  _MenuItem(Icons.pin_drop, 'Mapa', '/admin/mapa', color: Color(0xFF185FA5)),
  _MenuItem(Icons.settings, 'Configuración', '/admin/settings',
      color: Color(0xFF5F5E5A), adminOnly: true),
  _MenuItem(Icons.shield, 'Tenants', '/super/tenants',
      color: Color(0xFF534AB7), superAdminOnly: true),
];

class _MenuItem {
  const _MenuItem(
    this.icon,
    this.label,
    this.path, {
    this.color = const Color(0xFF5F5E5A),
    this.subtitulo,
    this.adminOnly = false,
    this.cobranza = false,
    this.superAdminOnly = false,
    this.settingKey,
    this.superRespetaSetting = false,
    this.moduloKey,
    this.children = const [],
  });
  final IconData icon;
  final String label;
  final String path;
  // Color del ícono en la card de la galería (tinte del círculo = color con α).
  final Color color;
  /// Subtítulo de 1 línea en la card (opcional). Diferencia cards que de otro
  /// modo suenan parecidas (Cobros / Centro de cobranza / Avisos — audit UX).
  final String? subtitulo;
  final bool adminOnly;
  /// Visible para admin Y admin_cobranza (no solo admin). Para superficies de
  /// cobranza que el rol admin_cobranza debe ver (ej. Avisos).
  final bool cobranza;
  final bool superAdminOnly;
  final String? settingKey;
  final bool superRespetaSetting;
  final String? moduloKey;
  final List<_MenuItem> children;
}

bool _menuVisible(
  _MenuItem m, {
  required bool esSuperAdmin,
  required bool tieneAccesoAdmin,
  bool esAdminCobranza = false,
  bool esAdminUsuarios = false,
  bool esLectura = false,
  bool impersonating = false,
  Set<String> pantallasOn = const {},
  Set<String> modulosOn = const {},
}) {
  // admin_usuarios: allowlist estricta — Clientes, Mapa y Solicitudes.
  if (esAdminUsuarios) {
    const permitido = {'/admin/clientes', '/admin/mapa', '/admin/solicitudes'};
    return permitido.contains(m.path);
  }
  if (m.settingKey != null &&
      (!esSuperAdmin || m.superRespetaSetting) &&
      !pantallasOn.contains(m.settingKey)) {
    return false;
  }
  if (m.moduloKey != null && !modulosOn.contains(m.moduloKey)) {
    return false;
  }
  if (m.superAdminOnly) return esSuperAdmin && !impersonating;
  // `lectura` (0198) ve el panel COMPLETO — es un rol de supervisión, no de
  // trabajo. Pasa los gates de rol (adminOnly/cobranza) pero NO los de setting
  // ni de módulo de arriba: una pantalla que el tenant tiene apagada sigue
  // apagada para él. Lo que no puede hacer es modificar, y eso lo resuelven las
  // pantallas ocultando sus acciones, no el menú.
  if (esLectura) return true;
  if (m.cobranza) return tieneAccesoAdmin || esAdminCobranza;
  if (m.adminOnly) return tieneAccesoAdmin;
  return true;
}

/// Conjunto de settingKeys habilitados por el super_admin para este tenant.
Set<String> _pantallasOn(AppSettings settings) => <String>{
      if (settings.pantallaPagosHabilitada) 'cobranza.pantalla_pagos',
      if (settings.avisosHabilitado) 'cobranza.avisos_habilitado',
    };

/// Conteo de alerta para el badge de la card: Tickets (en riesgo),
/// Inventario (stock bajo), Solicitudes (pendientes), Cobros a revisar
/// (cuotas cobradas de más). 0 = sin badge.
int _alertaDe(String path, int ticketsEnRiesgo, int stockBajo,
    int solicitudesPendientes, int cobrosARevisar) => switch (path) {
      '/admin/tickets' => ticketsEnRiesgo,
      '/admin/inventario' => stockBajo,
      '/admin/solicitudes' => solicitudesPendientes,
      '/admin/cobros-a-revisar' => cobrosARevisar,
      // La card de GRUPO también lo muestra: si el badge viviera solo adentro,
      // desde el inicio no habría forma de saber que hay plata descuadrada sin
      // entrar a Cobranza a mirar.
      '/admin/cobranza' => cobrosARevisar,
      _ => 0,
    };

/// Galería de inicio del admin (reemplaza el panel lateral). Grilla de tarjetas
/// con ícono de color por sección. La card "Administración" abre la sub-galería.
class MenuGaleriaScreen extends ConsumerWidget {
  const MenuGaleriaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;
    final tieneAccesoAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final esAdminCobranza = cobrador?.esAdminCobranza ?? false;
    final esAdminUsuarios = cobrador?.esAdminUsuarios ?? false;
    final esLectura = cobrador?.esLectura ?? false;
    final impersonating =
        ref.watch(impersonatedTenantIdProvider).valueOrNull != null;
    final settings = ref.watch(appSettingsProvider);
    final pantallasOn = _pantallasOn(settings);
    final modulosOn = ref.watch(modulosHabilitadosProvider).valueOrNull ?? {};
    final ticketsEnRiesgo =
        ref.watch(ticketsEnRiesgoCountProvider).valueOrNull ?? 0;
    final stockBajo =
        ref.watch(inventarioStockBajoCountProvider).valueOrNull ?? 0;
    final solicitudesPend =
        ref.watch(solicitudesPendientesCountProvider).valueOrNull ?? 0;
    final cobrosARevisar =
        ref.watch(cobrosARevisarCountProvider).valueOrNull ?? 0;

    final items = _adminMenu
        .where((m) => _menuVisible(m,
            esSuperAdmin: esSuperAdmin,
            tieneAccesoAdmin: tieneAccesoAdmin,
            esAdminCobranza: esAdminCobranza,
            esAdminUsuarios: esAdminUsuarios,
            esLectura: esLectura,
            impersonating: impersonating,
            pantallasOn: pantallasOn,
            modulosOn: modulosOn))
        .toList();

    // Sin teaser "Pendientes de cobranza" en el home: esa info vive COMPLETA en
    // el submenu Cobranza → Centro de cobranza (vencen hoy · gracia · mora ·
    // cortes · créditos), así que en el inicio sobraba (decisión Rubén
    // 2026-06-30). El home = solo la galería de cards.
    return _GaleriaGrid(
      items: items,
      ticketsEnRiesgo: ticketsEnRiesgo,
      stockBajo: stockBajo,
      solicitudesPendientes: solicitudesPend,
      cobrosARevisar: cobrosARevisar,
      // Cada card abre su ruta: la de grupo (Cobranza/Administración) apunta a su
      // sub-galería (m.path == /admin/cobranza|/admin/administracion), las de hoja
      // a su pantalla. `go` (dentro de closeModalsAndGoGuarded), no `push` → el
      // volver del shell funciona (regla #12).
      destino: (m) => m.path,
    );
  }
}

/// Sub-galería de un grupo del menú (Cobranza, Administración). Misma estética de
/// cards; cada una abre su sección. `grupoPath` = el path del grupo en `_adminMenu`
/// (ej. `/admin/cobranza`, `/admin/administracion`) → toma sus `children` y los
/// filtra por gating. Se llega vía `go` desde la card del grupo; el volver del
/// shell devuelve a la ruta que da `_backTargetFor` (regla #12).
class SubGaleriaScreen extends ConsumerWidget {
  const SubGaleriaScreen({super.key, required this.grupoPath});

  final String grupoPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;
    final tieneAccesoAdmin = cobrador?.tieneAccesoAdmin ?? false;
    // Necesario: los hijos de Cobranza (Centro/Avisos) son cobranza:true → sin
    // este flag el admin_cobranza no los vería dentro del grupo.
    final esAdminCobranza = cobrador?.esAdminCobranza ?? false;
    final esAdminUsuarios = cobrador?.esAdminUsuarios ?? false;
    final esLectura = cobrador?.esLectura ?? false;
    final impersonating =
        ref.watch(impersonatedTenantIdProvider).valueOrNull != null;
    final settings = ref.watch(appSettingsProvider);
    final pantallasOn = _pantallasOn(settings);
    final modulosOn = ref.watch(modulosHabilitadosProvider).valueOrNull ?? {};

    final grupo = _adminMenu.firstWhere((m) => m.path == grupoPath,
        orElse: () => const _MenuItem(Icons.tune, '', '/admin'));
    final items = grupo.children
        .where((m) => _menuVisible(m,
            esSuperAdmin: esSuperAdmin,
            tieneAccesoAdmin: tieneAccesoAdmin,
            esAdminCobranza: esAdminCobranza,
            esAdminUsuarios: esAdminUsuarios,
            esLectura: esLectura,
            impersonating: impersonating,
            pantallasOn: pantallasOn,
            modulosOn: modulosOn))
        .toList();

    // "Cobros a revisar" vive DENTRO del grupo Cobranza: sin este badge acá, el
    // contador solo se vería en el home y habría que entrar al grupo a ciegas.
    return _GaleriaGrid(
      items: items,
      ticketsEnRiesgo: 0,
      stockBajo: 0,
      cobrosARevisar: ref.watch(cobrosARevisarCountProvider).valueOrNull ?? 0,
      destino: (m) => m.path,
    );
  }
}

/// Grilla responsive de cards de la galería. `destino` resuelve la ruta de cada
/// item (la card de grupo va a la sub-galería).
class _GaleriaGrid extends ConsumerWidget {
  const _GaleriaGrid({
    required this.items,
    required this.ticketsEnRiesgo,
    required this.stockBajo,
    this.solicitudesPendientes = 0,
    this.cobrosARevisar = 0,
    required this.destino,
  });
  final List<_MenuItem> items;
  final int ticketsEnRiesgo;
  final int stockBajo;
  final int solicitudesPendientes;
  final int cobrosARevisar;
  final String Function(_MenuItem) destino;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        // 148 (no 132): da aire para el subtítulo de las cards de cobranza con
        // fuente de sistema grande (hasta ~1.5×) sin desbordar (audit QA 2026-06-30).
        mainAxisExtent: 148,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final m = items[i];
        return _GaleriaCard(
          item: m,
          alerta: _alertaDe(m.path, ticketsEnRiesgo, stockBajo,
              solicitudesPendientes, cobrosARevisar),
          onTap: () => context.closeModalsAndGoGuarded(ref, destino(m)),
        );
      },
    );
  }
}

class _GaleriaCard extends StatelessWidget {
  const _GaleriaCard({
    required this.item,
    required this.alerta,
    required this.onTap,
  });
  final _MenuItem item;
  final int alerta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ico = Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: item.color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(item.icon, color: item.color, size: 30),
    );
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant, width: 0.6),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              alerta > 0
                  ? Badge(label: Text('$alerta'), child: ico)
                  : ico,
              SizedBox(height: item.subtitulo == null ? 12 : 6),
              Text(
                item.label,
                textAlign: TextAlign.center,
                maxLines: item.subtitulo == null ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
              if (item.subtitulo != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    item.subtitulo!,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
