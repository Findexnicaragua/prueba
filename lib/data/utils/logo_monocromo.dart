import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Convierte el logo a blanco y negro PURO para el recibo térmico.
///
/// ## Por qué hace falta
///
/// El PDF del recibo lleva el texto como VECTORES y el logo como IMAGEN. El
/// driver de Windows los trata distinto: los vectores los manda en negro sólido
/// y a las imágenes les aplica una TRAMA de puntos. Por eso el recibo salía con
/// el texto nítido y el logo hecho un enrejado, aunque el logo fuera casi negro
/// (el azul de Telecable Mairena es RGB(0,31,108) = 12% de brillo).
///
/// La trama existe para representar grises con un cabezal que solo sabe quemar
/// o no quemar. Si la imagen no tiene grises, no hay nada que tramar: cada píxel
/// es tinta o es papel, y sale sólido.
///
/// ## Qué hace
///
/// Compone sobre blanco (el papel), y todo lo que quede más oscuro que [umbral]
/// pasa a negro opaco; el resto, a transparente. Sin valores intermedios: ni un
/// gris, ni un alpha parcial (los bordes suavizados son grises disfrazados y se
/// traman igual).
///
/// ## Alcance
///
/// Solo el RECIBO. Los reportes PDF del admin siguen con el logo a color — se
/// leen en pantalla o se imprimen en láser, donde el color es una ventaja y no
/// hay trama que evitar. El camino térmico de Android tampoco pasa por acá: ese
/// captura el widget y ya rasteriza bien (y no se toca — ver la lección de
/// v0.22.10-13 en `impresora_service_io.dart`).
class LogoMonocromo {
  /// Umbral de corte, sobre 255. Un logo tiene que ser legible en papel: lo que
  /// esté por debajo de este brillo es tinta. 160 deja pasar como tinta los
  /// azules/grises corporativos y descarta fondos claros.
  static const int umbralDefault = 160;

  // Memo de una sola entrada: el logo cambia muy de vez en cuando, pero esta
  // conversión corre en CADA recibo. Sin el memo se re-decodifica y se recorre
  // ~680k píxeles por impresión. Con él, una vez por corrida de la app.
  // (Regla de AUDIT-PROFUNDO §2: mirar la frecuencia, no solo la corrección.)
  static Uint8List? _entradaMemo;
  static Uint8List? _salidaMemo;

  /// Olvida el memo. Para tests y para cuando el admin cambia el logo.
  static void olvidar() {
    _entradaMemo = null;
    _salidaMemo = null;
  }

  /// Devuelve el logo en blanco y negro puro. Si no se puede decodificar,
  /// devuelve el original: un logo tramado es mejor que ningún logo.
  static Uint8List convertir(Uint8List origen, {int umbral = umbralDefault}) {
    if (origen.isEmpty) return origen;
    if (identical(_entradaMemo, origen) && _salidaMemo != null) {
      return _salidaMemo!;
    }
    try {
      final fuente = img.decodeImage(origen);
      if (fuente == null) return origen;

      final salida = img.Image(
          width: fuente.width, height: fuente.height, numChannels: 4);
      for (var y = 0; y < fuente.height; y++) {
        for (var x = 0; x < fuente.width; x++) {
          final p = fuente.getPixel(x, y);
          final a = p.a / 255.0;
          // Compuesto sobre el papel BLANCO antes de decidir. Sin esto, un
          // logo claro sobre transparente daría "tinta" por su alpha bajo.
          final luma = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b) * a +
              255 * (1 - a);
          final esTinta = luma < umbral;
          salida.setPixelRgba(x, y, 0, 0, 0, esTinta ? 255 : 0);
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(salida));
      _entradaMemo = origen;
      _salidaMemo = bytes;
      return bytes;
    } catch (e) {
      if (kDebugMode) debugPrint('LogoMonocromo.convertir: $e');
      return origen;
    }
  }
}
