import 'dart:typed_data';

/// Stub web del cache local del logo. En navegador no hay filesystem
/// persistente ni impresión térmica Bluetooth, así que el cache no aplica:
/// `read` siempre devuelve null y `save`/`delete` son no-ops. El recibo en
/// web se imprime como PDF con el logo embebido por otra vía.
///
/// Como acá no hay disco, `leerVersion` siempre da null → `obtenerLogo` no
/// puede saltear por versión y bajaría en cada llamada. Por eso el cache EN
/// MEMORIA de `LogoCacheService` (que no depende del filesystem) es el que
/// sostiene el caso web: una descarga por corrida, no una por recibo.
class LogoLocalStorage {
  static Future<bool> save(Uint8List bytes, String tenantId) async => false;

  static Future<Uint8List?> read(String tenantId) async => null;

  static Future<String?> leerVersion(String tenantId) async => null;

  static Future<bool> guardarVersion(String tenantId, String version) async =>
      false;

  static Future<bool> delete(String tenantId) async => false;
}
