import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/recibo/recibo_texto_escpos.dart';

/// El modo texto nativo imprimía las tildes como símbolos sueltos: "Período"
/// salía "PerÝodo", "Método" → "MÚtodo", "más" → "mßs", "Nº" → "N║"
/// (fotos del campo, 2026-07-31).
///
/// La causa NO era la impresora: `esc_pos_utils_plus` declara
/// `Generator({this.codec = latin1})` y codifica SIEMPRE en latin1, sin mirar
/// qué tabla se le pidió con `ESC t`. Le decíamos "interpretá CP850" y le
/// mandábamos bytes latin1 — la impresora hacía lo correcto con datos malos.
///
/// Estos tests fijan que el byte que sale del codec sea el de CP850. Es un bug
/// que se detecta SOLO en papel (en pantalla el String se ve perfecto), así que
/// la red tiene que estar acá.
void main() {
  /// Lo que termina yendo por el cable: el codec de la librería sobre el texto
  /// ya mapeado. Si esto cambia, cambia lo que imprime la térmica.
  List<int> bytes(String s) => latin1.encode(codificarCp850(s));

  group('las minúsculas acentuadas salen en su byte CP850', () {
    test('á é í ó ú ü', () {
      expect(bytes('á'), [0xA0]);
      expect(bytes('é'), [0x82]);
      expect(bytes('í'), [0xA1]);
      expect(bytes('ó'), [0xA2]);
      expect(bytes('ú'), [0xA3]);
      expect(bytes('ü'), [0x81]);
    });

    test('la ñ, que es la que NO se puede transliterar sin cambiar el nombre',
        () {
      expect(bytes('ñ'), [0xA4]);
      expect(bytes('Ñ'), [0xA5]);
    });
  });

  group('exactamente los caracteres que salieron mal en el papel', () {
    // Cada caso es un byte latin1 que la impresora leyó en CP850 y mostró como
    // otra cosa. Con el fix, el byte emitido ya es el de CP850.
    test('í ya no viaja como 0xED (que en CP850 se ve Ý)', () {
      expect(latin1.encode('í'), [0xED], reason: 'así viajaba antes');
      expect(bytes('í'), [0xA1], reason: 'y así tiene que viajar ahora');
    });

    test('é ya no viaja como 0xE9 (Ú)', () {
      expect(latin1.encode('é'), [0xE9]);
      expect(bytes('é'), [0x82]);
    });

    test('Ó ya no viaja como 0xD3 (Ë)', () {
      expect(latin1.encode('Ó'), [0xD3]);
      expect(bytes('Ó'), [0xE0]);
    });

    test('º ya no viaja como 0xBA (║, las dos barras del "Recibo Nº")', () {
      expect(latin1.encode('º'), [0xBA]);
      expect(bytes('º'), [0xA7]);
    });
  });

  group('las mayúsculas acentuadas', () {
    test('Á É Í Ó Ú', () {
      expect(bytes('Á'), [0xB5]);
      expect(bytes('É'), [0x90]);
      expect(bytes('Í'), [0xD6]);
      expect(bytes('Ó'), [0xE0]);
      expect(bytes('Ú'), [0xE9]);
    });
  });

  group('lo que NO debe romperse', () {
    test('el ASCII pasa intacto', () {
      expect(bytes('Recibo N: OF-11185'), latin1.encode('Recibo N: OF-11185'));
    });

    test('el largo en caracteres no cambia: la aritmética de columnas de row() '
        'cuenta posiciones y un mapeo 1:1 no la mueve', () {
      for (final s in ['Período', 'Método', 'más', 'Núñez', 'Ñandú', r'C$ 1,282.00']) {
        expect(codificarCp850(s).length, s.length, reason: s);
      }
    });

    test('una palabra entera del recibo real', () {
      expect(bytes('Período'), [0x50, 0x65, 0x72, 0xA1, 0x6F, 0x64, 0x6F]);
    });
  });

  group('lo no representable no puede reventar la impresión', () {
    // `latin1.encode` TIRA EXCEPCIÓN con codepoints > 0xFF: un emoji en el
    // nombre de un cliente dejaba el recibo sin imprimir, no era cosmético.
    test('un emoji en el nombre cae a ASCII en vez de tirar', () {
      expect(() => latin1.encode('Ana 🎉'), throwsA(anything),
          reason: 'sin el mapeo, esto es lo que pasaba');
      expect(() => bytes('Ana 🎉'), returnsNormally);
    });

    test('todo lo emitido entra en un byte', () {
      for (final c in codificarCp850('Ana 🎉 Peña ½ € Ω').codeUnits) {
        expect(c, lessThanOrEqualTo(0xFF));
      }
    });
  });
}
