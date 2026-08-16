import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Almacenamiento local del logo de la empresa cacheado para impresión
/// térmica OFFLINE (mobile/desktop con filesystem). Compañera
/// `logo_local_storage_web.dart` queda como stub (web no imprime en térmica).
///
/// El archivo se guarda como `logo_<tenantId>.png` dentro del directorio
/// de documentos de la app, así sobrevive reinicios y queda disponible sin
/// red al momento de imprimir.
///
/// Al lado del PNG se guarda `logo_<tenantId>.ver`, un archivo de texto con la
/// VERSIÓN del logo que hay en disco (`path|updated_at` de la fila de settings).
/// Ese marcador es lo que permite no volver a bajar el archivo NUNCA mientras
/// no cambie — incluso entre reinicios de la app. Sin él, el cache no puede
/// distinguir "el logo que tengo" de "el logo que hay", y la única forma de
/// estar seguro es volver a bajarlo (que es exactamente la fuga que se corrigió).
///
/// El marcador se escribe DESPUÉS del PNG a propósito: si el proceso muere en
/// el medio, queda un PNG sin marcador → la próxima corrida lo vuelve a bajar.
/// El error cae del lado seguro (bajar de más), nunca del lado de servir un
/// archivo viejo creyendo que está al día.
class LogoLocalStorage {
  static const _dirName = 'logo_empresa';

  /// Persiste `bytes` del logo del tenant `tenantId`. Devuelve false si no
  /// se pudo escribir (deja intacto el cache anterior si lo había).
  static Future<bool> save(Uint8List bytes, String tenantId) async {
    if (!_tenantSeguro(tenantId)) return false;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_nombre(tenantId)}');
      await f.writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Lee los bytes del logo cacheado del tenant. Null si no existe (nunca se
  /// cacheó, o el archivo se borró). Solo toca disco — sirve OFFLINE.
  static Future<Uint8List?> read(String tenantId) async {
    if (!_tenantSeguro(tenantId)) return null;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_nombre(tenantId)}');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Lee la versión del logo que hay en disco. Null si nunca se guardó
  /// (logo bajado por una versión vieja de la app, o descarga a medias).
  static Future<String?> leerVersion(String tenantId) async {
    if (!_tenantSeguro(tenantId)) return null;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_nombreVersion(tenantId)}');
      if (!await f.exists()) return null;
      final v = (await f.readAsString()).trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Anota qué versión del logo quedó en disco. Se llama DESPUÉS de `save`.
  static Future<bool> guardarVersion(String tenantId, String version) async {
    if (!_tenantSeguro(tenantId) || version.isEmpty) return false;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_nombreVersion(tenantId)}');
      await f.writeAsString(version, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Borra el logo cacheado del tenant (ej. el admin quitó el logo).
  /// Borra TAMBIÉN el marcador de versión: dejarlo huérfano haría que un
  /// logo re-subido con la misma versión se diera por cacheado sin archivo.
  static Future<bool> delete(String tenantId) async {
    if (!_tenantSeguro(tenantId)) return false;
    var borro = false;
    for (final nombre in [_nombre(tenantId), _nombreVersion(tenantId)]) {
      try {
        final dir = await _dir();
        final f = File('${dir.path}/$nombre');
        if (await f.exists()) {
          await f.delete();
          borro = true;
        }
      } catch (_) {}
    }
    return borro;
  }

  static String _nombre(String tenantId) => 'logo_$tenantId.png';
  static String _nombreVersion(String tenantId) => 'logo_$tenantId.ver';

  /// Defensa contra path traversal: el tenantId va en el nombre de archivo.
  /// Es un UUID, así que no debería tener separadores ni `..`.
  static bool _tenantSeguro(String tenantId) {
    if (tenantId.isEmpty) return false;
    return !(tenantId.contains('/') ||
        tenantId.contains('\\') ||
        tenantId.contains('..'));
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
