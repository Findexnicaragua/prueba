import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/admin/avisos/avisos_screen.dart';
import '../features/admin/avisos/centro_cobranza_screen.dart';
import '../features/admin/clientes/cliente_form_screen.dart';
import '../features/admin/clientes/clientes_admin_screen.dart';
import '../features/admin/cobradores/cobradores_admin_screen.dart';
import '../features/admin/rutas/rutas_screen.dart';
import '../features/admin/contratos/contratos_admin_screen.dart';
import '../features/contratos/contrato_detail_screen.dart';
import '../features/admin/dashboard/dashboard_admin_screen.dart';
import '../features/admin/dashboard/dashboard_cartera_screen.dart';
import '../features/admin/reportes/reporte_desembolsos_screen.dart';
import '../features/admin/reportes/reporte_indicadores_screen.dart';
import '../features/admin/reportes/reporte_resumen_mensual_screen.dart';
import '../features/admin/operaciones/cierre_dia_screen.dart';
import '../features/admin/geografia/geografia_admin_screen.dart';
import '../features/admin/incidentes/incidente_detail_screen.dart';
import '../features/admin/incidentes/incidentes_screen.dart';
import '../features/admin/inventario/inventario_v2_screen.dart';
import '../features/admin/inventario/ficha_equipo_screen.dart';
import '../features/admin/inventario/inventario_catalogo_screen.dart';
import '../features/admin/red/red_admin_screen.dart';
import '../features/admin/pagos/cobros_a_revisar_screen.dart';
import '../features/admin/pagos/pagos_admin_screen.dart';
import '../features/admin/planes/planes_admin_screen.dart';
import '../features/admin/reportes/reportes_admin_screen.dart';
import '../features/admin/settings/op_log_campos_screen.dart';
import '../features/admin/solicitudes/solicitudes_screen.dart';
import '../features/admin/tickets/admin_tickets_shell.dart';
import '../features/admin/tickets/ticket_detail_screen.dart';
import '../features/admin/tickets/ticket_form_screen.dart';
import '../features/admin/tickets/ticket_tipos_screen.dart';
import '../features/admin/etiquetas/etiquetas_admin_screen.dart';
import '../features/admin/tickets/tickets_list_screen.dart';
import '../features/admin/settings/settings_admin_screen.dart';
import '../features/admin/shell/admin_shell.dart';
import '../data/providers/cobrador_provider.dart';
import '../data/providers/db_epoch_provider.dart';
import '../data/providers/impersonation_provider.dart';
import '../data/providers/modulos_provider.dart';
import '../data/providers/sync_ready_provider.dart';
import '../data/providers/sync_status_provider.dart';
import '../data/providers/mora_count_provider.dart';
import '../data/repositories/settings_repo.dart';
import '../features/auth/auth_flow_provider.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/set_password_screen.dart';
import '../features/shared/widgets/sync_gate_screen.dart';
import '../features/super_admin/miembro_detalle_screen.dart';
import '../features/super_admin/super_shell.dart';
import '../features/super_admin/tenant_modulos_screen.dart';
import '../features/super_admin/tenants_list_screen.dart';
import '../features/clientes/cliente_detail_screen.dart';
import '../features/cobro/cobro_screen.dart';
import '../features/cuotas/cuotas_list_screen.dart';
import '../features/historial/historial_screen.dart';
import '../features/historial/mis_cobros_screen.dart';
import '../features/impresora/impresora_setup_screen.dart';
import '../features/mapa/mapa_screen.dart';
import '../features/recibo/recibo_screen.dart';
import '../features/settings/perfil_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/tecnico/mis_tickets_screen.dart';
import '../features/tecnico/tecnico_shell.dart';
import '../powersync/db.dart' as ps;

/// Stream del rol del usuario actual desde la tabla cobradores local.
/// Una sola suscripción global que el router lee en cada redirect.
/// Si aún no hay valor sincronizado, asumimos cobrador (conservador).
final _rolUsuarioProvider = StreamProvider<String?>((ref) async* {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) {
    yield null;
    return;
  }
  yield* ps.db
      .watch('SELECT rol FROM cobradores WHERE id = ?', parameters: [user.id])
      .map((rows) => rows.isEmpty ? null : rows.first['rol'] as String?);
});

/// Stream de `empresa.nombre`. Lo consume el reporte (nombre del ISP en los
/// PDF/CSV). Antes también gateaba el wizard de onboarding, que se quitó en
/// v0.6.4 — ahora el admin configura la empresa desde Ajustes. Se mantiene
/// "vivo" con un `ref.listen` en el router para que el nombre esté listo
/// cuando el reporte lo lee.
final empresaNombreProvider = StreamProvider<String?>((ref) async* {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  // Filtra al tenant efectivo para no leer la empresa del tenant System cuando
  // el super_admin impersona (M4) — si no, el header/reportes caían a "ISP".
  final tenantId = ref.watch(tenantIdProvider);
  final where = tenantId != null
      ? "WHERE clave = 'empresa.nombre' AND tenant_id = ?"
      : "WHERE clave = 'empresa.nombre'";
  final params = tenantId != null ? <Object?>[tenantId] : <Object?>[];
  yield* ps.db
      .watch('SELECT valor FROM settings $where', parameters: params)
      .map((rows) {
    if (rows.isEmpty) return null;
    final v = rows.first['valor'] as String?;
    if (v == null) return null;
    // Settings.valor es JSON serializado: "X" o null.
    final s = v.trim();
    if (s == 'null' || s == '""' || s.isEmpty) return null;
    return s;
  });
});

/// Mensaje a mostrar en la pantalla de login cuando el gate de acceso cerró la
/// sesión (cuenta o tenant desactivados). El login lo lee y lo limpia. Global
/// simple: el gate corre fuera del árbol de widgets (listener de auth).
final ValueNotifier<String?> mensajeGateAcceso = ValueNotifier<String?>(null);

/// Gate de revocación de acceso (fix F0, titular del audit). Al iniciar o
/// restaurar sesión, pregunta al server (RPC `verificar_acceso`) si el cobrador
/// y su tenant siguen activos. Si alguno está inactivo, cierra sesión. El
/// super_admin queda exento server-side. **FAIL-OPEN**: ante error de red o
/// respuesta ausente NO cierra sesión — un hipo de conexión no debe echar a un
/// usuario legítimo (el corte real lo respalda igual el sync-rules: sin `activo`
/// no baja datos).
Future<void> _gateAccesoRevocado(GoTrueClient auth) async {
  try {
    final res = await Supabase.instance.client.rpc('verificar_acceso');
    if (res is List && res.isNotEmpty && res.first is Map) {
      final row = res.first as Map;
      final activo =
          row['cobrador_activo'] == true && row['tenant_activo'] == true;
      if (!activo) {
        mensajeGateAcceso.value =
            'Tu acceso fue desactivado. Contactá al administrador.';
        await auth.signOut();
      }
    }
  } catch (_) {
    // fail-open: no bloquear por error de red / RPC.
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;
  final refresh = _AuthRefresh(auth);
  ref.onDispose(refresh.dispose);

  // El routerProvider se evalúa en el arranque, *antes* de que Supabase
  // restaure la sesión persistida. En ese momento auth.currentUser es null,
  // así que _rolUsuarioProvider hace `yield null; return;` y queda muerto
  // en AsyncData(null) — el redirect siempre vería rol=null y bloquearía
  // /super/*. Invalidamos los providers en cada cambio de auth para que
  // Riverpod los recree con el user.id correcto.
  //
  // También invalidamos cobradorActualProvider: sin esto, cuando user A
  // hace logout y user B login en el mismo browser, el AdminShell sigue
  // mostrando los datos de A (nombre, rol, menú filtrado) hasta que algo
  // dispare una recarga manual.
  final authSub = auth.onAuthStateChange.listen((data) {
    ref.invalidate(_rolUsuarioProvider);
    ref.invalidate(empresaNombreProvider);
    ref.invalidate(cobradorActualProvider);
    ref.invalidate(impersonatedTenantIdProvider);
    ref.invalidate(syncStatusProvider);
    ref.invalidate(moraCountProvider);
    // Al cerrar sesión, descartar cualquier impersonación optimista pendiente
    // para que el próximo login no herede un estado de impersonación stale.
    if (data.event == AuthChangeEvent.signedOut) {
      ref.read(pendingImpersonacionProvider.notifier).state = null;
    }
    // Gate de revocación de acceso (fix F0): sesión establecida → verificar
    // server-side que el cobrador y su tenant sigan activos; si no, cerrar
    // sesión. FAIL-OPEN ante error de red (ver _gateAccesoRevocado).
    if (data.session != null &&
        (data.event == AuthChangeEvent.signedIn ||
            data.event == AuthChangeEvent.initialSession ||
            data.event == AuthChangeEvent.tokenRefreshed)) {
      _gateAccesoRevocado(auth);
    }
  });
  ref.onDispose(authSub.cancel);

  // Mantiene viva la suscripción al rol y dispara refresh del router cuando
  // cambia (típicamente al primer sync). Sin esto, redirect llamaría
  // valueOrNull antes de que el stream tenga data y nadie se enteraría.
  ref.listen(_rolUsuarioProvider, (_, __) => refresh.poke());
  // Mantiene vivo `empresaNombreProvider` (lo lee el reporte) y reevalúa el
  // router cuando cambia.
  ref.listen(empresaNombreProvider, (_, __) => refresh.poke());
  // Cuando el super_admin cambia un toggle de tenant (ej. visibilidad de
  // Auditoría), reevaluamos el redirect para echar al admin de una ruta que
  // dejó de tener habilitada.
  ref.listen(appSettingsProvider, (_, __) => refresh.poke());
  // Y para que SetPasswordScreen pueda limpiar el flow y desencadenar
  // una re-evaluación del redirect (sino quedaría atrapado en
  // /set-password después de actualizar la contraseña).
  ref.listen(initialAuthFlowProvider, (_, __) => refresh.poke());
  // Sync gate (R7): cuando PowerSync confirma sync post-cambio de
  // identidad, syncReady flippa a true y queremos que el redirect
  // saque al user de /sync-gate hacia su pantalla por rol.
  ref.listen(syncReadyProvider, (_, __) => refresh.poke());
  // Grace timeout del sync gate (8s): cuando vence, el redirect debe
  // re-evaluarse para liberar el gate aunque PowerSync no haya confirmado.
  ref.listen(syncGateGraceProvider, (_, __) => refresh.poke());
  // Impersonación: cuando el super_admin entra o sale de un tenant,
  // re-evaluamos el redirect para moverlo entre /super/* y /admin/*.
  ref.listen(impersonatedTenantIdProvider, (_, next) {
    refresh.poke();
    // Cuando la fila local SINCRONIZADA alcanza el estado optimista pendiente
    // (entró: local == tenant destino · salió: local == null), limpiamos el
    // pending para volver a la fuente de verdad (la fila local).
    final pending = ref.read(pendingImpersonacionProvider);
    if (pending == null) return;
    final local = next.valueOrNull;
    final alcanzado =
        pending.saliendo ? local == null : local == pending.tenantId;
    if (alcanzado) {
      ref.read(pendingImpersonacionProvider.notifier).state = null;
    }
  });
  // El estado optimista de impersonación (entrar/salir) también reevalúa el
  // redirect: da el landing correcto YA, sin esperar el sync de la fila.
  ref.listen(pendingImpersonacionProvider, (_, __) => refresh.poke());

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final loggedIn = auth.currentSession != null;
      final goingToLogin = state.matchedLocation == '/login';
      if (!loggedIn) return goingToLogin ? null : '/login';
      if (goingToLogin) return '/';

      // Si la app arrancó desde un link de recovery / invite, el user
      // ya está logueado (Supabase auto-procesó el token) pero todavía
      // no setó su contraseña. Lo desviamos a /set-password antes de
      // dejarlo entrar al resto de la app. Funciona también para
      // invite (primera vez tras aceptar).
      final authFlow = ref.read(initialAuthFlowProvider);
      final yaEstaEnSetPassword =
          state.matchedLocation == '/set-password';
      if ((authFlow == 'recovery' || authFlow == 'invite') &&
          !yaEstaEnSetPassword) {
        return '/set-password';
      }
      // Si el flow ya no aplica (user terminó de setear o no había
      // flow) pero está en /set-password, lo sacamos.
      if (yaEstaEnSetPassword && authFlow != 'recovery' &&
          authFlow != 'invite') {
        return '/';
      }

      // Sync gate (R7) + role-resolution gate: esperamos en /sync-gate si
      //   (a) la identidad cambió (signOut + signIn, o user switch) y
      //       PowerSync todavía no confirmó un sync posterior al cambio, O
      //   (b) el usuario está autenticado pero el rol AÚN no resolvió a un
      //       valor concreto desde el SQLite local — sea porque el stream
      //       todavía no emitió (`AsyncLoading`, primer build / post-
      //       invalidate del `_rolUsuarioProvider`) o porque emitió pero la
      //       row de `cobradores` aún no se materializó (`AsyncData(null)`).
      //
      // El gate por rol cierra la ventana del flash de redirect: aunque
      // `syncReady` ya sea true (PowerSync confirmó el checkpoint), el
      // stream del rol puede no haber emitido todavía en este frame, o
      // haber emitido `null` porque ese checkpoint trajo otras tablas
      // (settings, etc.) antes que la row de `cobradores` del user. En
      // ambos casos `rol` da null más abajo y la lógica de landing cae en
      // el shell del cobrador (`/`) por ~1-2s antes de corregir cuando
      // llega el rol → flash visible en super_admin y admin. Gateando
      // mientras `rol == null` lo eliminamos por completo.
      //
      // Por qué NO se cuelga si el rol nunca materializa (desync real, la
      // row de `cobradores` genuinamente no está): el gate vive en
      // /sync-gate, y `SyncGateScreen` ofrece escape hatches propios —
      // "Reintentar conexión" a los 120s y "Volver al login" a los 180s.
      // El user nunca queda atascado en silencio. Y dejarlo entrar al
      // shell del cobrador sin rol era el peor resultado igual (vería data
      // vacía/rota porque las sync rules dependen del rol), así que el gate
      // es estrictamente mejor que el viejo fallback conservador.
      //
      // Va DESPUÉS del set-password gate porque ese flow no toca la
      // identidad de PowerSync — el user que setea contraseña ya es el
      // dueño del cache.
      final syncReady = ref.read(syncReadyProvider);
      final grace = ref.read(syncGateGraceProvider);
      final rol = ref.read(_rolUsuarioProvider).valueOrNull;
      final rolNoResuelto = rol == null;
      // Grace (8s) bypasea SOLO el sync pendiente, NUNCA el rol no resuelto.
      // Sin rol, la app no sabe qué interfaz mostrar → espera al sync que
      // traiga la fila de `cobradores`. Con rol local (logins subsiguientes),
      // grace libera inmediato y el delta sync corre en background.
      final mustWait = rolNoResuelto || (!syncReady && !grace);
      final goingToGate = state.matchedLocation == '/sync-gate';
      // Mientras haya que esperar, mantenemos al user en /sync-gate
      // (devolvemos null si ya está ahí → NO loop). Cuando termina la
      // espera, lo sacamos del gate hacia su landing `/` (que la lógica de
      // rol de abajo resuelve a /super/tenants · /admin · /).
      if (mustWait) return goingToGate ? null : '/sync-gate';
      if (goingToGate) return '/';

      // A partir de acá el gate garantiza `rol != null` (pasó porque
      // `rolNoResuelto == false`). Reusamos la `rol` ya leída arriba.
      final loc = state.matchedLocation;
      // EFECTIVO (optimista): al entrar/salir de un tenant, la fila local llega
      // por sync con lag. Usar el efectivo elimina el flash de /super/tenants
      // al entrar y el rebote a /admin al salir (audit 2026-07-04).
      final impersonating =
          ref.read(impersonatedTenantEfectivoProvider) != null;

      // Landing por rol desde la raíz `/`. Sólo en la raíz exacta —
      // los usuarios admin/super pueden querer ver pantallas del cobrador
      // navegando, así que sub-rutas como `/clientes/:id` no se tocan.
      //
      // super_admin impersonando → `/admin` (opera como admin del tenant).
      // super_admin normal → `/super/tenants` (panel SaaS).
      // admin / admin_cobranza → `/admin` (panel del tenant).
      // Landing de `/` + guards de shell por rol (tecnico / admin_tickets /
      // cobrador). Extraído a `redirectInicialPorRol` (PURO, sin `ref`) para
      // testearlo unitariamente — ver test/config/router_redirect_test.dart.
      final rRol = redirectInicialPorRol(
          rol: rol, loc: loc, impersonating: impersonating);
      if (rRol != null) return rRol;

      // Avisos: admin/admin_cobranza acceden a /admin/avisos solo si el
      // super_admin habilitó el toggle por tenant (cobranza.avisos_habilitado,
      // 0134). El super_admin la ve siempre (rol != admin/admin_cobranza).
      if ((rol == 'admin' || rol == 'admin_cobranza' || rol == 'lectura') &&
          (loc == '/admin/avisos' || loc.startsWith('/admin/avisos/'))) {
        final avisosOn = ref.read(appSettingsProvider).avisosHabilitado;
        if (!avisosOn) return '/admin';
      }

      // Pantalla opcional Pagos: el admin sólo accede si el super_admin habilitó
      // el toggle por tenant (B3 del audit). El super_admin (rol != 'admin') la
      // ve siempre; admin_cobranza ya cae en `soloAdmin`.
      // `lectura` incluido: sin él entraba por URL a /admin/pagos y /admin/avisos
      // aunque el tenant los tuviera apagados (el menú sí los ocultaba).
      if (rol == 'admin' || rol == 'lectura') {
        final s = ref.read(appSettingsProvider);
        if ((loc == '/admin/pagos' || loc.startsWith('/admin/pagos/')) &&
            !s.pantallaPagosHabilitada) {
          return '/admin';
        }
      }

      // Guard por rol en rutas admin-only: admin_cobranza no accede a
      // Cobradores / Planes / Geografía / Settings ni a las pantallas
      // opcionales Pagos / Notificaciones (alineado con el menú del shell,
      // que las marca adminOnly).
      const soloAdmin = [
        '/admin/cobradores',
        '/admin/geografia',
        '/admin/red',
        '/admin/etiquetas',
        '/admin/inventario',
        '/admin/tickets',
        '/admin/incidentes',
        '/admin/settings',
        '/admin/planes',
        '/admin/pagos',
        '/admin/solicitudes',
      ];
      if (rol == 'admin_cobranza' &&
          soloAdmin.any((p) => loc == p || loc.startsWith('$p/'))) {
        return '/admin';
      }

      // Guard admin_usuarios: allowlist estricta — solo Clientes y Mapa del
      // panel admin. Bloquea también /cobro y /recibo (rutas top-level de dinero).
      if (rol == 'admin_usuarios') {
        if (loc.startsWith('/cobro') || loc.startsWith('/recibo')) {
          return '/admin';
        }
        const permitido = ['/admin/clientes', '/admin/mapa', '/admin/solicitudes', '/admin/contratos'];
        final enAdmin = loc.startsWith('/admin');
        final esHome = loc == '/admin' || loc == '/admin/';
        if (enAdmin &&
            !esHome &&
            !permitido.any((p) => loc == p || loc.startsWith('$p/'))) {
          return '/admin';
        }
      }

      // Módulo opcional Inventario: si el tenant (o el impersonado) no lo tiene
      // habilitado, no se entra por URL directa (el menú ya lo oculta). Si el
      // provider aún no resolvió (null), dejamos pasar para no rebotar en carga.
      if (loc == '/admin/inventario' ||
          loc.startsWith('/admin/inventario/')) {
        final modulos = ref.read(modulosHabilitadosProvider).valueOrNull;
        if (modulos != null && !modulos.contains('inventario')) return '/admin';
      }

      // Módulo opcional Tickets (Fase 3): mismo gate que inventario. Cubre
      // tickets y los incidentes/outages (3D), ambos del módulo 'tickets'.
      if (loc == '/admin/tickets' || loc.startsWith('/admin/tickets/') ||
          loc == '/admin/incidentes' || loc.startsWith('/admin/incidentes/')) {
        final modulos = ref.read(modulosHabilitadosProvider).valueOrNull;
        if (modulos != null && !modulos.contains('tickets')) return '/admin';
      }

      // Panel /super/* sólo para super_admin. Cualquier otro rol que
      // intente entrar (por URL directa) se va al panel admin del tenant.
      if (loc.startsWith('/super') && rol != 'super_admin') {
        return '/admin';
      }

      // super_admin impersonando que intenta acceder a /super/*:
      // primero debe salir de la impersonación. Lo redirigimos a /admin
      // donde verá el banner de impersonación con "Salir".
      if (loc.startsWith('/super') && impersonating) {
        return '/admin';
      }

      // super_admin que dejó de impersonar pero quedó en /admin/*:
      // redirigir a /super/tenants (su panel real). Sin esto, el
      // super_admin queda viendo el AdminShell vacío post-exit.
      if (rol == 'super_admin' && !impersonating && loc.startsWith('/admin')) {
        return '/super/tenants';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/set-password',
        builder: (_, __) => const SetPasswordScreen(),
      ),
      GoRoute(
        path: '/sync-gate',
        builder: (_, __) => const SyncGateScreen(),
      ),

      // ── Cobrador: ShellRoute con bottom-nav (Cobros · Clientes · Mapa ·
      //    Mis cobros). '/' es la landing = pantalla de Cobros (cuotas por
      //    cliente + franja de KPIs). Perfil se accede desde el engranaje
      //    del AppBar (push, no tab). ──────────────────────────────────────
      ShellRoute(
        builder: (_, __, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/',          pageBuilder: (_, s) => _fadePage(s, _titled('Cobros', const CuotasListScreen(adminMode: true)))),
          GoRoute(path: '/clientes',  pageBuilder: (_, s) => _fadePage(s, _titled('Clientes', const ClientesAdminScreen(soloLectura: true)))),
          GoRoute(path: '/mapa',      pageBuilder: (_, s) => _fadePage(s, _titled('Mapa', const MapaScreen()))),
          GoRoute(path: '/mis-cobros', pageBuilder: (_, s) => _fadePage(s, _titled('Mis cobros', const MisCobrosScreen()))),
        ],
      ),

      // ── Técnico (Fase 3B): ShellRoute móvil-first con bottom-nav ───────
      //    (Mis tickets · Mapa · Perfil). El detalle del ticket se pushea
      //    fuera del shell (`/tecnico/tickets/:id`) con su propio back.
      ShellRoute(
        builder: (_, __, child) => TecnicoShell(child: child),
        routes: [
          GoRoute(path: '/tecnico',
              pageBuilder: (_, s) => _fadePage(s, _titled('Mis tickets', const MisTicketsScreen()))),
          GoRoute(path: '/tecnico/mapa',
              pageBuilder: (_, s) => _fadePage(s, _titled('Mapa', const MapaScreen()))),
          GoRoute(path: '/tecnico/perfil',
              pageBuilder: (_, s) => _fadePage(s, _titled('Mi perfil', const PerfilScreen(tecnicoMode: true)))),
        ],
      ),

      // ── Admin de tickets (admin_tickets): ShellRoute móvil-first ───────
      //    (Tickets · Mapa · Perfil). Detalle/form/tipos se pushean fuera del
      //    shell (abajo) con su propio back. Ve todos los tickets, sin dinero.
      ShellRoute(
        builder: (_, __, child) => AdminTicketsShell(child: child),
        routes: [
          GoRoute(path: '/admin-tickets',
              pageBuilder: (_, s) => _fadePage(s, _titled('Tickets', const TicketsListScreen()))),
          GoRoute(path: '/admin-tickets/mapa',
              pageBuilder: (_, s) => _fadePage(s, _titled('Mapa', const MapaScreen()))),
          GoRoute(path: '/admin-tickets/perfil',
              pageBuilder: (_, s) => _fadePage(s, _titled('Mi perfil', const PerfilScreen(tecnicoMode: true)))),
        ],
      ),

      // Detalle/form/tipos del ticket para admin_tickets (push fuera del shell,
      // Scaffold propio con back). Específicas ANTES que :id.
      GoRoute(
        path: '/admin-tickets/tickets/nuevo',
        builder: (_, __) => Scaffold(
          appBar: AppBar(title: const Text('Nuevo ticket')),
          body: const TicketFormScreen(),
        ),
      ),
      GoRoute(
        path: '/admin-tickets/tickets/tipos',
        builder: (_, __) => Scaffold(
          appBar: AppBar(title: const Text('Tipos de ticket')),
          body: const TicketTiposScreen(),
        ),
      ),
      GoRoute(
        path: '/admin-tickets/tickets/:id',
        builder: (_, s) => Scaffold(
          appBar: AppBar(title: const Text('Ticket')),
          body: TicketDetailScreen(ticketId: s.pathParameters['id']!),
        ),
      ),

      // ── Admin: ShellRoute con sidebar responsive ───────────────────────
      ShellRoute(
        builder: (_, __, child) => AdminShell(child: child),
        routes: [
          GoRoute(path: '/admin',
              pageBuilder: (_, s) => _fadePage(s, _titled('Panel admin', const MenuGaleriaScreen()))),
                    GoRoute(path: '/admin/cartera',
              pageBuilder: (_, s) => _fadePage(s, _titled('Cartera & Liquidez', const DashboardCarteraScreen()))),
          GoRoute(path: '/admin/desembolsos',
              pageBuilder: (_, s) => _fadePage(s, _titled('Desembolsos', const ReporteDesembolsosScreen()))),
          GoRoute(path: '/admin/indicadores',
              pageBuilder: (_, s) => _fadePage(s, _titled('Indicadores', const ReporteIndicadoresScreen()))),
          GoRoute(path: '/admin/resumen-mensual',
              pageBuilder: (_, s) => _fadePage(s, _titled('Resumen Mensual', const ReporteResumenMensualScreen()))),
          GoRoute(path: '/admin/cierre-dia',
              pageBuilder: (_, s) => _fadePage(s, _titled('Cierre de Día', const CierreDiaScreen()))),
          GoRoute(path: '/admin/resumen',
              pageBuilder: (_, s) => _fadePage(s, _titled('Resumen', const DashboardPinGate()))),
          GoRoute(path: '/admin/cobranza',
              pageBuilder: (_, s) => _fadePage(s, _titled('Cobranza',
                  const SubGaleriaScreen(grupoPath: '/admin/cobranza')))),
          GoRoute(path: '/admin/administracion',
              pageBuilder: (_, s) => _fadePage(s, _titled('Administración',
                  const SubGaleriaScreen(grupoPath: '/admin/administracion')))),
          GoRoute(path: '/admin/cobros',
              pageBuilder: (_, s) => _fadePage(s,
                  _titled('Cobros', const CuotasListScreen(adminMode: true)))),
          GoRoute(path: '/admin/avisos',
              pageBuilder: (_, s) =>
                  _fadePage(s, _titled('Avisos', const AvisosScreen()))),
          GoRoute(path: '/admin/centro-cobranza',
              pageBuilder: (_, s) => _fadePage(s, _titled(
                  'Centro de cobranza', const CentroCobranzaScreen()))),
          GoRoute(path: '/admin/clientes',
              pageBuilder: (_, s) => _fadePage(s, _titled('Clientes', const ClientesAdminScreen()))),
          GoRoute(path: '/admin/clientes/nuevo',
              pageBuilder: (_, s) => _fadePage(s, _titled('Nuevo cliente', const ClienteFormScreen()))),
          GoRoute(path: '/admin/clientes/:id/editar',
              pageBuilder: (_, s) => _fadePage(s, _titled('Editar cliente',
                  ClienteFormScreen(clienteId: s.pathParameters['id'])))),
          GoRoute(path: '/admin/clientes/:id',
              pageBuilder: (_, s) => _fadePage(s, ClienteDetailScreen(
                  clienteId: s.pathParameters['id']!))),
          GoRoute(path: '/admin/rutas',
              pageBuilder: (_, s) => _fadePage(s, _titled('Rutas', const RutasScreen()))),
          GoRoute(path: '/admin/contratos',
              pageBuilder: (_, s) => _fadePage(s, _titled('Contratos', const ContratosAdminScreen()))),
          GoRoute(path: '/admin/contratos/nuevo',
              pageBuilder: (_, s) => _fadePage(s, _titled('Nuevo contrato',
                  ContratoFormScreen(clienteId: s.uri.queryParameters['cliente_id'])))),
          GoRoute(path: '/admin/contratos/:id',
              pageBuilder: (_, s) => _fadePage(s, ContratoDetailScreen(
                  contratoId: s.pathParameters['id']!))),
          GoRoute(path: '/admin/planes',
              pageBuilder: (_, s) => _fadePage(s, _titled('Planes', const PlanesAdminScreen()))),
          GoRoute(path: '/admin/cobradores',
              pageBuilder: (_, s) => _fadePage(s, _titled('Cobradores', const CobradoresAdminScreen()))),
          // /admin/cuotas RETIRADA (decisión Rubén 2026-06-11): anular cuota
          // era terminal-peligroso y las cuotas manuales no se usan. Las
          // cuotas se gestionan desde el detalle del contrato.
          GoRoute(path: '/admin/pagos',
              pageBuilder: (_, s) => _fadePage(s, _titled('Pagos', const PagosAdminScreen()))),
          // Cobros a revisar: NO va en `soloAdmin` — admin_cobranza tiene que
          // poder resolver los duplicados (decisión de Rubén 2026-07-31).
          GoRoute(path: '/admin/cobros-a-revisar',
              pageBuilder: (_, s) => _fadePage(
                  s, _titled('Cobros a revisar', const CobrosARevisarScreen()))),
          GoRoute(path: '/admin/solicitudes',
              pageBuilder: (_, s) => _fadePage(s, _titled('Solicitudes', const SolicitudesScreen()))),
          GoRoute(path: '/admin/mapa',
              pageBuilder: (_, s) => _fadePage(s, _titled('Mapa', const MapaScreen()))),
          GoRoute(path: '/admin/reportes',
              pageBuilder: (_, s) => _fadePage(s, _titled('Reportes', const ReportesAdminScreen()))),
          GoRoute(path: '/admin/geografia',
              pageBuilder: (_, s) => _fadePage(s, _titled('Geografía', const GeografiaAdminScreen()))),
          GoRoute(path: '/admin/red',
              pageBuilder: (_, s) => _fadePage(s, _titled('Red', const RedAdminScreen()))),
          GoRoute(path: '/admin/etiquetas',
              pageBuilder: (_, s) => _fadePage(s, _titled('Etiquetas', const EtiquetasAdminScreen()))),
          GoRoute(path: '/admin/inventario',
              pageBuilder: (_, s) => _fadePage(s, _titled('Inventario', const InventarioV2Screen()))),
          // Catálogo de inventario (config: productos/categorías/ubicaciones/
          // proveedores). Sub-ruta de /admin/inventario → ya gateada por el módulo.
          GoRoute(path: '/admin/inventario/catalogo',
              pageBuilder: (_, s) => _fadePage(s, _titled('Catálogo de inventario', const InventarioCatalogoScreen()))),
          // Ficha de detalle de un serial (sub-ruta; hereda el AdminShell).
          GoRoute(path: '/admin/inventario/equipo/:id',
              pageBuilder: (_, s) => _fadePage(s, _titled('Equipo',
                  FichaEquipoScreen(serialId: s.pathParameters['id']!)))),
          // Tickets (módulo opcional, Fase 3). Específicas antes que /:id.
          GoRoute(path: '/admin/tickets',
              pageBuilder: (_, s) => _fadePage(s, _titled('Tickets', const TicketsListScreen()))),
          GoRoute(path: '/admin/tickets/tipos',
              pageBuilder: (_, s) => _fadePage(s, _titled('Tipos de ticket', const TicketTiposScreen()))),
          GoRoute(path: '/admin/tickets/nuevo',
              pageBuilder: (_, s) => _fadePage(s, _titled('Nuevo ticket',
                  TicketFormScreen(
                      clienteIdInicial: s.uri.queryParameters['cliente'])))),
          GoRoute(path: '/admin/tickets/:id',
              pageBuilder: (_, s) => _fadePage(s, _titled('Ticket',
                  TicketDetailScreen(ticketId: s.pathParameters['id']!)))),
          // Incidentes (outages, Fase 3D). Específicas antes que /:id.
          GoRoute(path: '/admin/incidentes',
              pageBuilder: (_, s) => _fadePage(s, _titled('Incidentes', const IncidentesScreen()))),
          GoRoute(path: '/admin/incidentes/:id',
              pageBuilder: (_, s) => _fadePage(s, _titled('Incidente',
                  IncidenteDetailScreen(incidenteId: s.pathParameters['id']!)))),
          GoRoute(path: '/admin/settings',
              pageBuilder: (_, s) => _fadePage(s, _titled('Configuración', const SettingsAdminScreen()))),
          GoRoute(path: '/admin/settings/historial-campos',
              pageBuilder: (_, s) => _fadePage(s, _titled(
                  'Campos del historial', const OpLogCamposScreen()))),
        ],
      ),

      // ── Super Admin: ShellRoute propio (sólo super_admin lo alcanza) ───
      ShellRoute(
        builder: (_, state, child) {
          final loc = state.matchedLocation;
          final titulo = loc.contains('/miembros/')
              ? 'Detalle del miembro'
              : (loc.startsWith('/super/tenants/') &&
                      loc.length > '/super/tenants/'.length
                  ? 'Configurar tenant'
                  : 'Tenants');
          return SuperShell(titulo: titulo, child: child);
        },
        routes: [
          GoRoute(
            path: '/super/tenants',
            pageBuilder: (_, s) => _fadePage(s, const TenantsListScreen()),
          ),
          GoRoute(
            path: '/super/tenants/:id',
            pageBuilder: (_, s) => _fadePage(s,
                TenantModulosScreen(tenantId: s.pathParameters['id']!)),
          ),
          GoRoute(
            path: '/super/tenants/:tid/miembros/:cid',
            pageBuilder: (_, s) => _fadePage(s, MiembroDetalleScreen(
              tenantId: s.pathParameters['tid']!,
              cobradorId: s.pathParameters['cid']!,
            )),
          ),
        ],
      ),

      // ── Rutas push del cobrador (con back propio) ──────────────────────
      GoRoute(
        path: '/perfil',
        builder: (_, __) => Scaffold(
          appBar: AppBar(title: const Text('Mi perfil')),
          body: const PerfilScreen(),
        ),
      ),
      GoRoute(
        path: '/historial',
        builder: (_, __) => const HistorialScreen(),
      ),
      GoRoute(
        path: '/clientes/:id',
        builder: (_, s) => ClienteDetailScreen(clienteId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/clientes/:id/editar',
        builder: (_, s) => ClienteFormScreen(clienteId: s.pathParameters['id']),
      ),
      GoRoute(
        path: '/contratos/nuevo',
        builder: (_, s) => ContratoFormScreen(
            clienteId: s.uri.queryParameters['cliente_id']),
      ),
      GoRoute(
        path: '/contratos/:id',
        builder: (_, s) => ContratoDetailScreen(
            contratoId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/cobro/:cuotaId',
        builder: (_, s) {
          final param = s.pathParameters['cuotaId']!;
          final ids = param.split(',');
          return CobroScreen(cuotaIds: ids);
        },
      ),
      GoRoute(
        path: '/recibo/:reciboId',
        builder: (_, s) => ReciboScreen(
          reciboId: s.pathParameters['reciboId']!,
          grupoCobro: s.uri.queryParameters['grupo'],
        ),
      ),
      GoRoute(
        path: '/perfil/impresora',
        builder: (_, __) => const ImpresoraSetupScreen(),
      ),

      // Detalle del ticket para el técnico (push fuera del shell, con back y
      // Scaffold propio). Reusa TicketDetailScreen en `tecnicoMode` (acota las
      // transiciones a avanzar/pausar/resolver y oculta reasignar).
      GoRoute(
        path: '/tecnico/tickets/:id',
        builder: (_, s) => Scaffold(
          appBar: AppBar(title: const Text('Ticket')),
          body: TicketDetailScreen(
            ticketId: s.pathParameters['id']!,
            tecnicoMode: true,
          ),
        ),
      ),
    ],
  );
});

Widget _titled(String titulo, Widget child) =>
    ShellTitleScope(titulo: titulo, child: child);

/// Página con transición de **deslizamiento con cobertura opaca** para las
/// sub-rutas de un shell. Se define a NIVEL DE PÁGINA (no envolviendo el body)
/// para que el Navigator interno del ShellRoute use ESTA y no la suya.
///
/// Por qué deslizamiento y no fade: un fade (cross-fade, FadeThrough, etc.) es
/// por definición un cruce de OPACIDADES → siempre hay un instante con las dos
/// pantallas semitransparentes encimadas. Para que NO se vean encimadas, la
/// entrante tiene **fondo opaco** y se desliza TAPANDO a la saliente: en ningún
/// píxel se ven las dos a la vez. La saliente queda detrás con un leve parallax.
CustomTransitionPage<void> _fadePage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      child: child,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          _CoverSlide(animation: animation, child: child),
    );

/// Deslizamiento con cobertura opaca. La página ENTRANTE entra desde la derecha
/// (fondo opaco) y tapa a la de atrás; la SALIENTE queda quieta con un leve
/// parallax a la izquierda. Se distingue por `animation.status`, pero aunque
/// fallara, la entrante va arriba en el z-order y es opaca → nunca hay
/// superposición visible (no se ven las dos pantallas a la vez).
class _CoverSlide extends StatelessWidget {
  const _CoverSlide({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final entrante = animation.status == AnimationStatus.forward ||
        animation.status == AnimationStatus.completed;
    final Animation<Offset> pos = entrante
        // Entra desde la derecha → centro.
        ? Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic))
        // Saliente (animation va 1→0): de centro → leve parallax a la izquierda.
        : Tween<Offset>(begin: const Offset(-0.18, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOut));
    return SlideTransition(
      position: pos,
      // Fondo opaco: garantiza que la entrante TAPE a la saliente (sin ver a
      // través), así nunca se ven las dos pantallas encimadas.
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: child,
      ),
    );
  }
}

/// Rutas compartidas que un shell móvil (tecnico/admin_tickets) puede abrir
/// fuera de su árbol (Scaffold propio con back) sin que el redirect lo rebote.
const _shellSharedRoutes = ['/perfil/impresora'];

/// Redirect inicial por rol: landing de `/` + guards de shell por rol
/// (tecnico, admin_tickets, cobrador). PURO (sin `ref`) → testeable. Devuelve la
/// ruta a redirigir, o `null` si no aplica (el caller sigue con los guards que
/// dependen de settings/módulos y el gating de /super).
String? redirectInicialPorRol({
  required String? rol,
  required String loc,
  required bool impersonating,
}) {
  // Landing al entrar (`/`): cada rol a su panel.
  if (loc == '/') {
    if (rol == 'super_admin') {
      return impersonating ? '/admin' : '/super/tenants';
    }
    if (rol == 'admin' ||
        rol == 'admin_cobranza' ||
        rol == 'admin_usuarios' ||
        rol == 'lectura') {
      return '/admin';
    }
    if (rol == 'admin_tickets' || rol == 'coordinador') {
      return '/admin-tickets';
    }
  }
  // Técnico: vive en `/tecnico/*` (+ impresora compartida).
  if (rol == 'tecnico' &&
      !loc.startsWith('/tecnico') &&
      !_shellSharedRoutes.contains(loc)) {
    return '/tecnico';
  }
  // admin_tickets y coordinador: viven en `/admin-tickets/*` (+ impresora).
  // El coordinador comparte shell porque su trabajo ES la cola de tickets; lo
  // que NO puede hacer (editar la orden) lo corta el trigger del server, no la
  // ruta — la UI solo le esconde los controles.
  if ((rol == 'admin_tickets' || rol == 'coordinador') &&
      !loc.startsWith('/admin-tickets') &&
      !_shellSharedRoutes.contains(loc)) {
    return '/admin-tickets';
  }
  // Cobrador puro: no entra a `/admin/*` (su shell es `/`).
  if (rol == 'cobrador' && loc.startsWith('/admin')) {
    return '/';
  }
  // `lectura` (0198): ve TODA pantalla de consulta y ninguna que exista para
  // modificar. Es denylist —no allowlist como admin_usuarios— porque el rol ve
  // el panel completo: la excepción son los formularios. Backstop de la UI, que
  // ya no le dibuja los botones para llegar acá.
  //
  // `/recibo` NO entra en la lista: es un documento de CONSULTA (reimprimir), y
  // bloquearlo lo expulsaba al panel desde el historial de pagos. Sus dos
  // escrituras ya pasan por la guardia `ps.dbW`.
  if (rol == 'lectura') {
    const rutasDeEscritura = [
      '/cobro',
      '/admin/clientes/nuevo',
      '/admin/contratos/nuevo',
      '/admin/tickets/nuevo',
      '/admin-tickets/tickets/nuevo',
      '/contratos/nuevo',
    ];
    final esFormNuevo =
        rutasDeEscritura.any((p) => loc == p || loc.startsWith('$p/'));
    // `/…/:id/editar` en cualquiera de sus variantes.
    if (esFormNuevo || loc.endsWith('/editar')) return '/admin';
  }
  // Exclusión inversa: SOLO el técnico entra a `/tecnico/*` y SOLO admin_tickets a
  // `/admin-tickets/*`. Cualquier otro rol por URL directa/back-stack → su landing
  // (antes solo se confinaba al dueño, no se excluía a los ajenos — audit 2026-06-30).
  // Las rutas compartidas (impresora) quedan exentas.
  if (rol != 'tecnico' &&
      loc.startsWith('/tecnico') &&
      !_shellSharedRoutes.contains(loc)) {
    return '/';
  }
  if (rol != 'admin_tickets' &&
      rol != 'coordinador' &&
      loc.startsWith('/admin-tickets') &&
      !_shellSharedRoutes.contains(loc)) {
    return '/';
  }
  return null;
}

class ShellTitleScope extends InheritedWidget {
  const ShellTitleScope({super.key, required this.titulo, required super.child});
  final String titulo;

  @override
  bool updateShouldNotify(ShellTitleScope oldWidget) => oldWidget.titulo != titulo;

  static String? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellTitleScope>()?.titulo;
}

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(GoTrueClient auth) {
    _sub = auth.onAuthStateChange.listen((_) => notifyListeners());
  }
  late final StreamSubscription<AuthState> _sub;

  /// Disparable externamente (ej. cuando llega el rol del usuario).
  void poke() => notifyListeners();

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
