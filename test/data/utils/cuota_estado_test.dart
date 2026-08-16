import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/cuota_estado.dart';

/// Tests de `calcularEstadoCuota` — la lógica de estado de cuota
/// extraída de `PagosRepo._calcularEstado` en el sprint de tests base.
///
/// **Por qué es el primer test del repo**: la función espeja la SQL
/// `recalcular_cuota_desde_pagos` (migración 0007). Si la lógica
/// divergiera entre cliente y server, los pagos cambiarían el estado
/// de cuota de un lado pero no del otro — bug silencioso de alto
/// impacto (cuotas mostradas como pendientes cuando ya están pagadas,
/// o viceversa). Mirror crítico → top riesgo de regresión.
///
/// Cualquier cambio a esta función DEBE replicarse en la SQL del
/// server. Estos tests son el guardia ante divergencia.
void main() {
  group('calcularEstadoCuota', () {
    group('anuladas — siempre quedan anuladas (regla terminal)', () {
      test('anulada con pago cero queda anulada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'anulada',
            montoCuota: 750.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'anulada',
        );
      });

      test('anulada con pago completo NO se reactiva como pagada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'anulada',
            montoCuota: 750.0,
            pagadoNuevo: 750.0,
            deltaCargosExtra: 0.0,
          ),
          'anulada',
        );
      });

      test('anulada con monto cero queda anulada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'anulada',
            montoCuota: 0.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'anulada',
        );
      });
    });

    group('pendientes — sin pago aún', () {
      test('pago cero → pendiente', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'pendiente',
        );
      });

      test('pago negativo (anulación de pago previo) → pendiente', () {
        // Edge case: un undo puede dejar el agregado en negativo
        // transitoriamente. La regla lo trata como sin pago.
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: -10.0,
            deltaCargosExtra: 0.0,
          ),
          'pendiente',
        );
      });

      test('estadoActual previo no afecta cuando pagado<=0', () {
        // No importa de qué estado venga, si pagado=0 va a pendiente.
        for (final e in ['pendiente', 'parcial', 'pagada', 'en_gracia']) {
          expect(
            calcularEstadoCuota(
              estadoActual: e,
              montoCuota: 750.0,
              pagadoNuevo: 0.0,
              deltaCargosExtra: 0.0,
            ),
            'pendiente',
            reason: 'desde estado $e con pagado=0 debe ser pendiente',
          );
        }
      });
    });

    group('pagadas — pago cubre o excede el total', () {
      test('pago exacto al monto → pagada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 750.0,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
        );
      });

      test('pago superior al monto → pagada', () {
        // El cliente paga de más (vuelto a su favor para próxima cuota).
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 1000.0,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
        );
      });

      test('total cero (cuota gratis) con pago cero → pagada (CONDONADA, '
          '0117)', () {
        // Regla 0117: total real 0 → no queda nada que cobrar → 'pagada'.
        // (Antes era 'pendiente' eterna con saldo 0, que bloqueaba el orden
        // de cobro del contrato — finding ALTO del audit del rediseño.)
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 0.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
        );
      });

      test('total cero con pago positivo mínimo → pagada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 0.0,
            pagadoNuevo: 0.01,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
        );
      });
    });

    group('parciales — pago entre 0 y total', () {
      test('pago menor al monto → parcial', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 300.0,
            deltaCargosExtra: 0.0,
          ),
          'parcial',
        );
      });

      test('pago muy chico → parcial', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 0.01,
            deltaCargosExtra: 0.0,
          ),
          'parcial',
        );
      });

      test('pago un centavo menos al monto → parcial', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 749.99,
            deltaCargosExtra: 0.0,
          ),
          'parcial',
        );
      });
    });

    group('cargos extra positivos — recargos suben el total', () {
      test('recargo de 50 sobre 750 → total 800', () {
        // Pago de 750 (que cubría el monto base) ya no cubre el total.
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 750.0,
            deltaCargosExtra: 50.0,
          ),
          'parcial',
        );
      });

      test('pago cubre monto + recargo exactamente → pagada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 800.0,
            deltaCargosExtra: 50.0,
          ),
          'pagada',
        );
      });
    });

    group('cargos extra negativos — descuentos bajan el total', () {
      test('descuento de 100 sobre 750 → total 650', () {
        // Con pago de 700 ya pasa el total descontado.
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 700.0,
            deltaCargosExtra: -100.0,
          ),
          'pagada',
        );
      });

      test('descuento que supera el monto → total clamped a 0', () {
        // Cuota de 750 con descuento de 800 → total real 0 (no -50).
        // Pago de 0.01 ya la cubre.
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 0.01,
            deltaCargosExtra: -800.0,
          ),
          'pagada',
        );
      });

      test('descuento total exacto + pago cero → pagada (condonada, 0117)',
          () {
        // Promo/ajuste del 100%: el total real queda en 0 → la cuota está
        // saldada sin plata. Espejo de recalcular_cuota_desde_pagos (0117).
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: -750.0,
          ),
          'pagada',
        );
      });

      test('quitar el descuento total revierte la condonación → pendiente',
          () {
        // El delta vuelve a 0 con pagado 0: la cuota reabre.
        expect(
          calcularEstadoCuota(
            estadoActual: 'pagada',
            montoCuota: 750.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'pendiente',
        );
      });

      test('descuento menor al monto, pago parcial → parcial', () {
        // 1000 monto - 100 desc = 900 total. Pago 500 → parcial.
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 1000.0,
            pagadoNuevo: 500.0,
            deltaCargosExtra: -100.0,
          ),
          'parcial',
        );
      });
    });

    group('precisión floating point — comparación en centavos', () {
      test('drift FP (0.1+0.2 vs 0.3) NO causa falso parcial', () {
        // Caso clásico de FP: 0.1 + 0.2 == 0.30000000000000004. El total
        // queda apenas por encima de 0.3 por el drift. El server guarda el
        // monto en numeric(10,2) (= 0.30 exacto) y daría 'pagada'; el cliente
        // redondea a centavos para NO divergir y mostrar 'parcial' offline.
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 0.1 + 0.2,
            pagadoNuevo: 0.3,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
          reason: 'redondeo a centavos absorbe el drift → pagada, igual que '
              'el server (numeric 10,2)',
        );
      });

      test('parciales que acumulan drift al sumarse → pagada', () {
        // 3 parciales de 111.11 = 333.33000000000004 (drift al sumar en Dart).
        // Sin redondeo, 333.33000000000004 vs total 333.33 podría flickear.
        const pagado = 111.11 + 111.11 + 111.11;
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 333.33,
            pagadoNuevo: pagado,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
        );
      });

      test('faltante real de 1 centavo SIGUE siendo parcial', () {
        // El redondeo a centavos NO debe tragar un faltante genuino: 749.99
        // de 750.00 está 1 centavo corto → parcial (coincide con el server).
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 749.99,
            deltaCargosExtra: 0.0,
          ),
          'parcial',
        );
      });
    });
  });
}
