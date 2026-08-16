import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemException, Platform, SocketException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Información de una actualización disponible.
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.downloadUrl,
    this.releaseNotes,
  });

  final String version;
  final String downloadUrl;
  final String? releaseNotes;
}

/// Servicio que checa si hay una versión más nueva de la app disponible
/// y la descarga/instala IN-APP (sin delegar al navegador).
///
/// Check: lee `version.json` del último GitHub Release del repo
/// (`releases/latest/download/` siempre apunta al más reciente). Formato:
///
/// ```json
/// {
///   "version": "0.11.0",
///   "download_url_windows": "https://.../CRM.msix",
///   "download_url_android": "https://.../CRM.apk",
///   "download_url": "https://.../fallback",
///   "release_notes": "..."
/// }
/// ```
///
/// Update in-app (2026-06-09 — antes se tiraba el link a Chrome y la
/// descarga moría en la cadena de redirecciones de GitHub):
///   1. [descargarActualizacion] baja el binario con el cliente HTTP de la
///      app (sigue los 302 de GitHub sin drama) a un directorio propio,
///      reportando progreso.
///   2. [instalar] lanza el instalador del SISTEMA via open_filex:
///      Android → diálogo "¿Instalar?" (requiere REQUEST_INSTALL_PACKAGES,
///      pedido en runtime); Windows → App Installer del .msix.
class UpdateService {
  /// Slug del tenant horneado en un build branded
  /// (`--dart-define=TENANT=<slug>`). Vacío = build genérico.
  static const _tenant = String.fromEnvironment('TENANT');

  /// Repo PÚBLICO de releases (`owner/repo`) de donde la app se autoactualiza.
  /// Se hornea en build-time desde `.env.json` (clave `UPDATE_REPO`, vía
  /// `--dart-define-from-file`). El default = el repo de producción, así un
  /// build SIN la clave sigue apuntando al canal vigente (cero cambio para
  /// producción). Para apuntar a OTRO dueño (traspaso/staging), basta cambiar
  /// `UPDATE_REPO` en `.env.json` y rebuildear — no se toca este archivo.
  static const _updateRepo = String.fromEnvironment(
    'UPDATE_REPO',
    defaultValue: 'rubenmaltez/sitecsa-updates',
  );

  /// URL del version.json. Hosteado como asset del último GitHub Release.
  /// La URL /latest/download/ siempre apunta al release más reciente.
  ///
  /// White-label (Opción B): en un build branded apunta al canal del tenant
  /// (`version-<slug>.json`), que trae las URLs de los assets de ESE tenant.
  /// Así cada app instalada se actualiza desde su propio archivo y conserva
  /// su ícono y nombre. El build genérico usa `version.json`.
  static String get _versionUrl {
    final archivo = _tenant.isEmpty ? 'version.json' : 'version-$_tenant.json';
    // Repo PUBLICO de releases (configurable via UPDATE_REPO; el codigo vive
    // en un repo privado aparte).
    return 'https://github.com/$_updateRepo/releases/latest/download/$archivo';
  }

  /// Checa si hay actualización disponible. Retorna null si está al día
  /// o si no se puede conectar (no bloquea el arranque).
  static Future<AppUpdate?> checkForUpdate() async {
    try {
      final response = await http
          .get(Uri.parse(_versionUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;

      var body = response.body;
      if (body.startsWith('\uFEFF')) {
        body = body.substring(1);
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final remoteVersion = json['version'] as String?;

      // URL por plataforma: version.json tiene download_url_windows,
      // download_url_android, y download_url como fallback genérico.
      // Formato esperado:
      // {
      //   "version": "0.2.0",
      //   "download_url_windows": "https://.../cobranza-isp-0.2.0.msix",
      //   "download_url_android": "https://.../cobranza-isp-0.2.0.apk",
      //   "download_url": "https://.../fallback",
      //   "release_notes": "..."
      // }
      final platformKey = kIsWeb
          ? 'download_url'
          : Platform.isAndroid
              ? 'download_url_android'
              : Platform.isWindows
                  ? 'download_url_windows'
                  : 'download_url';
      final downloadUrl =
          json[platformKey] as String? ?? json['download_url'] as String?;

      if (remoteVersion == null || downloadUrl == null) return null;

      final packageInfo = await PackageInfo.fromPlatform();
      final localVersion = packageInfo.version;

      if (_isNewer(remoteVersion, localVersion)) {
        return AppUpdate(
          version: remoteVersion,
          downloadUrl: downloadUrl,
          releaseNotes: json['release_notes'] as String?,
        );
      }

      return null;
    } catch (e) {
      debugPrint('[UPDATE] Check failed (non-blocking): $e');
      return null;
    }
  }

  /// Comparación semver simplificada: "1.2.0" > "1.1.0".
  /// Soporta major.minor.patch. Si el formato es inválido, retorna false.
  static bool _isNewer(String remote, String local) {
    final r = remote.split('.').map(int.tryParse).toList();
    final l = local.split('.').map(int.tryParse).toList();

    if (r.length < 3 || l.length < 3) return false;
    if (r.any((n) => n == null) || l.any((n) => n == null)) return false;

    for (var i = 0; i < 3; i++) {
      if (r[i]! > l[i]!) return true;
      if (r[i]! < l[i]!) return false;
    }
    return false;
  }

  // ── Descarga + instalación in-app ─────────────────────────────────────────

  /// Descarga el binario de [update] a un directorio de la app, en streaming
  /// y reportando avance via [onProgress] (0.0→1.0, o null si el server no
  /// mandó Content-Length → progreso indeterminado).
  ///
  /// El cliente HTTP de Dart sigue las redirecciones 302 de GitHub
  /// (releases/latest/download → CDN firmado) sin intervención — exactamente
  /// lo que el download manager de Chrome en Android no lograba.
  ///
  /// Lanza [Exception] con mensaje legible (en español) si la descarga falla;
  /// el caller (banner) lo muestra y ofrece reintentar. No usar en web (kIsWeb).
  ///
  /// Timeouts: 30s para el handshake inicial y 30s POR CHUNK del stream (no
  /// duración total — un APK grande en red lenta puede tardar minutos, pero un
  /// stall real entre chunks se detecta). Sin esto, una red rural que se cuelga
  /// sin RST dejaba el banner clavado en "Descargando…" para siempre.
  static const _timeout = Duration(seconds: 30);

  /// Cache de la última descarga completa (M17, audit UX): en Android, el
  /// permiso de instalación manda al user a Ajustes y al volver tocaba
  /// "Actualizar" de nuevo → se RE-DESCARGABA el APK entero (minutos en 3G
  /// rural). Si ya bajamos ESTA versión y el archivo sigue ahí, va directo.
  static File? _cacheArchivo;
  static String? _cacheVersion;

  static Future<File> descargarActualizacion(
    AppUpdate update, {
    void Function(double? progreso)? onProgress,
  }) async {
    if (_cacheVersion == update.version &&
        _cacheArchivo != null &&
        await _cacheArchivo!.exists()) {
      onProgress?.call(1.0);
      return _cacheArchivo!;
    }
    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(update.downloadUrl)))
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw Exception(
            'No se pudo descargar la actualización (HTTP ${response.statusCode}). '
            'Reintentá en unos minutos.');
      }

      // Extensión por PLATAFORMA (no sniffing de URL): Android instala APK,
      // Windows instala MSIX. open_filex infiere el tipo de la extensión, así
      // que debe matchear el contenido real que sirve la URL de esa plataforma.
      final ext = (!kIsWeb && Platform.isAndroid) ? 'apk' : 'msix';
      final nombre = _tenant.isEmpty
          ? 'CRM-v${update.version}.$ext'
          : 'CRM-$_tenant-v${update.version}.$ext';
      final dir = await _directorioDescarga();
      final archivo = File('${dir.path}/$nombre');

      final total = response.contentLength;
      var recibido = 0;
      final sink = archivo.openWrite(); // trunca si existía (re-descarga limpia)
      try {
        await for (final chunk in response.stream.timeout(_timeout)) {
          sink.add(chunk);
          recibido += chunk.length;
          onProgress?.call(
              (total != null && total > 0) ? recibido / total : null);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (total != null && total > 0 && recibido < total) {
        throw Exception('La descarga quedó incompleta. Reintentá.');
      }
      _cacheArchivo = archivo;
      _cacheVersion = update.version;
      return archivo;
    } on TimeoutException {
      throw Exception(
          'La descarga se quedó sin conexión. Verificá tu internet y reintentá.');
    } on SocketException {
      throw Exception(
          'Sin conexión con el servidor de descargas. Verificá tu internet y reintentá.');
    } on http.ClientException {
      throw Exception(
          'Sin conexión con el servidor de descargas. Verificá tu internet y reintentá.');
    } on FileSystemException {
      throw Exception(
          'No se pudo guardar la descarga (espacio o permisos). Liberá espacio y reintentá.');
    } finally {
      client.close();
    }
  }

  /// Directorio destino del instalador descargado.
  /// Android: external-files de la app (/Android/data/<pkg>/files) — es el
  /// path que el FileProvider de open_filex expone al instalador del sistema;
  /// fallback al support dir si el device no tiene external storage.
  /// Windows (y resto): temp del sistema.
  static Future<Directory> _directorioDescarga() async {
    if (!kIsWeb && Platform.isAndroid) {
      return (await getExternalStorageDirectory()) ??
          await getApplicationSupportDirectory();
    }
    return getTemporaryDirectory();
  }

  /// Lanza el instalador del sistema para [archivo] (el binario descargado).
  /// Retorna null si se lanzó OK, o un mensaje de error legible si no.
  ///
  /// Android: pide en runtime el permiso "instalar apps desconocidas"
  /// (REQUEST_INSTALL_PACKAGES — la 1ª vez el sistema abre el toggle de
  /// ajustes para ESTA app; con el permiso dado, open_filex dispara el
  /// diálogo nativo "¿Instalar?").
  /// Windows: abre el .msix con App Installer (un click "Actualizar").
  static Future<String?> instalar(File archivo) async {
    if (!kIsWeb && Platform.isAndroid) {
      final estado = await Permission.requestInstallPackages.request();
      if (!estado.isGranted) {
        return 'Para actualizar, permití "instalar aplicaciones" a la app '
            'en el ajuste que se abrió, y tocá Actualizar de nuevo.';
      }
    }
    final resultado = await OpenFilex.open(archivo.path);
    if (resultado.type != ResultType.done) {
      return 'No se pudo abrir el instalador: ${resultado.message}';
    }
    return null;
  }
}
