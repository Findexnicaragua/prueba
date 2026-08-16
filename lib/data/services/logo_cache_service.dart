import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'logo_local_storage.dart';

/// Caché OFFLINE del logo de la empresa, versionado contra la fila que
/// sincroniza PowerSync.
///
/// ## La regla
///
/// **Si el archivo ya está en disco y su versión coincide con la de la fila
/// sincronizada, NO se toca la red.** Ni una vez. Ni al arrancar la app.
///
/// La versión es `path|updated_at` de la fila `settings.empresa.logo_path`
/// (ver `AppSettings.empresaLogoVersion`). Esa fila ya viaja por PowerSync, así
/// que el cliente sabe gratis y offline si el logo cambió: no hace falta
/// preguntarle al servidor, ni pollear, ni "refrescar por las dudas".
///
/// ## Por qué el control vive ACÁ y no en quien llama
///
/// Este servicio nació con `refrescarLogo`, que bajaba INCONDICIONALMENTE y
/// confiaba en que su caller lo llamara en momentos sensatos. Se lo colgó de
/// `if (status.connected)` en el listener de `statusStream`, que NO es el
/// evento "se conectó" sino el estado "está conectado" — y PowerSync lo
/// re-emite ~25 veces por minuto. Resultado: ~12.000 descargas de 567 KB por
/// equipo por jornada, 35-62 GB/día de egress, con 2,7 MB guardados en total.
///
/// La lección quedó como regla de auditoría (ver `AUDIT-PROFUNDO.md`): el guard
/// va en la función llamada y se apoya en una versión PERSISTIDA, nunca en la
/// disciplina del caller. Acá eso significa que aunque alguien vuelva a colgar
/// esto de un latido, las mil llamadas cuestan mil comparaciones locales y cero
/// bytes de red.
///
/// ## Nunca bloquea la impresión
///
/// Si hay bytes en disco se devuelven YA, aunque la versión esté vencida, y el
/// refresco corre en segundo plano. Un cobrador sin señal imprime al instante
/// con el logo que tenga; jamás espera un timeout de red para sacar un recibo.
class LogoCacheService {
  LogoCacheService([SupabaseClient? supabase])
      : _supabase = supabase ?? Supabase.instance.client;
  final SupabaseClient _supabase;

  static const _bucket = 'logos-empresa';
  static const _timeout = Duration(seconds: 8);

  /// Tras una descarga fallida no se reintenta hasta pasada esta ventana.
  /// Sin esto, un equipo sin señal y sin logo en disco pagaría el timeout
  /// completo en CADA recibo.
  static const _esperaTrasFallo = Duration(minutes: 1);

  /// Bytes ya resueltos en esta corrida, por tenant. Evita ir al disco en cada
  /// recibo y es lo ÚNICO que cachea en web (donde no hay filesystem).
  static final Map<String, _LogoEnMemoria> _memoria = {};

  /// Descargas en curso, por tenant: dos pantallas pidiendo el logo a la vez
  /// comparten la misma descarga en lugar de disparar dos.
  static final Map<String, _Descarga> _enVuelo = {};

  /// Cuándo falló la última descarga, por tenant (para `_esperaTrasFallo`).
  static final Map<String, DateTime> _ultimoFallo = {};

  /// La versión de un logo: path + `updated_at` de su fila de settings.
  ///
  /// El path SOLO no alcanza: `LogoEmpresaService` siempre sube a
  /// `{tenant}/logo.png`, así que un logo nuevo tiene el mismo path que el
  /// viejo. `updated_at` sí cambia (`SettingsRepo.update` lo reescribe siempre).
  /// Función pura para poder testearla sin Supabase.
  static String tokenDe(String logoPath, String? version) =>
      '$logoPath|${version ?? ''}';

  /// ¿Sirve lo que hay en disco/memoria para esta versión? Pura y testeable:
  /// es el guard que decide si se toca la red.
  static bool sirveCache({
    required String? tokenGuardado,
    required String tokenPedido,
    required bool hayBytes,
  }) =>
      hayBytes && tokenGuardado != null && tokenGuardado == tokenPedido;

  /// Olvida el estado en memoria. Para tests y para el cambio de DB/usuario.
  static void olvidarCache() {
    _memoria.clear();
    _enVuelo.clear();
    _ultimoFallo.clear();
  }

  /// Tira el cache de un tenant (memoria + disco). Lo usa el admin al subir un
  /// logo nuevo, para forzar que la próxima lectura vaya a la red.
  static Future<void> invalidar(String tenantId) async {
    if (tenantId.isEmpty) return;
    _memoria.remove(tenantId);
    _enVuelo.remove(tenantId);
    _ultimoFallo.remove(tenantId);
    await LogoLocalStorage.delete(tenantId);
  }

  /// Bytes del logo para mostrar/imprimir. Null si el tenant no tiene logo
  /// configurado, o si no hay nada en disco y la descarga no se pudo hacer.
  ///
  /// NUNCA espera a la red si ya hay algo servible en disco.
  Future<Uint8List?> obtenerLogo({
    required String tenantId,
    required String? logoPath,
    required String? version,
  }) async {
    if (tenantId.isEmpty) return null;
    // Sin logo configurado: limpiar lo que hubiera quedado de antes.
    if (logoPath == null || logoPath.isEmpty) {
      await invalidar(tenantId);
      return null;
    }
    final token = tokenDe(logoPath, version);

    // 1) Memoria al día → cero disco, cero red.
    final mem = _memoria[tenantId];
    if (mem != null && mem.token == token) return mem.bytes;

    // 2) Disco.
    final enDisco = await LogoLocalStorage.read(tenantId);
    final tokenDisco = await LogoLocalStorage.leerVersion(tenantId);
    final hayBytes = enDisco != null && enDisco.isNotEmpty;

    if (sirveCache(
        tokenGuardado: tokenDisco, tokenPedido: token, hayBytes: hayBytes)) {
      _memoria[tenantId] = _LogoEnMemoria(token, enDisco!);
      return enDisco;
    }

    // 3) Hay bytes pero de otra versión: devolverlos YA y refrescar detrás.
    // Imprimir nunca espera a la red.
    if (hayBytes) {
      unawaited(_asegurar(tenantId, logoPath, token));
      return enDisco;
    }

    // 4) No hay NADA en disco: no queda otra que bajar y esperar.
    return _asegurar(tenantId, logoPath, token);
  }

  /// Deja el cache al día si hace falta. Lo llama el observador de la fila de
  /// settings en `main.dart` — el único disparador legítimo de una descarga.
  Future<void> asegurarCache({
    required String tenantId,
    required String? logoPath,
    required String? version,
  }) async {
    if (tenantId.isEmpty) return;
    if (logoPath == null || logoPath.isEmpty) {
      await invalidar(tenantId);
      return;
    }
    final token = tokenDe(logoPath, version);
    final mem = _memoria[tenantId];
    if (mem != null && mem.token == token) return;

    final enDisco = await LogoLocalStorage.read(tenantId);
    final tokenDisco = await LogoLocalStorage.leerVersion(tenantId);
    if (sirveCache(
        tokenGuardado: tokenDisco,
        tokenPedido: token,
        hayBytes: enDisco != null && enDisco.isNotEmpty)) {
      _memoria[tenantId] = _LogoEnMemoria(token, enDisco!);
      return;
    }
    await _asegurar(tenantId, logoPath, token);
  }

  /// Baja el logo una vez, compartiendo la descarga si ya hay una en curso
  /// para el mismo tenant y la misma versión.
  Future<Uint8List?> _asegurar(
      String tenantId, String logoPath, String token) {
    final actual = _enVuelo[tenantId];
    if (actual != null && actual.token == token) return actual.future;

    final future = _bajarYGuardar(tenantId, logoPath, token);
    _enVuelo[tenantId] = _Descarga(token, future);
    return future.whenComplete(() {
      if (_enVuelo[tenantId]?.token == token) _enVuelo.remove(tenantId);
    });
  }

  Future<Uint8List?> _bajarYGuardar(
      String tenantId, String logoPath, String token) async {
    // Backoff tras un fallo: sin señal, no repetir el timeout en cada recibo.
    final fallo = _ultimoFallo[tenantId];
    if (fallo != null && DateTime.now().difference(fallo) < _esperaTrasFallo) {
      return LogoLocalStorage.read(tenantId);
    }
    try {
      final bytes = await _supabase.storage
          .from(_bucket)
          .download(logoPath)
          .timeout(_timeout);
      if (bytes.isEmpty) return LogoLocalStorage.read(tenantId);

      // El marcador se escribe DESPUÉS de los bytes: si algo muere en el
      // medio, queda un PNG sin versión y la próxima corrida lo vuelve a
      // bajar. Preferimos bajar de más antes que servir viejo creyéndolo nuevo.
      final guardo = await LogoLocalStorage.save(bytes, tenantId);
      if (guardo) await LogoLocalStorage.guardarVersion(tenantId, token);
      _memoria[tenantId] = _LogoEnMemoria(token, bytes);
      _ultimoFallo.remove(tenantId);
      return bytes;
    } catch (e) {
      // Silenciado a propósito: sin red se sigue usando lo que haya en disco.
      // La impresión offline no depende de esto.
      _ultimoFallo[tenantId] = DateTime.now();
      if (kDebugMode) debugPrint('LogoCacheService: $e');
      return LogoLocalStorage.read(tenantId);
    }
  }

  /// Lee el logo cacheado del DISCO local. NO toca la red → sirve OFFLINE.
  /// Devuelve null si nunca se cacheó (o en web, donde no hay filesystem).
  Future<Uint8List?> leerLogoCacheado(String tenantId) async {
    if (tenantId.isEmpty) return null;
    return LogoLocalStorage.read(tenantId);
  }
}

class _LogoEnMemoria {
  const _LogoEnMemoria(this.token, this.bytes);
  final String token;
  final Uint8List bytes;
}

class _Descarga {
  const _Descarga(this.token, this.future);
  final String token;
  final Future<Uint8List?> future;
}
