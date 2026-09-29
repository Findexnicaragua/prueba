import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Servicio de ruteo vehicular en línea que utiliza la API de OpenStreetMap (OSRM).
/// Proporciona la geometría precisa calle por calle (incluyendo vías secundarias y residenciales).
class OsrmRoutingService {
  OsrmRoutingService._();
  static final OsrmRoutingService instance = OsrmRoutingService._();

  http.Client? _httpClient;
  http.Client get _client => _httpClient ??= http.Client();

  /// Endpoint público de OSRM para automóviles / motos (perfil driving).
  static const String _osrmBaseUrl = 'https://router.project-osrm.org/route/v1/driving';

  /// Timeout estricto para no congelar la UI si el teléfono tiene mala cobertura.
  static const Duration _timeout = Duration(milliseconds: 2500);

  /// Consulta la ruta óptima entre [start] y [end] por las calles reales.
  /// Retorna la lista detallada de coordenadas [path] y la distancia total en metros.
  /// Retorna `null` si no hay conexión, ocurre un timeout o la API responde con error.
  Future<({List<LatLng> path, double distanceMetres})?> findRoute(
    LatLng start,
    LatLng end,
  ) async {
    // Formato OSRM: {lon1},{lat1};{lon2},{lat2}
    final urlStr = '$_osrmBaseUrl/'
        '${start.longitude.toStringAsFixed(6)},${start.latitude.toStringAsFixed(6)};'
        '${end.longitude.toStringAsFixed(6)},${end.latitude.toStringAsFixed(6)}'
        '?overview=full&geometries=geojson';

    final uri = Uri.parse(urlStr);

    try {
      final response = await _client
          .get(
            uri,
            headers: {
              'User-Agent': 'SITECSA-CRM/0.44 (ISP Field Operation)',
              'Accept': 'application/json',
            },
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        return null;
      }

      final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (data['code'] != 'Ok') {
        return null;
      }

      final routes = data['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) {
        return null;
      }

      final route = routes.first as Map<String, dynamic>;
      final distance = (route['distance'] as num?)?.toDouble() ?? 0.0;
      final geometry = route['geometry'] as Map<String, dynamic>?;

      if (geometry == null || geometry['type'] != 'LineString') {
        return null;
      }

      final rawCoords = geometry['coordinates'] as List<dynamic>?;
      if (rawCoords == null || rawCoords.isEmpty) {
        return null;
      }

      final path = <LatLng>[];
      for (final item in rawCoords) {
        if (item is List && item.length >= 2) {
          final lng = (item[0] as num).toDouble();
          final lat = (item[1] as num).toDouble();
          path.add(LatLng(lat, lng));
        }
      }

      if (path.isEmpty) return null;

      // Asegurar que el inicio y el fin conecten exactamente con las coordenadas solicitadas
      if (path.first != start) {
        path.insert(0, start);
      }
      if (path.last != end) {
        path.add(end);
      }

      return (path: path, distanceMetres: distance);
    } catch (_) {
      // Cualquier fallo de red o parseo retorna null silenciosamente para activar fallback
      return null;
    }
  }

  /// Libera recursos del cliente HTTP si es necesario
  void dispose() {
    _httpClient?.close();
    _httpClient = null;
  }
}
