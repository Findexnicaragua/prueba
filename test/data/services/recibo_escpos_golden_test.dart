/// GOLDEN del stream ESC/POS que sale por **Bluetooth en Android**.
///
/// ## Por qué existe (el agujero que tapa)
///
/// Todo el trabajo de impresión de Windows se apoya en una promesa: "Android
/// queda byte-idéntico". El test que supuestamente la blindaba
/// (`recibo_escpos_test.dart` → 'sin parámetros no se emite ningún comando
/// nuevo') solo mira los PRIMEROS 6 BYTES: verifica que después del `ESC @`
/// arranque el `GS v 0` y nada más. Un cambio en el byte 500 —el umbral de
/// tinta, el recorte del blanco, el troceado en bandas, la polaridad, el
/// avance final— pasa ese test sin despeinarse. La promesa estaba declarada,
/// no verificada.
///
/// Acá se fija la salida COMPLETA: largo total, primeros y últimos bytes,
/// conteo de cada comando ESC/POS y un hash de todo el stream. Cualquier byte
/// que se mueva, en cualquier posición, rompe el test.
///
/// ## Los 3 caminos que cubre
///
/// `impresora_service_io.dart` (el transporte Bluetooth) llama
/// `comandosReciboEscPos(pngBytes, anchoMm)` **sin un solo parámetro
/// opcional**. Entonces los goldens son:
///
///   1. 80mm, defaults puros → el camino de casi toda la flota.
///   2. 80mm con `compatible: true` → las térmicas que no entienden `GS v 0`.
///   3. 58mm, defaults puros → el rollo chico (384 dots).
///
/// ## Cómo se regenera
///
/// Si un cambio APROBADO altera la salida, el propio fallo imprime el literal
/// Dart nuevo, listo para pegar en la constante `_golden*` que corresponda. No
/// hay que calcular nada a mano ni correr un script aparte.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:isp_billing/data/services/impresora/recibo_escpos.dart';

// ─────────────────────────────────────────────────────────────────────────────
// GOLDENS
// ─────────────────────────────────────────────────────────────────────────────

/// El recibo sintético mide 320 filas, con contenido de la 18 a la 301. El
/// recorte deja `(301-18+1) + 2*4` de padding = **292 filas** impresas. Ese
/// número explica los largos de los tres goldens: no son mágicos, se derivan.
const _filasImpresas = 292;

/// 80mm, `comandosReciboEscPos(png, 80)` — la llamada EXACTA de Bluetooth.
///
/// Largo = 2 (`ESC @`) + banda de 255 filas (8 + 72×255) + banda de 37
/// (8 + 72×37) + 3 (`ESC d 2`) + 3 (`GS V 0`) = **21048**.
/// Las 2 bandas salen de que 292 > 255, el tope de un `GS v 0`.
const _goldenAndroid80 = _Huella(
  largo: 21048,
  hash: '23bf1911b2e768d4',
  // 1b40 = ESC @ · 1d763000 = GS v 0 m=0 · 4800 = 72 bytes de ancho ·
  // ff00 = 255 filas · después arrancan las filas blancas del padding.
  cabeza: '1b 40 1d 76 30 00 48 00 ff 00 00 00 00 00 00 00',
  // …fin del raster · 1b6402 = ESC d 2 (avance) · 1d5600 = GS V 0 (corte).
  cola: '00 00 00 00 00 00 00 00 00 00 1b 64 02 1d 56 00',
  comandos: <String, int>{
    'ESC @ reset': 1,
    'ESC d avance': 1,
    'GS V corte': 1,
    'GS v 0 raster': 2,
  },
);

/// 80mm con `compatible: true` — bit image viejo (`ESC *`) en vez de raster.
///
/// Largo = 2 (`ESC @`) + 3 (`ESC 3 24`) + 13 bandas × (5 de header + 3×576 de
/// datos + 1 de `LF`) + 2 (`ESC 2`) + 3 (`ESC d 2`) + 3 (`GS V 0`) = **22555**.
/// 13 bandas porque `ESC *` va de a 24 filas: ⌈292/24⌉ = 13.
const _goldenAndroid80Compatible = _Huella(
  largo: 22555,
  hash: 'f9925a583bf41776',
  // 1b40 = ESC @ · 1b3318 = ESC 3 24 (interlineado) · 1b2a21 = ESC * m=33 ·
  // 4002 = 576 columnas · 0fffff = 1ª columna (4 filas de padding blanco
  // arriba y el resto tinta del encabezado).
  cabeza: '1b 40 1b 33 18 1b 2a 21 40 02 0f ff ff 0f ff ff',
  // …fin de la última banda · 0a = LF · 1b32 = ESC 2 (interlineado default) ·
  // 1b6402 = avance · 1d5600 = corte.
  cola: '00 00 00 00 00 00 00 0a 1b 32 1b 64 02 1d 56 00',
  comandos: <String, int>{
    'ESC * bit image': 13,
    'ESC 2 interlineado default': 1,
    'ESC 3 interlineado': 1,
    'ESC @ reset': 1,
    'ESC d avance': 1,
    'GS V corte': 1,
    'LF salto de linea': 13,
  },
);

/// 58mm, defaults puros — cabezal de 384 dots (48 bytes de ancho).
///
/// Largo = 2 + (8 + 48×255) + (8 + 48×37) + 3 + 3 = **14040**.
const _goldenAndroid58 = _Huella(
  largo: 14040,
  hash: 'fa7a248f7fdebd64',
  // 3000 = 48 bytes de ancho (384 dots), contra los 72 del rollo de 80mm.
  cabeza: '1b 40 1d 76 30 00 30 00 ff 00 00 00 00 00 00 00',
  cola: '00 00 00 00 00 00 00 00 00 00 1b 64 02 1d 56 00',
  comandos: <String, int>{
    'ESC @ reset': 1,
    'ESC d avance': 1,
    'GS V corte': 1,
    'GS v 0 raster': 2,
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// TESTS
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('golden del stream de Android', () {
    test('80mm con los defaults (la llamada de impresora_service_io)', () {
      final b = comandosReciboEscPos(_png(_reciboSintetico(576)), 80);
      expect(b, isNotNull, reason: 'el PNG sintético tiene que decodificar');
      // El raster moderno es el camino de TODOS: si desapareciera, la flota
      // entera cambiaría de comando de imagen de un release al otro.
      expect(b!.sublist(0, 6), [0x1B, 0x40, 0x1D, 0x76, 0x30, 0x00],
          reason: 'reset + GS v 0, sin nada en el medio');
      _verificarGolden('_goldenAndroid80', b, _goldenAndroid80);
    });

    test('80mm en modo compatible (ESC *)', () {
      final b =
          comandosReciboEscPos(_png(_reciboSintetico(576)), 80, compatible: true);
      expect(b, isNotNull);
      _verificarGolden(
          '_goldenAndroid80Compatible', b!, _goldenAndroid80Compatible);
    });

    test('58mm con los defaults', () {
      final b = comandosReciboEscPos(_png(_reciboSintetico(384)), 58);
      expect(b, isNotNull);
      _verificarGolden('_goldenAndroid58', b!, _goldenAndroid58);
    });

    test('la salida es DETERMINISTA: dos llamadas iguales, bytes iguales', () {
      // Sin esto un golden podría romperse por ruido (orden de iteración,
      // timestamps, buffers reusados) y se leería como una regresión real.
      final png = _png(_reciboSintetico(576));
      expect(comandosReciboEscPos(png, 80), comandosReciboEscPos(png, 80));
    });

    test('el largo del golden CIERRA con la aritmética del ESC/POS', () {
      // Un golden que nadie puede verificar es un golden que nadie se anima a
      // regenerar: quedaría "el hash que salió esa vez". Acá el largo de
      // `_goldenAndroid80` se DERIVA de las filas impresas y del formato del
      // comando. Si el recorte cambiara, este test explica POR QUÉ se movieron
      // los tres goldens a la vez, en lugar de dejar 3 hashes rotos a secas.
      final im = procesarParaTermica(_png(_reciboSintetico(576)), 80)!;
      expect(im.width, 576, reason: 'el ancho del cabezal de 80mm');
      expect(im.height, _filasImpresas,
          reason: 'contenido de la fila 18 a la 301, + 4 de padding a cada lado');

      const filasPorBanda = 255; // tope de un solo GS v 0
      const anchoBytes = 576 ~/ 8;
      const bandas = [filasPorBanda, _filasImpresas - filasPorBanda];
      final esperado = 2 + // ESC @
          bandas.fold<int>(0, (a, filas) => a + 8 + anchoBytes * filas) +
          3 + // ESC d 2 (avance)
          3; // GS V 0 (corte)
      expect(_goldenAndroid80.largo, esperado);
    });

    test('el golden TIENE dientes: caza un cambio en el MEDIO del stream', () {
      // Test del propio test. Mover el umbral de tinta un escalón no cambia ni
      // el largo, ni los comandos, ni el arranque, ni el cierre: toca SOLO
      // bytes del medio del raster. Es exactamente el agujero del test viejo
      // ('sin parámetros no se emite ningún comando nuevo'), que miraba los
      // primeros 6 bytes y daba verde igual.
      //
      // Se usa el parámetro `umbral` como stand-in de "alguien cambió el
      // pipeline" — así se prueba la sensibilidad sin tocar `recibo_escpos.dart`.
      // Si este test dejara de fallar el hash, el golden no protege nada.
      final png = _png(_reciboSintetico(576));
      final movido = comandosReciboEscPos(png, 80, umbral: 0.51)!;
      final h = _huellaDe(movido);

      // Todo lo que el test viejo miraba sigue idéntico…
      expect(movido.sublist(0, 6), [0x1B, 0x40, 0x1D, 0x76, 0x30, 0x00]);
      expect(h.largo, _goldenAndroid80.largo);
      expect(h.comandos, _goldenAndroid80.comandos);
      expect(h.cabeza, _goldenAndroid80.cabeza);
      expect(h.cola, _goldenAndroid80.cola);
      // …y sin embargo la salida NO es la misma. Solo el hash lo ve.
      expect(h.hash, isNot(_goldenAndroid80.hash),
          reason: 'el hash tiene que distinguir bytes del medio del raster; '
              'si no, este archivo da una falsa sensación de cobertura');
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ENTRADA DETERMINISTA
// ─────────────────────────────────────────────────────────────────────────────

Uint8List _png(img.Image im) => Uint8List.fromList(img.encodePng(im));

/// Recibo sintético: se dibuja acá, sin assets ni red, así el golden depende
/// SOLO del código de `recibo_escpos.dart`.
///
/// Cada elemento existe para tensar una parte distinta del pipeline — si el
/// lienzo fuera un rectángulo negro plano (como en los tests de contrato), un
/// cambio de umbral o de recorte no movería un solo byte y el golden no
/// serviría de nada:
///
///   · franjas blancas arriba/abajo → ejercitan `recortarBlancoVertical`, que
///     es quien decide el alto REAL impreso (y por lo tanto el largo total).
///   · alto > 255 filas → obliga al troceado en bandas de `GS v 0`.
///   · rampa de grises columna a columna → fija el umbral de tinta EXACTO: si
///     alguien mueve el 0.5 aunque sea un escalón, el corte de la rampa se
///     corre y el hash cambia.
///   · renglones de largo variable → cualquier cambio de reescalado o de
///     alineación de bits se nota en el raster.
img.Image _reciboSintetico(int anchoDots) {
  const alto = 320; // > 255 a propósito: fuerza 2 bandas de raster.
  final negro = img.ColorRgb8(0, 0, 0);
  final im = img.Image(width: anchoDots, height: alto);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));

  // Encabezado sólido (la barra negra del recibo).
  img.fillRect(im, x1: 0, y1: 18, x2: anchoDots - 1, y2: 45, color: negro);

  // "Renglones" de texto: largos variables pero FIJOS (fórmula, no random).
  for (var i = 0; i < 12; i++) {
    final y = 60 + i * 14;
    final ancho = ((i * 37 + 11) % (anchoDots - 40)) + 20;
    img.fillRect(im, x1: 8, y1: y, x2: 8 + ancho, y2: y + 7, color: negro);
  }

  // Rampa de grises: 0 en el borde izquierdo, 255 en el derecho.
  for (var x = 0; x < anchoDots; x++) {
    final g = (x * 256 ~/ anchoDots).clamp(0, 255);
    img.fillRect(im,
        x1: x, y1: 235, x2: x, y2: 274, color: img.ColorRgb8(g, g, g));
  }

  // Línea punteada de cierre.
  for (var x = 0; x < anchoDots; x += 6) {
    final x2 = (x + 2) >= anchoDots ? anchoDots - 1 : x + 2;
    img.fillRect(im, x1: x, y1: 294, x2: x2, y2: 301, color: negro);
  }
  return im;
}

// ─────────────────────────────────────────────────────────────────────────────
// HUELLA DEL STREAM
// ─────────────────────────────────────────────────────────────────────────────

/// Resumen verificable de un stream ESC/POS. Se guarda esto y no el hex
/// completo (serían ~6 KB por golden) porque así el fallo dice QUÉ cambió —
/// la estructura, el largo, el arranque, el cierre o el contenido— en vez de
/// escupir dos paredes de bytes para comparar a ojo.
class _Huella {
  const _Huella({
    required this.largo,
    required this.hash,
    required this.cabeza,
    required this.cola,
    required this.comandos,
  });

  /// Bytes totales del stream.
  final int largo;

  /// FNV-1a de 64 bits de TODOS los bytes (ver [_fnv1a64]).
  final String hash;

  /// Primeros 16 bytes en hex (init + arranque del bloque de imagen).
  final String cabeza;

  /// Últimos 16 bytes en hex (cola del raster + avance + corte).
  final String cola;

  /// Cuántas veces aparece cada comando ESC/POS, parseando el stream de
  /// verdad (salteando el payload de las imágenes, ver [_comandosDe]).
  final Map<String, int> comandos;
}

/// Clave que cuenta los bytes que el parser NO pudo ubicar dentro de un
/// comando. Si aparece, el stream dejó de ser ESC/POS bien formado.
const _bytesSueltos = '?? bytes fuera de comando';

_Huella _huellaDe(List<int> b) => _Huella(
      largo: b.length,
      hash: _fnv1a64(b),
      cabeza: _hex(b.take(16)),
      cola: _hex(b.skip(b.length < 16 ? 0 : b.length - 16)),
      comandos: _comandosDe(b),
    );

/// Recorre el stream como ESC/POS de verdad: cada comando sabe cuánto ocupa,
/// así el payload del raster NO se cuenta como comandos.
///
/// (Buscar las secuencias con un `contains` daría falsos positivos: los bytes
/// de una imagen contienen `1D 76 30 00` por pura casualidad cada tanto.)
Map<String, int> _comandosDe(List<int> b) {
  final conteo = <String, int>{};
  void sumar(String c) => conteo[c] = (conteo[c] ?? 0) + 1;
  bool hay(int i, int n) => i + n <= b.length;

  var i = 0;
  while (i < b.length) {
    final x = b[i];
    if (x == 0x1B && hay(i, 2)) {
      switch (b[i + 1]) {
        case 0x40: // ESC @
          sumar('ESC @ reset');
          i += 2;
          continue;
        case 0x32: // ESC 2
          sumar('ESC 2 interlineado default');
          i += 2;
          continue;
        case 0x33 when hay(i, 3): // ESC 3 n
          sumar('ESC 3 interlineado');
          i += 3;
          continue;
        case 0x61 when hay(i, 3): // ESC a n
          sumar('ESC a alineacion');
          i += 3;
          continue;
        case 0x64 when hay(i, 3): // ESC d n
          sumar('ESC d avance');
          i += 3;
          continue;
        case 0x37 when hay(i, 5): // ESC 7 n1 n2 n3
          sumar('ESC 7 densidad');
          i += 5;
          continue;
        case 0x2A when hay(i, 5): // ESC * m nL nH + 3 bytes por columna
          final cols = b[i + 3] | (b[i + 4] << 8);
          if (hay(i, 5 + 3 * cols)) {
            sumar('ESC * bit image');
            i += 5 + 3 * cols;
            continue;
          }
      }
    }
    if (x == 0x1D && hay(i, 2)) {
      switch (b[i + 1]) {
        case 0x76 when hay(i, 8) && b[i + 2] == 0x30: // GS v 0 m xL xH yL yH
          final anchoBytes = b[i + 4] | (b[i + 5] << 8);
          final filas = b[i + 6] | (b[i + 7] << 8);
          if (hay(i, 8 + anchoBytes * filas)) {
            sumar('GS v 0 raster');
            i += 8 + anchoBytes * filas;
            continue;
          }
        case 0x56 when hay(i, 3): // GS V m
          sumar('GS V corte');
          i += 3;
          continue;
        case 0x4C when hay(i, 4): // GS L nL nH
          sumar('GS L margen izq');
          i += 4;
          continue;
      }
    }
    if (x == 0x0A) {
      sumar('LF salto de linea');
      i += 1;
      continue;
    }
    sumar(_bytesSueltos);
    i += 1;
  }
  // Orden alfabético: el mapa se compara e imprime igual en cualquier corrida.
  final claves = conteo.keys.toList()..sort();
  return <String, int>{for (final k in claves) k: conteo[k]!};
}

String _hex(Iterable<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

/// FNV-1a de 64 bits, a mano.
///
/// `crypto` NO está declarada en el `pubspec.yaml` (entra solo como
/// dependencia transitiva) y la consigna es no sumar una dependencia directa
/// para un test — importarla igual dispararía el lint
/// `depend_on_referenced_packages`. FNV-1a es de 8 líneas y alcanza y sobra:
/// acá no se defiende de un atacante que busque colisiones, se detecta que un
/// byte cambió sin querer.
///
/// El wraparound de 64 bits del VM de Dart —donde corre `flutter test`— hace
/// la cuenta exacta y reproducible en cualquier máquina.
String _fnv1a64(List<int> bytes) {
  var h = 0xcbf29ce484222325; // offset basis
  for (final b in bytes) {
    h ^= b & 0xFF;
    h = h * 0x100000001b3; // prime FNV de 64 bits (desborda y envuelve)
  }
  final alto = (h >> 32) & 0xFFFFFFFF;
  final bajo = h & 0xFFFFFFFF;
  return alto.toRadixString(16).padLeft(8, '0') +
      bajo.toRadixString(16).padLeft(8, '0');
}

// ─────────────────────────────────────────────────────────────────────────────
// COMPARACIÓN Y MENSAJE DE FALLO
// ─────────────────────────────────────────────────────────────────────────────

const _leccion = '''
QUÉ SIGNIFICA: cambió la salida ESC/POS del camino de ANDROID. Estos bytes son
los que `impresora_service_io.dart` manda por Bluetooth a la flota entera de
térmicas (llama `comandosReciboEscPos(png, anchoMm)`, sin un solo parámetro
opcional). El invariante declarado en `recibo_escpos.dart` es que esa salida es
byte a byte la de siempre.

POR QUÉ IMPORTA: tocar el path compartido de impresión "para mejorarlo" ya
rompió a TODOS los tenants una vez — v0.22.10-13, hubo que revertir a
8c4e330/v0.22.14. La regla que salió de ahí (memoria
`impresion-no-tocar-raster-global`): un arreglo para un modelo puntual va por
modo opt-in POR IMPRESORA, NUNCA cambiando estos bytes.

QUÉ HACER:
 · Si el cambio NO era intencional → es una regresión, revertila.
 · Si SÍ era intencional y está aprobado → regenerá el golden pegando el
   literal de abajo en la constante indicada, y dejá dicho en el commit qué
   cambió de la salida y por qué es seguro para la flota.''';

void _verificarGolden(String constante, List<int> bytes, _Huella golden) {
  final a = _huellaDe(bytes);
  final nuevo = '\n\n--- literal nuevo para `$constante` ---\n'
      '${_comoLiteral(a)}\n--- fin ---';

  // Primero: que el stream siga siendo ESC/POS bien formado. Si el parser se
  // desincroniza, los conteos de abajo no querrían decir nada.
  expect(a.comandos[_bytesSueltos], isNull,
      reason: 'El stream tiene bytes que no caen dentro de ningún comando '
          'ESC/POS: se desincronizó (header con largo mal calculado, comando '
          'nuevo sin contemplar, o payload truncado). La impresora lo '
          'imprimiría como basura.\n\n$_leccion$nuevo');

  expect(a.comandos, golden.comandos,
      reason: 'Cambió la ESTRUCTURA del stream: hay comandos ESC/POS nuevos, '
          'de menos, o distinta cantidad de bandas de imagen.\n\n'
          '$_leccion$nuevo');

  expect(a.largo, golden.largo,
      reason: 'Cambió el LARGO del stream (${golden.largo} → ${a.largo} '
          'bytes) con los mismos comandos: se mueve cuánta imagen se manda '
          '(recorte del blanco, alto del raster, reescalado).\n\n'
          '$_leccion$nuevo');

  expect(a.cabeza, golden.cabeza,
      reason: 'Cambiaron los PRIMEROS bytes: el arranque del stream (init y/o '
          'el header del bloque de imagen).\n\n$_leccion$nuevo');

  expect(a.cola, golden.cola,
      reason: 'Cambiaron los ÚLTIMOS bytes: el cierre del stream (cola del '
          'raster, avance de papel o corte).\n\n$_leccion$nuevo');

  expect(a.hash, golden.hash,
      reason: 'Mismos comandos, mismo largo y mismos extremos, pero el '
          'CONTENIDO de la imagen cambió: se movió algún byte del medio '
          '(umbral de tinta, polaridad, conversión a grises, alineación de '
          'bits, reescalado). Es exactamente el caso que el test viejo no '
          'veía.\n\n$_leccion$nuevo');
}

/// Imprime la huella como literal Dart, listo para pegar. Sin esto, regenerar
/// un golden sería calcular a mano un hash y 32 bytes en hex.
String _comoLiteral(_Huella h) {
  final b = StringBuffer()
    ..writeln('const _Huella(')
    ..writeln('  largo: ${h.largo},')
    ..writeln("  hash: '${h.hash}',")
    ..writeln("  cabeza: '${h.cabeza}',")
    ..writeln("  cola: '${h.cola}',")
    ..writeln('  comandos: <String, int>{');
  for (final e in h.comandos.entries) {
    b.writeln("    '${e.key}': ${e.value},");
  }
  return (b
        ..writeln('  },')
        ..writeln(');'))
      .toString();
}
