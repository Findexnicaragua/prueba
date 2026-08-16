import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:isp_billing/data/utils/logo_termica.dart';

void main() {
  // Valida el HÍBRIDO de `procesarLogoTermica`: los extremos van a negro/blanco
  // sólido y la banda de tonos medios se dithera (mezcla) → gris. Es la garantía
  // de que el naranja (tono medio) sale como gris en vez de perderse a blanco,
  // sin ensuciar los sólidos.
  test('hibrido: negro solido, blanco solido, y gris (stipple) en banda media',
      () {
    // 24×30: 3 bandas horizontales de 10px → negro (0) / medio (150 ≈ 0.59) /
    // blanco (255).
    final src = img.Image(width: 24, height: 30);
    for (var y = 0; y < 30; y++) {
      final v = y < 10 ? 0 : (y < 20 ? 150 : 255);
      for (var x = 0; x < 24; x++) {
        src.setPixelRgb(x, y, v, v, v);
      }
    }
    final png = Uint8List.fromList(img.encodePng(src));

    final out = procesarLogoTermica(png, alturaDots: 30);
    expect(out, isNotNull);
    final res = img.decodeImage(out!)!;
    expect(res.height, 30);

    int negros(int y0, int y1) {
      var n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = 0; x < res.width; x++) {
          if (res.getPixel(x, y).luminanceNormalized < 0.5) n++;
        }
      }
      return n;
    }

    final porBanda = res.width * 10;
    // Banda oscura → TODO negro (sólido nítido).
    expect(negros(0, 10), porBanda, reason: 'la banda negra debe salir sólida');
    // Banda clara → NADA negro (blanco).
    expect(negros(20, 30), 0, reason: 'la banda blanca debe salir blanca');
    // Banda media → MEZCLA (ni todo negro ni todo blanco) = gris por stipple.
    final medio = negros(10, 20);
    expect(medio, greaterThan(0),
        reason: 'el tono medio NO debe perderse a blanco');
    expect(medio, lessThan(porBanda),
        reason: 'el tono medio NO debe volverse negro sólido');
  });

  test('PNG inválido devuelve null (no rompe la impresión)', () {
    final out = procesarLogoTermica(Uint8List.fromList([1, 2, 3, 4]),
        alturaDots: 60);
    expect(out, isNull);
  });
}
