import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/validators.dart';

/// Tests de Validators y sanitizePhone — lógica pura de validación
/// usada en ~10 forms del repo. Si rompe, los inputs sucios entran a
/// la BD o los formularios rechazan valores válidos.
void main() {
  group('Validators.email', () {
    test('email válido pasa', () {
      expect(Validators.email('foo@bar.com'), null);
    });

    test('email con subdominio pasa', () {
      expect(Validators.email('user@mail.example.com'), null);
    });

    test('email con + en local part pasa', () {
      expect(Validators.email('foo+tag@bar.com'), null);
    });

    test('sin @ falla', () {
      expect(Validators.email('foobar.com'), 'Email inválido');
    });

    test('sin TLD falla', () {
      expect(Validators.email('foo@bar'), 'Email inválido');
    });

    test('con espacios falla (regla estricta del repo)', () {
      // Antes del consolidate, algunos validators usaban [^@]+ que
      // aceptaba esto. Mantener regla estricta documentada.
      expect(Validators.email('foo bar@x.com'), 'Email inválido');
      expect(Validators.email('foo@bar com.com'), 'Email inválido');
    });

    test('vacío pasa (presencia es responsabilidad de requiredField)', () {
      expect(Validators.email(''), null);
      expect(Validators.email('   '), null);
      expect(Validators.email(null), null);
    });

    test('trim del input antes de validar', () {
      expect(Validators.email('  foo@bar.com  '), null);
    });
  });

  group('Validators.requiredField', () {
    test('texto no vacío pasa', () {
      expect(Validators.requiredField('hola'), null);
    });

    test('vacío falla con label default', () {
      expect(Validators.requiredField(''), 'Campo requerido');
      expect(Validators.requiredField(null), 'Campo requerido');
    });

    test('vacío con label custom interpola en el mensaje', () {
      expect(Validators.requiredField('', label: 'Email'), 'Email requerido');
      expect(Validators.requiredField(null, label: 'Nombre'),
          'Nombre requerido');
    });

    test('solo whitespace falla (post-trim)', () {
      expect(Validators.requiredField('   '), 'Campo requerido');
      expect(Validators.requiredField('\t\n'), 'Campo requerido');
    });

    test('texto con whitespace adelante/atrás pasa (post-trim queda algo)',
        () {
      expect(Validators.requiredField('  hola  '), null);
    });
  });

  group('Validators.minLength', () {
    test('largo exacto al mínimo pasa', () {
      expect(Validators.minLength('12345', 5), null);
    });

    test('largo mayor al mínimo pasa', () {
      expect(Validators.minLength('1234567890', 5), null);
    });

    test('largo menor al mínimo falla con mensaje interpolado', () {
      expect(Validators.minLength('123', 5), 'Mínimo 5 caracteres');
    });

    test('vacío pasa (presencia separada de requiredField)', () {
      expect(Validators.minLength('', 5), null);
      expect(Validators.minLength(null, 5), null);
    });

    test('trim antes de contar', () {
      // "abc" tiene 3 chars, mínimo 5 → falla. "  abc  " también.
      expect(Validators.minLength('  abc  ', 5), 'Mínimo 5 caracteres');
    });
  });

  group('Validators.maxLength', () {
    test('largo exacto al máximo pasa', () {
      expect(Validators.maxLength('12345', 5), null);
    });

    test('largo menor al máximo pasa', () {
      expect(Validators.maxLength('123', 5), null);
    });

    test('largo mayor al máximo falla con mensaje', () {
      expect(Validators.maxLength('123456', 5), 'Máximo 5 caracteres');
    });

    test('vacío pasa', () {
      expect(Validators.maxLength('', 5), null);
      expect(Validators.maxLength(null, 5), null);
    });

    test('trim antes de contar', () {
      // "  12345  " post-trim son 5 chars, máximo 5 → OK.
      expect(Validators.maxLength('  12345  ', 5), null);
    });
  });

  group('sanitizePhone (deja [0-9+])', () {
    test('formato típico nicaragüense', () {
      expect(sanitizePhone('+505 8888-8888'), '+50588888888');
    });

    test('strip letras', () {
      expect(sanitizePhone('abc12345678'), '12345678');
    });

    test('strip paréntesis y guiones, mantiene +', () {
      expect(sanitizePhone('+1 (505) 888-8888'), '+15058888888');
    });

    test('strip whitespace y tabs', () {
      expect(sanitizePhone('  +505\t8888\n8888  '), '+50588888888');
    });

    test('cadena vacía retorna vacío', () {
      expect(sanitizePhone(''), '');
    });

    test('cadena sin caracteres válidos retorna vacío', () {
      expect(sanitizePhone('abc def!@#'), '');
    });

    test('solo + sin dígitos', () {
      // Caso edge: PhoneTextField.sanitized lo trata como null,
      // pero la función sola devuelve "+".
      expect(sanitizePhone('+'), '+');
    });

    test('múltiples + se mantienen', () {
      // Edge case: el formato es raro pero la función no normaliza.
      // El validator de PhoneTextField lo aceptaría como ≥8 dígitos.
      expect(sanitizePhone('++505++8888'), '++505++8888');
    });
  });

  group('sanitizePhoneForWhatsApp (deja solo dígitos)', () {
    test('strip el + también', () {
      expect(sanitizePhoneForWhatsApp('+505 8888-8888'), '50588888888');
    });

    test('strip letras', () {
      expect(sanitizePhoneForWhatsApp('abc12345678'), '12345678');
    });

    test('solo + retorna vacío', () {
      // Útil para el guard "sin dígitos = inválido" de PhoneTextField.
      expect(sanitizePhoneForWhatsApp('+'), '');
    });

    test('cadena vacía retorna vacío', () {
      expect(sanitizePhoneForWhatsApp(''), '');
    });

    test('solo símbolos retorna vacío', () {
      expect(sanitizePhoneForWhatsApp('!@#\$%^&*()'), '');
    });

    test('strip todo whitespace', () {
      expect(sanitizePhoneForWhatsApp('5 0 5 8 8 8 8 8 8 8 8'),
          '50588888888');
    });
  });

  group('integración Validators + sanitizePhone (caso PhoneTextField)', () {
    test('telefono válido nicaragüense pasa todo el pipeline', () {
      const input = '+505 8888-8888';
      final sanitized = sanitizePhone(input);
      final digits = sanitizePhoneForWhatsApp(input);
      expect(sanitized, '+50588888888');
      expect(digits, '50588888888');
      expect(digits.length, greaterThanOrEqualTo(8)); // pasa validator
    });

    test('telefono solo con + no pasa el guard de PhoneTextField', () {
      const input = '+';
      final sanitized = sanitizePhone(input);
      final digits = sanitizePhoneForWhatsApp(sanitized);
      expect(sanitized, '+');
      expect(digits, ''); // → PhoneTextField.sanitized retorna null
    });

    test('input con letras filtradas por inputFormatters igual queda limpio',
        () {
      // Simula que las letras se cuelan (caso paste programático).
      const input = 'abc505 8888-8888xyz';
      final sanitized = sanitizePhone(input);
      expect(sanitized, '50588888888');
    });
  });
}
