import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:isp_billing/data/services/imagen_compresion.dart';

/// Genera un JPEG sintético de [w]x[h] con ruido (gradiente) para que el
/// peso sea realista (una imagen lisa comprime "demasiado bien" y no
/// ejercita la escalera de calidad).
Uint8List _jpegSintetico(int w, int h, {int quality = 95}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, (x * 7 + y * 3) % 256, (x + y * 11) % 256,
          (x * 13 + y * 5) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

/// Gradiente suave: comprime como una foto real (el ruido puro de
/// [_jpegSintetico] es el peor caso teórico de JPEG y no representa fotos).
Uint8List _jpegGradiente(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, x * 255 ~/ w, y * 255 ~/ h, 128);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

Uint8List _pngConAlpha(int w, int h) {
  final image = img.Image(width: w, height: h, numChannels: 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgba(x, y, 200, 50, 50, x.isEven ? 128 : 255);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('comprimirImagen', () {
    test('reduce dimensiones y peso de una foto grande', () async {
      final original = _jpegSintetico(3000, 2000);
      final out = await comprimirImagen(original, maxLado: 1920, calidad: 85);

      expect(out.ext, 'jpg');
      expect(out.mime, 'image/jpeg');
      expect(out.bytes.length, lessThan(original.length));

      final decoded = img.decodeImage(out.bytes)!;
      expect(decoded.width, lessThanOrEqualTo(1920));
      expect(decoded.height, lessThanOrEqualTo(1920));
      // Mantiene aspecto 3:2 (±1 px por redondeo).
      expect((decoded.width / decoded.height - 1.5).abs(), lessThan(0.01));
    });

    test('passthrough: JPEG chico dentro de límites vuelve intacto', () async {
      final original = _jpegSintetico(800, 600, quality: 80);
      final out = await comprimirImagen(original, maxLado: 1920, calidad: 85);

      expect(out.bytes, equals(original));
      expect(out.ext, 'jpg');
    });

    test('respeta maxBytes en una imagen compresible', () async {
      final original = _jpegGradiente(3000, 3000);
      const tope = 250 * 1024;
      final out = await comprimirImagen(
        original,
        maxLado: 1920,
        calidad: 85,
        maxBytes: tope,
      );

      expect(out.bytes.length, lessThanOrEqualTo(tope));
    });

    test('si NADA cumple maxBytes devuelve el intento más liviano', () async {
      // Ruido puro = peor caso de JPEG: ningún escalón baja de 50 KB. El
      // contrato es best-effort (el límite del bucket sigue siendo la red).
      final original = _jpegSintetico(3000, 3000);
      final out = await comprimirImagen(
        original,
        maxLado: 1920,
        calidad: 85,
        maxBytes: 50 * 1024,
      );

      expect(out.bytes.length, lessThan(original.length));
      final decoded = img.decodeImage(out.bytes)!;
      // Bajó hasta el último escalón de la escalera (1280 px).
      expect(decoded.width, lessThanOrEqualTo(1280));
    });

    test('PNG con alpha → JPEG compuesto sobre blanco (sin mantenerPng)',
        () async {
      final original = _pngConAlpha(1000, 1000);
      final out = await comprimirImagen(original, maxLado: 1920, calidad: 85);

      expect(out.ext, 'jpg');
      expect(out.mime, 'image/jpeg');
      final decoded = img.decodeImage(out.bytes)!;
      expect(decoded.width, 1000);
    });

    test('mantenerPng convierte un JPEG chico a PNG REAL (logo)', () async {
      // Logo JPEG 400x400: el PNG re-encodeado pesa MÁS que el JPEG, pero el
      // contrato de mantenerPng es PNG real (se sube como logo.png con
      // contentType image/png) — el fallback "preferir original" no aplica.
      final original = _jpegSintetico(400, 400, quality: 80);
      final out = await comprimirImagen(
        original,
        maxLado: 800,
        calidad: 85,
        mantenerPng: true,
        maxBytes: 950 * 1024,
      );

      expect(out.ext, 'png');
      expect(out.mime, 'image/png');
      // Magic bytes PNG (\x89PNG).
      expect(out.bytes[0], 0x89);
      expect(out.bytes[1], 0x50);
    });

    test('mantenerPng conserva formato PNG y redimensiona', () async {
      final original = _pngConAlpha(1200, 1200);
      final out = await comprimirImagen(
        original,
        maxLado: 800,
        calidad: 85,
        mantenerPng: true,
      );

      expect(out.ext, 'png');
      expect(out.mime, 'image/png');
      final decoded = img.decodeImage(out.bytes)!;
      expect(decoded.width, lessThanOrEqualTo(800));
    });

    test('bytes no decodificables vuelven intactos (fallback)', () async {
      final basura = Uint8List.fromList(List.generate(64, (i) => i));
      final out = await comprimirImagen(basura);

      expect(out.bytes, equals(basura));
    });

    test('orientación EXIF se hornea (la foto no queda acostada)', () async {
      // JPEG 1200x800 con EXIF orientation=6 (90° CW): el viewer "correcto"
      // la muestra 800x1200. Tras comprimir, los píxeles ya deben venir
      // rotados (800 de ancho) sin depender del EXIF.
      final base = img.Image(width: 1200, height: 800);
      img.fill(base, color: img.ColorRgb8(10, 200, 30));
      base.exif.imageIfd.orientation = 6;
      final original =
          Uint8List.fromList(img.encodeJpg(base, quality: 95));

      final out = await comprimirImagen(original, maxLado: 1920, calidad: 85);
      final decoded = img.decodeImage(out.bytes)!;
      expect(decoded.width, 800);
      expect(decoded.height, 1200);
    });
  });
}
