import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/cola_tecnico.dart';

Map<String, dynamic> t(String id, String estado,
        {int? orden, String creado = '2026-01-01T00:00:00Z'}) =>
    {'id': id, 'estado': estado, 'orden_cola': orden, 'created_at': creado};

void main() {
  group('cola del técnico — una orden a la vez', () {
    test('sin posición explícita, la activa es la más vieja', () {
      final cola = [
        t('b', 'asignado', creado: '2026-03-02T09:00:00Z'),
        t('a', 'asignado', creado: '2026-03-01T09:00:00Z'),
        t('c', 'asignado', creado: '2026-03-03T09:00:00Z'),
      ];
      expect(ordenActiva(cola), 'a');
      expect(ordenBloqueada(cola[0], 'a'), isTrue);
      expect(ordenBloqueada(cola[1], 'a'), isFalse);
    });

    test('la posición del coordinador manda sobre la antigüedad', () {
      final cola = [
        t('vieja', 'asignado', creado: '2026-03-01T09:00:00Z'),
        t('urgente', 'asignado', orden: 1, creado: '2026-03-09T09:00:00Z'),
      ];
      expect(ordenActiva(cola), 'urgente');
      expect(ordenBloqueada(cola[0], 'urgente'), isTrue);
    });

    test('las ordenadas van antes que las que no tienen posición', () {
      final cola = [
        t('sin', 'asignado', creado: '2026-01-01T09:00:00Z'),
        t('tercera', 'asignado', orden: 3, creado: '2026-05-01T09:00:00Z'),
        t('primera', 'asignado', orden: 1, creado: '2026-05-01T09:00:00Z'),
      ];
      final ordenada = [...cola]..sort(compararEnCola);
      expect(ordenada.map((e) => e['id']), ['primera', 'tercera', 'sin']);
    });

    test('se libera al RESOLVER, no al cerrar', () {
      // El cierre es del call center: si la cola lo esperara, un cliente que no
      // contesta paralizaría al técnico. Resuelta la primera, la segunda activa.
      final cola = [
        t('a', 'resuelto', creado: '2026-03-01T09:00:00Z'),
        t('b', 'asignado', creado: '2026-03-02T09:00:00Z'),
      ];
      expect(ordenActiva(cola), 'b');
      expect(ordenBloqueada(cola[1], 'b'), isFalse);
    });

    test('en_espera no bloquea ni queda bloqueada', () {
      // Bloquear con una orden en espera dejaría al técnico sin poder trabajar
      // en nada, que es lo contrario de para qué existe ese estado.
      final cola = [
        t('esperando', 'en_espera', creado: '2026-03-01T09:00:00Z'),
        t('activa', 'asignado', creado: '2026-03-02T09:00:00Z'),
      ];
      expect(ordenActiva(cola), 'activa');
      expect(ordenBloqueada(cola[0], 'activa'), isFalse,
          reason: 'la orden en espera se puede retomar cuando llega el repuesto');
    });

    test('sin órdenes en curso no hay activa y nada queda bloqueado', () {
      final cola = [
        t('a', 'resuelto'),
        t('b', 'cerrado'),
        t('c', 'cancelado'),
      ];
      expect(ordenActiva(cola), isNull);
      for (final o in cola) {
        expect(ordenBloqueada(o, null), isFalse);
      }
    });

    test('lista vacía no explota', () {
      expect(ordenActiva(const []), isNull);
    });

    test('una orden reabierta vuelve a ocupar la cola', () {
      final cola = [
        t('a', 'reabierto', creado: '2026-03-01T09:00:00Z'),
        t('b', 'asignado', creado: '2026-03-02T09:00:00Z'),
      ];
      expect(ordenActiva(cola), 'a');
      expect(ordenBloqueada(cola[1], 'a'), isTrue);
    });
  });
}
