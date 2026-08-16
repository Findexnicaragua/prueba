import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Reporta al server QUÉ VERSIÓN de la app corre este dispositivo (0225).
///
/// Existe porque no había forma de saberlo, y eso hizo que dos auditorías
/// sacaran conclusiones falsas leyendo datos de producción como si los hubiera
/// generado el código de `main`. Con esto se puede contestar "¿el fix ya le
/// llegó a esta persona?" sin preguntarle.
///
/// Es TELEMETRÍA, no dato de negocio, y por eso:
///  · Va DIRECTO por Supabase, no por PowerSync. No ocupa lugar en la cola de
///    sync ni compite con los writes que sí importan; si no hay internet, no
///    pasa nada y se reintenta en el próximo arranque.
///  · Es best-effort ABSOLUTO: cualquier error se traga. Nunca puede impedir
///    que alguien entre a trabajar.
///  · Una fila por INSTALL (el id se guarda en el device), se upsertea. No
///    crece sin techo.
class DispositivoService {
  DispositivoService._();
  static final instance = DispositivoService._();

  static const _kDeviceIdKey = 'device_id_v1';

  /// Id estable de ESTA instalación. Se genera una vez y queda en el device.
  /// No identifica a la persona: si dos usuarios comparten equipo, comparten id
  /// y la fila queda con el último que entró — que es justo lo que se quiere
  /// saber (qué versión corre ese equipo).
  static Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final guardado = prefs.getString(_kDeviceIdKey);
    if (guardado != null) return guardado;
    final nuevo = const Uuid().v4();
    await prefs.setString(_kDeviceIdKey, nuevo);
    return nuevo;
  }

  static String get _plataforma {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isWindows) return 'windows';
      if (Platform.isIOS) return 'ios';
      return Platform.operatingSystem;
    } catch (_) {
      return 'otro';
    }
  }

  /// Se llama al abrir sesión. No hace falta esperarla.
  Future<void> reportar({
    required String tenantId,
    required String usuarioId,
    String? usuarioNombre,
    String? rol,
  }) async {
    try {
      final info = await PackageInfo.fromPlatform();
      // Mismo formato que muestra la app en login/perfil, para poder comparar
      // de un vistazo contra el release publicado.
      final version = info.buildNumber.isEmpty
          ? info.version
          : '${info.version}+${info.buildNumber}';

      await Supabase.instance.client.from('app_dispositivos').upsert({
        'id': await _deviceId(),
        'tenant_id': tenantId,
        'usuario_id': usuarioId,
        'usuario_nombre': usuarioNombre,
        'rol': rol,
        'version': version,
        'plataforma': _plataforma,
        'modelo': _plataforma == 'windows'
            ? Platform.operatingSystemVersion
            : null,
        'visto_en': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      // Telemetría: NUNCA puede romper el arranque. Sin internet, sin permisos
      // o con la tabla ausente, simplemente no se reporta.
      if (kDebugMode) debugPrint('[dispositivo] no se pudo reportar: $e');
    }
  }
}
