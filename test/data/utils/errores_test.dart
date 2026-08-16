import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/errores.dart';

void main() {
  group('mensajeErrorHumano', () {
    test('saca el prefijo "Bad state:" de un StateError (fix cambio-plan)', () {
      // El throw del repo (cambiarPlan) es un StateError con mensaje en español;
      // antes se mostraba "Bad state: El cliente ya tiene...".
      final msg = mensajeErrorHumano(
        StateError('El cliente ya tiene un contrato activo en ese plan.'),
      );
      expect(msg, 'El cliente ya tiene un contrato activo en ese plan.');
      expect(msg.contains('Bad state'), isFalse);
    });

    test('sigue sacando el prefijo "Exception:" (comportamiento previo)', () {
      final msg = mensajeErrorHumano(Exception('No se pudo guardar el contrato.'));
      expect(msg, 'No se pudo guardar el contrato.');
      expect(msg.contains('Exception'), isFalse);
    });

    test('un throw en español ya humanizado pasa tal cual', () {
      final msg = mensajeErrorHumano(
        StateError('El ajuste no puede ser mayor al saldo pendiente.'),
      );
      expect(msg, 'El ajuste no puede ser mayor al saldo pendiente.');
    });

    test('errores técnicos de librería caen al mensaje genérico', () {
      final msg = mensajeErrorHumano('SqliteException(1): no such column: foo');
      expect(msg, contains('Algo salió mal'));
    });

    test('NO mangla "SocketException: ..." (el strip ancla al prefijo)', () {
      // Bug previo: replaceFirst("Exception: ") cortaba en el medio →
      // "SocketConnection refused" garabateado. Ahora queda intacto, se reconoce
      // el marcador SocketException, y cae al genérico amigable.
      final msg = mensajeErrorHumano('SocketException: Connection refused');
      expect(msg.contains('SocketConnection'), isFalse);
      expect(msg, contains('Algo salió mal'));
    });

    test('el contexto se interpola en el genérico', () {
      // 'no such column' es marcador técnico y no se mangla con los strips.
      final msg = mensajeErrorHumano(
        'no such column: plan_id',
        contexto: 'cambiar el plan',
      );
      expect(msg, contains('al cambiar el plan'));
    });

    test('un StateError con tildes (ñ/acentos) también queda limpio', () {
      final msg = mensajeErrorHumano(
        StateError('El día de pago no puede ser después del vencimiento.'),
      );
      expect(msg, 'El día de pago no puede ser después del vencimiento.');
      expect(msg.contains('Bad state'), isFalse);
    });
  });
}
