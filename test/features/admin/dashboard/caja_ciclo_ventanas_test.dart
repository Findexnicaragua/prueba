@TestOn('vm')
library;

/// Las ventanas de la tarjeta "Caja del ciclo".
///
/// Los tres bloques dejaron de tener el corte escrito en el SQL
/// (`date('now','-6 hours')`) y ahora las fechas se calculan en Dart y viajan
/// como parámetros. Eso es lo que permite retroceder, pero mueve el cálculo de
/// límites de día a un lugar nuevo — y ahí es exactamente donde se cuela un
/// desfase que después nadie encuentra.
///
/// Estos tests son de los BORDES: el domingo que abre la semana, el 15 que
/// abre el ciclo, y que las ventanas no se pisen ni dejen huecos.

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/periodo_dashboard.dart';
import 'package:isp_billing/features/admin/dashboard/caja_ciclo_card.dart';

void main() {
  group('bloque DÍA', () {
    test('el primero es hoy y cada uno dura exactamente un día', () {
      final hoy = DateTime(2026, 8, 28);
      final o = opcionesDe(BloqueCaja.dia, hoy);

      expect(o.first.desde, DateTime(2026, 8, 28));
      expect(o.first.hasta, DateTime(2026, 8, 29),
          reason: 'el fin es EXCLUSIVO: un pago del 29 no puede entrar en hoy');
      expect(o.first.etiqueta, 'Hoy');
      expect(o[1].etiqueta, 'Ayer');
      expect(o[1].desde, DateTime(2026, 8, 27));

      for (final v in o) {
        expect(v.hasta.difference(v.desde).inDays, 1);
      }
    });

    test('cruza el fin de mes sin saltarse días', () {
      final o = opcionesDe(BloqueCaja.dia, DateTime(2026, 9, 2));
      expect(o[2].desde, DateTime(2026, 8, 31));
      expect(o[3].desde, DateTime(2026, 8, 30));
    });
  });

  group('bloque SEMANA', () {
    test('arranca en DOMINGO, y si hoy es domingo arranca hoy', () {
      // 2026-08-28 es viernes; su domingo es el 23.
      final o = opcionesDe(BloqueCaja.semana, DateTime(2026, 8, 28));
      expect(o.first.desde, DateTime(2026, 8, 23));
      expect(o.first.desde.weekday, DateTime.sunday);
      expect(o.first.hasta, DateTime(2026, 8, 30));

      // Un domingo NO retrocede a la semana anterior: la suya arranca ese día.
      final dom = DateTime(2026, 8, 23);
      expect(dom.weekday, DateTime.sunday);
      expect(opcionesDe(BloqueCaja.semana, dom).first.desde, dom);
    });

    test('un sábado sigue en la misma semana que su domingo', () {
      // El sábado es el último día: recién a medianoche arranca la siguiente.
      final sab = DateTime(2026, 8, 29);
      expect(sab.weekday, DateTime.saturday);
      expect(opcionesDe(BloqueCaja.semana, sab).first.desde,
          DateTime(2026, 8, 23));
    });

    test('las semanas son contiguas: sin huecos ni solapes', () {
      final o = opcionesDe(BloqueCaja.semana, DateTime(2026, 8, 28));
      for (var i = 0; i < o.length - 1; i++) {
        expect(o[i].desde, o[i + 1].hasta,
            reason: 'la semana ${i + 1} tiene que terminar donde arranca la $i');
        expect(o[i].hasta.difference(o[i].desde).inDays, 7);
      }
    });
  });

  group('bloque PERÍODO', () {
    test('el ciclo va del 15 al 14, y el fin es exclusivo', () {
      // 28 ago cae en el ciclo 15 ago – 14 sep.
      final o = opcionesDe(BloqueCaja.periodo, DateTime(2026, 8, 28));
      expect(o.first.desde, DateTime(2026, 8, 15));
      expect(o.first.hasta, DateTime(2026, 9, 15));
      expect(o[1].desde, DateTime(2026, 7, 15));
      expect(o[1].hasta, DateTime(2026, 8, 15));
    });

    test('el día 14 todavía pertenece al ciclo anterior', () {
      // El borde que más se equivoca: el 14 cierra el ciclo, no lo abre.
      final o = opcionesDe(BloqueCaja.periodo, DateTime(2026, 8, 14));
      expect(o.first.desde, DateTime(2026, 7, 15));
      expect(o.first.hasta, DateTime(2026, 8, 15));
    });

    test('el día 15 ya abre el ciclo nuevo', () {
      final o = opcionesDe(BloqueCaja.periodo, DateTime(2026, 8, 15));
      expect(o.first.desde, DateTime(2026, 8, 15));
    });

    test('los períodos son contiguos y cruzan el año', () {
      final o = opcionesDe(BloqueCaja.periodo, DateTime(2026, 2, 20));
      for (var i = 0; i < o.length - 1; i++) {
        expect(o[i].desde, o[i + 1].hasta);
      }
      // Enero mira a diciembre del año anterior.
      expect(o[1].desde, DateTime(2026, 1, 15));
      expect(o[2].desde, DateTime(2025, 12, 15));
    });
  });

  group('ciclo de referencia del desglose', () {
    test('un período se clasifica contra SÍ MISMO, no contra el actual', () {
      // El bug que este test cierra: si el desglose comparara contra el ciclo
      // en curso, al mirar "15 jun – 14 jul" sus propias cuotas saldrían todas
      // como "atrasos de ciclos anteriores".
      final o = opcionesDe(BloqueCaja.periodo, DateTime(2026, 8, 28));
      for (final v in o) {
        expect(v.cicloRef, v.desde,
            reason: 'el ciclo de referencia de un período es él mismo');
      }
    });

    test('un día o una semana se clasifican contra el ciclo que los contiene',
        () {
      // Un día del 20 de agosto pertenece al ciclo 15 ago – 14 sep.
      final dias = opcionesDe(BloqueCaja.dia, DateTime(2026, 8, 20));
      expect(dias.first.cicloRef, DateTime(2026, 8, 15));

      // Y uno del 10 de agosto, al ciclo 15 jul – 14 ago.
      final antes = opcionesDe(BloqueCaja.dia, DateTime(2026, 8, 10));
      expect(antes.first.cicloRef, DateTime(2026, 7, 15));

      // La semana se ancla por su INICIO (el domingo), no por el día de hoy.
      final sem = opcionesDe(BloqueCaja.semana, DateTime(2026, 8, 18));
      expect(sem.first.desde, DateTime(2026, 8, 16));
      expect(sem.first.cicloRef, DateTime(2026, 8, 15),
          reason: 'el domingo 16 ya está en el ciclo que abrió el 15');
    });
  });

  test('las etiquetas de período coinciden con periodoLabel', () {
    final o = opcionesDe(BloqueCaja.periodo, DateTime(2026, 8, 28));
    // La tercera en adelante muestra el rango con el mismo formato que el
    // resto del Resumen: si divergieran, la misma ventana se llamaría de dos
    // formas en dos tarjetas.
    expect(o[2].etiqueta, periodoLabel(2026, 7));
    expect(o[2].rango, periodoLabel(2026, 7));
  });
}
