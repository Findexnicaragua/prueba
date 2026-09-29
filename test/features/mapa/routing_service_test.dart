import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:isp_billing/features/mapa/servicios/routing_service.dart';
import 'package:isp_billing/features/mapa/servicios/osrm_routing_service.dart';

void main() {
  group('RoutingService & RouteResult Tests', () {
    test('RouteResult formatea distancias correctamente', () {
      const rutaCorta = RouteResult(
        path: [LatLng(12.13, -86.25), LatLng(12.14, -86.25)],
        distanceMetres: 450.2,
        isOffline: false,
        isFallback: false,
      );
      expect(rutaCorta.distanciaFormateada, '450 m');

      const rutaLarga = RouteResult(
        path: [LatLng(12.13, -86.25), LatLng(12.20, -86.25)],
        distanceMetres: 3450.8,
        isOffline: true,
        isFallback: false,
      );
      expect(rutaLarga.distanciaFormateada, '3.5 km');
    });

    test('RoutingService responde y no genera rutas nulas ante puntos válidos', () async {
      const start = LatLng(12.1364, -86.2513);
      const end = LatLng(12.1420, -86.2450);

      final route = await RoutingService.instance.findRoute(start, end);

      expect(route, isNotNull);
      expect(route!.path.length, greaterThanOrEqualTo(2));
      expect(route.distanceMetres, greaterThan(0));
      expect(route.path.first.latitude, closeTo(start.latitude, 0.001));
      expect(route.path.last.latitude, closeTo(end.latitude, 0.001));
    });

    test('RoutingService utiliza caché en memoria para llamadas subsecuentes', () async {
      const start = LatLng(12.1200, -86.2600);
      const end = LatLng(12.1250, -86.2650);

      final sw1 = Stopwatch()..start();
      final route1 = await RoutingService.instance.findRoute(start, end);
      sw1.stop();

      final sw2 = Stopwatch()..start();
      final route2 = await RoutingService.instance.findRoute(start, end);
      sw2.stop();

      expect(route1, isNotNull);
      expect(route2, isNotNull);
      expect(route1!.distanceMetres, equals(route2!.distanceMetres));
      expect(route1.path.length, equals(route2.path.length));
      // La llamada en caché debe ser prácticamente instantánea (< 50 ms)
      expect(sw2.elapsedMilliseconds, lessThan(50));
    });

    test('OsrmRoutingService maneja desconexiones y no lanza excepciones no controladas', () async {
      final service = OsrmRoutingService.instance;
      // Puntos en coordenadas válidas
      const start = LatLng(12.1000, -86.2000);
      const end = LatLng(12.1050, -86.2050);

      // No debe lanzar error ni crashear aunque no haya red o falle el endpoint
      expect(() async => await service.findRoute(start, end), returnsNormally);
    });
  });
}
