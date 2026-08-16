import 'package:geolocator/geolocator.dart';

/// Captura de la ubicación GPS del dispositivo.
///
/// Existía la MISMA danza de permisos duplicada en `mapa_screen.dart` y en
/// `mapa_picker_screen.dart`; la orden del técnico (0204) la necesitaba por
/// tercera vez, así que se extrajo acá en vez de copiarla otra vez.
///
/// No toca `context` ni muestra SnackBars a propósito: devuelve un resultado
/// que el llamador decide cómo mostrar. Así se puede usar desde un widget, un
/// repo o un test sin arrastrar el árbol de widgets.
class UbicacionActual {
  const UbicacionActual._();

  /// Pide permiso (si hace falta) y devuelve la posición.
  ///
  /// Nunca lanza por permisos ni por GPS apagado: esos casos vuelven como
  /// [ResultadoUbicacion] con `error` cargado. Sí puede lanzar el plugin en
  /// fallos raros de plataforma, y eso lo captura el propio método.
  static Future<ResultadoUbicacion> obtener() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const ResultadoUbicacion.error(
            'El servicio de GPS está desactivado.');
      }
      var permiso = await Geolocator.checkPermission();
      if (permiso == LocationPermission.denied) {
        permiso = await Geolocator.requestPermission();
        if (permiso == LocationPermission.denied) {
          return const ResultadoUbicacion.error(
              'Permiso de ubicación denegado.');
        }
      }
      if (permiso == LocationPermission.deniedForever) {
        return const ResultadoUbicacion.error(
            'Permiso de ubicación denegado permanentemente. Habilitalo en los '
            'ajustes del teléfono.');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      return ResultadoUbicacion.ok(pos.latitude, pos.longitude);
    } catch (e) {
      return ResultadoUbicacion.error('No se pudo obtener la ubicación: $e');
    }
  }
}

/// Resultado de [UbicacionActual.obtener]: o coordenadas, o un motivo legible.
class ResultadoUbicacion {
  final double? lat;
  final double? lng;
  final String? error;

  const ResultadoUbicacion.ok(double this.lat, double this.lng) : error = null;
  const ResultadoUbicacion.error(this.error)
      : lat = null,
        lng = null;

  bool get exito => error == null;
}
