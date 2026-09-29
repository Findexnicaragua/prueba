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

  // ==========================================================================
  // El clamp del prorrateo al suspender/cancelar (audit 2026-08-22, CRITICO).
  //
  // La cuota es un SNAPSHOT del precio de su momento; `precioMensual` es el
  // precio LIVE del plan. Si el plan subio -o la cuota venia de un plan
  // anterior- el prorrateo de los dias consumidos podia superar el monto de la
  // propia cuota: darse de baja a mitad de mes salia MAS CARO que el mes
  // entero. Caso real que motivo el fix: SE0338 de Mairena, cuota de C$513 con
  // el plan a C$1.282, suspendida al dia 26 de su ciclo -> quedaba en C$1.075.
  //
  // Estos tests fijan la REGLA, no la implementacion: prorratear nunca sube una
  // cuota, y nunca esconde plata ya cobrada.
  // ==========================================================================
  // Pedido de Rubén (2026-09-02): "me gustaría que dijera cuánto es el
  // prorrateo por día para así hacer la suma de cuántos días son los que está
  // calculando". El punto de estos tests es que la CUENTA QUE SE MUESTRA dé el
  // TOTAL QUE SE COBRA: si divergen, la pantalla miente y el cliente no puede
  // rehacer el número.
  group('cambio de plan — tramos del prorrateo (la cuenta que se muestra)', () {
    // El caso exacto que Rubén tiene en pantalla: 500 → 800, día_pago 15,
    // cambio el 20-jun. Ciclo en curso 15-jun → 15-jul.
    final hoy = DateTime(2026, 6, 20);
    final finVentana = servicioFin(DateTime(2026, 7, 1), 15); // 15-jul

    ProrrateoCambioPlan r() => prorrateoCambioPlanHoy(
        hoy: hoy,
        finVentanaActual: finVentana,
        precioViejo: 500,
        precioNuevo: 800);

    test('parte por MES calendario: 25 días → 2 tramos, no 1', () {
      final t = r().tramos;
      expect(t.length, 2, reason: 'el rango cruza junio y julio');
      expect(t[0].mes, 6);
      expect(t[0].dias, 10); // 21-jun..30-jun
      expect(t[1].mes, 7);
      expect(t[1].dias, 15); // 1-jul..15-jul
      expect(t[0].dias + t[1].dias, r().dias);
    });

    test('cada tramo usa el precio diario de SU mes (no un promedio)', () {
      final t = r().tramos;
      // La diferencia es 300: junio la divide por 30, julio por 31.
      expect(t[0].precioDia, closeTo(10.0000, 0.0001));
      expect(t[1].precioDia, closeTo(9.6774, 0.0001));
      // Y por eso NO son iguales: es justamente lo que hace imposible mostrar
      // "25 días × un precio". El promedio 245,16/25 = 9,8064 no es el precio
      // de ningún día real y no debe aparecer en ninguna superficie.
      expect(t[0].precioDia, isNot(closeTo(t[1].precioDia, 0.01)));
      expect(t[0].precioDia, isNot(closeTo(9.8064, 0.01)));
      expect(t[1].precioDia, isNot(closeTo(9.8064, 0.01)));
    });

    test('LA CUENTA CIERRA: la suma de los subtotales == el monto cobrado', () {
      final p = r();
      final suma = p.tramos.fold<double>(0, (a, t) => a + t.subtotal);
      expect(p.monto, closeTo(245.16, 0.005));
      // Tolerancia de 1 centavo: el total redondea UNA vez y los subtotales
      // redondean cada uno. Si esto se va de un centavo, la pantalla está
      // mostrando una cuenta que no da el número que se cobra.
      expect(suma, closeTo(p.monto, 0.01));
      expect(p.tramos[0].subtotal, closeTo(100.00, 0.005));
      expect(p.tramos[1].subtotal, closeTo(145.16, 0.005));
    });

    test('el rango mostrado arranca en hoy+1 (hoy ya se sirvió al plan viejo)',
        () {
      final p = r();
      expect(p.desde, DateTime(2026, 6, 21));
      expect(p.hasta, DateTime(2026, 7, 15));
    });

    test('un rango dentro de UN solo mes da UN tramo', () {
      final p = prorrateoCambioPlanHoy(
          hoy: DateTime(2026, 7, 1),
          finVentanaActual: DateTime(2026, 7, 15),
          precioViejo: 500,
          precioNuevo: 800);
      expect(p.tramos.length, 1);
      expect(p.tramos.single.dias, 14);
      expect(p.tramos.single.mes, 7);
      final suma = p.tramos.fold<double>(0, (a, t) => a + t.subtotal);
      expect(suma, closeTo(p.monto, 0.01));
    });

    test('el downgrade también trae el desglose (el crédito hay que explicarlo)',
        () {
      final p = prorrateoCambioPlanHoy(
          hoy: hoy,
          finVentanaActual: finVentana,
          precioViejo: 800,
          precioNuevo: 500);
      expect(p.esUpgrade, isFalse);
      expect(p.tramos.length, 2);
      final suma = p.tramos.fold<double>(0, (a, t) => a + t.subtotal);
      expect(suma, closeTo(p.monto, 0.01));
    });

    test('sin ajuste no hay desglose ni rango (nada que explicar)', () {
      final p = prorrateoCambioPlanHoy(
          hoy: hoy,
          finVentanaActual: finVentana,
          precioViejo: 500,
          precioNuevo: 500);
      expect(p.sinAjuste, isTrue);
      expect(p.tramos, isEmpty);
      expect(p.desde, isNull);
      expect(p.hasta, isNull);
    });

    test('un ciclo ya vencido no inventa tramos', () {
      final p = prorrateoCambioPlanHoy(
          hoy: DateTime(2026, 7, 20), // después del fin de ventana
          finVentanaActual: finVentana,
          precioViejo: 500,
          precioNuevo: 800);
      expect(p.dias, 0);
      expect(p.tramos, isEmpty);
    });

    // Barrido del año: la propiedad tiene que valer en TODOS los ciclos, no
    // solo en el de junio. Febrero (28) es el que más se aparta.
    test('la cuenta cierra en los 12 ciclos del año', () {
      for (var m = 1; m <= 12; m++) {
        final fin = servicioFin(DateTime(2026, m, 1), 15);
        final desde = DateTime(2026, m - 1 < 1 ? 12 : m - 1, 20);
        final p = prorrateoCambioPlanHoy(
            hoy: desde,
            finVentanaActual: fin,
            precioViejo: 500,
            precioNuevo: 800);
        if (p.sinAjuste) continue;
        final suma = p.tramos.fold<double>(0, (a, t) => a + t.subtotal);
        expect(suma, closeTo(p.monto, 0.01), reason: 'ciclo mes $m');
        expect(p.tramos.fold<int>(0, (a, t) => a + t.dias), p.dias,
            reason: 'días del ciclo mes $m');
      }
    });
  });

  group('clamp del prorrateo (suspension/cancelacion)', () {
    // Reproduce la formula de contratos_repo: prorrateo acotado por arriba al
    // monto de la cuota y por abajo a lo ya pagado.
    double montoTrasCorte({
      required DateTime periodo,
      required int diaPago,
      required DateTime fechaCorte,
      required double precioMensual,
      required double montoCuota,
      required double pagado,
    }) {
      final v = ventanaServicio(periodo, diaPago);
      final prorrateado = montoPuente(v.inicio, fechaCorte, precioMensual);
      final acotado = prorrateado > montoCuota ? montoCuota : prorrateado;
      return acotado < pagado ? pagado : acotado;
    }

    test('el caso SE0338: cuota barata + plan caro NO puede superar la cuota', () {
      final m = montoTrasCorte(
        periodo: DateTime(2026, 8, 1),
        diaPago: 27,
        fechaCorte: DateTime(2026, 8, 22), // ~26 dias del ciclo consumidos
        precioMensual: 1282, // precio LIVE del plan
        montoCuota: 513, // lo que decia SU cuota
        pagado: 0,
      );
      expect(m, lessThanOrEqualTo(513),
          reason: 'prorratear jamas puede cobrar mas que el mes entero de esa cuota');
      expect(m, 513, reason: 'con el ciclo casi completo, queda topeado en su monto');
    });

    test('cuota alineada al plan: el prorrateo normal NO se altera', () {
      final v = ventanaServicio(DateTime(2026, 8, 1), 15);
      final corte = v.inicio.add(const Duration(days: 10));
      final esperado = montoPuente(v.inicio, corte, 1000);
      final m = montoTrasCorte(
        periodo: DateTime(2026, 8, 1), diaPago: 15, fechaCorte: corte,
        precioMensual: 1000, montoCuota: 1000, pagado: 0,
      );
      expect(m, esperado, reason: 'el clamp no debe tocar el caso sano');
      expect(m, lessThan(1000));
    });

    test('lo ya pagado nunca se esconde (piso), aun con el techo puesto', () {
      final m = montoTrasCorte(
        periodo: DateTime(2026, 8, 1), diaPago: 27,
        fechaCorte: DateTime(2026, 8, 3), // pocos dias -> prorrateo chico
        precioMensual: 1282, montoCuota: 513,
        pagado: 400, // el cliente ya abono 400
      );
      expect(m, greaterThanOrEqualTo(400),
          reason: 'bajar el monto por debajo del pago dejaria plata cobrada sin cuota');
    });

    test('sube el precio del plan a mitad de ciclo: la cuota vieja no se infla', () {
      // Cuota generada cuando el plan valia 600; hoy el plan vale 900.
      final m = montoTrasCorte(
        periodo: DateTime(2026, 8, 1), diaPago: 10,
        fechaCorte: DateTime(2026, 8, 31),
        precioMensual: 900, montoCuota: 600, pagado: 0,
      );
      expect(m, lessThanOrEqualTo(600));
    });
  });
}
