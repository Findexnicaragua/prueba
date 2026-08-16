import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:http_cache_file_store/http_cache_file_store.dart';
import 'package:path_provider/path_provider.dart';

/// Caché en disco de los tiles del mapa (offline-first "mientras navegás").
///
/// Estrategia: cache-first vía el default `CachePolicy.forceCache` de
/// flutter_map_cache — si el tile ya está en disco y no expiró (ver
/// [_maxStale]), se sirve del disco SIN tocar la red (ahorra datos del
/// cobrador); si no está, se baja y se guarda. Estando SIN señal, los tiles
/// ya guardados se siguen sirviendo (fallback a caché ante error de red). NO
/// pre-descarga zonas: lo que el cobrador nunca abrió online no está
/// disponible offline (decisión de scope; la pre-descarga de áreas queda
/// para un sprint futuro).
///
/// **Plataformas:** Android + Windows (filesystem nativo). En **web** el
/// `FileCacheStore` no aplica (no hay filesystem persistente), así que
/// [tileProvider] cae al `NetworkTileProvider` de flutter_map — el mapa
/// sigue funcionando, solo sin caché en disco. Todo el init es best-effort:
/// si algo falla, se degrada al provider de red sin romper el mapa.
///
/// **Sin tope de tamaño** (decisión de Rubén): el disco crece sin techo. La
/// red de seguridad es (a) [maxStale] de 90 días — los tiles no tocados en
/// ese lapso se revalidan/reciclan — y (b) el botón "Borrar caché del mapa"
/// en /perfil, que llama a [clear]. [cacheSizeBytes] alimenta el indicador
/// de tamaño de esa misma pantalla.
class MapTileCache {
  MapTileCache._();

  /// Singleton — una sola caché compartida por TODOS los mapas de la app
  /// (mapa del cobrador, mapa del admin, mini-mapa del form de cliente). Las
  /// capas calles (OSM) y satélite (ArcGIS) comparten el store: las URLs
  /// distintas generan claves distintas, así que no se pisan.
  static final MapTileCache instance = MapTileCache._();

  /// Subcarpeta dentro del directorio de soporte de la app donde viven los
  /// tiles cacheados. Aislada para que [cacheSizeBytes]/[clear] midan y
  /// limpien SOLO los tiles, sin tocar otra data de la app.
  static const String _subdir = 'map_tiles_cache';

  /// Antigüedad máxima antes de revalidar un tile. No es un tope de tamaño
  /// (eso quedó "sin tope"): es higiene para que zonas viejas no queden
  /// pegadas para siempre.
  static const Duration _maxStale = Duration(days: 90);

  FileCacheStore? _store;
  String? _dir;
  bool _initialized = false;

  /// Inicializa el store de disco. Idempotente y best-effort. En web no hace
  /// nada (no hay filesystem persistente). Llamar una vez al arrancar (main).
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb) return;
    try {
      // Directorio de soporte de la app (NO el de caché del SO, que el
      // sistema puede borrar): queremos que los tiles sobrevivan para el
      // uso offline. Android → filesDir; Windows → %APPDATA%/<app>.
      final base = await getApplicationSupportDirectory();
      final dir = '${base.path}${Platform.pathSeparator}$_subdir';
      await Directory(dir).create(recursive: true);
      _dir = dir;
      _store = FileCacheStore(dir);
    } catch (e) {
      // Si falla (permisos, plataforma rara), el mapa cae a red sin romper.
      if (kDebugMode) debugPrint('MapTileCache.init falló: $e');
      _store = null;
      _dir = null;
    }
  }

  /// `tileProvider` para los `TileLayer`. Cacheado en disco en Android/Windows;
  /// en web o si el init falló, devuelve el `NetworkTileProvider` de flutter_map
  /// (mismo comportamiento que antes de esta feature). El `userAgentPackageName`
  /// del `TileLayer` se sigue respetando: flutter_map lo inyecta en los headers
  /// que este provider usa para bajar el tile.
  TileProvider tileProvider() {
    final store = _store;
    if (store == null) return NetworkTileProvider();
    return CachedTileProvider(store: store, maxStale: _maxStale);
  }

  /// Tamaño total en bytes de la caché de tiles en disco. 0 en web, si el
  /// init falló, o si todavía no se cacheó ningún tile.
  Future<int> cacheSizeBytes() async {
    final dir = _dir;
    if (dir == null) return 0;
    try {
      final d = Directory(dir);
      if (!await d.exists()) return 0;
      var total = 0;
      await for (final entity in d.list(recursive: true, followLinks: false)) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (e) {
      if (kDebugMode) debugPrint('MapTileCache.cacheSizeBytes falló: $e');
      return 0;
    }
  }

  /// Vacía la caché de tiles. Primero pide al store que limpie sus entradas
  /// y después borra cualquier archivo residual de la carpeta como defensa,
  /// así el "Borrar caché" del usuario libera disco de verdad.
  Future<void> clear() async {
    final store = _store;
    if (store != null) {
      try {
        await store.clean();
      } catch (e) {
        if (kDebugMode) debugPrint('MapTileCache.clear (store) falló: $e');
      }
    }
    final dir = _dir;
    if (dir != null) {
      try {
        final d = Directory(dir);
        if (await d.exists()) {
          await for (final entity in d.list(followLinks: false)) {
            await entity.delete(recursive: true);
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('MapTileCache.clear (fs) falló: $e');
      }
    }
  }
}
