import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Almacenamiento local de fotos del comprobante (mobile/desktop con
/// filesystem). Compañera `foto_local_storage_web.dart` queda como stub.
class FotoLocalStorage {
  static const _dirName = 'foto_comprobante';

  /// Persiste `bytes` con nombre `name` (debe ser un UUID sin paths).
  /// Devuelve null si no se pudo escribir.
  static Future<bool> save(Uint8List bytes, String name) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Lee los bytes guardados con `name`. Null si no existe.
  static Future<Uint8List?> read(String name) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/$name');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Borra el archivo si existe. Devuelve true si lo borró efectivamente.
  static Future<bool> delete(String name) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/$name');
      if (await f.exists()) {
        await f.delete();
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Lista los nombres de archivos en el directorio (para GC).
  static Future<List<String>> listAll() async {
    try {
      final dir = await _dir();
      final files = dir.listSync();
      return files.whereType<File>().map((f) => f.uri.pathSegments.last).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
