import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/cobrador_helpers.dart';

/// Tests de cobrador_helpers — funciones puras de presentación usadas en
/// el panel super_admin (CircleAvatar initials, labels de rol). Si rompe,
/// los avatares muestran basura o los roles aparecen con label incorrecto.
void main() {
  group('initialsFromName', () {
    test('nombre y apellido devuelve dos iniciales en mayúscula', () {
      expect(initialsFromName('Rubén Maltez'), 'RM');
    });

    test('nombre simple devuelve una sola inicial', () {
      expect(initialsFromName('Admin'), 'A');
    });

    test('string vacío devuelve ?', () {
      expect(initialsFromName(''), '?');
    });

    test('solo whitespace devuelve ?', () {
      expect(initialsFromName('   '), '?');
      expect(initialsFromName('\t\n'), '?');
    });

    test('nombre con tres o más palabras toma primera y última', () {
      expect(initialsFromName('Juan Carlos Pérez'), 'JP');
    });

    test('espacios múltiples entre palabras se toleran', () {
      expect(initialsFromName('  María   López  '), 'ML');
    });

    test('nombre con una sola letra', () {
      expect(initialsFromName('R'), 'R');
    });

    test('minúsculas se convierten a mayúsculas', () {
      expect(initialsFromName('ana ruiz'), 'AR');
    });
  });

  group('rolLabel', () {
    // El rol INTERNO sigue siendo 'super_admin'; sólo cambió la etiqueta que ve
    // el usuario (traspaso de la app al nuevo dueño).
    test('super_admin se muestra como Dev', () {
      expect(rolLabel('super_admin'), 'Dev');
    });

    test('admin devuelve Administrador', () {
      expect(rolLabel('admin'), 'Administrador');
    });

    test('admin_cobranza devuelve Admin de cobranza', () {
      expect(rolLabel('admin_cobranza'), 'Admin de cobranza');
    });

    test('cobrador devuelve Cobrador', () {
      expect(rolLabel('cobrador'), 'Cobrador');
    });

    test('tecnico devuelve Técnico', () {
      expect(rolLabel('tecnico'), 'Técnico');
    });

    test('admin_tickets devuelve Admin de tickets', () {
      expect(rolLabel('admin_tickets'), 'Admin de tickets');
    });

    test('rol desconocido devuelve el string crudo (fallback)', () {
      expect(rolLabel('viewer'), 'viewer');
      expect(rolLabel('manager'), 'manager');
    });

    test('string vacío devuelve string vacío (fallback sin crash)', () {
      expect(rolLabel(''), '');
    });
  });

  group('moduloLabel', () {
    test('códigos del catálogo devuelven su nombre capitalizado', () {
      expect(moduloLabel('cobranza'), 'Cobranza');
      expect(moduloLabel('inventario'), 'Inventario');
      expect(moduloLabel('tickets'), 'Tickets');
    });

    test('código desconocido capitaliza la primera letra (fallback)', () {
      expect(moduloLabel('red'), 'Red');
      expect(moduloLabel('geografia'), 'Geografia');
    });

    test('string vacío devuelve string vacío sin crash', () {
      expect(moduloLabel(''), '');
    });
  });
}
