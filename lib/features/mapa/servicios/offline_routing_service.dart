import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Nodo del grafo de ruteo para el algoritmo A*
class _RouteNode {
  final int id;
  final double lat;
  final double lng;
  double gScore = double.infinity;
  double fScore = double.infinity;
  _RouteNode? parent;

  _RouteNode({required this.id, required this.lat, required this.lng});
}

/// Servicio que realiza el ruteo de carreteras 100% offline utilizando
/// una red de calles principal almacenada en un SQLite local.
class OfflineRoutingService {
  OfflineRoutingService._();
  static final OfflineRoutingService instance = OfflineRoutingService._();

  Database? _db;
  bool _initialized = false;

  /// Inicializa la base de datos copiándola desde los assets del bundle
  /// de la app hacia el sistema de archivos del dispositivo si no existe.
  Future<void> init() async {
    if (_initialized) return;

    try {
      final docDir = await getApplicationSupportDirectory();
      final targetFile = File('${docDir.path}/rutas_nicaragua.db');

      // Si no existe el archivo, lo copiamos de assets
      if (!await targetFile.exists()) {
        final byteData = await rootBundle.load('assets/rutas_nicaragua.db');
        final bytes = byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
        await targetFile.writeAsBytes(bytes, flush: true);
      }

      // Abrir base de datos local
      _db = sqlite3.open(targetFile.path);
      _initialized = true;
    } catch (e) {
      throw Exception('No se pudo inicializar la base de datos de rutas offline: $e');
    }
  }

  /// Cierra la conexión de base de datos
  void dispose() {
    _db?.dispose();
    _db = null;
    _initialized = false;
  }

  /// Calcula la distancia del semiverseno (Haversine) entre dos coordenadas (en metros).
  double _haversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0; // Radio de la Tierra en metros
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) *
            sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  /// Busca el nodo de la red vial más cercano a la coordenada GPS proporcionada.
  _RouteNode? _findNearestNode(double lat, double lng) {
    if (_db == null) return null;

    // Proximidad rápida: ordenamos por distancia euclidiana al cuadrado (suficiente para distancias cortas)
    final stmt = _db!.prepare('''
      SELECT id, latitud, longitud 
        FROM nodos 
       ORDER BY ((latitud - ?) * (latitud - ?) + (longitud - ?) * (longitud - ?)) ASC 
       LIMIT 1
    ''');

    try {
      final rows = stmt.select([lat, lat, lng, lng]);
      if (rows.isEmpty) return null;

      final row = rows.first;
      return _RouteNode(
        id: row['id'] as int,
        lat: row['latitud'] as double,
        lng: row['longitud'] as double,
      );
    } finally {
      stmt.dispose();
    }
  }

  /// Obtiene los vecinos de un nodo origen desde la base de datos SQLite.
  List<({int id, double lat, double lng, double distancia})> _getNeighbors(int nodeId) {
    if (_db == null) return const [];

    final stmt = _db!.prepare('''
      SELECT t.destino_id, t.distancia_metros, n.latitud, n.longitud
        FROM tramos t
        JOIN nodos n ON n.id = t.destino_id
       WHERE t.origen_id = ?
    ''');

    try {
      final rows = stmt.select([nodeId]);
      return rows.map((r) => (
        id: r['destino_id'] as int,
        lat: r['latitud'] as double,
        lng: r['longitud'] as double,
        distancia: (r['distancia_metros'] as num).toDouble(),
      )).toList();
    } finally {
      stmt.dispose();
    }
  }

  /// Recupera la geometría detallada (puntos curvos de la carretera) entre dos nodos secuenciales.
  List<LatLng> _getSegmentGeometry(int origenId, int destinoId) {
    if (_db == null) return const [];

    final stmt = _db!.prepare('''
      SELECT camino_coordenadas 
        FROM tramos 
       WHERE origen_id = ? AND destino_id = ?
       LIMIT 1
    ''');

    try {
      final rows = stmt.select([origenId, destinoId]);
      if (rows.isEmpty) return const [];

      final rawCoords = rows.first['camino_coordenadas'] as String;
      final decoded = json.decode(rawCoords) as List<dynamic>;

      return decoded.map((p) {
        final list = p as List<dynamic>;
        return LatLng((list[0] as num).toDouble(), (list[1] as num).toDouble());
      }).toList();
    } catch (_) {
      return const [];
    } finally {
      stmt.dispose();
    }
  }

  /// Calcula la ruta óptima entre el Punto A y el Punto B de forma 100% offline.
  /// Devuelve un listado de coordenadas LatLng para dibujar la Polyline y la distancia en metros.
  Future<({List<LatLng> path, double distanceMetres})?> findRoute(
    LatLng start,
    LatLng end,
  ) async {
    await init();
    if (_db == null) return null;

    // Buscar los nodos de la red vial más cercanos al inicio y fin reales
    final startNode = _findNearestNode(start.latitude, start.longitude);
    final endNode = _findNearestNode(end.latitude, end.longitude);

    if (startNode == null || endNode == null) return null;
    if (startNode.id == endNode.id) {
      return (path: [start, end], distanceMetres: _haversineDistance(start.latitude, start.longitude, end.latitude, end.longitude));
    }

    // Inicializar el algoritmo A*
    final openSet = PriorityQueue<_RouteNode>((a, b) => a.fScore.compareTo(b.fScore));
    final allNodes = <int, _RouteNode>{};

    startNode.gScore = 0;
    startNode.fScore = _haversineDistance(startNode.lat, startNode.lng, endNode.lat, endNode.lng);

    openSet.add(startNode);
    allNodes[startNode.id] = startNode;

    final closedSet = <int>{};
    _RouteNode? targetNodeReached;

    // Máximo de iteraciones de salvaguarda para evitar loops infinitos o búsquedas eternas
    int iterations = 0;
    const maxIterations = 8000;

    while (openSet.isNotEmpty && iterations < maxIterations) {
      iterations++;
      final current = openSet.removeFirst();

      if (current.id == endNode.id) {
        targetNodeReached = current;
        break;
      }

      closedSet.add(current.id);

      final neighbors = _getNeighbors(current.id);
      for (final neighborData in neighbors) {
        if (closedSet.contains(neighborData.id)) continue;

        // gScore es la distancia desde el inicio hasta el vecino pasando por current
        final tentativeGScore = current.gScore + neighborData.distancia;

        var neighbor = allNodes[neighborData.id];
        if (neighbor == null) {
          neighbor = _RouteNode(
            id: neighborData.id,
            lat: neighborData.lat,
            lng: neighborData.lng,
          );
          allNodes[neighborData.id] = neighbor;
        }

        if (tentativeGScore < neighbor.gScore) {
          // Este es el mejor camino encontrado hasta ahora hacia este vecino
          neighbor.parent = current;
          neighbor.gScore = tentativeGScore;
          // fScore = gScore + heurística (línea recta al destino final de ruteo)
          neighbor.fScore = tentativeGScore + _haversineDistance(neighbor.lat, neighbor.lng, endNode.lat, endNode.lng);

          if (!openSet.contains(neighbor)) {
            openSet.add(neighbor);
          }
        }
      }
    }

    if (targetNodeReached == null) {
      // Si el grafo no está conectado, hacemos fallback a una línea recta directa
      return (
        path: [start, end],
        distanceMetres: _haversineDistance(start.latitude, start.longitude, end.latitude, end.longitude)
      );
    }

    // Reconstruir el camino óptimo hacia atrás
    final List<int> nodePath = [];
    _RouteNode? curr = targetNodeReached;
    while (curr != null) {
      nodePath.insert(0, curr.id);
      curr = curr.parent;
    }

    // Unir las geometrías detalladas de los tramos
    final List<LatLng> detailedPath = [];
    detailedPath.add(start); // Empezar en la ubicación exacta del usuario

    double totalDistance = 0.0;

    for (int i = 0; i < nodePath.length - 1; i++) {
      final origenId = nodePath[i];
      final destinoId = nodePath[i + 1];

      final segment = _getSegmentGeometry(origenId, destinoId);
      if (segment.isNotEmpty) {
        // Añadir los puntos del segmento evitando duplicar extremos
        for (final pt in segment) {
          if (detailedPath.isEmpty || detailedPath.last != pt) {
            detailedPath.add(pt);
          }
        }
      } else {
        // Fallback si falta geometría por alguna inconsistencia
        final originGeom = allNodes[origenId];
        final destGeom = allNodes[destinoId];
        if (originGeom != null && destGeom != null) {
          final pt = LatLng(destGeom.lat, destGeom.lng);
          if (detailedPath.last != pt) {
            detailedPath.add(pt);
          }
        }
      }
    }

    detailedPath.add(end); // Terminar en la ubicación exacta del cliente

    // Calcular distancia real
    for (int i = 0; i < detailedPath.length - 1; i++) {
      totalDistance += _haversineDistance(
        detailedPath[i].latitude,
        detailedPath[i].longitude,
        detailedPath[i + 1].latitude,
        detailedPath[i + 1].longitude,
      );
    }

    return (path: detailedPath, distanceMetres: totalDistance);
  }
}
