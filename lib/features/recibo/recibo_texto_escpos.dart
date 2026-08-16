import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;

import '../../data/models/pago.dart';
import '../../data/models/recibo_layout.dart';
import '../../data/services/impresora/recibo_escpos.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/monto_a_letras.dart';
import 'recibo_cargos.dart' show cargoEtiquetaRecibo;

// ---------------------------------------------------------------------------
// Modo COMPATIBLE — el recibo como comandos ESC/POS de TEXTO NATIVO.
//
// A diferencia del modo Imagen (rasteriza TODA la hoja a un bitmap grande), acá
// el texto se manda con los comandos que TODA impresora ESC/POS entiende:
//   - MUCHO más liviano (bytes de texto, no ~70KB de imagen) → no desborda el
//     buffer de las impresoras baratas → sin recibos cortados ni basura.
//   - Codepage español (CP850) → tildes/ñ correctas y SIN "caracteres chinos"
//     (la impresora barata, sin este comando, interpreta los bytes con su
//     codepage nativo — a veces chino — y escupe garabatos).
//   - El logo va como imagen CHICA (opcional; ya viene pre-procesada).
//
// La matemática/contenido del dinero es IDÉNTICA a `recibo_pdf` / `recibo_ticket`
// (mismos campos, mismas fórmulas) — solo cambia el renderer. Se ITERA el mismo
// `settings.reciboLayout` (orden/visibilidad/sub-toggles), así el admin controla
// el recibo igual que en modo Imagen.
// ---------------------------------------------------------------------------

/// Codepage con acentos españoles. CP850 (Multilingual Latin-1) tiene
/// á é í ó ú ñ Ñ ¿ ¡ ü y lo soporta casi toda térmica ESC/POS china barata.
const _cp = 'CP850';

/// Tabla que se le PIDE a la impresora (`ESC t`), según la estrategia. Tiene que
/// coincidir SIEMPRE con cómo `_tx` arma los bytes: si las dos no hablan la
/// misma tabla, la impresora imprime el glifo equivocado con datos correctos
/// (fue exactamente el bug de las tildes — ver `_cp850`).
String _tablaPedida() => _estrategia == 'latin1' ? 'CP1252' : _cp;

/// Construye el recibo como bytes ESC/POS de texto nativo. [logoBytes] debe venir
/// YA PRE-PROCESADO y chico (el call-site lo pasa por `procesarLogoTermica` en un
/// isolate — decodificar un logo grande acá bloquearía el hilo/ANR).
/// [tildesModo] = estrategia de acentos por-dispositivo:
///  - `'cp850'` (default): tildes vía codepage occidental (tabla 2). Requiere
///    que la impresora respete `FS .` (cancelar modo chino).
///  - `'latin1'`: lo mismo pero pidiendo la tabla CP1252 (16) en vez de CP850.
///    Para las térmicas que no traen la 2 pero sí la occidental de Windows.
///  - `'gbk'`: tildes codificadas en el ALFABETO NATIVO de la impresora china —
///    GBK/GB2312 contiene á é í ó ú ü en su zona pinyin (el chino las usa para
///    el pinyin). En vez de pelear contra el modo chino, le hablamos en chino:
///    la tilde sale como acento REAL (un poco más ancha, celda fullwidth).
///    Ñ/mayúsculas acentuadas no existen en GBK → caen a N/A-E-I-O-U.
///  - `'ascii'`: translitera TODO a ASCII puro (á→a): 0 bytes altos →
///    IMPOSIBLE de corromper en cualquier firmware. El plan C infalible.
Future<List<int>> construirReciboTextoEscPos({
  Map<String, dynamic>? row,
  List<Map<String, dynamic>>? rows,
  required AppSettings settings,
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
  List<Map<String, dynamic>> cargosRows = const [],
  required int anchoMm,
  String tildesModo = 'cp850',
  bool aplicarTamanos = false,
  bool logoRasterManual = false,
  int? maxCharsPorLinea,
  int margenIzqDots = 0,
  int feedFinalLineas = 2,
  int reservaDerechaDots = 0,
  bool filasPlanas = false,
}) async {
  final esMulti = rows != null && rows.length > 1;
  _estrategia = tildesModo;
  _aplicarTamanos = aplicarTamanos;
  _logoRasterManual = logoRasterManual;
  _anchoMm = anchoMm;
  _filasPlanas = filasPlanas;

  final profile = await CapabilityProfile.load();
  // `spaceBetweenRows` (default 5 de la librería) es la ÚNICA palanca que corre
  // el ancla ABSOLUTA (`ESC $`) del borde derecho de `gen.row` hacia adentro: la
  // columna de monto se ancla en `576 − spaceBetweenRows` dots, HARDCODEADO a
  // 576 e independiente del conteo de columnas (por eso 42↔46 nunca movió el
  // corte). Con `reservaDerechaDots` (Windows) el monto queda ~6mm dentro del
  // papel → no lo come la cuchilla. Default 0 = 5 = como imprime Android (las
  // filas centradas no usan el ancla → intactas).
  final gen = Generator(anchoMm >= 80 ? PaperSize.mm80 : PaperSize.mm58, profile,
      spaceBetweenRows: 5 + reservaDerechaDots);

  final bytes = <int>[];
  bytes.addAll(gen.reset()); // ESC @ — limpia el buffer y estado.
  // Margen izquierdo (GS L). El control ya existía en la pantalla de Windows
  // pero SOLO lo aplicaba el modo imagen: en texto nativo el slider no hacía
  // nada. Se emite acá, después del reset (que lo borraría).
  bytes.addAll(comandosMargenIzquierdo(margenIzqDots));
  // Ancho útil de línea. El default de la librería en 80mm son 48 caracteres =
  // 576 puntos = el cabezal ENTERO, sin margen. Con el margen de arriba, o con
  // el que reserve la impresora, los últimos caracteres caen fuera del papel y
  // la línea sale cortada a la derecha. Bajarlo devuelve el borde derecho.
  var chars = maxCharsPorLinea ?? charsPorLineaConMargen(anchoMm, margenIzqDots);
  // Tope duro: el contenido (margen + chars·12 dots de fuente A) nunca cruza el
  // ancho del cabezal. Sin esto, un `charsPorLinea` explícito del slider (p.ej.
  // 48 + margen) se pasaba del papel y la cantidad salía cortada a la derecha.
  // Android manda margen 0 y chars null → charsMax 48 == chars → NO toca nada.
  final charsMax = (anchoDotsTermica(anchoMm) - margenIzqDots) ~/ 12;
  if (chars > charsMax) chars = charsMax;
  // `chars` es el ancho TOTAL de línea disponible — es LO QUE MIDE la "regla de
  // ancho" desde el borde izquierdo. La sangría sale de ADENTRO de ese ancho,
  // NUNCA se le suma: si se sumara, cargar el número medido (p.ej. 42) produciría
  // líneas de 45 y la cantidad volvería a cortarse, justo el bug que la regla
  // viene a cerrar. Con margen 2 a cada lado: línea impresa = chars − 2.
  const margenChars = 2;
  _indentPlano = chars >= 34 ? margenChars : 0;
  _colsPlanas = chars - 2 * _indentPlano;
  if (chars > 0 && chars != (anchoMm >= 80 ? 48 : 32)) {
    bytes.addAll(gen.setGlobalFont(PosFontType.fontA, maxCharsPerLine: chars));
  }
  if (tildesModo == 'gbk') {
    // FS & (0x1C 0x26) — asegurar el modo Kanji/chino ON: en este modo las
    // tildes van como pares GBK de 2 bytes y NECESITAN la interpretación china.
    // En firmware cableado a GBK es un no-op; en firmware que respeta el toggle
    // lo enciende. El ASCII (<0x80) imprime igual en ambos casos.
    bytes.addAll(const [0x1C, 0x26]);
    // Ñ/ñ NO existen en GBK (ni en su zona pinyin) → se DEFINEN como caracteres
    // de USUARIO (ESC &, bitmap 12×24 = fuente A) en los códigos 0x7B '{' y
    // 0x7D '}' (jamás aparecen en un recibo) y se activa el set de usuario
    // (ESC % 1). Los códigos NO definidos caen a la fuente residente (spec
    // Epson) → el resto imprime normal. Así "Peña"/"Núñez" salen con eñe REAL
    // también en chinas cableadas.
    bytes.addAll(const [0x1B, 0x26, 0x03, 0x7B, 0x7B, 12]); // definir ñ en '{'
    bytes.addAll(_glifoEnie);
    bytes.addAll(const [0x1B, 0x26, 0x03, 0x7D, 0x7D, 12]); // definir Ñ en '}'
    bytes.addAll(_glifoEnieMayus);
    bytes.addAll(const [0x1B, 0x25, 0x01]); // activar set de usuario
  } else {
    // FS . (0x1C 0x2E) — CANCELAR el modo Kanji/chino. LAS TÉRMICAS CHINAS
    // BARATAS ARRANCAN EN MODO CHINO (GBK): interpretan todo byte alto
    // (0x80-0xFE) como la PRIMERA MITAD de un ideograma de 2 bytes → una tilde
    // CP850 (1 byte alto) se traga la letra siguiente y sale un carácter chino
    // ("Período"→"Per㟛odo", confirmado en la 3nStar PPT305BT, 2026-07-11).
    // Seleccionar el codepage (ESC t) NO alcanza: el modo Kanji tiene
    // precedencia sobre la tabla de caracteres. ESC @ (reset) vuelve al default
    // del firmware (chino) → SIEMPRE inmediatamente DESPUÉS del reset.
    // (Algunos firmware lo IGNORAN — la 3nStar entre ellos → para esos existen
    // los modos 'gbk' y 'ascii'.)
    bytes.addAll(const [0x1C, 0x2E]);
    // ESC t global para todo el ticket (belt-and-braces; cada text() igual lo
    // re-emite por sus styles).
    bytes.addAll(gen.setGlobalCodeTable(_tablaPedida()));
  }

  var algoEmitido = false;
  for (final b in settings.reciboLayout) {
    if (!b.visible) continue;
    final bloque = esMulti
        ? _bloqueMulti(gen, b, rows, settings, logoBytes, moraRows,
            cargosRows)
        : _bloqueSingle(gen, b, row ?? rows!.first, settings, logoBytes,
            moraRows, cargosRows);
    if (bloque.isEmpty) continue;
    // Hueco ANTES del bloque = el espaciado ENTRE SEGMENTOS, en líneas de feed.
    // Mismo nivel de config que imagen/PDF pero AMORTIGUADO (reciboEspacioFeed):
    // la térmica de texto no tiene sub-renglón, así que amplio=2 líneas (no 3)
    // para no inflar el papel.
    if (algoEmitido) {
      final n = reciboEspacioFeed(b.espacioAntes);
      if (n > 0) bytes.addAll(gen.feed(n));
    }
    bytes.addAll(bloque);
    algoEmitido = true;
  }

  // Avance antes del corte (Windows lo sube para que el pie supere la cuchilla;
  // default 2 = como imprime Android).
  bytes.addAll(gen.feed(feedFinalLineas));
  bytes.addAll(gen.cut());
  return bytes;
}

// ----- helpers de estilo -----------------------------------------------------

/// Estrategia de tildes del build EN CURSO ('cp850'|'gbk'|'ascii'; la setea el
/// entry-point según la config por-dispositivo). File-private y single-isolate
/// (la UI) → seguro.
String _estrategia = 'cp850';

/// ¿Se aplican los tamaños del diseñador al texto? **Default false = como
/// imprime Android hoy** (todo en el tamaño base de la impresora, distinguido
/// solo por negrita).
///
/// Este archivo lo COMPARTEN el modo compatible de Android y el modo texto
/// nativo de Windows. Conectar los tamaños sin esta bandera le cambiaría el
/// recibo a Android, y el pedido fue explícito: Windows no toca Android.
/// Windows lo pasa en true desde `construirReciboTextoEscPos`.
bool _aplicarTamanos = false;

/// ¿El logo se emite con el `GS v 0` MANUAL del proyecto en vez de `gen.image`?
/// **Default false = como imprime Android hoy** (gen.image = `ESC *`). Windows/USB
/// lo pasa en true: la 3nStar RPT004 NO dibuja el `ESC *` de gen.image (el logo
/// no salía), pero sí el `GS v 0` manual (el mismo que ya imprime el recibo en
/// modo imagen). Mismo patrón de gate single-isolate que `_aplicarTamanos`.
bool _logoRasterManual = false;

/// Ancho de papel (mm) del build en curso — para centrar el logo del raster
/// manual al ancho del cabezal. Lo setea `construirReciboTextoEscPos`.
int _anchoMm = 58;

/// Windows/RPT004: las filas "etiqueta: valor" se emiten como UNA línea de texto
/// plano rellenada con espacios, en vez de `gen.row` (que ancla el valor por
/// `ESC $` absoluto + `ESC a 2` right-justify → esta térmica IGNORA el `ESC $` y
/// justifica al borde FÍSICO del papel, comiéndose 2-3 chars; por eso ni bajar
/// columnas ni `spaceBetweenRows` lo arreglaban). Con texto plano el valor se
/// ubica SOLO por conteo de caracteres desde x=0 → inmune a que el firmware no
/// honre `ESC $`/`ESC a`/`GS L`. Default false = Android usa `gen.row`
/// (byte-idéntico). NO aplica a 'gbk' (pares fullwidth de 2 celdas).
bool _filasPlanas = false;

/// Ancho (en caracteres) al que se rellenan las filas planas = las columnas
/// efectivas del build. Cada char = 12 dots (fuente A) → borde derecho del valor
/// = `_colsPlanas × 12` dots, que debe caber en el imprimible del cabezal.
int _colsPlanas = 46;

/// Sangría izquierda (en caracteres) de las filas planas. La RPT004 ignora el
/// `GS L`, así que el margen izquierdo se hornea con ESPACIOS. Se calcula para
/// CENTRAR el bloque en el papel: `(charsQueEntran − _colsPlanas) ~/ 2`.
int _indentPlano = 0;

/// Normaliza espacios Unicode "raros" a espacio común. CLAVE:
/// `NumberFormat.currency` (Fmt.cordobas) separa monto y "C$" con un NBSP
/// (U+00A0) — ese byte alto rompía TODO: en CP850 la impresora china se comía
/// la "C" ("732,00蜆$") y en el transliterador salía '?' ("732,00?C$").
/// Confirmado en campo 2026-07-11.
String _normEspacios(String s) => s
    .replaceAll(String.fromCharCode(0x00A0), ' ') // NBSP (NumberFormat.currency)
    .replaceAll(String.fromCharCode(0x202F), ' ') // narrow NBSP
    .replaceAll(String.fromCharCode(0x2009), ' '); // thin space

/// Translitera a ASCII puro (sin bytes altos). Es la salida GARANTIZADA para
/// firmware que ignora hasta el FS . — con ASCII no hay NADA que el modo chino
/// pueda malinterpretar (GBK es ASCII-compatible en 0x00-0x7F).
String quitarTildes(String s) {
  const mapa = {
    'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u',
    'Á': 'A', 'É': 'E', 'Í': 'I', 'Ó': 'O', 'Ú': 'U', 'Ü': 'U',
    'ñ': 'n', 'Ñ': 'N', '¿': '?', '¡': '!', 'º': 'o', 'ª': 'a', '°': 'o',
  };
  final sb = StringBuffer();
  for (final ch in _normEspacios(s).split('')) {
    sb.write(mapa[ch] ?? ch);
  }
  // Cualquier resto no-ASCII (emoji, símbolo raro en nombre/pie) → '?': mejor
  // un '?' que un ideograma que se traga la letra siguiente.
  return sb.toString().replaceAll(RegExp(r'[^\x00-\x7F]'), '?');
}

/// Vocales acentuadas en la zona PINYIN de GB2312 (el alfabeto NATIVO de las
/// impresoras chinas — las usan para el pinyin). Par de 2 bytes por vocal:
/// la impresora en modo chino las imprime como el ACENTO REAL (glifo fullwidth,
/// un poco más ancho que una letra ASCII). 2 bytes = 2 celdas → la aritmética
/// de columnas de `row` (que cuenta bytes) sigue cuadrando.
const _gbkPinyin = <int, List<int>>{
  0xE1: [0xA8, 0xA2], // á
  0xE9: [0xA8, 0xA6], // é
  0xED: [0xA8, 0xAA], // í
  0xF3: [0xA8, 0xAE], // ó
  0xFA: [0xA8, 0xB2], // ú
  0xFC: [0xA8, 0xB9], // ü
};

/// Glifos de USUARIO ñ/Ñ para el modo GBK (ESC &): bitmap 12×24 (fuente A) en
/// formato columna-mayor, 3 bytes por columna, bit7 = fila superior del grupo.
/// Diseño basado en la tipografía VGA clásica (CP437 0xA4/0xA5) escalada 12×24.
/// Generados por script (2026-07-11); NO editar a mano.
const _glifoEnie = <int>[
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x3F, 0xFC, 0x0F, 0x3F, 0xFC, //
  0x0C, 0x0C, 0x00, 0x0F, 0x30, 0x00, 0x03, 0x30, 0x00, 0x0F, 0x3F, 0xFC, //
  0x0C, 0x0F, 0xFC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];
const _glifoEnieMayus = <int>[
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0D, 0xFF, 0xFF, 0x3D, 0xFF, 0xFF, //
  0x30, 0x7E, 0x00, 0x3C, 0x0F, 0xC0, 0x0C, 0x01, 0xF8, 0x3D, 0xFF, 0xFF, //
  0x31, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

/// Codifica texto para el modo GBK: ASCII pasa directo, vocal acentuada → su
/// par pinyin GB2312, ñ/Ñ → sus glifos de usuario ('{' y '}', definidos al
/// inicio del ticket), y el resto no-representable (mayúsculas acentuadas,
/// ¿¡, emoji) cae a la transliteración ASCII.
Uint8List _gbkBytes(String s) {
  final out = BytesBuilder();
  for (final r in _normEspacios(s).runes) {
    final par = _gbkPinyin[r];
    if (par != null) {
      out.add(par);
    } else if (r == 0xF1) {
      out.addByte(0x7B); // ñ → glifo de usuario en '{'
    } else if (r == 0xD1) {
      out.addByte(0x7D); // Ñ → glifo de usuario en '}'
    } else if (r < 0x80) {
      out.addByte(r);
    } else {
      for (final c in quitarTildes(String.fromCharCode(r)).codeUnits) {
        if (c < 0x80) out.addByte(c);
      }
    }
  }
  return out.toBytes();
}

/// Byte CP850 de cada carácter del español.
///
/// **El bug que arregla (2026-07-31, fotos del campo):** `esc_pos_utils_plus`
/// declara `Generator({this.codec = latin1})` y codifica SIEMPRE en latin1, sin
/// mirar qué tabla se le pidió a la impresora con `ESC t`. O sea: le decíamos
/// "interpretá CP850" y le mandábamos bytes latin1 — dos tablas distintas para
/// el mismo byte. La impresora hacía lo correcto con datos incorrectos:
/// `í`(0xED)→`Ý`, `é`(0xE9)→`Ú`, `á`(0xE1)→`ß`, `Ó`(0xD3)→`Ë`, `º`(0xBA)→`║`.
/// Cada uno es exactamente el glifo CP850 del byte latin1. Eso también explica
/// por qué existían los planes B y C ('gbk'/'ascii'): se peleaba con el síntoma.
///
/// **Por qué se arregla acá y no cambiando `ESC t`:** como latin1 mapea
/// U+00XX → byte 0xXX uno a uno, alcanza con reemplazar cada carácter por el
/// CODEPOINT igual a su byte CP850. Lo que se le dice a la impresora NO cambia
/// (sigue siendo la tabla 2) → una térmica que hoy imprime bien sigue igual.
/// Es 1:1 en caracteres, así que la aritmética de columnas de `row()` tampoco
/// se mueve.
const _cp850 = <String, int>{
  'á': 0xA0, 'é': 0x82, 'í': 0xA1, 'ó': 0xA2, 'ú': 0xA3, 'ü': 0x81,
  'Á': 0xB5, 'É': 0x90, 'Í': 0xD6, 'Ó': 0xE0, 'Ú': 0xE9, 'Ü': 0x9A,
  'ñ': 0xA4, 'Ñ': 0xA5, '¿': 0xA8, '¡': 0xAD,
  'º': 0xA7, 'ª': 0xA6, '°': 0xF8,
};

/// Pública (y no `_aCp850`) para poder testear el mapeo SOLO, sin generador ni
/// impresora — mismo criterio que `tamanoEscPos`.
String codificarCp850(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    final b = _cp850[String.fromCharCode(r)];
    if (b != null) {
      sb.writeCharCode(b);
    } else if (r < 0x80) {
      sb.writeCharCode(r);
    } else {
      // No representable en CP850 (emoji, símbolo raro en un nombre): a ASCII.
      // No es cosmético — `latin1.encode` TIRA EXCEPCIÓN con codepoints > 0xFF,
      // así que un solo emoji en el nombre del cliente reventaba la impresión.
      sb.write(quitarTildes(String.fromCharCode(r)));
    }
  }
  return sb.toString();
}

String _tx(String s) {
  final n = _normEspacios(s);
  if (_estrategia == 'ascii') return quitarTildes(n);
  // 'latin1': el codec de la librería YA es la tabla que se le pidió a la
  // impresora (CP1252 ⊃ latin1 en la zona acentuada) → no hay nada que remapear.
  if (_estrategia == 'latin1') return n;
  return codificarCp850(n);
}

/// Tamaño de carácter del bloque que se está emitiendo. Se setea en
/// `_bloqueSingle` desde `b.size` (el tamaño del diseñador de recibo) y lo leen
/// `_centro`/`_fila`/`_total`. Mismo patrón de estado por-archivo que
/// `_estrategia`/`_cp`.
///
/// El ESC/POS soporta hasta 8× en alto y ancho, pero el ANCHO se topa en 2×: al
/// duplicarlo se parten a la mitad los caracteres por línea (48 → 24 en 80mm) y
/// un bloque largo se envolvería. El alto no tiene ese problema.
PosTextSize _alto = PosTextSize.size1;
PosTextSize _ancho = PosTextSize.size1;

void _setTamano(ReciboTextoSize size) {
  if (!_aplicarTamanos) {
    _alto = PosTextSize.size1;
    _ancho = PosTextSize.size1;
    return;
  }
  // El mapeo vive en `recibo_escpos.dart` como función PURA — así se testea sin
  // instanciar el generador ni la impresora.
  final t = tamanoEscPos(size);
  _alto = _posSize(t.alto);
  _ancho = _posSize(t.ancho);
}

PosTextSize _posSize(int n) => switch (n) {
      2 => PosTextSize.size2,
      3 => PosTextSize.size3,
      4 => PosTextSize.size4,
      _ => PosTextSize.size1,
    };

PosStyles _estilo({bool bold = false, PosAlign align = PosAlign.left, bool cp = true}) =>
    PosStyles(
      align: align,
      bold: bold,
      height: _alto,
      width: _ancho,
      codeTable: cp ? _tablaPedida() : null,
    );

List<int> _centro(Generator gen, String s, {bool bold = false}) {
  if (_estrategia == 'gbk') {
    return gen.textEncoded(_gbkBytes(s),
        styles: _estilo(align: PosAlign.center, bold: bold, cp: false));
  }
  if (_filasPlanas) return _centroPlano(gen, s, bold: bold);
  return gen.text(_tx(s), styles: _estilo(align: PosAlign.center, bold: bold));
}

/// Línea centrada SIN depender del centrado del firmware (Windows/RPT004): parte
/// el texto por PALABRAS a `_colsPlanas` y centra cada línea con espacios,
/// emitiendo left-aligned.
///
/// Por qué: `ESC a 1` (centrar) lo resuelve la impresora sobre SU ancho nominal
/// (576 dots), y NO parte las líneas largas → el monto en letras ("UN MIL
/// DOSCIENTOS… CON 00/100" = 51 chars = 612 dots) se salía del papel y se cortaba
/// (foto del campo). Partiendo y centrando por conteo de chars, ninguna línea
/// supera `_colsPlanas × 12` dots.
List<int> _centroPlano(Generator gen, String s, {bool bold = false}) {
  final cols = _colsPlanas;
  final lineas = <String>[];
  for (final parrafo in s.split('\n')) {
    var actual = '';
    for (final palabra in parrafo.split(' ')) {
      if (palabra.isEmpty) continue;
      final tentativa = actual.isEmpty ? palabra : '$actual $palabra';
      if (tentativa.length <= cols) {
        actual = tentativa;
      } else {
        if (actual.isNotEmpty) lineas.add(actual);
        // Palabra sola más larga que el ancho: se emite cruda (la impresora la
        // envuelve) — no se puede partir sin cambiar el dato.
        actual = palabra.length <= cols ? palabra : '';
        if (palabra.length > cols) lineas.add(palabra);
      }
    }
    if (actual.isNotEmpty) lineas.add(actual);
  }
  if (lineas.isEmpty) return const [];
  final centradas = [
    for (final l in lineas)
      l.length >= cols ? l : ' ' * ((cols - l.length) ~/ 2) + l,
  ];
  return gen.text(_tx(_conSangria(centradas.join('\n'))),
      styles: _estilo(bold: bold));
}

/// Antepone la sangría izquierda (`_indentPlano` espacios) a CADA línea del
/// bloque — el margen izquierdo horneado, ya que la RPT004 ignora el `GS L`.
String _conSangria(String bloque) {
  if (_indentPlano <= 0) return bloque;
  final pad = ' ' * _indentPlano;
  return bloque.split('\n').map((l) => '$pad$l').join('\n');
}

/// Fila "etiqueta: valor" (etiqueta izq, valor der). 5/12 vs 7/12 del ancho.
List<int> _fila(Generator gen, String label, String value,
    {bool bold = false}) {
  if (_estrategia == 'gbk') {
    return gen.row([
      PosColumn(
          textEncoded: _gbkBytes('$label:'),
          width: 5,
          styles: _estilo(bold: bold, cp: false)),
      PosColumn(
          textEncoded: _gbkBytes(value),
          width: 7,
          styles: _estilo(align: PosAlign.right, bold: bold, cp: false)),
    ]);
  }
  if (_filasPlanas) return _filaPlano(gen, label, value, bold: bold);
  return gen.row([
    PosColumn(
        text: _tx('$label:'),
        width: 5,
        styles: _estilo(bold: bold)),
    PosColumn(
        text: _tx(value),
        width: 7,
        styles: _estilo(align: PosAlign.right, bold: bold)),
  ]);
}

/// Fila "etiqueta: valor" como UNA línea de texto plano (Windows/RPT004). La
/// etiqueta arranca en x=0 (todas alineadas) y el valor se ubica por CONTEO de
/// caracteres, pegado a la columna `_colsPlanas` (× 12 dots ≤ imprimible). Sin
/// `ESC $`, sin `ESC a 2`, sin `GS L` → no depende de que el firmware los honre.
/// `gen.text` con colWidth 12 saltea la reposición por `ESC $` (solo mueve a
/// x=0) y `_tx`/`_encode` son 1:1 en longitud → el conteo predice los glifos.
List<int> _filaPlano(Generator gen, String label, String value,
    {bool bold = false}) {
  final l = '$label:';
  final cols = _colsPlanas;
  final String linea;
  if (l.length + 1 + value.length <= cols) {
    // Entra en una línea: etiqueta a la izq, valor pegado a la derecha.
    linea = l + ' ' * (cols - l.length - value.length) + value;
  } else if (value.length <= cols) {
    // No entra junto: valor en la línea de abajo, alineado a la derecha.
    linea = '$l\n${' ' * (cols - value.length)}$value';
  } else {
    // Valor larguísimo (nombre/plan): crudo debajo (la impresora lo envuelve).
    linea = '$l\n$value';
  }
  return gen.text(_tx(_conSangria(linea)), styles: _estilo(bold: bold));
}

/// Línea de total (etiqueta + valor, ambos en negrita).
List<int> _total(Generator gen, String label, String value) => _fila(
    gen, label.replaceAll(':', ''), value,
    bold: true);

/// Logo pre-procesado (chico, B/N) como imagen ESC/POS centrada. Si falla,
/// devuelve vacío (mejor recibo sin logo que romper la impresión).
List<int> _logo(Generator gen, Uint8List? logoBytes) {
  if (logoBytes == null) return const [];
  try {
    final im = img.decodeImage(logoBytes);
    if (im == null) return const [];
    if (_logoRasterManual) {
      // Windows/USB (3nStar RPT004): esta térmica NO dibuja el `ESC *` que emite
      // gen.image → el logo no salía. Se emite con el MISMO `GS v 0` armado a
      // mano que ya imprime bien el recibo en modo imagen (rasterGsv0). El logo
      // (ya pre-procesado B/N por procesarLogoTermica, más angosto que el papel)
      // se centra paddeando a blanco hasta el ancho del cabezal —esta impresora
      // ignora el GS L, así que el centrado va HORNEADO en el bitmap, no por
      // comando—. Umbral 0.5 = el de siempre.
      final anchoDots = anchoDotsTermica(_anchoMm);
      final centrado =
          im.width >= anchoDots ? im : _padLogoCentrado(im, anchoDots);
      return rasterGsv0(centrado, umbral: 0.5);
    }
    return gen.image(im, align: PosAlign.center);
  } catch (_) {
    return const [];
  }
}

/// Pone [im] sobre un lienzo BLANCO de [anchoDots] de ancho, centrado
/// horizontalmente (alto = alto del logo). Como `rasterGsv0` emite desde x=0,
/// este padding es lo que centra el logo en el papel sin recortarlo — el
/// equivalente al `align: center` del `ESC *`.
img.Image _padLogoCentrado(img.Image im, int anchoDots) {
  final canvas = img.Image(width: anchoDots, height: im.height);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  final dx = ((anchoDots - im.width) / 2).round();
  img.compositeImage(canvas, im, dstX: dx, dstY: 0);
  return canvas;
}

// ----- bloques SINGLE --------------------------------------------------------

/// Emite los campos de un bloque de info (compatible) en el orden + visibilidad
/// de `b.campos` (nivel-campo). null = sin dato → no se emite. Fallback: si
/// `b.campos` viniera vacío, usa el orden del mapa.
List<int> _emitirCamposEscpos(ReciboBloque b, Map<String, List<int>?> campos) {
  final orden = b.campos.isNotEmpty
      ? b.campos
      : [for (final id in campos.keys) ReciboCampo(id: id)];
  final out = <int>[];
  for (final c in orden) {
    if (!c.visible) continue;
    final bytes = campos[c.id];
    if (bytes != null) out.addAll(bytes);
  }
  return out;
}

List<int> _bloqueSingle(
  Generator gen,
  ReciboBloque b,
  Map<String, dynamic> r,
  AppSettings s,
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows,
  List<Map<String, dynamic>> cargosRows,
) {
  // El tamaño del diseñador manda también acá: se aplica al bloque entero antes
  // de emitirlo. El logo NO lo usa — su tamaño ya vino resuelto en el raster
  // que arma `_logoProcesado` (los mismos 5 niveles), así que se deja en base
  // para no alterar los bloques que vengan después.
  _setTamano(b.id == 'logo' ? ReciboTextoSize.normal : b.size);
  switch (b.id) {
    case 'logo':
      return _logo(gen, logoBytes);
    case 'empresa':
      return _emitirCamposEscpos(b, {
        'empresa.nombre': s.empresaNombre.isNotEmpty
            ? _centro(gen, s.empresaNombre.toUpperCase(), bold: true)
            : null,
        'empresa.direccion': s.empresaDireccion.isNotEmpty
            ? _centro(gen, s.empresaDireccion)
            : null,
        'empresa.telefono': s.empresaTelefono.isNotEmpty
            ? _centro(gen, 'Tel: ${s.empresaTelefono}')
            : null,
        'empresa.ruc': s.empresaRuc.isNotEmpty
            ? _centro(gen, 'RUC: ${s.empresaRuc}')
            : null,
      });
    case 'titulo':
      if (s.reciboTitulo.isEmpty) return const [];
      return _centro(gen, s.reciboTitulo.toUpperCase(), bold: true);
    case 'meta':
      final emision = DateTime.parse(r['fecha_pago'] as String);
      return _emitirCamposEscpos(b, {
        'meta.numero': _fila(gen, 'Recibo Nº', r['numero_completo'] as String),
        'meta.fecha': _fila(gen, 'Fecha', Fmt.fechaCorta(emision)),
        'meta.hora': _fila(gen, 'Hora', Fmt.hora(emision)),
        'meta.cobrador': _fila(gen, 'Colector', r['cobrador_nombre'] as String),
      });
    case 'cliente':
      return _emitirCamposEscpos(b, {
        'cliente.nombre': _fila(gen, 'Cliente', r['cliente_nombre'] as String),
        'cliente.id': r['cliente_codigo'] != null
            ? _fila(gen, 'ID', r['cliente_codigo'] as String)
            : null,
        'cliente.cedula': r['cliente_cedula'] != null
            ? _fila(gen, 'Cédula', r['cliente_cedula'] as String)
            : null,
      });
    case 'servicio':
      final periodoCuota = DateTime.parse(r['periodo'] as String);
      final esManual = r['plan_nombre'] == null;
      final diaPago = (r['dia_pago'] as num?)?.toInt();
      final periodoLabel = esManual || diaPago == null
          ? Fmt.mes(periodoCuota)
          : Fmt.periodoRecibo(diaPago, periodoCuota);
      return _emitirCamposEscpos(b, {
        'servicio.servicio': _fila(
            gen,
            'Servicio',
            esManual
                ? (r['cuota_descripcion'] as String? ?? 'Cuota manual')
                : r['plan_nombre'] as String),
        'servicio.ticket': r['ticket_correlativo'] != null
            ? _fila(gen, 'Ticket', '#${r['ticket_correlativo']}')
            : null,
        'servicio.periodo': (!_esPuenteSolo(r, cargosRows) && !esManual)
            ? _fila(gen, 'Período',
                periodoLabel[0].toUpperCase() + periodoLabel.substring(1))
            : null,
      });
    case 'cuota':
      final saldoCuota = ((r['cuota_monto'] as num).toDouble() +
              (r['cargos_neto'] as num? ?? 0).toDouble()) -
          (r['monto_pagado_cuota'] as num? ?? r['monto_cordobas'] as num)
              .toDouble();
      final abonoPrevio = (r['monto_pagado_cuota'] as num? ?? 0).toDouble() -
          (r['monto_cordobas'] as num).toDouble();
      final puenteSolo = _esPuenteSolo(r, cargosRows);
      return [
        if (!puenteSolo)
          ..._fila(gen, 'Cuota base', Fmt.cordobas(r['cuota_monto'] as num)),
        if (!puenteSolo && abonoPrevio > 0.01)
          ..._fila(gen, 'Abono previo', Fmt.cordobas(abonoPrevio)),
        ..._lineasCargos(gen, cargosRows, r['cuota_id'], s),
        if (!puenteSolo && s.reciboMostrarAdeudado && saldoCuota > 0.01)
          ..._fila(gen, 'Saldo cuota', Fmt.cordobas(saldoCuota)),
      ];
    case 'metodo':
      return _emitirCamposEscpos(b, {
        'metodo.metodo': _fila(gen, 'Método',
            MetodoPago.fromString(r['metodo'] as String).label.toUpperCase()),
        'metodo.referencia': r['referencia'] != null
            ? _fila(gen, 'Ref.', r['referencia'] as String)
            : null,
        'metodo.recibido': (r['moneda'] as String) == 'USD'
            ? _fila(
                gen,
                'Recibido',
                'US\$${(r['monto_original'] as num).toStringAsFixed(2)} '
                    '(tasa ${(r['tasa_conversion'] as num).toStringAsFixed(2)})')
            : null,
      });
    case 'letras':
      return _centro(
          gen,
          montoALetras((r['monto_cordobas'] as num).toDouble(),
              moneda: (r['moneda'] as String?) ?? 'NIO'),
          bold: true);
    case 'totales':
      final vuelto = (r['vuelto_cordobas'] as num? ?? 0).toDouble();
      final cobrado = (r['monto_cordobas'] as num).toDouble();
      final esUsd = (r['moneda'] as String) == 'USD';
      return [
        ..._total(gen, 'Monto', Fmt.cordobas(r['monto_cordobas'] as num)),
        if (vuelto > 0.01) ...[
          ..._total(gen, esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
              Fmt.cordobas(vuelto)),
          ..._total(
              gen,
              'PAGADO',
              esUsd
                  ? 'US\$${(r['monto_original'] as num).toStringAsFixed(2)} = ${Fmt.cordobas(cobrado + vuelto)}'
                  : Fmt.cordobas(cobrado + vuelto)),
        ],
      ];
    case 'mora':
      return _moraBloque(gen, moraRows);
    case 'pie':
      if (s.pieRecibo.isEmpty) return const [];
      return _centro(gen, s.pieRecibo);
    case 'whatsapp':
      if (s.empresaWhatsapp.isEmpty) return const [];
      return _centro(gen, 'WhatsApp: ${s.empresaWhatsapp}');
    default:
      return const [];
  }
}

// ----- bloques MULTI ---------------------------------------------------------

List<int> _bloqueMulti(
  Generator gen,
  ReciboBloque b,
  List<Map<String, dynamic>> rows,
  AppSettings s,
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows,
  List<Map<String, dynamic>> cargosRows,
) {
  final first = rows.first;
  // Ídem single: el tamaño del diseñador aplica al bloque. Los casos que
  // delegan en `_bloqueSingle` lo re-setean ahí (mismo valor, inofensivo).
  _setTamano(b.id == 'logo' ? ReciboTextoSize.normal : b.size);
  switch (b.id) {
    // Encabezado/pie iguales al single (usan la primera fila).
    case 'logo':
    case 'empresa':
    case 'titulo':
    case 'pie':
    case 'whatsapp':
      return _bloqueSingle(gen, b, first, s, logoBytes, moraRows, cargosRows);
    case 'meta':
      final emision = DateTime.parse(first['fecha_pago'] as String);
      final cuerpoMeta = _emitirCamposEscpos(b, {
        'meta.numero': _fila(gen, 'Recibos',
            '${first['numero_completo']} - ${rows.last['numero_completo']}'),
        'meta.fecha': _fila(gen, 'Fecha', Fmt.fechaCorta(emision)),
        'meta.hora': _fila(gen, 'Hora', Fmt.hora(emision)),
        'meta.cobrador': _fila(gen, 'Colector', first['cobrador_nombre'] as String),
      });
      return [
        ..._centro(gen, 'COBRO MÚLTIPLE (${rows.length} cuotas)', bold: true),
        ...cuerpoMeta,
      ];
    case 'cliente':
      return _emitirCamposEscpos(b, {
        'cliente.nombre': _fila(gen, 'Cliente', first['cliente_nombre'] as String),
        'cliente.id': first['cliente_codigo'] != null
            ? _fila(gen, 'ID', first['cliente_codigo'] as String)
            : null,
        'cliente.cedula': first['cliente_cedula'] != null
            ? _fila(gen, 'Cédula', first['cliente_cedula'] as String)
            : null,
      });
    case 'servicio':
      return const []; // en multi la lista de cuotas cubre el servicio.
    case 'cuota':
      final out = <int>[];
      for (final r in rows) {
        final label = Fmt.mesServicioLabel(
            DateTime.parse(r['periodo'] as String),
            (r['dia_pago'] as num?)?.toInt());
        out.addAll(_fila(gen, label, Fmt.cordobas(r['monto_cordobas'] as num)));
        out.addAll(_lineasCargos(gen, cargosRows, r['cuota_id'], s));
      }
      return out;
    case 'metodo':
      final esUsd = (first['moneda'] as String?) == 'USD';
      return _emitirCamposEscpos(b, {
        'metodo.metodo': _fila(gen, 'Método',
            MetodoPago.fromString(first['metodo'] as String).label.toUpperCase()),
        'metodo.referencia': first['referencia'] != null
            ? _fila(gen, 'Ref.', first['referencia'] as String)
            : null,
        'metodo.recibido': esUsd
            ? _fila(
                gen,
                'Recibido',
                'US\$${_sum(rows, 'monto_original').toStringAsFixed(2)} '
                    '(tasa ${(first['tasa_conversion'] as num).toStringAsFixed(2)})')
            : null,
      });
    case 'letras':
      return _centro(
          gen,
          montoALetras(_sum(rows, 'monto_cordobas'),
              moneda: (first['moneda'] as String?) ?? 'NIO'),
          bold: true);
    case 'totales':
      final totalCobrado = _sum(rows, 'monto_cordobas');
      final totalVuelto = _sum(rows, 'vuelto_cordobas');
      final esUsd = (first['moneda'] as String?) == 'USD';
      return [
        ..._total(gen, 'Total cobrado', Fmt.cordobas(totalCobrado)),
        if (totalVuelto > 0.01) ...[
          ..._total(gen, esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
              Fmt.cordobas(totalVuelto)),
          ..._total(
              gen,
              'PAGADO',
              esUsd
                  ? 'US\$${_sum(rows, 'monto_original').toStringAsFixed(2)} = ${Fmt.cordobas(totalCobrado + totalVuelto)}'
                  : Fmt.cordobas(totalCobrado + totalVuelto)),
        ],
      ];
    case 'mora':
      return _moraBloque(gen, moraRows);
    default:
      return const [];
  }
}

// ----- helpers de contenido (espejo de recibo_pdf) ---------------------------

double _sum(List<Map<String, dynamic>> rows, String campo) {
  var t = 0.0;
  for (final r in rows) {
    t += (r[campo] as num? ?? 0).toDouble();
  }
  return t;
}

bool _esPuenteSolo(Map<String, dynamic> r, List<Map<String, dynamic>> cargos) {
  final base = (r['cuota_monto'] as num?)?.toDouble() ?? 0;
  final aplicado = (r['monto_cordobas'] as num?)?.toDouble() ?? 0;
  final pagadoCuota = (r['monto_pagado_cuota'] as num? ?? aplicado).toDouble();
  final hayPuente = cargos.any((c) =>
      c['cuota_id'] == r['cuota_id'] && (c['origen'] as String?) == 'puente');
  return hayPuente && (pagadoCuota - aplicado) >= base - 0.01;
}

List<int> _lineasCargos(Generator gen, List<Map<String, dynamic>> cargos,
    Object? cuotaId, AppSettings s) {
  if (cuotaId == null) return const [];
  final mostrar = s.reciboMostrarDescuentos;
  final conMotivo = mostrar && s.reciboMostrarMotivoDescuentos;
  final out = <int>[];
  for (final c in cargos) {
    if (c['cuota_id'] == cuotaId &&
        ((c['origen'] as String?) == 'puente' || mostrar)) {
      out.addAll(_fila(
        gen,
        cargoEtiquetaRecibo(c, conMotivo: conMotivo),
        '${(c['tipo'] as String? ?? '').startsWith('descuento') ? '-' : '+'}'
        '${Fmt.cordobas(c['monto'] as num? ?? 0)}',
      ));
    }
  }
  return out;
}

List<int> _moraBloque(Generator gen, List<Map<String, dynamic>> moraRows) {
  if (moraRows.isEmpty) return const [];
  final totalMora =
      moraRows.fold<double>(0, (s, m) => s + (m['saldo'] as num).toDouble());
  return [
    ..._centro(gen, 'EN MORA', bold: true),
    for (final m in moraRows)
      ..._fila(
          gen,
          Fmt.mesServicioLabel(
              DateTime.parse(m['periodo'] as String),
              (m['dia_pago'] as num?)?.toInt()),
          Fmt.cordobas(m['saldo'] as num)),
    ..._total(gen, 'Total en mora', Fmt.cordobas(totalMora)),
  ];
}
