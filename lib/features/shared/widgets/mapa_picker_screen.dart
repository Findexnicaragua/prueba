import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/services/map_tile_cache.dart';
import '../../../data/utils/errores.dart';
import 'mapa_widgets_compartidos.dart';

/// Pantalla full-screen para elegir coordenadas tocando el mapa. Compartida por
/// el form de cliente y el de nodo de red. Devuelve el `LatLng` elegido vía
/// `Navigator.pop`, o null si se cancela. Usa el caché de tiles offline.
///
/// Mantiene la MISMA experiencia que el mapa principal de clientes
/// (`mapa_screen.dart`): rotación con dos dedos + brújula para volver al norte,
/// pin de ubicación actual estilo Google Maps + botón "centrar en mi ubicación",
/// y toggle calle ↔ satélite con su atribución.
class MapaPickerScreen extends StatefulWidget {
  const MapaPickerScreen({super.key, required this.inicial});
  final LatLng inicial;

  @override
  State<MapaPickerScreen> createState() => _MapaPickerScreenState();
}

class _MapaPickerScreenState extends State<MapaPickerScreen> {
  late LatLng _punto;
  final _mapController = MapController();

  // Toggle de capa: false = calle (OSM), true = satélite (Esri).
  bool _satelite = false;
  // Ángulo de rotación de la cámara (para mostrar/ocultar la brújula).
  double _rotationAngle = 0.0;

  Position? _currentPosition;
  StreamSubscription<Position>? _positionSubscription;
  // Evita orfanar suscripciones si _initLocation se dispara concurrente (taps
  // rápidos en "centrar" antes de que el primer init asigne _positionSubscription).
  bool _initLocationEnCurso = false;

  @override
  void initState() {
    super.initState();
    _punto = widget.inicial;
    _initLocation();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  /// Suscribe al stream de posición para mostrar el pin de ubicación actual.
  /// Defensivo en Windows/sin GPS: si algo falla, simplemente no se muestra el
  /// pin (el picker sigue funcionando para tocar y elegir un punto).
  Future<void> _initLocation() async {
    if (_initLocationEnCurso || _positionSubscription != null) return;
    _initLocationEnCurso = true;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(
        (position) {
          if (mounted) setState(() => _currentPosition = position);
        },
        onError: (e) {
          if (kDebugMode) debugPrint('Error en stream de ubicación: $e');
        },
      );

      final lastPos = await Geolocator.getLastKnownPosition();
      if (lastPos != null && mounted && _currentPosition == null) {
        setState(() => _currentPosition = lastPos);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error _initLocation: $e');
    } finally {
      _initLocationEnCurso = false;
    }
  }

  /// Centra la cámara en la ubicación actual (no cambia el punto elegido: el
  /// usuario igual debe tocar para fijar el marcador).
  Future<void> _centrarEnUbicacion() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('El servicio de GPS está desactivado.')),
          );
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Permiso de ubicación denegado.')),
            );
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Permiso de ubicación denegado permanentemente.')),
          );
        }
        return;
      }

      if (_positionSubscription == null) _initLocation();

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (mounted) {
        setState(() => _currentPosition = pos);
        _mapController.move(LatLng(pos.latitude, pos.longitude), 16.0);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'No se pudo obtener la ubicación: ${mensajeErrorHumano(e)}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Seleccionar ubicación'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () => Navigator.pop(context, _punto),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _punto,
                    initialZoom: 13,
                    maxZoom: 20,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all,
                    ),
                    onTap: (_, p) => setState(() => _punto = p),
                    onMapEvent: (event) {
                      if (event.camera.rotation != _rotationAngle) {
                        setState(() => _rotationAngle = event.camera.rotation);
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: _satelite
                          ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                          : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.ispbilling.app',
                      // Ver nota en mapa_screen.dart: satélite Esri hace upscale
                      // desde z17 (en vez del gris "Map data not yet available").
                      maxNativeZoom: _satelite ? 17 : 19,
                      tileProvider: MapTileCache.instance.tileProvider(),
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _punto,
                          width: 40,
                          height: 40,
                          child: Icon(Icons.location_on,
                              color: Theme.of(context).colorScheme.error,
                              size: 40),
                        ),
                        if (_currentPosition != null)
                          Marker(
                            point: LatLng(_currentPosition!.latitude,
                                _currentPosition!.longitude),
                            width: 40,
                            height: 40,
                            child: const UbicacionActualMarker(),
                          ),
                      ],
                    ),
                    MapAttributionBanner(satelite: _satelite),
                  ],
                ),
                // Botón flotante para alternar calle ↔ satélite.
                Positioned(
                  top: 8,
                  right: 8,
                  child: SafeArea(
                    bottom: false,
                    child: FloatingActionButton.small(
                      heroTag: 'picker_capa_toggle',
                      tooltip: _satelite ? 'Ver calles' : 'Ver satélite',
                      onPressed: () => setState(() => _satelite = !_satelite),
                      child: Icon(_satelite ? Icons.map : Icons.layers),
                    ),
                  ),
                ),
                // Botón de brújula (solo si está rotado).
                if (_rotationAngle != 0.0)
                  Positioned(
                    top: 56,
                    right: 8,
                    child: SafeArea(
                      bottom: false,
                      child: FloatingActionButton.small(
                        heroTag: 'picker_compass',
                        tooltip: 'Restablecer orientación al norte',
                        onPressed: () {
                          _mapController.rotate(0.0);
                          setState(() => _rotationAngle = 0.0);
                        },
                        child: Transform.rotate(
                          angle: -_rotationAngle * (pi / 180.0),
                          child: const Icon(Icons.explore),
                        ),
                      ),
                    ),
                  ),
                // Botón "centrar en mi ubicación".
                Positioned(
                  bottom: 16,
                  right: 16,
                  child: SafeArea(
                    child: FloatingActionButton.small(
                      heroTag: 'picker_mi_ubicacion',
                      tooltip: 'Centrar en mi ubicación',
                      onPressed: _centrarEnUbicacion,
                      child: const Icon(Icons.my_location),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Lat: ${_punto.latitude.toStringAsFixed(6)}, '
              'Lng: ${_punto.longitude.toStringAsFixed(6)}',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
