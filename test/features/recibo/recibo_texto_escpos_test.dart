import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:isp_billing/data/repositories/settings_repo.dart';
import 'package:isp_billing/features/recibo/recibo_texto_escpos.dart';

void main() {
  // CapabilityProfile.load() lee un asset JSON del paquete → hace falta el
  // binding de test para el asset bundle. Fmt.fechaCorta usa el locale es_NI.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('es_NI', null));

  // Valida el núcleo del modo Compatible: que el codepage español (CP850)
  // exista en el perfil y codifique las tildes como 1 BYTE de codepage —
  // NO como UTF-8 crudo (0xC3 0xAn), que es justo lo que las térmicas chinas
  // interpretan como "caracteres chinos".
  test('CP850 codifica tildes como byte de codepage, no UTF-8', () async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(PaperSize.mm80, profile);

    final bytes =
        gen.text('Período más Ñoño', styles: const PosStyles(codeTable: 'CP850'));

    expect(bytes, isNotEmpty);

    // Hay al menos un byte alto (0x80-0xFE) = una tilde codificada al codepage.
    expect(bytes.any((b) => b >= 0x80 && b < 0xFF), isTrue,
        reason: 'las tildes deben salir como bytes del codepage');

    // NO debe aparecer la secuencia UTF-8 de 'í' (0xC3 0xAD) ni de 'á' (0xC3 0xA1):
    // si apareciera, se estaría mandando UTF-8 crudo → garabatos en la térmica.
    var hayUtf8 = false;
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0xC3 && (bytes[i + 1] == 0xAD || bytes[i + 1] == 0xA1)) {
        hayUtf8 = true;
      }
    }
    expect(hayUtf8, isFalse, reason: 'no debe mandar UTF-8 crudo');
  });

  test('el comando de selección de codepage (ESC t) va en el stream', () async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(PaperSize.mm80, profile);
    final bytes = gen.text('áéíóú', styles: const PosStyles(codeTable: 'CP850'));
    // ESC t n (0x1B 0x74 n) = seleccionar tabla de caracteres.
    var hayEscT = false;
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x1B && bytes[i + 1] == 0x74) hayEscT = true;
    }
    expect(hayEscT, isTrue,
        reason: 'debe emitir ESC t para fijar el codepage en la impresora');
  });

  // Row mínimo válido para construir el recibo (single). Los campos son los que
  // leen los bloques del renderer.
  Map<String, dynamic> rowDemo() => {
        'numero_completo': 'SA-01418',
        'fecha_pago': '2026-06-30T00:00:00',
        'cobrador_nombre': 'System Admin',
        'cliente_nombre': 'David Pineda Sáenz',
        'cliente_codigo': 'SE0020',
        'cliente_cedula': null,
        'periodo': '2026-06-01',
        'fecha_vencimiento': '2026-06-30',
        'plan_nombre': 'INTERNET 20MB',
        'cuota_descripcion': null,
        'ticket_correlativo': null,
        'cuota_id': 'cu-1',
        'cuota_monto': 732.0,
        'cargos_neto': 0.0,
        'monto_pagado_cuota': 732.0,
        'monto_cordobas': 732.0,
        'vuelto_cordobas': 0.0,
        'monto_original': 732.0,
        'tasa_conversion': 1.0,
        'metodo': 'efectivo',
        'referencia': null,
        'moneda': 'NIO',
      };

  test('el recibo CANCELA el modo chino (FS .) justo después del reset',
      () async {
    final bytes = await construirReciboTextoEscPos(
      row: rowDemo(),
      settings: AppSettings(null),
      anchoMm: 80,
    );
    // FS . = 0x1C 0x2E — sin esto, las térmicas chinas (GBK) interpretan los
    // bytes altos de las tildes como ideogramas de 2 bytes (bug 3nStar).
    var hayFsDot = false;
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x1C && bytes[i + 1] == 0x2E) hayFsDot = true;
    }
    expect(hayFsDot, isTrue,
        reason: 'debe cancelar el modo Kanji/chino tras el reset');
  });

  test('quitarTildes translitera a ASCII y reemplaza lo desconocido', () {
    expect(quitarTildes('Período Código Método más Ñoño ¿¡ Nº'),
        'Periodo Codigo Metodo mas Nono ?! No');
    // Nada no-ASCII sobrevive (un emoji en el pie del recibo, por ejemplo).
    expect(quitarTildes('ok💥ok').codeUnits.every((c) => c < 0x80), isTrue);
  });

  test('NBSP de Fmt.cordobas se normaliza a espacio común, NO a "?"', () {
    // NumberFormat.currency separa monto y "C\$" con U+00A0 (confirmado
    // 0x30 0xA0 0x43 0x24 en "732,00 C\$"). Ese char rompía los 3 modos:
    // '?' en ascii ("732,00?C\$") y "C" comida en cp850/gbk ("732,00蜆\$").
    const conNbsp = '732,00 C\$';
    expect(quitarTildes(conNbsp), '732,00 C\$');
  });

  test('modo GBK: ñ/Ñ van como glifos de usuario (ESC & + ESC % + códigos)',
      () async {
    final row = rowDemo()..['cliente_nombre'] = 'Peña Núñez';
    final bytes = await construirReciboTextoEscPos(
      row: row,
      settings: AppSettings(null),
      anchoMm: 80,
      tildesModo: 'gbk',
    );
    var hayDefEnie = false; // ESC & 3 0x7B 0x7B (definición de ñ)
    var hayActivacion = false; // ESC % 1 (set de usuario ON)
    for (var i = 0; i < bytes.length - 4; i++) {
      if (bytes[i] == 0x1B &&
          bytes[i + 1] == 0x26 &&
          bytes[i + 2] == 0x03 &&
          bytes[i + 3] == 0x7B) {
        hayDefEnie = true;
      }
      if (bytes[i] == 0x1B && bytes[i + 1] == 0x25 && bytes[i + 2] == 0x01) {
        hayActivacion = true;
      }
    }
    expect(hayDefEnie, isTrue, reason: 'debe definir el glifo de ñ (ESC &)');
    expect(hayActivacion, isTrue,
        reason: 'debe activar el set de usuario (ESC % 1)');
    // "Peña" → la ñ viaja como 0x7B ('{' remapeado al glifo) precedida de 'e'.
    var hayEnieCodificada = false;
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x65 && bytes[i + 1] == 0x7B) hayEnieCodificada = true;
    }
    expect(hayEnieCodificada, isTrue,
        reason: 'la ñ de "Peña" debe ir como código 0x7B');
  });

  test('modo GBK: la tilde va como par pinyin GB2312 + FS & presente',
      () async {
    final bytes = await construirReciboTextoEscPos(
      row: rowDemo(),
      settings: AppSettings(null),
      anchoMm: 80,
      tildesModo: 'gbk',
    );
    // "Período" → la í debe ir como el par GB2312 0xA8 0xAA (zona pinyin).
    var hayPinyinI = false;
    var hayFsAmp = false; // FS & = 0x1C 0x26 (modo Kanji ON)
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0xA8 && bytes[i + 1] == 0xAA) hayPinyinI = true;
      if (bytes[i] == 0x1C && bytes[i + 1] == 0x26) hayFsAmp = true;
    }
    expect(hayPinyinI, isTrue,
        reason: 'la í de "Período" debe codificarse como pinyin GB2312');
    expect(hayFsAmp, isTrue, reason: 'debe asegurar el modo Kanji ON');
    // Y el NBSP del monto NO debe aparecer como byte alto suelto (0xFF/0xA0
    // pegado a la C) — normalizado a espacio.
    var nbspCrudo = false;
    for (var i = 0; i < bytes.length - 1; i++) {
      if ((bytes[i] == 0xFF || bytes[i] == 0xA0) && bytes[i + 1] == 0x43) {
        nbspCrudo = true;
      }
    }
    expect(nbspCrudo, isFalse, reason: 'el NBSP antes de C\$ debe ser espacio');
  });

  test('modo sin tildes: el stream NO contiene NINGÚN byte alto de texto',
      () async {
    final bytes = await construirReciboTextoEscPos(
      row: rowDemo(),
      settings: AppSettings(null),
      anchoMm: 80,
      tildesModo: 'ascii',
    );
    // Sin bytes altos no hay NADA que un firmware en modo chino pueda
    // malinterpretar (GBK es ASCII-compatible). Los únicos bytes >0x7F
    // permitidos serían de comandos gráficos — acá no hay logo (logoBytes null),
    // así que el stream entero debe ser <0x80 salvo argumentos de comandos ESC
    // conocidos (ESC t n / GS ! n usan n chicos). Chequeo estricto: ningún par
    // consecutivo de bytes altos (que es la firma de un ideograma GBK).
    var paresAltos = 0;
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] >= 0x80 && bytes[i + 1] >= 0x80) paresAltos++;
    }
    expect(paresAltos, 0,
        reason: 'con tildes=false no debe haber pares de bytes altos');
  });

  test(
      'filasPlanas (Windows/RPT004): las filas etiqueta:valor se rellenan con '
      'ESPACIOS (el valor se ubica por conteo de chars, no por ESC \$)',
      () async {
    final bytes = await construirReciboTextoEscPos(
      row: rowDemo(),
      settings: AppSettings(null),
      anchoMm: 80,
      tildesModo: 'ascii',
      filasPlanas: true,
      maxCharsPorLinea: 42,
    );
    // La fila plana rellena etiqueta↔valor con un RUN de espacios literales
    // (0x20). gen.row NO haría esto (posiciona cada columna con ESC \$ absoluto);
    // ese run largo es la firma de que la fila salió como texto plano paddeado.
    var maxRun = 0, run = 0;
    for (final b in bytes) {
      if (b == 0x20) {
        run++;
        if (run > maxRun) maxRun = run;
      } else {
        run = 0;
      }
    }
    expect(maxRun, greaterThanOrEqualTo(10),
        reason: 'la fila plana debe rellenar con espacios entre etiqueta y valor');
  });

  test(
      'SIN filasPlanas (default = Android/Bluetooth): las filas usan gen.row, '
      'sin el run largo de espacios → byte-comportamiento intacto', () async {
    final bytes = await construirReciboTextoEscPos(
      row: rowDemo(),
      settings: AppSettings(null),
      anchoMm: 80,
      tildesModo: 'ascii',
    );
    var maxRun = 0, run = 0;
    for (final b in bytes) {
      if (b == 0x20) {
        run++;
        if (run > maxRun) maxRun = run;
      } else {
        run = 0;
      }
    }
    expect(maxRun, lessThan(10),
        reason: 'gen.row posiciona por ESC \$, no con runs largos de espacios');
  });

  test(
      'filasPlanas: NINGUNA línea supera el ancho del papel — incluido el monto '
      'en letras (se parte por palabras en vez de cortarse)', () async {
    // "UN MIL DOSCIENTOS OCHENTA Y DOS CORDOBAS CON 00/100" = 51 chars = 612
    // dots > 576 del cabezal: sin partir, la térmica lo CORTABA (foto del campo).
    final row = rowDemo()
      ..['monto_cordobas'] = 1282.0
      ..['cuota_monto'] = 1282.0
      ..['monto_pagado_cuota'] = 1282.0
      ..['monto_original'] = 1282.0;
    const cols = 42;
    final bytes = await construirReciboTextoEscPos(
      row: row,
      settings: AppSettings(null),
      anchoMm: 80,
      tildesModo: 'ascii',
      filasPlanas: true,
      maxCharsPorLinea: cols,
    );
    // Reconstruir las líneas IMPRIMIBLES: los comandos ESC/GS traen argumentos
    // binarios, así que se cuentan solo los tramos de chars imprimibles entre
    // saltos de línea, salteando cada comando con su(s) argumento(s).
    var maxLinea = 0, actual = 0;
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b == 0x1B || b == 0x1D || b == 0x1C) {
        i += 2; // saltear el comando + sus args más comunes (aprox. suficiente)
        continue;
      }
      if (b == 0x0A) {
        if (actual > maxLinea) maxLinea = actual;
        actual = 0;
      } else if (b >= 0x20 && b < 0x7F) {
        actual++;
      }
    }
    if (actual > maxLinea) maxLinea = actual;
    // Tope: el bloque (cols) + la sangría izquierda que centra el bloque en el
    // papel. Nunca los 48 chars (576 dots) que el cabezal puede imprimir.
    expect(maxLinea, lessThanOrEqualTo(48),
        reason: 'ninguna línea puede exceder los 48 chars (576 dots) del papel');
  });
}
