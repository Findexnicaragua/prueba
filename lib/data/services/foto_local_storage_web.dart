import 'dart:typed_data';

/// Stub para web: el storage local de fotos no aplica (no hay filesystem
/// persistente sin IndexedDB). El admin web sólo VE fotos via URL firmada;
/// la captura es exclusiva del cobrador en mobile.
class FotoLocalStorage {
  static Future<bool> save(Uint8List bytes, String name) async => false;
  static Future<Uint8List?> read(String name) async => null;
  static Future<bool> delete(String name) async => false;
  static Future<List<String>> listAll() async => const [];
}
