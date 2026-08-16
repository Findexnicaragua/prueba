import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:isp_billing/data/utils/logo_monocromo.dart';

/// El driver de Windows TRAMA las imágenes raster del PDF (el texto, que va
/// vectorial, sale sólido). Por eso el recibo salía con el texto nítido y el
/// logo hecho un enrejado de puntos, aunque el azul del logo sea casi negro
/// (RGB(0,31,108) = 12% de brillo). Sin grises no hay nada que tramar.
///
/// Lo que estos tests protegen: que la salida NO tenga ni un valor intermedio,
/// ni en color ni en transparencia. Un borde suavizado es un gris disfrazado y
/// se trama igual que el resto.
Uint8List _png(img.Image im) => Uint8List.fromList(img.encodePng(im));

({Set<int> colores, Set<int> alphas}) _nivelesDe(Uint8List bytes) {
  final im = img.decodeImage(bytes)!;
  final colores = <int>{};
  final alphas = <int>{};
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      alphas.add(p.a.toInt());
      if (p.a > 0) {
        colores..add(p.r.toInt())..add(p.g.toInt())..add(p.b.toInt());
      }
    }
  }
  return (colores: colores, alphas: alphas);
}

void main() {
  setUp(LogoMonocromo.olvidar);

  test('el azul del logo real se vuelve tinta sólida', () {
    final fuente = img.Image(width: 4, height: 4, numChannels: 4);
    img.fill(fuente, color: img.ColorRgba8(0, 31, 108, 255)); // el azul Mairena
    final r = _nivelesDe(LogoMonocromo.convertir(_png(fuente)));
    expect(r.colores, {0}, reason: 'tiene que quedar negro puro');
    expect(r.alphas, {255}, reason: 'opaco: es tinta');
  });

  test('NO quedan grises ni transparencias parciales', () {
    // Un degradé completo: el caso peor, todo lo que el driver tramaría.
    final fuente = img.Image(width: 256, height: 8, numChannels: 4);
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 256; x++) {
        fuente.setPixelRgba(x, y, x, x, x, x);
      }
    }
    final r = _nivelesDe(LogoMonocromo.convertir(_png(fuente)));
    expect(r.colores.difference({0}), isEmpty,
        reason: 'cualquier valor que no sea 0 se trama');
    expect(r.alphas.difference({0, 255}), isEmpty,
        reason: 'un alpha intermedio es un gris disfrazado');
  });

  test('el fondo claro queda como papel, no como tinta', () {
    final fuente = img.Image(width: 4, height: 4, numChannels: 4);
    img.fill(fuente, color: img.ColorRgba8(245, 245, 245, 255));
    expect(_nivelesDe(LogoMonocromo.convertir(_png(fuente))).alphas, {0});
  });

  test('lo transparente se decide contra el PAPEL blanco, no por su color', () {
    // Un negro totalmente transparente NO es tinta: sobre papel blanco se ve
    // blanco. Sin componer primero, su color diría "negro" y saldría manchón.
    final fuente = img.Image(width: 4, height: 4, numChannels: 4);
    img.fill(fuente, color: img.ColorRgba8(0, 0, 0, 0));
    expect(_nivelesDe(LogoMonocromo.convertir(_png(fuente))).alphas, {0});
  });

  test('bytes ilegibles devuelven el original, no rompen la impresión', () {
    // Un logo tramado es mejor que un recibo sin logo o una excepción.
    final basura = Uint8List.fromList([1, 2, 3, 4, 5]);
    expect(LogoMonocromo.convertir(basura), same(basura));
    expect(LogoMonocromo.convertir(Uint8List(0)), isEmpty);
  });

  test('el memo evita reconvertir en cada recibo', () {
    // Sin memo se re-decodifican y recorren ~680k píxeles POR IMPRESIÓN.
    // (Regla de AUDIT-PROFUNDO §2: mirar la frecuencia, no solo la corrección.)
    final fuente = img.Image(width: 8, height: 8, numChannels: 4);
    img.fill(fuente, color: img.ColorRgba8(0, 31, 108, 255));
    final bytes = _png(fuente);
    expect(LogoMonocromo.convertir(bytes), same(LogoMonocromo.convertir(bytes)),
        reason: 'la segunda llamada tiene que devolver lo ya convertido');
  });

  test('olvidar() fuerza la reconversión (el admin cambió el logo)', () {
    final fuente = img.Image(width: 8, height: 8, numChannels: 4);
    img.fill(fuente, color: img.ColorRgba8(0, 31, 108, 255));
    final bytes = _png(fuente);
    final primera = LogoMonocromo.convertir(bytes);
    LogoMonocromo.olvidar();
    expect(LogoMonocromo.convertir(bytes), isNot(same(primera)));
  });
}
