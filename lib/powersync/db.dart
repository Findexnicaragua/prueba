import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, debugPrint;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'connector.dart';
import 'schema.dart';

/// Base PowerSync activa. Se recrea al cambiar de usuario (per-user DB).
late PowerSyncDatabase db;

/// Stream global de errores de CRUD upload.
final uploadErrorsController = StreamController<CrudUploadError>.broadcast();

/// User ID de la DB actualmente abierta. null si no hay DB abierta.
String? _currentDbUserId;

/// Lock para serializar operaciones de DB.
Completer<void>? _pendingOp;

/// Suscripción al connector actual (para cancelar al reconectar).
StreamSubscription<CrudUploadError>? _connectorSub;

/// Callback que se invoca después de abrir una nueva DB per-user.
/// main.dart lo usa para re-suscribir statusStream y re-invalidar providers.
void Function(PowerSyncDatabase newDb)? onDatabaseSwitched;

/// Directorio base para las DBs (lazy).
String? _dbDirPath;

Future<String> _getDbDir() async {
  if (_dbDirPath != null) return _dbDirPath!;
  if (kIsWeb) {
    _dbDirPath = '';
    return '';
  }
  final base = await getApplicationSupportDirectory();
  _dbDirPath = base.path;
  return base.path;
}

/// Versión de WIPE de la DB local: va en el NOMBRE del archivo, así que
/// cambiarla fuerza una DB fresca (re-sync COMPLETO del slice) para TODOS.
///
/// ⚠️ NO bumpear por cambios ADITIVOS de schema (columna/tabla/índice nuevos):
/// PowerSync los aplica IN-PLACE al reabrir — `initialize()` reconstruye las
/// views sobre los datos ya sincronizados, sin re-descargar (verificado en
/// `test/powersync/schema_inplace_test.dart`). Para un cambio aditivo SOLO se
/// edita `schema.dart`; el archivo y los datos locales se conservan.
///
/// Bumpear SOLO cuando un cambio NO puede aplicarse in-place:
///   • DESTRUCTIVO: renombrar/borrar/cambiar el TIPO de una columna ya poblada
///     (la view vieja quedaría inconsistente con el JSON crudo).
///   • Sospecha de cache local corrupto que exija empezar de cero.
/// (Un cambio de SYNC RULES se re-materializa solo en el server; no necesita
/// bump del cliente salvo que cambie la FORMA de una tabla.) Política completa
/// (árbol aditivo/destructivo/sync-rules): ARQUITECTURA.md Receta R4/R10.
///
/// Aislamiento entre usuarios: lo da el `userId` del nombre, NO esta versión
/// (cada user tiene su propio archivo). Asume que el `userId` de Supabase NO se
/// recicla (UUID server-side, nunca reusado).
///
/// Historia: antes era `_schemaVersion` y se bumpeaba en CADA cambio de schema
/// (33 veces, ~97% aditivos) → re-sync gratis evitable. El cambio de `_v` a `_w`
/// produce UN wipe de transición para todos; desde ahí, los aditivos no wipean.
const _dbWipeVersion = 1;

String _dbPathForUser(String userId, String basePath) {
  if (kIsWeb) {
    return 'sitecsa_${userId}_w$_dbWipeVersion.db';
  }
  return '$basePath/sitecsa_${userId}_w$_dbWipeVersion.db';
}

/// Abre la DB genérica (sin user). Solo para el boot inicial antes del login.
Future<void> openDatabase() async {
  final dir = await _getDbDir();
  final path = kIsWeb
      ? 'sitecsa_default_w$_dbWipeVersion.db'
      : '$dir/sitecsa_default_w$_dbWipeVersion.db';
  db = PowerSyncDatabase(schema: schema, path: path);
  await db.initialize();
}

/// Abre (o reutiliza) la DB del usuario específico. Si es el mismo user
/// que la DB actual, no hace nada (reconexión instantánea). Si es un
/// user diferente, cierra la DB anterior y abre la nueva.
Future<void> openDatabaseForUser(String userId) async {
  if (_currentDbUserId == userId) return;

  // Serializar con cualquier operación en vuelo.
  // WHILE y no IF (M5, audit Fase 4 del Sprint 1): al completarse la op en
  // vuelo se despertaban TODOS los esperantes y corrian concurrentes (el
  // segundo no re-chequeaba). Con el loop, cada despertado re-verifica si
  // otro le gano el turno y vuelve a esperar.
  while (_pendingOp != null && !_pendingOp!.isCompleted) {
    await _pendingOp!.future;
  }
  final op = Completer<void>();
  _pendingOp = op;

  try {
    // Cambia el usuario → el rol cacheado para la guardia de escritura (0198)
    // es del ANTERIOR. Se limpia acá y no se espera a que
    // `cobradorActualProvider` emita: en esa ventana, un rol que sí puede
    // escribir quedaría bloqueado por el cache de un `lectura` previo (y al
    // revés sería peor). `null` = no bloquear; RLS sigue siendo el backstop.
    rolActualCache = null;

    // Cerrar la DB anterior.
    try { await db.disconnect(); } catch (_) {}
    try { await db.close(); } catch (_) {}

    final dir = await _getDbDir();
    final path = _dbPathForUser(userId, dir);
    db = PowerSyncDatabase(schema: schema, path: path);
    await db.initialize();
    _currentDbUserId = userId;

    // Notificar a main.dart para re-suscribir statusStream y providers.
    onDatabaseSwitched?.call(db);
  } finally {
    op.complete();
  }
}

/// Conecta PowerSync usando la sesión Supabase actual.
///
/// Serializa con `_pendingOp` igual que `openDatabaseForUser` y
/// `disconnectPowerSync`: si hay un open/disconnect en vuelo (caso típico:
/// signOut global de forzar-password seguido del re-login), `connect` espera
/// a que termine antes de tocar `db`. Sin esta serialización, un `db.connect`
/// podía correr contra una instancia que se estaba cerrando/reabriendo y
/// dejaba a PowerSync sin emitir checkpoint → sync gate colgado (el bug
/// histórico "stuck post-forzar-password" que solo F5 desbloqueaba).
Future<void> connectPowerSync() async {
  // WHILE y no IF (M5, audit Fase 4 del Sprint 1): al completarse la op en
  // vuelo se despertaban TODOS los esperantes y corrian concurrentes (el
  // segundo no re-chequeaba). Con el loop, cada despertado re-verifica si
  // otro le gano el turno y vuelve a esperar.
  while (_pendingOp != null && !_pendingOp!.isCompleted) {
    await _pendingOp!.future;
  }
  final op = Completer<void>();
  _pendingOp = op;
  try {
    // Cancelar suscripción anterior del connector.
    await _connectorSub?.cancel();

    final connector = SupabaseConnector(Supabase.instance.client);
    _connectorSub = connector.uploadErrors.listen((error) {
      uploadErrorsController.add(error);
    });
    await db.connect(connector: connector, params: await _paramsCliente());
  } finally {
    op.complete();
  }
}

/// Versión de la app cacheada: `PackageInfo.fromPlatform()` cruza el canal de
/// plataforma y `connect` puede correr varias veces por sesión (re-login,
/// cambio de usuario, reconexión).
String? _versionCache;

/// Datos que la app declara al conectar. Viajan en `client_params` y quedan
/// en los logs del servidor de sync — es de donde el panel del VPS saca la
/// versión que corre cada equipo.
///
/// Sirve para responder "¿quién no actualizó?", que sin esto no se puede: el
/// `user_agent` que manda PowerSync solo trae su propia versión de librería
/// (`powersync-dart-core/1.8.0 Dart/3.11.5 windows`), idéntica en toda la
/// flota. Y mirar por USUARIO no alcanza: cuentas compartidas como "Oficina"
/// se usan desde varias PCs a la vez, cada una con su versión.
///
/// ⚠️ Estos parámetros NO los lee ninguna sync rule (todas filtran por
/// `request.user_id()`), así que no cambian los buckets ni disparan re-sync.
/// Antes de referenciar `request.parameters` en una sync rule hay que evaluar
/// el impacto: ahí sí cambiaría la identidad del bucket y toda la flota
/// re-bajaría su slice.
Future<Map<String, dynamic>> _paramsCliente() async {
  try {
    _versionCache ??= (await PackageInfo.fromPlatform()).version;
    return {'app_version': _versionCache!};
  } catch (e) {
    // Nunca bloquear el sync por no poder leer la versión.
    if (kDebugMode) debugPrint('_paramsCliente: $e');
    return const {};
  }
}

/// Desconecta PowerSync sin borrar datos locales.
Future<void> disconnectPowerSync() async {
  // WHILE y no IF (M5, audit Fase 4 del Sprint 1): al completarse la op en
  // vuelo se despertaban TODOS los esperantes y corrian concurrentes (el
  // segundo no re-chequeaba). Con el loop, cada despertado re-verifica si
  // otro le gano el turno y vuelve a esperar.
  while (_pendingOp != null && !_pendingOp!.isCompleted) {
    await _pendingOp!.future;
  }
  final op = Completer<void>();
  _pendingOp = op;
  try {
    await db.disconnect();
  } finally {
    op.complete();
  }
}

// ── Guardia de escritura del rol `lectura` (0198) ─────────────────────────

/// Rol del usuario logueado, cacheado para poder consultarlo de forma SÍNCRONA
/// desde [dbW]. Lo mantiene `cobradorActualProvider` (única fuente de verdad).
String? rolActualCache;

/// Se lanza cuando el rol `lectura` intenta escribir. La UI ya oculta las
/// acciones; esto es la red por debajo, para las que se escapen.
class SoloLecturaException implements Exception {
  const SoloLecturaException();
  @override
  String toString() => 'Tu usuario es de solo lectura: no podés modificar datos.';
}

/// La MISMA base que [db], pero pasando por la guardia de solo-lectura.
///
/// Toda escritura del cliente (`execute`, `writeTransaction`) va por acá en vez
/// de por `db` directo. Se hizo así, y no gateando botón por botón, porque hay
/// ~84 escrituras en ~32 archivos: cazarlas a mano deja huecos, y un hueco no
/// da un error visible sino un **cambio fantasma** — el usuario ve aplicarse la
/// operación y el connector la descarta después, sin avisarle.
///
/// Con esto, lo que se escape falla ANTES de tocar el SQLite y el usuario ve un
/// mensaje claro. Ocultar los controles sigue siendo lo preferible (esto es el
/// backstop, no el reemplazo). Las LECTURAS siguen usando `db` sin restricción.
PowerSyncDatabase get dbW {
  if (rolActualCache == 'lectura') throw const SoloLecturaException();
  return db;
}
