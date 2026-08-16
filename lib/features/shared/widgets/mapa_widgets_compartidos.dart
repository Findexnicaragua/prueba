import 'package:flutter/material.dart';

/// Widgets de mapa compartidos entre el mapa principal de clientes
/// (`mapa_screen.dart`) y el selector de ubicación (`mapa_picker_screen.dart`),
/// para que ambos se vean y comporten idéntico. Extraídos del mapa principal.

/// Marcador animado de la ubicación actual del usuario: punto azul con halo
/// pulsante, estilo Google Maps. Se usa como `child` de un `Marker`.
class UbicacionActualMarker extends StatefulWidget {
  const UbicacionActualMarker({super.key});

  @override
  State<UbicacionActualMarker> createState() => _UbicacionActualMarkerState();
}

class _UbicacionActualMarkerState extends State<UbicacionActualMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final value = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 14 + (26 * value),
              height: 14 + (26 * value),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue.withValues(alpha: 0.4 * (1.0 - value)),
              ),
            ),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue.shade600,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 3,
                    offset: Offset(0, 1.5),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Banner de atribución del proveedor de tiles (OSM / Esri). Va como hijo del
/// `FlutterMap` (se ancla abajo-izquierda).
class MapAttributionBanner extends StatelessWidget {
  const MapAttributionBanner({super.key, required this.satelite});

  /// Cuando true, el tile es Esri World Imagery → atribución de Esri.
  final bool satelite;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white70,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              satelite
                  ? '© Esri, Maxar, Earthstar Geographics'
                  : '© OpenStreetMap',
              style: const TextStyle(fontSize: 10, color: Colors.black87),
            ),
          ),
        ),
      ),
    );
  }
}
