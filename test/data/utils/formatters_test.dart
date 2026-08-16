import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:isp_billing/data/utils/formatters.dart';

/// Tests de Fmt — formatters de moneda, fecha y período usados en
/// **todas las pantallas** del repo (dashboard, recibo, lista de
/// cuotas, lista de pagos, historial, etc.).
///
/// Si una rompe, se rompe en todas esas pantallas a la vez. Tests
/// pensados como guardia ante regresión sutil (especialmente
/// `fechaRelativa` que tiene lógica condicional compleja).
void main() {
  setUpAll(() async {
    // initializeDateFormatting cargar los locale data de es_NI para
    // que DateFormat con `'EEEE'`/`'MMMM'` retorne nombres en español.
    // Sin esto, los tests fallan con LocaleDataException.
    await initializeDateFormatting('es_NI', null);
  });

  group('Fmt.cordobas', () {
    test('formato con 2 decimales', () {
      // El locale es_NI usa coma decimal y punto miles. Verificamos
      // que el output contiene los componentes clave en vez de match
      // exacto (resistente a variaciones de locale data).
      final out = Fmt.cordobas(750.5);
      expect(out, contains('C\$'));
      expect(out, contains('750'));
      expect(out, contains('50'));
    });

    test('entero — agrega 00 decimales', () {
      final out = Fmt.cordobas(1000);
      expect(out, contains('C\$'));
      expect(out, contains('1'));
      expect(out, contains('000'));
    });

    test('cero', () {
      final out = Fmt.cordobas(0);
      expect(out, contains('C\$'));
      expect(out, contains('0'));
    });

    test('negativo (raro pero posible en reportes)', () {
      final out = Fmt.cordobas(-50);
      expect(out, contains('50'));
    });
  });

  group('Fmt.dolares', () {
    test('formato dólar', () {
      final out = Fmt.dolares(20);
      expect(out, contains('US\$'));
      expect(out, contains('20'));
    });

    test('decimales', () {
      final out = Fmt.dolares(36.5);
      expect(out, contains('US\$'));
      expect(out, contains('36'));
      expect(out, contains('50'));
    });
  });

  group('Fmt.monto (selector por moneda)', () {
    test('moneda USD usa dolares', () {
      expect(Fmt.monto(100, 'USD'), contains('US\$'));
    });

    test('moneda NIO usa cordobas', () {
      expect(Fmt.monto(100, 'NIO'), contains('C\$'));
    });

    test('cualquier otro string default a cordobas', () {
      // Comportamiento del else: solo USD desvía. EUR, GBP, etc. → C$.
      expect(Fmt.monto(100, 'EUR'), contains('C\$'));
      expect(Fmt.monto(100, ''), contains('C\$'));
    });
  });

  group('Fmt.fechaCorta', () {
    test('formato dd/MM/yyyy', () {
      expect(Fmt.fechaCorta(DateTime(2026, 5, 22)), '22/05/2026');
    });

    test('mes y día con leading zero', () {
      expect(Fmt.fechaCorta(DateTime(2026, 1, 5)), '05/01/2026');
    });
  });

  group('Fmt.fechaRelativa (lógica condicional crítica)', () {
    final hoy = DateTime(2026, 5, 22);

    test('mismo día → Hoy', () {
      expect(Fmt.fechaRelativa(hoy, hoy), 'Hoy');
    });

    test('hora distinta mismo día → Hoy (ignora hora, solo fecha)', () {
      // El método extrae year/month/day, ignora hora/min/seg.
      expect(
        Fmt.fechaRelativa(
          DateTime(2026, 5, 22, 23, 59, 59),
          DateTime(2026, 5, 22, 0, 0, 0),
        ),
        'Hoy',
      );
    });

    test('un día atrás → Ayer', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 21), hoy), 'Ayer');
    });

    test('un día adelante → Mañana', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 23), hoy), 'Mañana');
    });

    test('3 días adelante → En 3 días', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 25), hoy), 'En 3 días');
    });

    test('6 días adelante (boundary inclusivo) → En 6 días', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 28), hoy), 'En 6 días');
    });

    test('7 días adelante (boundary exclusivo) → fecha corta absoluta', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 29), hoy), '29/05/2026');
    });

    test('5 días atrás → Hace 5 días', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 17), hoy), 'Hace 5 días');
    });

    test('6 días atrás (boundary inclusivo) → Hace 6 días', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 16), hoy), 'Hace 6 días');
    });

    test('7 días atrás (boundary exclusivo) → fecha corta absoluta', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 15), hoy), '15/05/2026');
    });

    test('mes anterior → fecha corta absoluta', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 4, 1), hoy), '01/04/2026');
    });

    test('parámetro hoy default a DateTime.now() no lanza excepción', () {
      // Eliminado el test estricto que assertaba 'Hoy' — flaky por
      // racing con medianoche entre el now() capturado y el now() que
      // computa el default del param. Acá solo verificamos que la
      // función no rompe cuando se llama sin `hoy` — el valor de
      // retorno (Hoy/Ayer/Mañana según el momento) ya está cubierto
      // por los tests con `hoy:` explícito de arriba.
      expect(() => Fmt.fechaRelativa(DateTime.now()), returnsNormally);
    });
  });

  group('Fmt.hora', () {
    test('formato HH:mm 24h', () {
      expect(Fmt.hora(DateTime(2026, 5, 22, 14, 30)), '14:30');
    });

    test('media noche', () {
      expect(Fmt.hora(DateTime(2026, 5, 22, 0, 0)), '00:00');
    });

    test('un minuto antes de media noche', () {
      expect(Fmt.hora(DateTime(2026, 5, 22, 23, 59)), '23:59');
    });

    test('leading zero en minutos', () {
      expect(Fmt.hora(DateTime(2026, 5, 22, 9, 5)), '09:05');
    });
  });

  group('Fmt.periodoRecibo / mesServicio (MES DE SERVICIO — regla 2026-08-01)', () {
    // Rubén: la cuota se nombra por el mes de SERVICIO, anclado al día de pago
    // FIJO. día 1-14 → mes = período−1; día 15+ → mes = período. Reemplaza el
    // "mes de período" de v0.31.3 (que dejaba todo un mes adelantado para ≤14).

    test('día 1-14 → el mes ANTERIOR al período', () {
      for (final dia in [1, 5, 10, 14]) {
        expect(Fmt.periodoRecibo(dia, DateTime(2026, 5, 1)).toLowerCase(),
            contains('abril'),
            reason: 'día $dia (≤14) sobre período mayo debería dar abril');
      }
    });

    test('día 15-31 → el mes del período', () {
      for (final dia in [15, 16, 25, 31]) {
        expect(Fmt.periodoRecibo(dia, DateTime(2026, 5, 1)).toLowerCase(),
            contains('mayo'),
            reason: 'día $dia (≥15) sobre período mayo debería dar mayo');
      }
    });

    test('rollover: período enero + día ≤14 → diciembre del año previo', () {
      final out = Fmt.periodoRecibo(5, DateTime(2027, 1, 1));
      expect(out.toLowerCase(), contains('diciembre'));
      expect(out, contains('2026'));
    });

    test('período enero + día ≥15 → enero (sin corrimiento)', () {
      final out = Fmt.periodoRecibo(20, DateTime(2027, 1, 1));
      expect(out.toLowerCase(), contains('enero'));
      expect(out, contains('2027'));
    });

    test('meses consecutivos → labels ÚNICOS y consecutivos', () {
      // El corrimiento es uniforme (mismo día) → consecutivos siguen distintos.
      final labels = [
        for (var m = 2; m <= 10; m++)
          Fmt.mesServicioLabel(DateTime(2026, m, 1), 5),
      ];
      expect(labels, [
        'Enero 2026', 'Febrero 2026', 'Marzo 2026', 'Abril 2026', 'Mayo 2026',
        'Junio 2026', 'Julio 2026', 'Agosto 2026', 'Septiembre 2026',
      ]);
    });
  });

  group('Fmt.fechaLarga', () {
    test('formato legible con nombre de mes en español', () {
      final out = Fmt.fechaLarga(DateTime(2026, 5, 22));
      // Esperado: "22 de mayo de 2026"
      expect(out, contains('22'));
      expect(out.toLowerCase(), contains('mayo'));
      expect(out, contains('2026'));
      expect(out, contains('de'));
    });

    test('primer día del año', () {
      final out = Fmt.fechaLarga(DateTime(2026, 1, 1));
      expect(out, contains('1'));
      expect(out.toLowerCase(), contains('enero'));
      expect(out, contains('2026'));
    });

    test('último día del año', () {
      final out = Fmt.fechaLarga(DateTime(2026, 12, 31));
      expect(out, contains('31'));
      expect(out.toLowerCase(), contains('diciembre'));
      expect(out, contains('2026'));
    });

    test('día sin leading zero (formato d, no dd)', () {
      // El patrón es "d 'de' MMMM 'de' y" — día sin padding.
      final out = Fmt.fechaLarga(DateTime(2026, 3, 5));
      // Debe ser "5 de marzo de 2026", NO "05 de marzo de 2026".
      expect(out, startsWith('5'));
    });
  });

  group('Fmt.mes', () {
    test('formato MMMM y con nombre de mes en español', () {
      final out = Fmt.mes(DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('mayo'));
      expect(out, contains('2026'));
    });

    test('enero', () {
      final out = Fmt.mes(DateTime(2026, 1, 15));
      expect(out.toLowerCase(), contains('enero'));
      expect(out, contains('2026'));
    });

    test('diciembre — boundary fin de año', () {
      final out = Fmt.mes(DateTime(2026, 12, 25));
      expect(out.toLowerCase(), contains('diciembre'));
      expect(out, contains('2026'));
    });

    test('ignora el día — solo muestra mes y año', () {
      // Dos fechas del mismo mes con días distintos deben dar idéntico output.
      final a = Fmt.mes(DateTime(2026, 7, 1));
      final b = Fmt.mes(DateTime(2026, 7, 31));
      expect(a, equals(b));
    });
  });

  group('Fmt.diaSemana', () {
    test('viernes — nombre completo en español con mayúscula inicial', () {
      // 22 de mayo 2026 es viernes.
      final out = Fmt.diaSemana(DateTime(2026, 5, 22));
      expect(out.toLowerCase(), equals('viernes'));
      // Verifica que la primera letra es mayúscula.
      expect(out[0], equals(out[0].toUpperCase()));
    });

    test('lunes — primer día laboral', () {
      // 25 de mayo 2026 es lunes.
      final out = Fmt.diaSemana(DateTime(2026, 5, 25));
      expect(out.toLowerCase(), equals('lunes'));
      expect(out[0], equals('L'));
    });

    test('domingo', () {
      // 24 de mayo 2026 es domingo.
      final out = Fmt.diaSemana(DateTime(2026, 5, 24));
      expect(out.toLowerCase(), equals('domingo'));
      expect(out[0], equals('D'));
    });

    test('capitalización — solo la primera letra es mayúscula', () {
      // El método hace [0].toUpperCase() + substring(1). Verificamos
      // que el resto está en minúscula (como viene de DateFormat).
      final out = Fmt.diaSemana(DateTime(2026, 5, 22));
      expect(out, equals(out[0].toUpperCase() + out.substring(1).toLowerCase()));
    });

    test('sábado — fin de semana', () {
      // 23 de mayo 2026 es sábado.
      final out = Fmt.diaSemana(DateTime(2026, 5, 23));
      expect(out.toLowerCase(), equals('sábado'));
      expect(out[0], equals('S'));
    });
  });

  group('el mes que se MUESTRA = MES DE SERVICIO anclado al día fijo (2026-08-01)', () {
    // Rubén: la cuota se nombra por el mes de servicio consumido. día 1-14 →
    // período−1; día 15+ → período. Anclado al día de pago FIJO (no al
    // vencimiento corrido domingo→lunes) → el mes es CONSTANTE.

    test('SE0047 (Jeymi, día 5): la serie corre un mes atrás', () {
      // Períodos feb..jul → Enero..Junio.
      expect(Fmt.mesServicioLabel(DateTime(2026, 2, 1), 5), 'Enero 2026');
      expect(Fmt.mesServicioLabel(DateTime(2026, 3, 1), 5), 'Febrero 2026');
      expect(Fmt.mesServicioLabel(DateTime(2026, 7, 1), 5), 'Junio 2026');
    });

    test('PN0190 (Heizell, día 14): también corre (junio→mayo, julio→junio)', () {
      // día 14 es ≤14 → corre. Antes (v0.31.3) daba Junio/Julio; ahora Mayo/Junio.
      expect(Fmt.mesServicioLabel(DateTime(2026, 6, 1), 14), 'Mayo 2026');
      expect(Fmt.mesServicioLabel(DateTime(2026, 7, 1), 14), 'Junio 2026');
    });

    test('día 15+ NO corre: el mes es el del período', () {
      final periodo = DateTime(2026, 7, 1);
      for (final dia in [15, 16, 20, 25, 31]) {
        expect(Fmt.mesServicioLabel(periodo, dia), 'Julio 2026',
            reason: 'día $dia');
      }
    });

    test('día 1-14 SIEMPRE corre un mes atrás', () {
      final periodo = DateTime(2026, 7, 1);
      for (final dia in [1, 5, 10, 14]) {
        expect(Fmt.mesServicioLabel(periodo, dia), 'Junio 2026',
            reason: 'día $dia');
      }
    });

    test('sin dia_pago (cuota manual) NO corre: usa el mes del período', () {
      expect(Fmt.mesServicioLabel(DateTime(2026, 7, 1), null), 'Julio 2026');
    });

    test('robusto al domingo→lunes: el día FIJO no depende del vencimiento', () {
      // El 14/jun/2026 cae domingo → la cuota vence el 15. Pero el labeling toma
      // el día de pago FIJO (14), no el vencimiento (15), así que el mes NO
      // salta: período junio con día 14 → Mayo (no Junio).
      expect(DateTime(2026, 6, 14).weekday, DateTime.sunday);
      expect(Fmt.mesServicioLabel(DateTime(2026, 6, 1), 14), 'Mayo 2026');
    });

    test('cruza el año: período enero + día ≤14 → diciembre del año previo', () {
      expect(Fmt.mesServicioLabel(DateTime(2026, 1, 1), 5), 'Diciembre 2025');
      expect(Fmt.mesServicioLabel(DateTime(2026, 1, 1), 20), 'Enero 2026');
    });

    test('dos cuotas consecutivas NUNCA muestran el mismo mes', () {
      for (var dia = 1; dia <= 28; dia++) {
        for (var m = 1; m <= 11; m++) {
          final a = Fmt.mesServicioLabel(DateTime(2026, m, 1), dia);
          final b = Fmt.mesServicioLabel(DateTime(2026, m + 1, 1), dia);
          expect(a, isNot(b), reason: 'dia_pago $dia, meses $m y ${m + 1}');
        }
      }
    });
  });
}
