import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Matriz Bayer 8×8 (dither ordenado). Valores 0..63; el umbral por celda es
/// `(valor + 0.5) / 64`. A diferencia del error-diffusion (Floyd-Steinberg), el
/// dither ordenado NO propaga error → los sólidos quedan LIMPIOS y solo la banda
/// de tonos medios se convierte en un patrón regular de gris.
const _bayer8 = <List<int>>[
  [0, 32, 8, 40, 2, 34, 10, 42],
  [48, 16, 56, 24, 50, 18, 58, 26],
  [12, 44, 4, 36, 14, 46, 6, 38],
  [60, 28, 52, 20, 62, 30, 54, 22],
  [3, 35, 11, 43, 1, 33, 9, 41],
  [51, 19, 59, 27, 49, 17, 57, 25],
  [15, 47, 7, 39, 13, 45, 5, 37],
  [63, 31, 55, 23, 61, 29, 53, 21],
];

/// Pre-procesa el logo del recibo para la impresión **TÉRMICA**. Resuelve dos
/// problemas de campo (2026-07-10, tenants Mairena + Telenet):
///
///  1. **Logo AUSENTE** (Mairena, logo 8000×4500): un logo grande no alcanza a
///     decodificarse/pintarse en el `delay` del snapshot offscreen y sale en
///     BLANCO. Redimensionarlo ANTES a la altura de display (`alturaDots`) lo
///     hace pintar al instante.
///  2. **Tonos de color perdidos** (Telenet, naranja): el recibo se binariza por
///     umbral (1-bit), que tira los tonos medios (naranja ≈ 0.65 de luminancia)
///     a BLANCO. Este HÍBRIDO **umbraliza los extremos** (negro sólido para
///     wordmarks/bloques, blanco para el fondo) y **ditherea SOLO la banda media**
///     (Bayer ordenado) → el naranja sale como GRIS sin ensuciar los sólidos.
///
/// El TEXTO del recibo NO pasa por acá: se binariza aparte por umbral simple en
/// `impresora_service_io`, así que sigue nítido. Solo el logo recibe el híbrido.
/// Devuelve un PNG blanco/negro (ya binarizado) o `null` si el PNG no decodifica.
///
/// [alturaDots] = altura exacta en px con la que el widget muestra el logo
/// (`60 * escala`), para que Skia NO lo re-escale después y desarme el patrón.
/// Entrada para `compute` (correr en un ISOLATE, fuera del hilo de UI). Decodificar
/// un logo grande (ej. 8000×4500) es de segundos → en el hilo de UI bloquea la
/// app y Android dispara el ANR ("la app dejó de responder"). `compute` lo lleva
/// a un isolate (en web corre sincrónico, pero ahí no se imprime en térmica).
/// El record `(bytes, alturaDots)` es sendable entre isolates.
Uint8List? procesarLogoTermicaIsolate((Uint8List, int, int, bool) args) =>
    procesarLogoTermica(args.$1,
        alturaDots: args.$2, maxAnchoDots: args.$3, suavizado: args.$4);

/// [suavizado] (Windows, opt-in) usa promediado al achicar y acota el dither a
/// los rellenos. **Default false = el pipeline con el que Android imprime desde
/// siempre** — el bitmap del logo cambia con esta bandera, así que se gatea por
/// plataforma en vez de tocarle el raster a la flota entera (lección v0.22.10-13).
Uint8List? procesarLogoTermica(Uint8List src,
    {required int alturaDots, int maxAnchoDots = 0, bool suavizado = false}) {
  try {
    return _procesar(src, alturaDots, maxAnchoDots, suavizado);
  } catch (_) {
    // Logo corrupto/formato raro: NO romper la impresión — el call-site cae al
    // logo crudo (o a nada). `decodeImage` puede lanzar (no solo devolver null).
    return null;
  }
}

Uint8List? _procesar(
    Uint8List src, int alturaDots, int maxAnchoDots, bool suavizado) {
  img.Image? im = img.decodeImage(src);
  if (im == null) return null;

  // Aplanar sobre BLANCO (el logo puede traer alpha; sin esto lo transparente
  // se vuelve negro al pasar a grises → mancha).
  if (im.hasAlpha) {
    final fondo = img.Image(width: im.width, height: im.height);
    img.fill(fondo, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(fondo, im);
    im = fondo;
  }

  // PNG INDEXADO (paleta) → RGB. `copyResize` IGNORA la interpolación pedida si
  // la imagen tiene paleta (image 4.x, copy_resize.dart: "You can't interpolate
  // index pixels" → la fuerza a nearest). Sin este `convert`, el `average` de
  // abajo sería un NO-OP silencioso en cualquier logo indexado.
  if (suavizado && im.hasPalette) im = im.convert(numChannels: 3);
  final interp =
      suavizado ? img.Interpolation.average : img.Interpolation.nearest;

  // Redimensionar a la altura de display exacta (mantiene aspecto). Clave para
  // (1) que pinte al instante y (2) que no haya re-escalado posterior.
  //
  // `average` (promedio del bloque fuente completo) NO es cosmético: el default
  // de `copyResize` es NEAREST (point-sample), que a 2-6× de reducción descarta
  // la mayoría de los píxeles y deja el borde de cada CURVA donde caiga el
  // muestreo → arcos dentados (el ícono de wifi). Los trazos rectos y gruesos
  // absorben ese corrimiento; las curvas finas no. Medido: a 117 dots el error
  // RMS del borde cae de 24.7 a 0.14.
  final alto = alturaDots < 1 ? 1 : alturaDots;
  if (im.height != alto) {
    im = img.copyResize(im,
        height: alto, interpolation: interp);
  }

  // Tope de ancho al papel: si tras escalar por altura el logo se pasa del
  // ancho imprimible (logos anchos + tamaños grandes), reescalar por ancho para
  // que no se recorte en la térmica (mantiene aspecto).
  if (maxAnchoDots > 0 && im.width > maxAnchoDots) {
    im = img.copyResize(im,
        width: maxAnchoDots, interpolation: interp);
  }

  // Luminancia + CROMA (max-min RGB) en un solo pase. NO se usa `img.grayscale`
  // porque el gate del dither necesita saber si el píxel tiene COLOR.
  final w = im.width, h = im.height;
  final lum = Float32List(w * h);
  final croma = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = im.getPixel(x, y);
      final i = y * w + x;
      lum[i] = p.luminanceNormalized.toDouble();
      // `maxChannelValue` (no 255 fijo): un PNG de 16 bits daría croma siempre
      // alta y el gate ditherearía todo.
      final mcv = p.maxChannelValue.toDouble();
      final r = p.r / mcv, g = p.g / mcv, b = p.b / mcv;
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      croma[i] = (mx - mn).toDouble();
    }
  }

  // Híbrido: umbral en los extremos + Bayer SOLO donde el dither aporta.
  const bajo = 0.42, alto2 = 0.82, duro = 0.50;
  const epsColor = 0.15; // croma mínima para tratar el píxel como "de color"
  const epsPlano = 0.12; // variación 3×3 máxima para tratarlo como "relleno"
  final out = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final v = lum[i];
      final bool negro;
      if (v < bajo) {
        negro = true; // sólido oscuro → negro nítido
      } else if (v > alto2) {
        negro = false; // fondo claro → blanco
      } else {
        // Banda media. El dither existe para los RELLENOS de tono medio (el
        // naranja de Telenet, un gris plano): ahí simula el gris y no se pierden.
        // En un BORDE anti-aliaseado (el halo que deja `average` alrededor de un
        // trazo negro) el Bayer no simula nada: lo vuelve puntitos y desdibuja el
        // contorno. Se ditherea si el píxel tiene COLOR o si su vecindad 3×3 es
        // plana; un borde acromático va por umbral duro → curvas limpias.
        // Sin `suavizado` (Android) el dither corre como siempre: sin gate.
        var ditherear = !suavizado || croma[i] > epsColor;
        if (!ditherear) {
          final x0 = x > 0 ? x - 1 : 0, x1 = x < w - 1 ? x + 1 : w - 1;
          final y0 = y > 0 ? y - 1 : 0, y1 = y < h - 1 ? y + 1 : h - 1;
          var mn = 1.0, mx = 0.0;
          for (var yy = y0; yy <= y1; yy++) {
            for (var xx = x0; xx <= x1; xx++) {
              final t = lum[yy * w + xx];
              if (t < mn) mn = t;
              if (t > mx) mx = t;
            }
          }
          ditherear = (mx - mn) < epsPlano;
        }
        if (ditherear) {
          final t = (_bayer8[y & 7][x & 7] + 0.5) / 64.0;
          negro = ((v - bajo) / (alto2 - bajo)) < t;
        } else {
          negro = v < duro;
        }
      }
      final c = negro ? 0 : 255;
      out.setPixelRgb(x, y, c, c, c);
    }
  }
  return img.encodePng(out);
}
