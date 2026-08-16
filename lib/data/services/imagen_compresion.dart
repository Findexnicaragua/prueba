import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Compresión client-side de imágenes ANTES de subir a Supabase Storage.
///
/// Por qué existe: `image_picker` solo aplica `imageQuality`/`maxWidth` en
/// Android/iOS — en Windows (admin de escritorio) esos parámetros se IGNORAN
/// y la foto sube cruda (o el bucket la rechaza por tamaño). Este servicio
/// garantiza el mismo resultado en TODAS las plataformas usando el paquete
/// `image` (pure Dart, ya presente en el repo para la impresión térmica).
///
/// Se usa en los 6 puntos de subida: fotos de cliente, adjuntos de ticket,
/// foto de comprobante, logo de empresa y documentos-foto de contrato.
/// Corre en un isolate (`compute`) para no congelar la UI.
///
/// Perfiles estándar (mantener consistentes con los límites de bucket de las
/// migraciones 0019/0060/0104):
///   - Foto (cliente/ticket/documento-foto): maxLado 1920, calidad 85.
///   - Comprobante de pago: maxLado 1600, calidad 75.
///   - Logo: maxLado 800, mantenerPng (transparencia).
class ImagenComprimida {
  const ImagenComprimida({
    required this.bytes,
    required this.ext,
    required this.mime,
  });

  final Uint8List bytes;

  /// Extensión SIN punto ('jpg' | 'png') — para armar el storage_path.
  final String ext;

  /// Content-type para `FileOptions` del upload.
  final String mime;
}

/// Comprime/redimensiona [original] para upload.
///
/// - Redimensiona si el lado mayor supera [maxLado] (mantiene aspecto).
/// - Re-encodea a JPEG [calidad] (o PNG si [mantenerPng], p.ej. logos).
/// - Corrige orientación EXIF (fotos "acostadas" de cámara).
/// - Si [maxBytes] != null, baja calidad/resolución por pasos hasta cumplir.
/// - Passthrough: un JPEG que ya está dentro de límites y pesa poco se
///   devuelve INTACTO (evita re-comprimir lo que image_picker ya comprimió
///   en Android → sin doble pérdida de calidad).
/// - Si los bytes no se pueden decodificar (formato raro/corrupto) devuelve
///   el original tal cual — el límite server-side del bucket sigue siendo
///   la red de seguridad, igual que hoy.
Future<ImagenComprimida> comprimirImagen(
  Uint8List original, {
  int maxLado = 1920,
  int calidad = 85,
  int? maxBytes,
  bool mantenerPng = false,
}) {
  return compute(
    _comprimirSync,
    _ParamsCompresion(
      bytes: original,
      maxLado: maxLado,
      calidad: calidad,
      maxBytes: maxBytes,
      mantenerPng: mantenerPng,
    ),
  );
}

class _ParamsCompresion {
  const _ParamsCompresion({
    required this.bytes,
    required this.maxLado,
    required this.calidad,
    required this.maxBytes,
    required this.mantenerPng,
  });

  final Uint8List bytes;
  final int maxLado;
  final int calidad;
  final int? maxBytes;
  final bool mantenerPng;
}

/// Un JPEG dentro de dimensiones que pese menos que esto no se re-encodea.
/// Por encima, aunque las dimensiones den, conviene recomprimir (puede venir
/// con calidad ~98 de cámara y pesar varios MB igual).
const _umbralPassthroughBytes = 800 * 1024;

bool _esJpeg(Uint8List b) => b.length > 2 && b[0] == 0xFF && b[1] == 0xD8;

bool _esPng(Uint8List b) =>
    b.length > 4 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

/// Hay rotación EXIF sin aplicar (orientation distinta de 1/normal).
bool _necesitaBake(img.Image image) {
  final o = image.exif.imageIfd.orientation;
  return o != null && o != 1;
}

ImagenComprimida _original(Uint8List bytes) {
  // Conservamos el formato real del archivo para ext/mime.
  final esPng = _esPng(bytes);
  return ImagenComprimida(
    bytes: bytes,
    ext: esPng ? 'png' : 'jpg',
    mime: esPng ? 'image/png' : 'image/jpeg',
  );
}

ImagenComprimida _comprimirSync(_ParamsCompresion p) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(p.bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) return _original(p.bytes);

  // Passthrough: JPEG ya chico en píxeles y bytes, sin rotación EXIF
  // pendiente → no degradar de nuevo (cubre lo que image_picker ya comprimió
  // en Android).
  final ladoOriginal =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  if (!p.mantenerPng &&
      _esJpeg(p.bytes) &&
      !_necesitaBake(decoded) &&
      ladoOriginal <= p.maxLado &&
      p.bytes.length <= _umbralPassthroughBytes &&
      (p.maxBytes == null || p.bytes.length <= p.maxBytes!)) {
    return _original(p.bytes);
  }

  // EXIF: la orientación se "hornea" en los píxeles (los reportes/visores
  // sin soporte EXIF la mostrarían rotada). Solo cuando hace falta:
  // bakeOrientation copia la imagen entera aun sin EXIF (RAM 2× al cuete).
  final image = _necesitaBake(decoded) ? img.bakeOrientation(decoded) : decoded;

  final ladoMayor =
      image.width > image.height ? image.width : image.height;

  // Escalera de intentos: primero el perfil pedido; si hay tope de bytes y
  // no entra, bajar calidad y después resolución.
  final intentos = <({int lado, int calidad})>[
    (lado: p.maxLado, calidad: p.calidad),
    if (p.maxBytes != null) ...[
      (lado: p.maxLado, calidad: p.calidad - 10),
      (lado: 1600 < p.maxLado ? 1600 : (p.maxLado * 3) ~/ 4, calidad: 70),
      (lado: 1280 < p.maxLado ? 1280 : (p.maxLado * 2) ~/ 3, calidad: 65),
    ],
  ];

  Uint8List? mejor;
  String ext = p.mantenerPng ? 'png' : 'jpg';
  for (final intento in intentos) {
    final encoded = _encode(
      image,
      maxLado: intento.lado,
      calidad: intento.calidad.clamp(50, 100),
      png: p.mantenerPng,
    );
    if (mejor == null || encoded.length < mejor.length) mejor = encoded;
    if (p.maxBytes == null || encoded.length <= p.maxBytes!) {
      mejor = encoded;
      break;
    }
  }

  // Si el re-encode salió MÁS pesado que el original (imagen ya óptima) y el
  // original igual cumple los límites, preferir el original — pero SOLO si
  // ya viene en el formato de salida garantizado (mantenerPng promete PNG
  // real: un logo JPEG chico debe re-encodearse igual, no volver como JPEG
  // que después se sube etiquetado image/png).
  if (mejor == null ||
      (mejor.length >= p.bytes.length &&
          ladoMayor <= p.maxLado &&
          (p.maxBytes == null || p.bytes.length <= p.maxBytes!) &&
          (p.mantenerPng ? _esPng(p.bytes) : _esJpeg(p.bytes)))) {
    return _original(p.bytes);
  }

  return ImagenComprimida(
    bytes: mejor,
    ext: ext,
    mime: ext == 'png' ? 'image/png' : 'image/jpeg',
  );
}

Uint8List _encode(
  img.Image image, {
  required int maxLado,
  required int calidad,
  required bool png,
}) {
  var trabajo = image;
  final ladoMayor =
      trabajo.width > trabajo.height ? trabajo.width : trabajo.height;
  if (ladoMayor > maxLado) {
    trabajo = img.copyResize(
      trabajo,
      width: trabajo.width >= trabajo.height ? maxLado : null,
      height: trabajo.height > trabajo.width ? maxLado : null,
      interpolation: img.Interpolation.average,
    );
  }

  if (png) {
    return Uint8List.fromList(img.encodePng(trabajo));
  }

  // JPEG no tiene alpha: si la imagen trae canal alpha (PNG/screenshot),
  // componer sobre fondo blanco — descartar el canal a secas puede dejar
  // fondo negro.
  if (trabajo.numChannels == 4) {
    final canvas = img.Image(
      width: trabajo.width,
      height: trabajo.height,
      numChannels: 3,
    );
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, trabajo);
    trabajo = canvas;
  }

  return Uint8List.fromList(img.encodeJpg(trabajo, quality: calidad));
}
