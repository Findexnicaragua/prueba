import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'offline_routing_service.dart';
import 'osrm_routing_service.dart';

/// Resultado enriquecido de un cálculo de ruta
class RouteResult {
  final List<LatLng> path;
  final double distanceMetres;
  final bool isOffline;
  final bool isFallback;

  const RouteResult({
    required this.path,
    required this.distanceMetres,
    required this.isOffline,
    required this.isFallback,
  });

  /// Distancia formateada para lectura humana (ej. "850 m" o "3.2 km")
  String get distanciaFormateada {
    if (distanceMetres < 1000) {
      return '${distanceMetres.round()} m';
    } else {
      return '${(distanceMetres / 1000).toStringAsFixed(1)} km';
    }
  }
}

/// Orquestador principal de ruteo de SITECSA CRM.
/// Implementa la arquitectura híbrida:
/// 1. Caché local en memoria de rutas recientes.
/// 2. Consulta en línea a OSRM (OpenStreetMap) con timeout estricto.
/// 3. Fallback transparente al motor de red vial offline (SQLite local).
class RoutingService {
  RoutingService._();
  static final RoutingService instance = RoutingService._();

  // Caché en memoria: clave -> (resultado, timestamp)
  final Map<String, ({RouteResult result, DateTime timestamp})> _cache = {};
  static const Duration _cacheTtl = Duration(minutes: 15);
  static const int _maxCacheEntries = 60;

  String _cacheKey(LatLng a, LatLng b) {
    return '${a.latitude.toStringAsFixed(5)},${a.longitude.toStringAsFixed(5)}->'
        '${b.latitude.toStringAsFixed(5)},${b.longitude.toStringAsFixed(5)}';
  }

  /// Calcula la ruta óptima entre [start] y [end].
  /// Intenta primero OSRM en línea; si falla o no hay datos, utiliza el motor offline.
  Future<RouteResult?> findRoute(LatLng start, LatLng end) async {
    final key = _cacheKey(start, end);
    final now = DateTime.now();

    // 1. Revisar caché en memoria
    final cached = _cache[key];
    if (cached != null && now.difference(cached.timestamp) < _cacheTtl) {
      return cached.result;
    }

    // 2. Intentar servicio OSRM en línea (precisión calle por calle)
    try {
      final onlineResult = await OsrmRoutingService.instance.findRoute(start, end);
      if (onlineResult != null && onlineResult.path.length >= 2) {
        final result = RouteResult(
          path: onlineResult.path,
          distanceMetres: onlineResult.distanceMetres,
          isOffline: false,
          isFallback: false,
        );
        _saveToCache(key, result, now);
        return result;
      }
    } catch (_) {
      // Continuar al fallback offline sin interrumpir la UX
    }

    // 3. Fallback a motor de carreteras offline local
    try {
      final offlineResult = await OfflineRoutingService.instance.findRoute(start, end);
      if (offlineResult != null && offlineResult.path.length >= 2) {
        final result = RouteResult(
          path: offlineResult.path,
          distanceMetres: offlineResult.distanceMetres,
          isOffline: true,
          isFallback: offlineResult.isFallback,
        );
        _saveToCache(key, result, now);
        return result;
      }
    } catch (_) {
      // Fallback final
    }

    // 4. Salvaguarda absoluta (si no hay red ni base de datos disponible)
    final directDistance = _haversineDistance(
      start.latitude,
      start.longitude,
      end.latitude,
      end.longitude,
    );

    final emergencyResult = RouteResult(
      path: [start, end],
      distanceMetres: directDistance,
      isOffline: true,
      isFallback: true,
    );
    return emergencyResult;
  }

  void _saveToCache(String key, RouteResult result, DateTime timestamp) {
    if (_cache.length >= _maxCacheEntries) {
      // Remover la entrada más vieja
      final oldestKey = _cache.keys.first;
      _cache.remove(oldestKey);
    }
    _cache[key] = (result: result, timestamp: timestamp);
  }

  double _haversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) *
            sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  /// Limpia la caché y recursos
  void dispose() {
    _cache.clear();
    OsrmRoutingService.instance.dispose();
    OfflineRoutingService.instance.dispose();
  }
}
