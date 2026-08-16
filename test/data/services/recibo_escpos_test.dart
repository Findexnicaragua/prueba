import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:isp_billing/data/models/recibo_layout.dart';
import 'package:isp_billing/data/services/impresora/recibo_escpos.dart';

/// El armado del raster ESC/POS salió de `ImpresoraService` para que la
/// impresión DIRECTA de Windows use exactamente el mismo que Android por
/// Bluetooth (2026-07-29).
///
/// Estos tests fijan el contrato de esa salida. El transporte de impresión ya
/// rompió a la flota una vez por "mejorar" el path compartido (v0.22.10-13):
/// acá no se optimiza nada, se protege que siga emitiendo lo mismo.
Uint8List _png(img.Image im) => Uint8List.fromList(img.encodePng(im));

img.Image _lienzo(int w, int h, {int gris = 255}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(gris, gris, gris));
  return im;
}

void main() {
  group('ancho del cabezal según el rollo', () {
    test('80mm son 576 puntos y 58mm son 384', () {
      expect(anchoDotsTermica(80), 576);
      expect(anchoDotsTermica(58), 384);
    });

    test('cualquier ancho >= 80 usa el cabezal grande', () {
      expect(anchoDotsTermica(110), 576);
    });

    test('los anchos legacy (57, 0) caen en el chico', () {
      expect(anchoDotsTermica(57), 384);
      expect(anchoDotsTermica(0), 384);
    });
  });

  group('los comandos del recibo', () {
    test('abren con reset y cierran con avance + corte', () {
      final b = comandosReciboEscPos(_png(_lienzo(576, 40, gris: 0)), 80)!;
      expect(b.take(2), [0x1B, 0x40], reason: 'ESC @ deja la térmica limpia');
      expect(b.sublist(b.length - 6), [0x1B, 0x64, 0x02, 0x1D, 0x56, 0x00],
          reason: 'ESC d 2 (avance) + GS V 0 (corte)');
    });

    test('un PNG ilegible NO rompe la impresión, devuelve null', () {
      expect(comandosReciboEscPos(Uint8List.fromList([1, 2, 3]), 80), isNull);
    });
  });

  group('el raster GS v 0', () {
    test('lleva el ancho en BYTES, no en puntos', () {
      // 576 puntos = 72 bytes por fila. Mandar 576 en el header rompe el
      // ancho y el recibo sale angosto/torcido.
      final r = rasterGsv0(_lienzo(576, 8, gris: 0));
      expect(r.take(4), [0x1D, 0x76, 0x30, 0x00]);
      expect(r[4], 72, reason: 'xL = (576+7)>>3');
      expect(r[5], 0, reason: 'xH');
      expect(r[6], 8, reason: 'yL = filas');
    });

    test('negro = bit encendido (polaridad 1 quema)', () {
      // Invertida, el recibo sale en negativo: fondo quemado y letras blancas.
      final negro = rasterGsv0(_lienzo(8, 1, gris: 0));
      final blanco = rasterGsv0(_lienzo(8, 1, gris: 255));
      expect(negro.last, 0xFF, reason: '8 puntos negros = todos los bits');
      expect(blanco.last, 0x00);
    });

    test('parte en bandas de 255 filas', () {
      // Algunas térmicas truncan un raster muy alto: hay que trocearlo.
      final r = rasterGsv0(_lienzo(8, 300, gris: 0));
      final cabeceras = <int>[];
      for (var i = 0; i + 3 < r.length; i++) {
        if (r[i] == 0x1D && r[i + 1] == 0x76 && r[i + 2] == 0x30) {
          cabeceras.add(r[i + 6]);
          i += 7 + 1 * r[i + 6]; // saltar los datos de esta banda
        }
      }
      expect(cabeceras, [255, 45], reason: '300 filas = 255 + 45');
    });

    test('el umbral es 0.5: el gris medio-oscuro es tinta', () {
      expect(rasterGsv0(_lienzo(8, 1, gris: 100)).last, 0xFF);
      expect(rasterGsv0(_lienzo(8, 1, gris: 200)).last, 0x00);
    });
  });

  group('el procesado de la captura', () {
    test('lleva la imagen al ancho EXACTO del cabezal', () {
      final r = procesarParaTermica(_png(_lienzo(300, 50, gris: 0)), 80);
      expect(r!.width, 576);
    });

    test('lo transparente se vuelve BLANCO, no negro', () {
      // Sin aplanar sobre blanco, el alpha de la captura se leía como negro y
      // la térmica quemaba el fondo entero: recibo en NEGATIVO.
      final im = img.Image(width: 576, height: 20, numChannels: 4);
      img.fill(im, color: img.ColorRgba8(0, 0, 0, 0)); // transparente
      final r = procesarParaTermica(_png(im), 80)!;
      expect(r.getPixel(10, 10).luminanceNormalized, greaterThan(0.9),
          reason: 'transparente tiene que quedar como papel, no como tinta');
    });

    test('recorta el blanco de arriba y abajo', () {
      // La captura viene con alto holgado (targetSize 5000): sin recorte se
      // imprimiría medio metro de papel en blanco por recibo.
      final im = _lienzo(576, 400);
      img.fillRect(im, x1: 0, y1: 200, x2: 575, y2: 220,
          color: img.ColorRgb8(0, 0, 0));
      final r = procesarParaTermica(_png(im), 80)!;
      expect(r.height, lessThan(60), reason: 'debe quedar la franja + padding');
      expect(r.height, greaterThan(20), reason: 'sin comerse el contenido');
    });

    test('una captura toda blanca no se recorta a nada', () {
      final r = procesarParaTermica(_png(_lienzo(576, 100)), 80)!;
      expect(r.height, 100);
    });
  });

  group('la prueba de impresión', () {
    test('es ASCII puro: no depende del codepage del modelo', () {
      final b = comandosPruebaEscPos(80);
      expect(b.every((x) => x < 128), isTrue);
    });

    test('abre con reset y cierra con corte', () {
      final b = comandosPruebaEscPos(80);
      expect(b.take(2), [0x1B, 0x40]);
      expect(b.sublist(b.length - 3), [0x1D, 0x56, 0x00]);
    });
  });

  group('la regla de ancho MIDE el cabezal', () {
    // La regla solo sirve si cada línea mide EXACTAMENTE lo que dice su número:
    // el operador lee el último número completo y ese pasa a ser el ancho. Si
    // una línea midiera distinto, la medición mentiría y el recibo seguiría
    // cortándose (el bug que la regla viene a cerrar).
    test('cada línea numerada mide EXACTAMENTE su número de caracteres', () {
      final b = comandosReglaAnchoEscPos(80);
      // Reconstruir las líneas imprimibles (ASCII entre saltos de línea).
      final lineas = <String>[];
      final actual = StringBuffer();
      for (final x in b) {
        if (x == 0x0A) {
          lineas.add(actual.toString());
          actual.clear();
        } else if (x >= 0x20 && x < 0x7F) {
          actual.writeCharCode(x);
        }
      }
      // Las líneas de la regla llevan su número en AMBOS extremos (así se
      // distingue "trunca" de "envuelve" — si no, la regla podría mentir).
      final numeradas =
          lineas.where((l) => RegExp(r'^\d+-+\d+$').hasMatch(l)).toList();
      expect(numeradas, isNotEmpty, reason: 'la regla debe emitir sus líneas');
      for (final l in numeradas) {
        final m = RegExp(r'^(\d+)-+(\d+)$').firstMatch(l)!;
        expect(m.group(1), m.group(2),
            reason: 'ambos extremos deben rotular el MISMO número');
        expect(l.length, int.parse(m.group(1)!),
            reason: 'la línea rotulada ${m.group(1)} debe medir eso');
      }
      // Y ninguna puede pasarse del cabezal nominal (48 chars en 80mm).
      expect(numeradas.map((l) => l.length).reduce((a, c) => a > c ? a : c), 48);
    });

    test('es ASCII puro y cierra con corte (mide el cabezal, no el firmware)',
        () {
      final b = comandosReglaAnchoEscPos(80);
      expect(b.every((x) => x < 128), isTrue);
      expect(b.take(2), [0x1B, 0x40]);
      expect(b.sublist(b.length - 3), [0x1D, 0x56, 0x00]);
    });

    test('en 58mm la regla se topa en 32 caracteres', () {
      final b = comandosReglaAnchoEscPos(58);
      final lineas = <String>[];
      final actual = StringBuffer();
      for (final x in b) {
        if (x == 0x0A) {
          lineas.add(actual.toString());
          actual.clear();
        } else if (x >= 0x20 && x < 0x7F) {
          actual.writeCharCode(x);
        }
      }
      final numeradas =
          lineas.where((l) => RegExp(r'^\d+-+\d+$').hasMatch(l)).toList();
      expect(numeradas.map((l) => l.length).reduce((a, c) => a > c ? a : c), 32);
    });
  });

  group('los ajustes de Windows NO tocan a Android', () {
    // La promesa: llamar sin los parámetros opcionales tiene que emitir los
    // MISMOS bytes que antes de agregarlos. El transporte Bluetooth llama así,
    // y ya rompió a la flota una vez por cambiarle el raster (v0.22.10-13).
    test('sin parámetros no se emite ningún comando nuevo', () {
      final b = comandosReciboEscPos(_png(_lienzo(576, 24, gris: 0)), 80)!;
      // Tras el reset viene el raster directo: ni densidad (ESC 7) ni margen (GS L).
      expect(b.take(2), [0x1B, 0x40]);
      expect(b[2], 0x1D, reason: 'debe seguir el GS v 0 del raster');
      expect(b.sublist(2, 6), [0x1D, 0x76, 0x30, 0x00]);
    });

    test('el umbral por defecto es el de Android', () {
      expect(umbralTintaDefault, 0.5);
      final conDefault = rasterGsv0(_lienzo(8, 1, gris: 100));
      final explicito = rasterGsv0(_lienzo(8, 1, gris: 100), umbral: 0.5);
      expect(conDefault, explicito);
    });

    test('subir el umbral engrosa: un gris claro pasa a ser tinta', () {
      // gris 160 NO es tinta a 0.5, SÍ lo es a 0.7 → así se arregla la letra fina.
      expect(rasterGsv0(_lienzo(8, 1, gris: 160)).last, 0x00);
      expect(rasterGsv0(_lienzo(8, 1, gris: 160), umbral: 0.7).last, 0xFF);
    });
  });

  group('comandos de ajuste de Windows', () {
    test('margen 0 no emite nada; con valor emite GS L', () {
      expect(comandosMargenIzquierdo(0), isEmpty);
      expect(comandosMargenIzquierdo(-5), isEmpty);
      expect(comandosMargenIzquierdo(24), [0x1D, 0x4C, 24, 0]);
      // Más de 255 dots se parte en dos bytes.
      expect(comandosMargenIzquierdo(300), [0x1D, 0x4C, 44, 1]);
    });

    test('la densidad es opt-in: null no emite nada', () {
      // Una térmica que no entienda ESC 7 escupiría basura, así que solo se
      // manda si alguien lo configuró a propósito.
      expect(comandosDensidad(null), isEmpty);
      expect(comandosDensidad(80), [0x1B, 0x37, 7, 80, 2]);
    });

    test('el calor se topa en el rango que acepta la impresora', () {
      expect(comandosDensidad(1)[3], 3);
      expect(comandosDensidad(999)[3], 255);
    });
  });

  group('modo texto nativo · el tamaño del diseñador aplica', () {
    // Antes el modo nativo ignoraba los tamaños: todo salía en el base y solo
    // se distinguía por la negrita. Ahora los mapea al comando de tamaño de
    // carácter del ESC/POS (GS !), que soporta hasta 8x en alto y ancho.
    test('los 5 niveles del diseñador mapean a tamaños de impresora', () {
      // chico y normal comparten el base: la impresora no tiene nada más chico.
      expect(tamanoEscPos(ReciboTextoSize.chico), (alto: 1, ancho: 1));
      expect(tamanoEscPos(ReciboTextoSize.normal), (alto: 1, ancho: 1));
      expect(tamanoEscPos(ReciboTextoSize.grande), (alto: 2, ancho: 1));
      expect(tamanoEscPos(ReciboTextoSize.extraGrande), (alto: 2, ancho: 2));
      expect(tamanoEscPos(ReciboTextoSize.gigante), (alto: 3, ancho: 2));
    });

    test('el ANCHO nunca pasa de 2x', () {
      // Duplicar el ancho parte a la mitad los caracteres por línea (48 -> 24
      // en 80mm). Más que eso envolvería los bloques largos.
      for (final t in ReciboTextoSize.values) {
        expect(tamanoEscPos(t).ancho, lessThanOrEqualTo(2),
            reason: '$t se pasaría de ancho y envolvería');
      }
    });

    test('el alto crece de forma monótona con el nivel', () {
      final alturas =
          ReciboTextoSize.values.map((t) => tamanoEscPos(t).alto).toList();
      for (var i = 1; i < alturas.length; i++) {
        expect(alturas[i], greaterThanOrEqualTo(alturas[i - 1]),
            reason: 'un nivel más grande no puede imprimir más chico');
      }
    });
  });

  group('el margen se descuenta de los DOS lados', () {
    // v0.30.0 estrenó el margen con 3mm de default pero NADIE achicaba el
    // contenido: el `GS L` corría el recibo a la derecha y los últimos puntos
    // caían FUERA del papel. Se veía como "el borde derecho cortado".
    test('sin margen, el recibo usa el cabezal entero', () {
      expect(procesarParaTermica(_png(_lienzo(576, 40, gris: 0)), 80)!.width,
          576);
      expect(charsPorLineaConMargen(80, 0), 48);
    });

    test('procesarParaTermica reescala al cabezal y NO hornea margen', () {
      // El margen del recibo va como padding EN el widget (ReciboTicket.
      // margenHorizontal), renderizado a TAMAÑO COMPLETO. procesarParaTermica solo
      // reescala al ancho del cabezal — no encoge ni agrega bordes blancos.
      final im = procesarParaTermica(_png(_lienzo(576, 40, gris: 0)), 80,
          margenDots: 24)!;
      expect(im.width, 576, reason: 'reescala al cabezal entero');
      // Era todo negro → sin bordes horneados, el borde sigue siendo contenido.
      expect(im.getPixel(4, im.height ~/ 2).luminanceNormalized, lessThan(0.5),
          reason: 'sin margen horneado: el borde es tinta, no papel');
      expect(charsPorLineaConMargen(80, 24), 44);
    });

    test('un margen absurdo no deja el recibo en nada', () {
      expect(charsPorLineaConMargen(80, 999), greaterThanOrEqualTo(20));
      expect(procesarParaTermica(_png(_lienzo(576, 40, gris: 0)), 80,
              margenDots: 999)!.width,
          greaterThan(0));
    });

    test('58mm también', () {
      expect(charsPorLineaConMargen(58, 0), 32);
      expect(charsPorLineaConMargen(58, 24), 28); // (384-48)/12
    });
  });

  group('modo compatible de imagen (ESC *) — opt-in por dispositivo', () {
    // Hay térmicas que reciben el GS v 0 moderno y lo imprimen como caracteres
    // sueltos en vez de dibujarlo (foto del campo 2026-07-31). ESC * es el
    // comando viejo que esas SÍ entienden.
    test('sin el flag NO cambia nada: sigue saliendo el raster de siempre', () {
      final b = comandosReciboEscPos(_png(_lienzo(576, 24, gris: 0)), 80)!;
      expect(b.sublist(2, 6), [0x1D, 0x76, 0x30, 0x00]);
    });

    test('con el flag sale ESC * y NO GS v 0', () {
      final b = comandosReciboEscPos(_png(_lienzo(576, 24, gris: 0)), 80,
          compatible: true)!;
      expect(b.contains(0x1D) && _tieneSecuencia(b, [0x1D, 0x76, 0x30]), isFalse,
          reason: 'no puede quedar el raster moderno');
      expect(_tieneSecuencia(b, [0x1B, 0x2A, 33]), isTrue);
    });

    test('fija el interlineado en 24 y lo devuelve al default', () {
      final b = bitImageEscAsterisco(_lienzo(8, 24, gris: 0));
      expect(b.take(3), [0x1B, 0x33, 24], reason: 'sin esto sale rayado');
      expect(b.sublist(b.length - 2), [0x1B, 0x32]);
    });

    test('el ancho va en COLUMNAS (no en bytes como el raster)', () {
      // ESC * manda 3 bytes por columna, así que nL/nH son puntos, no bytes.
      final b = bitImageEscAsterisco(_lienzo(576, 24, gris: 0));
      expect(b.sublist(3, 6), [0x1B, 0x2A, 33]);
      expect(b[6], 576 & 0xFF);
      expect(b[7], 576 >> 8);
    });

    test('negro = bit encendido, igual que el raster', () {
      final negro = bitImageEscAsterisco(_lienzo(1, 24, gris: 0));
      final blanco = bitImageEscAsterisco(_lienzo(1, 24, gris: 255));
      expect(negro.sublist(8, 11), [0xFF, 0xFF, 0xFF]);
      expect(blanco.sublist(8, 11), [0x00, 0x00, 0x00]);
    });

    test('una banda incompleta no se sale de la imagen', () {
      // 10 filas = media banda: las 14 que faltan quedan en blanco, sin leer
      // píxeles inexistentes.
      expect(() => bitImageEscAsterisco(_lienzo(8, 10, gris: 0)),
          returnsNormally);
    });
  });
}

bool _tieneSecuencia(List<int> b, List<int> seq) {
  for (var i = 0; i + seq.length <= b.length; i++) {
    var ok = true;
    for (var j = 0; j < seq.length; j++) {
      if (b[i + j] != seq[j]) { ok = false; break; }
    }
    if (ok) return true;
  }
  return false;
}
