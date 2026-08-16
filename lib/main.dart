import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/env.dart';
import 'data/providers/auth_identity_provider.dart';
import 'data/providers/foto_comprobante_provider.dart';
import 'data/services/logo_cache_service.dart';
import 'data/services/map_tile_cache.dart';
import 'features/auth/auth_flow_provider.dart';
import 'package:powersync/powersync.dart' show SyncStatus;

import 'data/providers/db_epoch_provider.dart';
import 'data/providers/impersonation_provider.dart';
import 'powersync/db.dart' as ps;

const _kLastKnownUserIdKey = 'last_known_user_id';

/// Flag one-shot: revierte el namespace v0.24.7 que movió la DB a un
/// subdirectorio `<slug>/` (innecesario: MSIX/Android ya aíslan AppSupport
/// por identity_name/applicationId). Mueve los archivos de vuelta a la raíz.
const _kRevertDbNamespaceKey = 'revert_db_namespace_v2_done';
const _kTenantSlug = String.fromEnvironment('TENANT');

// Suscripción al auth state change. Se guarda en scope global para
// poder cancelarla en hot restart (dev) — sino el listener previo
// intenta usar el ProviderContainer disposed y tira excepciones.
StreamSubscription? _authSub;

Future<void> main() async {
  // Envolvemos todo en runZonedGuarded para capturar excepciones uncaught
  // de código async (sin try/catch) que no son interceptadas por
  // FlutterError.onError. Se imprimen a consola; sin persistencia (error_logs
  // se eliminó — no se usaba para debug).
  //
  // WidgetsFlutterBinding.ensureInitialized() corre DENTRO de la zona para
  // que el binding y los runApp queden en la misma zona — sin esto
  // Flutter emite "Zone mismatch" warnings.
  await runZonedGuarded<Future<void>>(_bootstrap, (error, stack) {
    debugPrint('[uncaught] $error\n$stack');
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Path URL strategy en web: URLs limpias (`/admin` en vez de `/#/admin`).
  // Necesario para que Supabase pueda redirigir invitaciones/recuperaciones
  // con `#access_token=...` sin que GoRouter intente parsear el fragmento
  // como ruta y reviente.
  if (kIsWeb) usePathUrlStrategy();

  // Capturamos el tipo de flow ANTES de Supabase.initialize.
  //   - Implicit flow (fragment con #type=...): la SDK limpia el fragmento
  //     al procesarlo, así que se debe leer antes.
  //   - PKCE flow (query con ?code=... + opcionalmente ?flow=...): la SDK
  //     puede o no procesar el code automáticamente, depende de la
  //     versión. Leemos `?flow=...` para conocer el tipo.
  // Posibles valores: 'recovery' (forgot password), 'invite' (primera
  // entrada tras invitación), 'signup' (confirm email), null si arranque
  // normal.
  final initialUri = Uri.base;
  final initialAuthFlow = _extractAuthFlow(initialUri);
  final initialAuthError = _extractAuthError(initialUri);
  final initialPkceCode = initialUri.queryParameters['code'];

  if (!Env.isConfigured) {
    runApp(const _ConfigMissingApp());
    return;
  }

  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );

  // Migración: revierte el namespace de DB v0.24.7 (subdirectorio <slug>
  // innecesario — el SO ya aísla AppSupport por paquete).
  await _revertirDbNamespaceSiFalta();

  await ps.openDatabase();

  // Inicializa la caché en disco de los tiles del mapa (Android/Windows).
  // Best-effort y no-bloqueante en la práctica: si falla, el mapa cae al
  // NetworkTileProvider. En web es un no-op (no hay filesystem persistente).
  await MapTileCache.instance.init();

  // Pre-cargar el last_known_user_id de SharedPreferences. El
  // authIdentityProvider lo necesita como estado inicial para detectar
  // user switch cross-session: si la pestaña se cerró post-signOut y
  // otro user se loguea al reabrir, sin este storage arrancaríamos en
  // (null, null) y no gatearíamos el cache stale del user anterior.
  final prefs = await SharedPreferences.getInstance();
  final lastKnownUserId = prefs.getString(_kLastKnownUserIdKey);

  // ProviderContainer creado acá (no dentro de ProviderScope) para que el
  // listener de auth de abajo pueda mutar el authIdentityProvider — el
  // sync gate (R7) necesita capturar el momento exacto de signIn/signOut.
  final container = ProviderContainer(
    overrides: [
      initialAuthFlowProvider.overrideWith((_) => initialAuthFlow),
      initialAuthErrorProvider.overrideWith((_) => initialAuthError),
      authIdentityProvider.overrideWith((ref) => AuthIdentityNotifier(
            lastKnownUserId: lastKnownUserId,
            onPersist: (uid) => prefs.setString(_kLastKnownUserIdKey, uid),
          )),
    ],
  );

  // Conectar/desconectar PowerSync siguiendo el ciclo de vida de la sesión.
  // `initialSession` cubre el caso de arranque con token persistido.
  //
  // IMPORTANTE: el listener se setea ANTES de exchangeCodeForSession para
  // que los eventos del exchange (signedIn en flows recovery/invite) sean
  // capturados — sino PowerSync queda desconectado pese a tener sesión.
  //
  // **Telemetría del sync flow** (debug del bug "sync gate stuck
  // post-forzar-password"): logueamos cada paso del flow signedIn →
  // connectPowerSync para que la próxima reproducción del bug aparezca
  // en /super/logs con info útil. `connectPowerSync` envuelto en
  // try/catch porque sino las excepciones del SDK quedan silenciadas
  // dentro del listener async.
  // Cancelar suscripción previa si existe (hot restart en dev). Sin
  // cancel, el listener viejo intenta usar el container disposed →
  // ProviderDisposedException en consola.
  _authSub?.cancel();
  _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
    final session = data.session;
    switch (data.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
        if (session != null) {
          debugPrint('[SYNC-DIAG] ${data.event.name} for user ${session.user.id}');
          container
              .read(authIdentityProvider.notifier)
              .onSignIn(session.user.id);
          try {
            debugPrint('[SYNC-DIAG] openDatabaseForUser starting…');
            await ps.openDatabaseForUser(session.user.id);
            debugPrint('[SYNC-DIAG] connectPowerSync starting…');
            await ps.connectPowerSync();
            debugPrint('[SYNC-DIAG] connectPowerSync returned OK');
          } catch (e, stack) {
            debugPrint('[SYNC-DIAG] connectPowerSync THREW: $e\n$stack');
          }
        }
        break;
      case AuthChangeEvent.signedOut:
        // Sólo desconectamos sync — la data local del usuario anterior
        // queda en SQLite por performance / offline. El sync gate (R7)
        // bloquea la UI hasta que PowerSync confirme un sync posterior
        // al signOut, así el próximo user no ve data del anterior.
        debugPrint('[SYNC-DIAG] signedOut event');
        container.read(authIdentityProvider.notifier).onSignOut();
        try {
          await ps.disconnectPowerSync();
          debugPrint('[SYNC-DIAG] disconnectPowerSync returned OK');
        } catch (e, stack) {
          debugPrint('[SYNC-DIAG] disconnectPowerSync THREW: $e\n$stack');
        }
        break;
      default:
        break;
    }
  });

  // Si la SDK ya restauró sesión durante initialize (usuario con token
  // persistido), el listener puede haber 'llegado tarde' al initialSession
  // event. Forzamos un connect manual como red de seguridad — sino
  // PowerSync queda desconectado pese a tener sesión.
  //
  // El guard `currentIdentity.userId != restoredSession.user.id` evita el
  // double-connect: si el listener YA recibió initialSession y llamó
  // onSignIn, el provider tiene el uid actual → skipeamos. Si el state
  // inicial vino del storage (mismo uid restaurado) también skipeamos.
  // Sólo entramos si la identidad efectivamente cambió.
  final restoredSession = Supabase.instance.client.auth.currentSession;
  if (restoredSession != null) {
    final currentIdentity = container.read(authIdentityProvider);
    if (currentIdentity.userId != restoredSession.user.id) {
      debugPrint('[SYNC-DIAG] Fallback manual connect for restored user '
          '${restoredSession.user.id} (identity ≠ session)');
      container
          .read(authIdentityProvider.notifier)
          .onSignIn(restoredSession.user.id);
      try {
        await ps.openDatabaseForUser(restoredSession.user.id);
        await ps.connectPowerSync();
        debugPrint('[SYNC-DIAG] Fallback connect returned OK');
      } catch (e, stack) {
        debugPrint('[SYNC-DIAG] Fallback connect THREW: $e\n$stack');
      }
    } else {
      debugPrint('[SYNC-DIAG] Fallback skip (identity already matches '
          'restored session user)');
    }
  }

  // Si vino un código PKCE en la URL y la SDK no lo intercambió sola,
  // lo hacemos a mano. Después de exchangeCodeForSession, la sesión queda
  // activa, dispara signedIn, y el listener de arriba conecta PowerSync.
  if (initialPkceCode != null && kIsWeb) {
    try {
      await Supabase.instance.client.auth
          .exchangeCodeForSession(initialPkceCode);
    } catch (e) {
      // Si falla (link expirado, code ya usado, code_verifier no en
      // localStorage de este browser), no bloqueamos el arranque —
      // el usuario verá la pantalla de login.
      debugPrint('exchangeCodeForSession falló: $e');
    }
  }

  // Background worker: sube fotos del comprobante pendientes cuando hay
  // conexión. El service tiene su propio lock interno — el botón manual
  // en perfil y este worker comparten la misma protección.
  //
  // Importante: leemos del container (mismo singleton que la UI consume).
  // Con instancia local separada, el StreamController de `results` no
  // sería el mismo que el UI watchea via `uploadResultsProvider` y los
  // SnackBars de R8 nunca llegarían.
  // GC de archivos huérfanos al arrancar (cobros cancelados, etc.).
  final fotoService = container.read(fotoComprobanteServiceProvider);
  unawaited(fotoService.limpiarHuerfanos());

  Object? lastReportedSyncError;
  StreamSubscription<SyncStatus>? statusSub;
  StreamSubscription<Object?>? logoSub;

  void subscribeStatusStream() {
    statusSub?.cancel();
    lastReportedSyncError = null;
    statusSub = ps.db.statusStream.listen((status) {
    // ⚠️ `status.connected` NO es el evento "se conectó": es el ESTADO "está
    // conectado", y PowerSync lo re-emite en cada checkpoint (~25 veces por
    // minuto). Todo lo que cuelgue de acá corre a esa frecuencia. Nada que
    // toque la red va en este bloque — el cacheo del logo vivía acá y costó
    // 35-62 GB/día de egress (ver `LogoCacheService` y `AUDIT-PROFUNDO.md`).
    // `sincronizarPendientes` es seguro: tiene lock propio y consulta el
    // SQLite local; sin fotos pendientes no sale a la red.
    if (status.connected) {
      unawaited(fotoService.sincronizarPendientes());
    }
    // Telemetría del sync flow: si PowerSync reporta un error
    // (anyError, downloadError, uploadError), lo capturamos al
    // logger. Eso nos da visibilidad del bug "sync gate stuck" si
    // PowerSync está fallando silenciosamente sin emitir checkpoint.
    final err = status.anyError;
    if (err != null && err != lastReportedSyncError) {
      lastReportedSyncError = err;
      debugPrint('[SYNC-DIAG] PowerSync anyError: $err');
    } else if (err == null && lastReportedSyncError != null) {
      lastReportedSyncError = null;
    }
    });
  }

  /// Observa la FILA del logo, no la conexión.
  ///
  /// `settings.empresa.logo_path` ya viaja por PowerSync, así que el cliente se
  /// entera solo —y offline— de que el admin cambió el logo. Ese es el único
  /// disparador legítimo de una descarga: el dato cambió. `ps.db.watch` emite
  /// cuando la tabla cambia, y si lo hace de más no importa: `asegurarCache`
  /// compara contra la versión que hay en disco y sale sin tocar la red.
  void subscribeLogoWatch() {
    logoSub?.cancel();
    if (kIsWeb) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    // El JOIN con `cobradores` resuelve el tenant del usuario logueado sin
    // una segunda consulta (la fila de `cobradores` replica el uid de auth).
    logoSub = ps.db
        .watch(
          'SELECT s.tenant_id, s.valor, s.updated_at FROM settings s '
          'JOIN cobradores c ON c.tenant_id = s.tenant_id '
          "WHERE c.id = ? AND s.clave = 'empresa.logo_path' LIMIT 1",
          parameters: [uid],
        )
        .listen((rows) {
      if (rows.isEmpty) return;
      unawaited(_asegurarLogoCacheado(rows.first));
    }, onError: (Object e) {
      if (kDebugMode) debugPrint('subscribeLogoWatch: $e');
    });
  }

  // Suscribir al statusStream de la DB inicial.
  subscribeStatusStream();
  subscribeLogoWatch();

  // Callback: cuando openDatabaseForUser crea una nueva DB, re-suscribir
  // statusStream e invalidar providers que capturaron la DB vieja.
  ps.onDatabaseSwitched = (_) {
    subscribeStatusStream();
    // El watch del logo se ata a la DB y al uid de la sesión: al cambiar de
    // usuario hay que re-atarlo o quedaría escuchando la DB anterior.
    subscribeLogoWatch();
    // Bump del epoch: recrea TODOS los providers globales bound a ps.db que
    // hacen `ref.watch(dbEpochProvider)` (#7). Reemplaza la lista hardcodeada
    // e incompleta de invalidate() que dejaba providers (settings, clientes,
    // cuotas, rol, KPIs del dashboard...) con el stream de la DB anterior →
    // "data vieja / settings vacío" hasta el F5. Corre DESPUÉS de abrir la DB
    // nueva, así los providers recreados la capturan.
    container.read(dbEpochProvider.notifier).state++;
    // Evict del imageCache global cuando cambia la DB (login / logout /
    // switch de usuario / super_admin entra o sale de impersonación): las
    // NetworkImage cacheadas apuntan a signed URLs del tenant ANTERIOR y no
    // deben mostrarse tras el switch. Sin esto, tras exit de impersonación
    // el preview de un tenant podía pintar 1-2 frames con el logo del anterior.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  };

  // Impersonación (super_admin) NO dispara onDatabaseSwitched (mismo userId),
  // pero SÍ cambia el tenant efectivo → las NetworkImage cacheadas del tenant
  // anterior (logo, fotos con signed URL) no deben mostrarse. Limpiamos el
  // imageCache en cada transición para cortar el flash de "logo del anterior".
  container.listen<AsyncValue<String?>>(
    impersonatedTenantIdProvider,
    (previous, next) {
      final prevId = previous?.valueOrNull;
      final nextId = next.valueOrNull;
      if (prevId == nextId) return;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    },
  );

  runApp(UncontrolledProviderScope(
    container: container,
    child: const IspBillingApp(),
  ));
}

/// Refresca el cache local del logo de la empresa cuando hay conexión, para
/// que la impresión térmica (offline) pueda imprimirlo. Lee el `tenant_id` y
/// el `empresa.logo_path` directamente de la DB local de PowerSync.
///
/// Best-effort + silencioso: cualquier error (DB vacía, sin sesión, sin red
/// real) no debe romper el flujo de conectividad. En web el cache no aplica
/// (no hay térmica ni filesystem persistente) → se skipea para no gastar
/// banda en una descarga que el storage backend descartaría igual.
/// Migración one-shot (2026-07-15) — aislamiento cross-app v1.
///
/// **Contexto:** hasta v0.24.6, `LogoLocalStorage` cacheaba el logo del recibo
/// Migración one-shot v2: revierte el namespace de DB de v0.24.7.
///
/// v0.24.7 movió la DB a `<AppSupport>/<slug>/`, pero el SO ya aísla
/// AppSupport por identity_name (MSIX) / applicationId (Android). El
/// subdirectorio era innecesario y causó que la app no encontrara la DB
/// vieja → re-sync completo → vista vacía ("Nada por cobrar") post-update.
///
/// Mueve los archivos DB del subdirectorio de vuelta a la raíz, y limpia
/// el residuo `logo_empresa_<slug>/` que creó la migración v1.
Future<void> _revertirDbNamespaceSiFalta() async {
  if (kIsWeb) return;
  if (_kTenantSlug.isEmpty) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kRevertDbNamespaceKey) ?? false) return;

    if (!Platform.isWindows && !Platform.isAndroid && !Platform.isIOS) {
      await prefs.setBool(_kRevertDbNamespaceKey, true);
      return;
    }

    final base = await getApplicationSupportDirectory();
    final slugDir = Directory('${base.path}/$_kTenantSlug');
    if (await slugDir.exists()) {
      final entities = await slugDir.list().toList();
      for (final entity in entities) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          final dest = File('${base.path}/$name');
          await entity.copy(dest.path);
          debugPrint('[MIGRACION-V2] Movido: ${entity.path} → ${dest.path}');
        }
      }
      await slugDir.delete(recursive: true);
      debugPrint('[MIGRACION-V2] Borrado subdir: ${slugDir.path}');
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final slugLogoDir =
        Directory('${docsDir.path}/logo_empresa_$_kTenantSlug');
    if (await slugLogoDir.exists()) {
      await slugLogoDir.delete(recursive: true);
      debugPrint('[MIGRACION-V2] Borrado logo slug: ${slugLogoDir.path}');
    }

    await prefs.setBool(_kRevertDbNamespaceKey, true);
  } catch (e) {
    debugPrint('[MIGRACION-V2] Falló (non-blocking): $e');
  }
}

/// Deja el logo al día en disco a partir de la fila observada.
///
/// El logo se imprime OFFLINE (la térmica nunca toca la red), así que tiene que
/// estar en disco ANTES de que el cobrador salga a la calle. Esta es la única
/// descarga proactiva de la app, y solo ocurre si la versión en disco quedó
/// vieja — el resto de las emisiones del watch salen sin tocar la red.
Future<void> _asegurarLogoCacheado(Map<String, dynamic> fila) async {
  if (kIsWeb) return;
  try {
    final tenantId = fila['tenant_id'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;

    // empresa.logo_path: el valor está JSON-encodeado ("path" o null).
    final raw = fila['valor'] as String?;
    String? logoPath;
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is String && decoded.isNotEmpty) logoPath = decoded;
      } catch (_) {
        // Valor no-JSON (defensa): usar el raw si parece un path.
        if (raw.isNotEmpty && raw != 'null') logoPath = raw;
      }
    }
    if (logoPath == null) return;

    await LogoCacheService().asegurarCache(
      tenantId: tenantId,
      logoPath: logoPath,
      version: fila['updated_at'] as String?,
    );
  } catch (e) {
    if (kDebugMode) debugPrint('_asegurarLogoCacheado: $e');
  }
}

/// Lee el código de error de la URL inicial. Supabase manda errores en
/// query params cuando el link caduca o es inválido:
///   `?error=access_denied&error_code=otp_expired&error_description=…`
/// Preferimos error_description (legible) > error_code > error.
String? _extractAuthError(Uri uri) {
  final desc = uri.queryParameters['error_description'];
  if (desc != null && desc.isNotEmpty) return desc.replaceAll('+', ' ');
  final code = uri.queryParameters['error_code'];
  if (code != null && code.isNotEmpty) return code;
  return uri.queryParameters['error'];
}

/// Determina el tipo de flow de auth a partir de la URL inicial.
///
/// Supabase puede mandar el usuario de vuelta vía dos esquemas:
///   - Implicit flow → `#access_token=...&type=recovery&...` (fragmento)
///   - PKCE flow     → `?code=...` (query) — preferido en versiones nuevas
///
/// Para PKCE el `type` se pierde en el redirect — Supabase no lo
/// propaga en la URL final. Para preservarlo, agregamos `?flow=...` al
/// redirectTo al iniciar el flow (ver login_screen y edge fn invitar).
/// Si la URL tiene `?code=...` pero no `?flow=...` (link viejo o desde
/// otro path), asumimos 'recovery' como default — es el caso más común
/// y el SetPasswordScreen funciona igual.
String? _extractAuthFlow(Uri uri) {
  // 1. Query param explícito (PKCE con redirectTo customizado).
  final fromQuery = uri.queryParameters['flow'];
  if (fromQuery != null) return fromQuery;

  // 2. Fragment (implicit flow).
  if (uri.fragment.isNotEmpty) {
    final fragParams = Uri.splitQueryString(uri.fragment);
    final fromFragment = fragParams['type'];
    if (fromFragment != null) return fromFragment;
  }

  // 3. Code PKCE sin flow explícito — asumimos recovery por default.
  if (uri.queryParameters['code'] != null) {
    return 'recovery';
  }

  return null;
}

class _ConfigMissingApp extends StatelessWidget {
  const _ConfigMissingApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Configuración pendiente:\n\n'
              'Faltan SUPABASE_URL / SUPABASE_ANON_KEY / '
              'POWERSYNC_URL / POWERSYNC_TOKEN_ENDPOINT.\n\n'
              'Lanza la app con:\n'
              'flutter run --dart-define-from-file=.env.json',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
