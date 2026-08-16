import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/prorrateo.dart';

void main() {
  group('diasDelMes', () {
    test('meses de 30/31', () {
      expect(diasDelMes(2026, 6), 30); // junio
      expect(diasDelMes(2026, 7), 31); // julio
      expect(diasDelMes(2026, 1), 31); // enero
    });
    test('febrero no bisiesto y bisiesto', () {
      expect(diasDelMes(2026, 2), 28);
      expect(diasDelMes(2028, 2), 29); // 2028 bisiesto
    });
  });

  group('precioPorDia (precio / días reales del mes)', () {
    test('junio C\$900 → 30/día', () {
      expect(precioPorDia(DateTime(2026, 6, 10), 900), closeTo(30, 0.0001));
    });
    test('julio C\$900 → 29.03/día', () {
      expect(precioPorDia(DateTime(2026, 7, 5), 900), closeTo(900 / 31, 0.0001));
    });
  });

  group('anclaServicio (1ª ocurrencia del día nuevo después de pagadoHasta)', () {
    final pagado = DateTime(2026, 6, 15); // pagó hasta el 15 de junio

    test('mover al 30 (mismo mes) → 30 jun', () {
      expect(anclaServicio(pagado, 30), DateTime(2026, 6, 30));
    });
    test('mover al 14 (antes del 15) → 14 jul', () {
      expect(anclaServicio(pagado, 14), DateTime(2026, 7, 14));
    });
    test('mover al 10 (antes del 15) → 10 jul', () {
      expect(anclaServicio(pagado, 10), DateTime(2026, 7, 10));
    });
    test('mover al 16 (1 día después) → 16 jun', () {
      expect(anclaServicio(pagado, 16), DateTime(2026, 6, 16));
    });
    test('clamp a fin de mes: día 31 desde 15 feb → 28 feb', () {
      expect(anclaServicio(DateTime(2026, 2, 15), 31), DateTime(2026, 2, 28));
    });
    test('rollover de año: día 10 desde 20 dic → 10 ene del año sig', () {
      expect(anclaServicio(DateTime(2026, 12, 20), 10), DateTime(2027, 1, 10));
    });
  });

  group('diasPuente', () {
    test('15 jun → 30 jun = 15 días', () {
      expect(diasPuente(DateTime(2026, 6, 15), DateTime(2026, 6, 30)), 15);
    });
    test('15 jun → 14 jul = 29 días', () {
      expect(diasPuente(DateTime(2026, 6, 15), DateTime(2026, 7, 14)), 29);
    });
    test('15 jun → 10 jul = 25 días (ejemplo de Rubén)', () {
      expect(diasPuente(DateTime(2026, 6, 15), DateTime(2026, 7, 10)), 25);
    });
  });

  group('montoPuente (cada día con los días de su mes)', () {
    test('15→30 jun, C\$900 = 15 días × 30 = 450', () {
      expect(montoPuente(DateTime(2026, 6, 15), DateTime(2026, 6, 30), 900),
          closeTo(450, 0.001));
    });
    test('15 jun→10 jul, C\$900 = 15×(900/30) + 10×(900/31)', () {
      const esperado = 15 * (900 / 30) + 10 * (900 / 31); // 450 + 290.32...
      expect(montoPuente(DateTime(2026, 6, 15), DateTime(2026, 7, 10), 900),
          closeTo(esperado, 0.01));
    });
    test('ancla no posterior a pagado → 0', () {
      expect(montoPuente(DateTime(2026, 6, 15), DateTime(2026, 6, 15), 900), 0);
    });
  });

  group('calcularPuenteCambioFecha (ejemplos de Rubén end-to-end)', () {
    final pagado = DateTime(2026, 6, 15);

    test('15 → 30: puente 15 días, ancla 30 jun, primer cobro completo 30 jul', () {
      final p =
          calcularPuenteCambioFecha(pagadoHasta: pagado, diaNuevo: 30, precioMensual: 900);
      expect(p.anclaServicio, DateTime(2026, 6, 30));
      expect(p.diasPuente, 15);
      expect(p.montoPuente, closeTo(450, 0.001));
    });

    test('15 → 10: puente 25 días, ancla 10 jul (→ primer cobro completo 10 ago)', () {
      final p =
          calcularPuenteCambioFecha(pagadoHasta: pagado, diaNuevo: 10, precioMensual: 900);
      expect(p.anclaServicio, DateTime(2026, 7, 10));
      expect(p.diasPuente, 25);
      expect(p.montoPuente, closeTo(15 * (900 / 30) + 10 * (900 / 31), 0.01));
    });
  });

  // Espejo offline del server `calcular_fecha_pago` (0014): clamp a fin de mes +
  // domingo→lunes. DISTINTA de anclaServicio (que NO ajusta domingo→lunes).
  group('calcularFechaPago (fecha de cobro de la cuota)', () {
    test('día normal (no domingo, sin clamp)', () {
      // 2026-01-06 es martes.
      expect(calcularFechaPago(DateTime(2026, 1, 1), 6), DateTime(2026, 1, 6));
    });
    test('clamp al último día del mes (31 en feb → 28)', () {
      // 2026-02-28 es sábado (no domingo) → sin ajuste extra.
      expect(calcularFechaPago(DateTime(2026, 2, 1), 31), DateTime(2026, 2, 28));
    });
    test('domingo se corre a lunes', () {
      // 2026-01-04 es domingo → 05 (lunes).
      expect(calcularFechaPago(DateTime(2026, 1, 1), 4), DateTime(2026, 1, 5));
    });
    test('nunca devuelve un domingo', () {
      for (var mes = 1; mes <= 12; mes++) {
        for (var dia = 1; dia <= 31; dia++) {
          final f = calcularFechaPago(DateTime(2026, mes, 1), dia);
          expect(f.weekday, isNot(DateTime.sunday),
              reason: 'mes $mes día $dia → $f cae domingo');
        }
      }
    });
  });

  // Excedente = lo PAGADO por servicio que no se prestará (crédito por excedente).
  // dia_pago = 15 (≠ 1, para no cegar el anclaje §1c); suspensión el 18-jun-2026.
  group('excedenteCuota (crédito por excedente, anclado al día_pago)', () {
    final susp = DateTime(2026, 6, 18);

    test('futuro pagado entero → todo lo pagado (caso que motiva la feature)', () {
      // Período agosto (vence 15-ago, ventana (15-jul,15-ago]) → futuro el 18-jun.
      expect(
        excedenteCuota(
            periodo: DateTime(2026, 8, 1),
            diaPago: 15,
            montoPagado: 900,
            x: susp,
            precioMensual: 900),
        closeTo(900, 0.001),
      );
    });

    test('en_curso con sobre-pago → pagado − días consumidos', () {
      // Período julio (ventana (15-jun,15-jul]) → en_curso el 18-jun. Servido =
      // 16,17,18-jun = 3 × 30 = 90. Pagó 900 → excedente 810.
      expect(
        excedenteCuota(
            periodo: DateTime(2026, 7, 1),
            diaPago: 15,
            montoPagado: 900,
            x: susp,
            precioMensual: 900),
        closeTo(810, 0.01),
      );
    });

    test('en_curso pagado justo lo servido → 0', () {
      expect(
        excedenteCuota(
            periodo: DateTime(2026, 7, 1),
            diaPago: 15,
            montoPagado: 90,
            x: susp,
            precioMensual: 900),
        0,
      );
    });

    test('cumplido (servicio ya entregado) → 0 aunque esté pagado', () {
      // Período junio (ventana (15-may,15-jun]) → cumplido el 18-jun.
      expect(
        excedenteCuota(
            periodo: DateTime(2026, 6, 1),
            diaPago: 15,
            montoPagado: 900,
            x: susp,
            precioMensual: 900),
        0,
      );
    });

    test('sin pago → 0', () {
      expect(
        excedenteCuota(
            periodo: DateTime(2026, 8, 1),
            diaPago: 15,
            montoPagado: 0,
            x: susp,
            precioMensual: 900),
        0,
      );
    });

    test('anclaje día_pago 6: en_curso jul servido = 12 días × 30 = 360', () {
      // dia_pago 6 → ventana julio (6-jun,6-jul]; 7..18-jun = 12 días. Pagó 900
      // → excedente 540. (≠ del caso dia_pago 15: prueba que ancla al día_pago.)
      expect(
        excedenteCuota(
            periodo: DateTime(2026, 7, 1),
            diaPago: 6,
            montoPagado: 900,
            x: susp,
            precioMensual: 900),
        closeTo(540, 0.01),
      );
    });
  });

  group('cambio de plan — montoCuotaRevaluada', () {
    test('cuota futura pendiente → precio nuevo', () {
      expect(montoCuotaRevaluada(500, 0), 500);
    });
    test('clampea a >= lo pagado (respeta CHECK monto_pagado<=monto)', () {
      expect(montoCuotaRevaluada(300, 450), 450); // no baja debajo de lo pagado
      expect(montoCuotaRevaluada(500, 450), 500);
    });
  });

  group('cambio de plan — prorrateoCambioPlanHoy (días no servidos a la diferencia)', () {
    // día_pago 15: el ciclo en curso de hoy=25-jun vence el 15-jul.
    final hoy = DateTime(2026, 6, 25);
    final finVentana = servicioFin(DateTime(2026, 7, 1), 15); // 15-jul

    test('ancla al día_pago, NO al mes calendario (día_pago=15 → 15-jul)', () {
      expect(finVentana, DateTime(2026, 7, 15));
    });

    test('upgrade 300→500: cobra la diferencia de los 20 días restantes', () {
      final r = prorrateoCambioPlanHoy(
          hoy: hoy, finVentanaActual: finVentana, precioViejo: 300, precioNuevo: 500);
      expect(r.esUpgrade, isTrue);
      expect(r.dias, 20); // 26-jun..15-jul inclusive
      // 5 días de junio a 200/30 + 15 días de julio a 200/31.
      expect(r.monto, closeTo(130.11, 0.01));
      // == montoPuente con la diferencia (misma math que cambio-fecha/suspensión).
      expect(r.monto, montoPuente(hoy, finVentana, 200));
    });

    test('downgrade 500→300: misma magnitud, esUpgrade=false (va a crédito)', () {
      final r = prorrateoCambioPlanHoy(
          hoy: hoy, finVentanaActual: finVentana, precioViejo: 500, precioNuevo: 300);
      expect(r.esUpgrade, isFalse);
      expect(r.monto, closeTo(130.11, 0.01));
    });

    test('mismo precio → sin ajuste', () {
      final r = prorrateoCambioPlanHoy(
          hoy: hoy, finVentanaActual: finVentana, precioViejo: 400, precioNuevo: 400);
      expect(r.sinAjuste, isTrue);
      expect(r.monto, 0);
    });

    test('cambio el último día del ciclo → 0 días, 0 monto', () {
      final r = prorrateoCambioPlanHoy(
          hoy: finVentana,
          finVentanaActual: finVentana,
          precioViejo: 300,
          precioNuevo: 500);
      expect(r.dias, 0);
      expect(r.monto, 0);
    });
  });
}
