/// Generación de los bytes ESC/POS del recibo, a partir de la captura del
/// widget. Compartido por los DOS transportes que imprimen en térmica:
///
///   · Bluetooth (Android) — `impresora_service_io.dart`
///   · Cola RAW de Windows — `windows_raw_printer.dart`
///
/// ## Por qué existe este archivo
///
/// El camino de Android imprime perfecto porque NADIE interpreta el recibo en
/// el medio: se rasteriza acá, a los dots exactos del cabezal, y esos puntos se
/// mandan tal cual. El camino de Windows, en cambio, entregaba un PDF al driver,
/// que lo reescalaba y reposicionaba según una configuración de papel que la app
/// no puede leer — de ahí los recibos cortados de un lado o del otro y el texto
/// opaco (síntoma clásico de reescalado). Tres intentos de calibrar la geometría
/// a ciegas movieron el corte de lado sin resolverlo.
///
/// Este módulo es lo que permite que Windows use el MISMO raster que Android.
///
/// ## Invariante de la extracción
///
/// El código salió TAL CUAL de `ImpresoraService` (2026-07-29). La salida para
/// una misma entrada tiene que ser byte a byte idéntica a la de antes: el
/// transporte Bluetooth ya rompió a la flota una vez por tocarlo de más
/// (v0.22.10-13), así que acá NO se "mejora" nada. Lo cubre
/// `test/data/services/recibo_escpos_test.dart`.
library;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../models/recibo_layout.dart';

/// Ancho útil del cabezal en dots, por tipo de rollo (estándar ESC/POS).
int anchoDotsTermica(int anchoMm) => anchoMm >= 80 ? 576 : 384;

/// Umbral por defecto: un píxel es tinta si es más oscuro que esto.
///
/// 0.5 es el valor con el que Android imprime desde siempre. **NO cambiarlo**:
/// es el default de todos los parámetros opcionales de este archivo, y eso es
/// lo que garantiza que el camino Bluetooth siga emitiendo los MISMOS bytes.
/// Windows puede subirlo (ver `umbral` en `comandosReciboEscPos`).
const double umbralTintaDefault = 0.5;

/// Traduce el tamaño del diseñador de recibo al tamaño de carácter del ESC/POS
/// (`GS !`), para el modo de TEXTO NATIVO.
///
/// El estándar soporta hasta 8× en alto y ancho, pero acá el **ancho se topa en
/// 2×**: duplicarlo parte a la mitad los caracteres por línea (48 → 24 en 80mm)
/// y un bloque largo se envolvería. El alto no tiene ese problema, así que es el
/// que lleva la escala.
///
/// `chico` y `normal` caen en el mismo tamaño: la impresora no tiene nada más
/// chico que su base. Es la única equivalencia del diseñador que se pierde.
({int alto, int ancho}) tamanoEscPos(ReciboTextoSize size) => switch (size) {
      ReciboTextoSize.chico => (alto: 1, ancho: 1),
      ReciboTextoSize.normal => (alto: 1, ancho: 1),
      ReciboTextoSize.grande => (alto: 2, ancho: 1),
      ReciboTextoSize.extraGrande => (alto: 2, ancho: 2),
      ReciboTextoSize.gigante => (alto: 3, ancho: 2),
    };

/// Comando ESC/POS de MARGEN IZQUIERDO, en dots (`GS L nL nH`).
///
/// El cabezal empieza a imprimir corrido esta cantidad. Sin esto el texto sale
/// pegado al borde del papel, que es lo que se veía en PC.
/// [dots] 0 = sin margen (no emite comando).
List<int> comandosMargenIzquierdo(int dots) {
  if (dots <= 0) return const [];
  return <int>[0x1D, 0x4C, dots & 0xFF, (dots >> 8) & 0xFF];
}

/// Comando de DENSIDAD del cabezal (`ESC 7 n1 n2 n3`): cuánto calienta, o sea
/// cuán negro sale. [tiempoCalor] es el parámetro que mueve la aguja (a más
/// tiempo, más negro); 80 es el valor típico de fábrica.
///
/// ⚠️ OPT-IN a propósito: devuelve vacío si [tiempoCalor] es null. No todas las
/// térmicas soportan `ESC 7`, y una que no lo entienda podría escupir basura en
/// el papel. Se activa solo cuando alguien lo configura y lo prueba.
List<int> comandosDensidad(int? tiempoCalor) {
  if (tiempoCalor == null) return const [];
  final t = tiempoCalor.clamp(3, 255);
  // n1 = puntos calentados a la vez, n2 = tiempo de calor, n3 = intervalo.
  return <int>[0x1B, 0x37, 7, t, 2];
}

/// Bytes ESC/POS completos para imprimir la captura del recibo: reset, raster
/// y avance + corte. Null si el PNG no se puede decodificar.
///
/// [pngBytes] es la captura del widget `ReciboTicket` (ya viene al ancho de
/// dots del papel). El mismo stream sirve para Bluetooth y para la cola RAW.
/// [umbral] sube el grosor del trazo (más píxeles pasan a tinta). [margenIzqDots]
/// y [tiempoCalor] son los ajustes de Windows. Los tres tienen el valor con el
/// que Android imprime hoy, así que llamar sin ellos emite los MISMOS bytes.
List<int>? comandosReciboEscPos(
  Uint8List pngBytes,
  int anchoMm, {
  double umbral = umbralTintaDefault,
  int margenIzqDots = 0,
  int? tiempoCalor,
  bool compatible = false,
  int feedFinalLineas = 2,
  Uint8List? logoNativo,
  int logoOffsetDots = 0,
  int logoMaxAnchoDots = 0,
}) {
  // try/catch obligatorio: con bytes corruptos el decoder de `image` LANZA en
  // vez de devolver null (se mete en el decoder de GIF y revienta ahí). Antes
  // de extraer este código, eso lo tapaba el try/catch de `imprimirImagen`;
  // la impresión directa de Windows llama acá derecho, así que la defensa
  // tiene que vivir en esta función. Lo cazó su test.
  final img.Image? imagen;
  try {
    imagen = procesarParaTermica(pngBytes, anchoMm, margenDots: margenIzqDots);
  } catch (e) {
    if (kDebugMode) debugPrint('comandosReciboEscPos: $e');
    return null;
  }
  if (imagen == null) {
    if (kDebugMode) debugPrint('comandosReciboEscPos: PNG no decodificable');
    return null;
  }
  return <int>[
    // Reset/init (ESC @): limpia el buffer y deja la térmica en estado
    // conocido (saca cualquier modo raro previo).
    0x1B, 0x40,
    // Ajustes de Windows. Vacíos con los defaults → Android no ve diferencia.
    ...comandosDensidad(tiempoCalor),
    // LOGO aparte (Windows): a tamaño nativo y con umbral fino, ANTES del cuerpo.
    // Va acá y no dentro de la captura porque el umbral grueso del texto (0.62)
    // le cerraba los huecos a los arcos finos. Null (Android) → no emite nada.
    // El feed va DENTRO del if del raster: si el PNG no decodifica no queda un
    // avance huérfano.
    ...(() {
      if (logoNativo == null) return const <int>[];
      final r = rasterLogoCentrado(logoNativo, anchoMm,
          compatible: compatible,
          offsetDots: logoOffsetDots,
          maxAnchoDots: logoMaxAnchoDots);
      if (r.isEmpty) return const <int>[];
      return <int>[...r, 0x1B, 0x64, 0x01]; // ESC d 1 — respiro logo↔cuerpo
    })(),
    // El margen izquierdo ya va HORNEADO en el bitmap (`procesarParaTermica`),
    // NO por `GS L`: muchas térmicas USB lo ignoran y el recibo salía pegado a la
    // izquierda. `margenIzqDots` se sigue pasando a `procesarParaTermica` arriba.
    if (compatible)
      ...bitImageEscAsterisco(imagen, umbral: umbral)
    else
      ...rasterGsv0(imagen, umbral: umbral),
    // Avance de papel antes del corte (parametrizable) + corte total.
    ..._bytesFeedCorte(feedFinalLineas),
  ];
}

/// Avance final + corte: [feedFinalLineas] líneas (`ESC d n`) antes del corte
/// total (`GS V 0`). Default 2 = como imprime Android desde siempre (llamar sin
/// el parámetro emite los MISMOS bytes). Windows lo sube para que el ÚLTIMO
/// bloque (pie/slogan) supere la separación física cabezal→cuchilla antes del
/// corte — si no, la cuchilla lo corta por arriba y el pie se pierde (reaparece
/// en el tope del recibo siguiente). `GS V 0` es inofensivo si no hay cutter.
List<int> _bytesFeedCorte(int feedFinalLineas) => <int>[
      0x1B, 0x64, feedFinalLineas.clamp(1, 255),
      0x1D, 0x56, 0x00,
    ];

/// Igual que [comandosReciboEscPos] pero devuelve el recibo PARTIDO en
/// segmentos, cada uno un bloque de comandos ESC/POS COMPLETO:
/// `[[init+densidad], [banda1], [banda2], …, [feed+cut]]`.
///
/// Es para el envío DOSIFICADO de Windows (`WindowsRawPrinter.enviarSegmentos`):
/// mandar el raster en ráfagas chicas con pausas entre medio evita desbordar el
/// buffer de entrada de las térmicas USB baratas (la 3nStar RPT004 tiene 128 KB
/// → un recibo largo con lista de mora lo cruza y el firmware DESCARTA la cola,
/// perdiendo el pie/slogan). Dosificando, la tasa de entrada queda acotada a la
/// del cabezal y el buffer nunca se llena.
///
/// El corte cae SIEMPRE en frontera de comando (banda `GS v 0` entera), nunca a
/// la mitad de un raster (lección v0.22.10-13). Null si el PNG no decodifica.
/// EXCLUSIVO del path Windows opt-in (envío lento) — Android nunca lo llama.
List<List<int>>? comandosReciboEscPosSegmentado(
  Uint8List pngBytes,
  int anchoMm, {
  double umbral = umbralTintaDefault,
  int margenIzqDots = 0,
  int? tiempoCalor,
  bool compatible = false,
  int bandaFilas = 48,
  int feedFinalLineas = 2,
  Uint8List? logoNativo,
  int logoOffsetDots = 0,
  int logoMaxAnchoDots = 0,
}) {
  final img.Image? imagen;
  try {
    imagen = procesarParaTermica(pngBytes, anchoMm, margenDots: margenIzqDots);
  } catch (e) {
    if (kDebugMode) debugPrint('comandosReciboEscPosSegmentado: $e');
    return null;
  }
  if (imagen == null) {
    if (kDebugMode) {
      debugPrint('comandosReciboEscPosSegmentado: PNG no decodificable');
    }
    return null;
  }
  final segmentos = <List<int>>[];
  // Segmento 0: reset/init (ESC @) + densidad opcional (deja la térmica en
  // estado conocido antes del raster).
  segmentos.add(<int>[0x1B, 0x40, ...comandosDensidad(tiempoCalor)]);
  // Logo aparte (ver `rasterLogoCentrado`): su propio segmento, así el pacing
  // también lo dosifica.
  if (logoNativo != null) {
    final r = rasterLogoCentrado(logoNativo, anchoMm,
        compatible: compatible,
        offsetDots: logoOffsetDots,
        maxAnchoDots: logoMaxAnchoDots);
    if (r.isNotEmpty) segmentos.add(<int>[...r, 0x1B, 0x64, 0x01]);
  }
  if (compatible) {
    // ESC * ya se emite por bandas de 24 con su propia cadencia interna; se
    // manda como un único segmento (modo raro opt-in — el pacing fino por banda
    // es para GS v 0, el camino de todos).
    segmentos.add(bitImageEscAsterisco(imagen, umbral: umbral));
  } else {
    final banda = bandaFilas.clamp(1, 255);
    for (var y0 = 0; y0 < imagen.height; y0 += banda) {
      final filas =
          (y0 + banda <= imagen.height) ? banda : (imagen.height - y0);
      segmentos.add(_bandaGsv0(imagen, y0, filas, umbral));
    }
  }
  // Último segmento: avance (parametrizable) + corte.
  segmentos.add(_bytesFeedCorte(feedFinalLineas));
  return segmentos;
}

/// Línea `App vX.Y.Z` que estampa la versión en las impresiones de DIAGNÓSTICO
/// (prueba y regla de ancho). Vacía si no viene versión — así los call-sites
/// que no la pasan emiten byte por byte lo mismo que antes.
///
/// Por qué existe: la foto de un papel de diagnóstico no dice de qué build
/// salió, y se perdieron rondas enteras discutiendo si una impresión venía del
/// build viejo o del nuevo. Con la versión impresa, cada foto se autoidentifica.
///
/// Se pliega a ASCII imprimible A PROPÓSITO: estas dos impresiones prueban el
/// CANAL, no el codepage. Un carácter alto acá podría salir como basura en un
/// firmware cualquiera y ensuciar justo el diagnóstico que se está leyendo.
List<int> _lineaVersionEscPos(String? version) {
  if (version == null) return const [];
  final limpio = version
      .trim()
      // Se acepta "0.31.23" o "v0.31.23" sin que salga "App vv0.31.23".
      .replaceFirst(RegExp(r'^[vV]'), '')
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '');
  if (limpio.isEmpty) return const [];
  return 'App v$limpio\n'.codeUnits;
}

/// Bytes de una impresión de PRUEBA en modo directo.
///
/// ASCII puro y texto nativo de la impresora (no raster): si esto sale, la
/// impresora entiende ESC/POS y el modo directo sirve; si no sale nada, no lo
/// entiende y hay que dejarlo apagado. Deliberadamente NO depende del codepage
/// (sin tildes) ni de una fuente: prueba el canal, no el diseño del recibo.
///
/// [version] estampa `App vX.Y.Z` al pie. Es opcional y por default NO imprime
/// nada, para no alterar la salida de ningún call-site que no la pase.
List<int> comandosPruebaEscPos(int anchoMm, {String? version}) => <int>[
      0x1B, 0x40, // ESC @  reset
      0x1B, 0x61, 0x01, // ESC a 1  centrado
      ...'PRUEBA DE IMPRESION\n'.codeUnits,
      ...'modo directo\n'.codeUnits,
      ...'papel ${anchoDotsTermica(anchoMm)} puntos\n'.codeUnits,
      ...'Si lees esto, funciona\n'.codeUnits,
      ..._lineaVersionEscPos(version),
      0x1B, 0x64, 0x03, // ESC d 3  avanza 3 lineas
      0x1D, 0x56, 0x00, // GS V 0   corte (lo ignora si no tiene cutter)
    ];

/// Emite un logo YA PRE-PROCESADO (`procesarLogoTermica`) como raster `GS v 0` a
/// TAMAÑO NATIVO, centrado en el papel — **sin pasar por la captura de pantalla**.
///
/// Por qué existe: en modo IMAGEN el logo viajaba dentro de la foto del recibo
/// entero → se agrandaba ×2 (supersampling), se achicaba ÷2 (`average`) y se
/// re-binarizaba con el umbral del TEXTO (0.62, subido a propósito para que la
/// letra salga más negra). Ese umbral alto engorda los trazos y CIERRA los huecos
/// entre los arcos finos (el ícono de wifi salía como un manchón), y el
/// re-muestreo los borronea. El modo TEXTO nunca tuvo ese problema porque emite
/// el logo así: directo, a su resolución, con umbral 0.5 (confirmado en el papel
/// por el cliente — mismo logo, texto OK / imagen mal).
///
/// El centrado va HORNEADO (columnas blancas a los lados) porque estas térmicas
/// ignoran el `GS L`. Devuelve vacío si el PNG no decodifica: mejor recibo sin
/// logo que impresión rota.
/// [compatible] emite el logo con `ESC *` en vez de `GS v 0` — OBLIGATORIO
/// respetarlo: el modo compatible existe para las térmicas que reciben el raster
/// moderno y escupen sus bytes como caracteres. Si el logo saliera siempre en
/// `GS v 0`, esos tenants verían una tira de basura ANTES del recibo.
/// [offsetDots] corre el logo para alinearlo con el CUERPO (Windows 80mm lo
/// desplaza para compensar la zona muerta del cabezal); [maxAnchoDots] lo topa al
/// ancho útil del cuerpo, para que un logo ancho no se meta en esa zona muerta ni
/// (si viniera crudo por un fallo del pre-proceso) dispare un raster gigante.
List<int> rasterLogoCentrado(Uint8List logoPng, int anchoMm,
    {double umbral = umbralTintaDefault,
    bool compatible = false,
    int offsetDots = 0,
    int maxAnchoDots = 0}) {
  try {
    var im = img.decodeImage(logoPng);
    if (im == null) return const [];
    final anchoDots = anchoDotsTermica(anchoMm);
    final limite = (maxAnchoDots > 0 && maxAnchoDots < anchoDots)
        ? maxAnchoDots
        : anchoDots;
    // Techo duro de ancho: protege del logo CRUDO (fallback de `_logoProcesado`
    // si el pre-proceso falla) — sin esto un PNG de 8000px emitiría megabytes de
    // raster a una impresora con 128 KB de buffer.
    if (im.width > limite) {
      im = img.copyResize(im,
          width: limite, interpolation: img.Interpolation.average);
    }
    final img.Image salida;
    if (im.width >= anchoDots) {
      salida = im;
    } else {
      final canvas = img.Image(width: anchoDots, height: im.height);
      img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
      final dx = (((anchoDots - im.width) / 2).round() + offsetDots)
          .clamp(0, anchoDots - im.width);
      img.compositeImage(canvas, im, dstX: dx, dstY: 0);
      salida = canvas;
    }
    return compatible
        ? bitImageEscAsterisco(salida, umbral: umbral)
        : rasterGsv0(salida, umbral: umbral);
  } catch (e) {
    if (kDebugMode) debugPrint('rasterLogoCentrado: $e');
    return const [];
  }
}

/// REGLA DE ANCHO: imprime líneas de largo EXACTO conocido, cada una terminada
/// con su propio número. El operador anota el número más alto que se vea
/// COMPLETO — ese es el ancho real de esa impresora, medido en vez de estimado.
///
/// Por qué existe: el ancho imprimible NOMINAL (48 caracteres en 80mm = 576
/// dots) no es el que imprime cada térmica; varias imprimen menos y recortan la
/// derecha. Sin medirlo, cada ajuste de ancho es a ciegas (pasó con la 3nStar
/// RPT004: 3 rondas moviendo el ancho sin datos). Con la regla, el número sale
/// del papel y se carga en "Ancho de línea".
///
/// Deliberadamente ASCII puro y sin comandos de posición/tamaño: mide el
/// CABEZAL, no el firmware. Cada carácter de la fuente A ocupa 12 dots, así que
/// una línea de N caracteres = N×12 dots.
///
/// [version] estampa `App vX.Y.Z` al pie (opcional; por default no imprime
/// nada). Va DESPUÉS de las líneas numeradas para no meterse en la medición: lo
/// que el operador lee es el último número completo, y una línea extra arriba
/// sólo sería ruido en el medio de la escalera.
List<int> comandosReglaAnchoEscPos(int anchoMm, {String? version}) {
  final maxCols = anchoDotsTermica(anchoMm) ~/ 12; // 48 (80mm) | 32 (58mm)
  final out = <int>[
    0x1B, 0x40, // ESC @  reset (vuelve al ancho nominal del modelo)
    0x1B, 0x61, 0x00, // ESC a 0  alineado a la izquierda
  ];
  void ln(String s) => out.addAll([...s.codeUnits, 0x0A]);

  ln('REGLA DE ANCHO');
  ln('Anote el numero mas alto que');
  ln('aparezca a la IZQUIERDA y a la');
  ln('DERECHA de la MISMA linea:');
  ln('');
  // Líneas de largo EXACTO n, rotuladas en AMBOS extremos. Rotular los dos lados
  // distingue los dos comportamientos posibles del firmware ante una línea más
  // larga que el papel: si TRUNCA, falta el número derecho; si ENVUELVE, ese
  // número reaparece solo en la línea siguiente. Con un solo rótulo (derecha) el
  // caso "envuelve" haría anotar un ancho MAYOR al real — la regla mentiría.
  final desde = (maxCols - 12) < 8 ? 8 : maxCols - 12;
  for (var n = desde; n <= maxCols; n += 2) {
    final e = n.toString();
    ln(e + '-' * (n - 2 * e.length) + e);
  }
  ln('');
  ln('Cargue ese numero en:');
  ln('Perfil > Impresora >');
  ln('Ancho de linea');
  out.addAll(_lineaVersionEscPos(version));
  out.addAll([0x1B, 0x64, 0x04, 0x1D, 0x56, 0x00]); // avance + corte
  return out;
}

/// Arma el comando GS v 0 (raster bit image) A MANO desde una imagen en
/// grises/dither. Control TOTAL de:
///   - polaridad: 1 = punto negro (quema).
///   - ancho en bytes: (w+7)>>3, header xL/xH correcto.
///   - se parte en BANDAS (≤255 filas) para no exceder el buffer de la
///     térmica (algunas truncan rasters muy altos).
/// Umbral 0.5 sobre luminancia: la imagen ya viene dithered (casi B/N).
///
/// Se eligió GS v 0 manual sobre `gen.imageRaster` porque este último codificaba
/// mal en algunas térmicas (salía negativo/angosto) — confirmado en campo
/// (GOOJPRT PT-210).
List<int> rasterGsv0(img.Image im,
    {double umbral = umbralTintaDefault, int bandaFilas = 255}) {
  final h = im.height;
  final banda = bandaFilas.clamp(1, 255); // filas por comando GS v 0
  final out = <int>[];
  for (var y0 = 0; y0 < h; y0 += banda) {
    final filas = (y0 + banda <= h) ? banda : (h - y0);
    out.addAll(_bandaGsv0(im, y0, filas, umbral));
  }
  return out;
}

/// Emite UNA banda `GS v 0` (m=0) para las filas `[y0, y0+filas)`. Es la unidad
/// de corte SEGURA para el envío dosificado de Windows: cada banda es un comando
/// ESC/POS COMPLETO, así que partir el recibo entre bandas nunca corta un raster
/// a la mitad (lección v0.22.10-13). Con `bandaFilas=255` (default) `rasterGsv0`
/// concatena estas bandas y emite EXACTAMENTE los mismos bytes que antes.
List<int> _bandaGsv0(img.Image im, int y0, int filas, double umbral) {
  final w = im.width;
  final widthBytes = (w + 7) >> 3;
  final raster = Uint8List(widthBytes * filas);
  for (var y = 0; y < filas; y++) {
    for (var x = 0; x < w; x++) {
      if (im.getPixel(x, y0 + y).luminanceNormalized < umbral) {
        raster[y * widthBytes + (x >> 3)] |= (0x80 >> (x & 7));
      }
    }
  }
  // GS v 0  m=0  xL xH  yL yH  [data]
  return <int>[
    0x1D, 0x76, 0x30, 0x00,
    widthBytes & 0xff, (widthBytes >> 8) & 0xff,
    filas & 0xff, (filas >> 8) & 0xff,
    ...raster,
  ];
}

/// Pipeline captura→bitmap-térmico (decode → aplanar sobre blanco → resize a
/// dots → grayscale → recortar blanco). La binarización final la hace
/// `rasterGsv0` por UMBRAL (0.5), sin dither. Devuelve null si el PNG no
/// decodifica.
img.Image? procesarParaTermica(Uint8List pngBytes, int anchoMm,
    {int margenDots = 0}) {
  // Ancho útil en dots según el papel: 58mm ≈ 384 px, 80mm = 576 px
  // (anchos estándar ESC/POS). 80mm es el estándar de producción.
  //
  // La captura ya viene al ancho del cabezal (o mayor, con el supersampling 2×
  // de Windows) → se reescala al ancho EXACTO del cabezal. El margen del recibo
  // va HORNEADO como padding EN el widget (`ReciboTicket.margenHorizontal`), NO
  // acá: así el texto se renderiza a TAMAÑO COMPLETO (sin encoger) y los márgenes
  // salen simétricos y nítidos. `margenDots` queda sin uso (compat de firma).
  final anchoContenido = anchoDotsTermica(anchoMm);

  img.Image? imagen = img.decodeImage(pngBytes);
  if (imagen == null) return null;

  // Aplanar sobre fondo BLANCO opaco. La captura del widget (`screenshot`)
  // viene con canal alpha (toImage produce RGBA); sin esto, al pasar a grises
  // las zonas transparentes quedan NEGRAS y la térmica las quema → recibo en
  // NEGATIVO (fondo negro). Aplanar = transparente se vuelve blanco, así el
  // recorte funciona y el recibo sale en positivo.
  if (imagen.hasAlpha) {
    final fondo = img.Image(width: imagen.width, height: imagen.height);
    img.fill(fondo, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(fondo, imagen);
    imagen = fondo;
  }

  // Reescalar al ancho del CONTENIDO. Cuando la captura viene a MAYOR resolución
  // (supersampling de Windows, pixelRatio 2×) este downscale con `average` deja
  // las letras más nítidas en la térmica. Con captura a 1× y margen 0 (Android)
  // el ancho ya coincide → NO corre y la salida es byte-idéntica a la de siempre.
  if (imagen.width != anchoContenido) {
    imagen = img.copyResize(imagen,
        width: anchoContenido, interpolation: img.Interpolation.average);
  }

  // Monocromo por UMBRAL (NO dithering): grayscale y listo — la binarización
  // real la hace `rasterGsv0` con su umbral 0.5 (luminanceNormalized < 0.5).
  // Por qué NO dither: el recibo es LINE-ART (texto + logo sólido), no una
  // foto. El Floyd-Steinberg dispersa los trazos sólidos en puntitos sueltos
  // → el logo sale "tiznado"/ilegible en cabezales de baja resolución
  // (58mm = 384 dots, impresoras baratas tipo PT-210). El umbral da negro
  // SÓLIDO y bordes limpios. Validado contra los 3 logos reales de producción
  // (incluido uno de fondo negro/inverso): todos nítidos, ninguno se rompe;
  // 0.5 es el único umbral seguro (0.6/0.7 se comen el logo inverso). El
  // dither solo servía para fotos con degradado, que un recibo no tiene.
  imagen = img.grayscale(imagen);
  // Recortar el margen blanco arriba/abajo (la captura puede venir con alto
  // holgado/centrado por el targetSize) → no se imprime tira en blanco y se
  // aprovecha el papel.
  imagen = recortarBlancoVertical(imagen);
  return imagen;
}

/// Recorta el margen BLANCO de arriba y abajo de una imagen en grises, para
/// que la térmica no imprima tira en blanco (la captura puede venir con alto
/// holgado por el `targetSize`). Deja un pequeño padding. Si la imagen es
/// toda blanca, la devuelve sin tocar.
img.Image recortarBlancoVertical(img.Image im) {
  bool filaConContenido(int y) {
    for (var x = 0; x < im.width; x++) {
      // luminanceNormalized: 0 (negro) … 1 (blanco). < 0.95 = hay tinta.
      if (im.getPixel(x, y).luminanceNormalized < 0.95) return true;
    }
    return false;
  }

  var top = 0;
  var bottom = im.height - 1;
  while (top < im.height && !filaConContenido(top)) {
    top++;
  }
  while (bottom > top && !filaConContenido(bottom)) {
    bottom--;
  }
  if (top >= bottom) return im; // todo blanco → no recortar

  // Padding mínimo arriba/abajo (≈0.5mm) para aprovechar el papel sin que
  // las ascendentes/descendentes queden al ras del borde.
  const pad = 4;
  final y0 = (top - pad) < 0 ? 0 : (top - pad);
  var alto = (bottom - top + 1) + pad * 2;
  if (y0 + alto > im.height) alto = im.height - y0;
  return img.copyCrop(im, x: 0, y: y0, width: im.width, height: alto);
}


/// El MISMO bitmap que [rasterGsv0] pero con `ESC * 33` (bit image de 24 puntos,
/// doble densidad), el comando VIEJO de ESC/POS.
///
/// Existe porque hay térmicas que reciben el `GS v 0` moderno y, en vez de
/// dibujarlo, imprimen los bytes del bitmap como caracteres sueltos: sale una
/// tira de basura en lugar del recibo (foto del campo 2026-07-31, con el modo
/// texto de la MISMA impresora funcionando bien — o sea, el canal está bien y
/// lo que no entiende es ese comando puntual).
///
/// **Es opt-in por dispositivo, nunca automático.** `GS v 0` sigue siendo el
/// camino de todos: cambiar el raster compartido para arreglar un modelo ya
/// rompió a la flota entera una vez (v0.22.10-13).
///
/// Formato: por cada banda de 24 filas se emite `ESC * 33 nL nH` y luego 3
/// bytes por columna (bit7 = fila de arriba de cada grupo de 8), cerrando con
/// un avance de línea. Es más verboso que el raster —3 bytes por columna contra
/// 1 por cada 8 puntos— pero lo entiende hasta el firmware más viejo.
List<int> bitImageEscAsterisco(img.Image im, {double umbral = umbralTintaDefault}) {
  final out = <int>[];
  // Interlineado = 24 puntos (ESC 3 24), si no la impresora deja un hueco
  // blanco entre banda y banda y el recibo sale rayado.
  out.addAll([0x1B, 0x33, 24]);
  for (var y0 = 0; y0 < im.height; y0 += 24) {
    out.addAll([0x1B, 0x2A, 33, im.width & 0xFF, (im.width >> 8) & 0xFF]);
    for (var x = 0; x < im.width; x++) {
      for (var k = 0; k < 3; k++) {
        var b = 0;
        for (var bit = 0; bit < 8; bit++) {
          final y = y0 + k * 8 + bit;
          if (y >= im.height) continue;
          if (im.getPixel(x, y).luminanceNormalized < umbral) {
            b |= 0x80 >> bit;
          }
        }
        out.add(b);
      }
    }
    out.add(0x0A); // avanzar a la banda siguiente
  }
  out.addAll([0x1B, 0x32]); // ESC 2 — interlineado de vuelta al default
  return out;
}


/// Caracteres por línea que entran DESCONTANDO el margen de los dos lados.
///
/// El default de la librería ESC/POS (48 en 80mm) son 576 puntos: el cabezal
/// ENTERO, sin un solo punto de margen. Con un margen izquierdo configurado —o
/// con el que reserve la impresora— los últimos caracteres caen fuera del papel
/// y la línea sale cortada a la derecha (fotos del campo 2026-07-31).
///
/// Cada carácter de la fuente A ocupa 12 puntos. Se descuenta el margen DOS
/// veces para que quede simétrico: el `GS L` corre el texto a la derecha, así
/// que sin reservar también del otro lado se empuja el corte en vez de sacarlo.
int charsPorLineaConMargen(int anchoMm, int margenDots) {
  final util = anchoDotsTermica(anchoMm) - 2 * margenDots.clamp(0, 60);
  return (util ~/ 12).clamp(20, anchoMm >= 80 ? 48 : 32);
}
