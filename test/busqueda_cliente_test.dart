import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/repositories/settings_repo.dart';
import 'package:isp_billing/data/utils/busqueda_cliente.dart';

/// Tests del folding canónico de búsqueda (ñ/acentos → ASCII-minúscula).
///
/// El problema raíz: SQLite `lower()`/`upper()` son ASCII-only (NO bajan Ñ ni
/// vocales acentuadas) y los códigos se guardan en MAYÚSCULA, así que sin
/// plegar ambos lados, un código 'JÑ0048' no matchea la query 'jñ0048' y la
/// unicidad de código no detecta duplicados con ñ. `foldBusqueda` (Dart) y
/// `foldSqlExpr` (genera SQL) deben plegar a LA MISMA forma para que cliente y
/// SQL comparen igual.
void main() {
  group('foldBusqueda', () {
    test('baja a minúscula y pliega ñ → n', () {
      expect(foldBusqueda('JÑ0048'), 'jn0048');
      expect(foldBusqueda('PEÑA'), 'pena');
      expect(foldBusqueda('Núñez'), 'nunez');
      expect(foldBusqueda('MUÑOZ'), 'munoz');
    });

    test('pliega vocales acentuadas → base ASCII', () {
      expect(foldBusqueda('García'), 'garcia');
      expect(foldBusqueda('José'), 'jose');
    });

    test('ü/Ü → u', () {
      expect(foldBusqueda('ü'), 'u');
      expect(foldBusqueda('Ü'), 'u');
      expect(foldBusqueda('Müller'), 'muller');
    });

    test('mayúsculas y minúsculas dan el MISMO resultado', () {
      expect(foldBusqueda('JÑ0048'), foldBusqueda('jñ0048'));
      expect(foldBusqueda('PEÑA'), foldBusqueda('peña'));
      expect(foldBusqueda('GARCÍA'), foldBusqueda('garcía'));
    });

    test('es idempotente: fold(fold(x)) == fold(x)', () {
      for (final s in ['JÑ0048', 'García', 'PEÑA', 'Núñez', 'José', 'Müller']) {
        expect(foldBusqueda(foldBusqueda(s)), foldBusqueda(s),
            reason: 'no idempotente para "$s"');
      }
    });
  });

  group('foldSqlExpr', () {
    test('genera SQL con replace() + lower() + coalesce', () {
      final expr = foldSqlExpr('codigo');
      expect(expr, contains('replace('));
      expect(expr, contains('lower('));
      expect(expr, contains('coalesce('));
      expect(expr, contains('codigo'));
    });

    test('mapea AMBOS casos de Ñ/ñ (replace es case-sensitive)', () {
      final expr = foldSqlExpr('codigo');
      // replace() en SQLite es case-sensitive y lower() es ASCII-only → la
      // expresión debe encadenar replaces para la mayúscula Y la minúscula,
      // si no, una de las dos no se pliega.
      expect(expr, contains("'Ñ'"));
      expect(expr, contains("'ñ'"));
    });
  });

  group('busquedaClienteMatch (todos los toggles ON)', () {
    // AppSettings(null) → todos los getters busquedaPor* devuelven su default
    // true → todos los campos entran a la búsqueda.
    final settings = AppSettings(null);

    test('settings de prueba tiene todos los toggles ON', () {
      expect(settings.busquedaPorCodigo, isTrue);
      expect(settings.busquedaPorCedula, isTrue);
      expect(settings.busquedaPorTelefono, isTrue);
      expect(settings.busquedaPorContrato, isTrue);
    });

    test('matchea código con ñ buscando con y sin ñ', () {
      expect(
        busquedaClienteMatch('jn0048', settings, codigo: 'JÑ0048'),
        isTrue,
      );
      expect(
        busquedaClienteMatch('jñ0048', settings, codigo: 'JÑ0048'),
        isTrue,
      );
    });

    test('matchea nombre con ñ/acento buscando plegado o con ñ', () {
      expect(
        busquedaClienteMatch('jose pena', settings, nombre: 'José Peña'),
        isTrue,
      );
      expect(
        busquedaClienteMatch('peña', settings, nombre: 'José Peña'),
        isTrue,
      );
    });
  });

  group('tokensBusqueda', () {
    test('parte en palabras y pliega cada token', () {
      expect(tokensBusqueda('María Peña'), ['maria', 'pena']);
      expect(tokensBusqueda('  maria   ruiz '), ['maria', 'ruiz']);
    });
    test('query vacía o solo espacios → lista vacía', () {
      expect(tokensBusqueda(''), isEmpty);
      expect(tokensBusqueda('   '), isEmpty);
    });
  });

  group('coincideTokens (AND en cualquier orden, acento-insensible)', () {
    const nombre = 'María Luisa Peña Ruíz';
    test('encuentra con tokens en cualquier orden y sin tildes', () {
      expect(coincideTokens(nombre, 'maria ruiz'), isTrue);
      expect(coincideTokens(nombre, 'luisa ruiz'), isTrue);
      expect(coincideTokens(nombre, 'maria pena'), isTrue);
      expect(coincideTokens(nombre, 'ruiz maria'), isTrue);
      expect(coincideTokens(nombre, 'peña'), isTrue);
    });
    test('falla si algún token no está presente', () {
      expect(coincideTokens(nombre, 'maria gomez'), isFalse);
      expect(coincideTokens(nombre, 'pedro'), isFalse);
    });
    test('query vacía → true (no filtra)', () {
      expect(coincideTokens(nombre, ''), isTrue);
      expect(coincideTokens(nombre, '   '), isTrue);
    });
  });

  group('busquedaClienteMatch por TOKENS', () {
    final settings = AppSettings(null);
    test('encuentra por nombre con tokens en cualquier orden', () {
      expect(
        busquedaClienteMatch('maria ruiz', settings,
            nombre: 'María Luisa Peña Ruíz'),
        isTrue,
      );
      expect(
        busquedaClienteMatch('luisa pena', settings,
            nombre: 'María Luisa Peña Ruíz'),
        isTrue,
      );
    });
    test('token faltante → no matchea', () {
      expect(
        busquedaClienteMatch('maria gomez', settings,
            nombre: 'María Luisa Peña Ruíz'),
        isFalse,
      );
    });
    test('tokens pueden cruzar campos (nombre + código)', () {
      expect(
        busquedaClienteMatch('maria 0048', settings,
            nombre: 'María Peña', codigo: 'JÑ0048'),
        isTrue,
      );
    });
  });

  group('foldSqlTokens', () {
    test('ANDea un LIKE por token, plegando la columna', () {
      final b = foldSqlTokens('c.nombre', 'maria ruiz');
      expect(b.params, ['%maria%', '%ruiz%']);
      expect(b.sql, contains(' AND '));
      expect(b.sql, contains('lower('));
    });
    test('query vacía → sql vacío', () {
      expect(foldSqlTokens('c.nombre', '   ').sql, '');
    });
  });
}
