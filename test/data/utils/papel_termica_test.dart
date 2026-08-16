import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/papel_termica.dart';

/// Un milímetro en puntos PDF.
const _mm = 72 / 25.4;

/// Escala que aplica el plugin de Windows: `LOGPIXELSX / 72`.
double dotsEnImpresora(double puntos, {double dpi = 203}) => puntos * dpi / 72;

/// Geometría del recibo en el camino de ESCRITORIO. Tres bugs encadenados de
/// producción, cada uno destapado al arreglar el anterior:
///
///   1. página de 80mm → 639,37 dots (fraccionario) → texto GRIS por reescalado,
///      y el contenido se pasaba de los 72,07mm imprimibles → CORTE A LA DERECHA.
///   2. página de 72,07mm (dots exactos) → texto nítido, pero el driver la apoyó
///      en el borde del PAPEL y no donde arranca el cabezal → los primeros
///      3,96mm cayeron en zona muerta → CORTE A LA IZQUIERDA. Se arregló un lado
///      y se rompió el otro.
///   3. página del ancho del PAPEL en dots enteros, con el contenido metido
///      media zona muerta de cada lado → cae justo en los 576 dots que imprime
///      el cabezal, y da igual dónde apoye el driver.
///
/// Estos tests fijan el invariante del punto 3.
void main() {
  group('la página cae en dots ENTEROS (si no, el texto sale gris)', () {
    test('rollo de 80 → 640 dots exactos', () {
      final dots = dotsEnImpresora(anchoPaginaPuntos(80));
      expect(dots, closeTo(640, 0.01));
      expect(dots % 1, lessThan(0.01),
          reason: 'fraccionario = cada glifo se reescala y sale gris');
    });

    test('rollo de 58 → 464 dots exactos', () {
      expect(dotsEnImpresora(anchoPaginaPuntos(58)), closeTo(464, 0.01));
    });

    test('el 80mm crudo NO cae en dots enteros (por qué fallaba el intento 1)',
        () {
      expect(dotsEnImpresora(80 * _mm), closeTo(639.37, 0.05));
      expect(dotsEnImpresora(80 * _mm) % 1, greaterThan(0.1));
    });
  });

  group('la página mide lo que el PAPEL (si no, el driver la corre)', () {
    test('rollo de 80 → la página es ~80mm', () {
      expect(anchoPaginaPuntos(80) / _mm, closeTo(80, 0.15));
    });

    test('rollo de 58 → la página es ~58mm', () {
      expect(anchoPaginaPuntos(58) / _mm, closeTo(58, 0.15));
    });

    test('REGRESIÓN: la página NO puede ser solo el área imprimible', () {
      // Esto fue el intento 2: 72,07mm. Nítido pero corrido → corte izquierdo.
      expect(anchoPaginaPuntos(80) / _mm, greaterThan(75),
          reason: 'una página más angosta que el papel se puede correr');
      expect(anchoPaginaPuntos(58) / _mm, greaterThan(54));
    });
  });

  group('el contenido cae DENTRO de lo que el cabezal imprime', () {
    test('rollo de 80 → quedan exactamente los 576 dots del cabezal', () {
      final utiles = dotsEnImpresora(
          anchoPaginaPuntos(80) - 2 * margenHorizontalPuntos(80));
      expect(utiles, closeTo(576, 0.5),
          reason: 'de más se corta, de menos se desperdicia papel');
    });

    test('rollo de 58 → quedan exactamente los 384 dots del cabezal', () {
      final utiles = dotsEnImpresora(
          anchoPaginaPuntos(58) - 2 * margenHorizontalPuntos(58));
      expect(utiles, closeTo(384, 0.5));
    });

    test('el margen es la MITAD de la zona muerta, a cada lado', () {
      // El cabezal viene centrado en el rollo, así que la zona muerta se
      // reparte. Si el margen fuera el total, el recibo saldría corrido.
      expect(dotsEnImpresora(margenHorizontalPuntos(80)), closeTo(32, 0.5));
      expect(dotsEnImpresora(margenHorizontalPuntos(58)), closeTo(40, 0.5));
    });

    test('REGRESIÓN: el margen no puede ser un respiro estético chico', () {
      // Era 6pt (17 dots) — menos que los 32 de zona muerta, y por eso se
      // comía la primera letra de cada etiqueta.
      expect(margenHorizontalPuntos(80), greaterThan(10));
      expect(margenHorizontalPuntos(58), greaterThan(12));
    });

    test('el margen no se come el recibo: queda al menos 80% útil', () {
      for (final mm in [80, 58]) {
        final contenido =
            anchoPaginaPuntos(mm) - 2 * margenHorizontalPuntos(mm);
        expect(contenido / anchoPaginaPuntos(mm), greaterThan(0.8),
            reason: 'en $mm mm el margen deja el recibo muy angosto');
      }
    });
  });

  group('anchos raros no rompen', () {
    test('cualquier ancho >= 80 se trata como rollo de 80', () {
      expect(anchoPaginaPuntos(100), anchoPaginaPuntos(80));
      expect(margenHorizontalPuntos(100), margenHorizontalPuntos(80));
    });

    test('los anchos legacy (57, 0) caen en el formato chico', () {
      expect(anchoPaginaPuntos(57), anchoPaginaPuntos(58));
      expect(anchoPaginaPuntos(0), anchoPaginaPuntos(58));
    });
  });

  test('el alto de respaldo es FINITO y entra en un short', () {
    // El plugin hace `dmPaperLength = round(alto * 254 / 72)` sobre un short.
    // Infinito ahí era comportamiento indefinido: DEVMODE corrupto, Windows lo
    // descartaba y la app perdía el control del papel.
    expect(altoFallbackPuntos.isFinite, isTrue);
    final decimasDeMm = (altoFallbackPuntos * 254 / 72).round();
    expect(decimasDeMm, greaterThan(0));
    expect(decimasDeMm, lessThan(32767),
        reason: 'no puede desbordar el short del DEVMODE');
  });
}
