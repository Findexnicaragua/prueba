import 'package:flutter_test/flutter_test.dart';

// No importamos invokeEdgeFunction porque los tests end-to-end de esa
// función requieren mockear SupabaseClient (mockito no está en dev_deps).
// Los tests de este archivo cubren la lógica pura de manejo de errores
// replicada del source — ver comentarios en cada group.
//
// Imports que se necesitarían con mockito:
// import 'package:supabase_flutter/supabase_flutter.dart';
// import 'package:isp_billing/data/utils/edge_functions.dart';

// ---------------------------------------------------------------------------
// Lógica extraída — réplica exacta de _humanizarError tal como aparece
// duplicada en cobradores_admin_screen.dart y tenant_dialogs_invitar.dart.
// Si el source cambia, este test debe actualizarse en paralelo.
//
// Esta función ES la que queremos testear, pero es privada (_) en dos
// widgets State. La replicamos aquí para cubrir los 3 paths documentados.
// ---------------------------------------------------------------------------
String humanizarError(Object e) {
  final raw = e.toString();
  if (raw.startsWith('FunctionException')) {
    final match = RegExp(r'error:\s*([^}]+)').firstMatch(raw);
    if (match != null) {
      final extracted = match.group(1)?.trim();
      if (extracted != null && extracted.isNotEmpty) return extracted;
    }
  }
  return raw.replaceFirst('Exception: ', '');
}

// ---------------------------------------------------------------------------
// Lógica del generic catch de invokeEdgeFunction (líneas 57-67 del source).
// Misma regex, pero aplicada solo cuando el toString contiene
// 'FunctionException'. Si no matchea, hace rethrow (aquí retornamos null
// para indicar "no se pudo extraer").
// ---------------------------------------------------------------------------
String? extractFromFunctionExceptionString(String s) {
  if (s.contains('FunctionException')) {
    final match = RegExp(r'error:\s*([^}]+)').firstMatch(s);
    if (match != null) {
      final extracted = match.group(1)?.trim();
      if (extracted != null && extracted.isNotEmpty) {
        return extracted;
      }
    }
  }
  return null;
}

void main() {
  // =========================================================================
  // Tests de humanizarError — la función privada duplicada en 2 widgets.
  //
  // Cubre los 3 paths documentados en el docstring del source:
  //   1. Exception("msg") → pela "Exception: "
  //   2. FunctionException raw (type mismatch del SDK) → extrae campo error
  //   3. Cualquier otra excepción → toString tal cual
  // =========================================================================
  group('humanizarError', () {
    group('Path 1: Exception typed — pela prefijo "Exception: "', () {
      test('Exception con mensaje legible', () {
        final e = Exception('El email ya está registrado');
        expect(humanizarError(e), 'El email ya está registrado');
      });

      test('Exception con mensaje vacío', () {
        // Exception('') produce toString 'Exception: '
        final e = Exception('');
        // Pela "Exception: " → queda vacío
        expect(humanizarError(e), '');
      });

      test('Exception genérica sin argumento', () {
        // Exception() produce 'Exception'
        final e = Exception();
        // No empieza con 'FunctionException', no tiene 'Exception: '
        // (tiene solo 'Exception'), así que replaceFirst no matchea
        // el ': ' y retorna 'Exception' tal cual.
        expect(humanizarError(e), 'Exception');
      });

      test('Exception lanzada por invokeEdgeFunction — mensaje real', () {
        // invokeEdgeFunction lanza Exception(mensaje) donde mensaje es
        // el campo 'error' del body de la Edge Function.
        final e = Exception('Cobrador no encontrado en este tenant');
        expect(
            humanizarError(e), 'Cobrador no encontrado en este tenant');
      });
    });

    group('Path 2: FunctionException raw — extrae campo error con regex',
        () {
      test('FunctionException toString con campo error', () {
        // Simula el toString real de FunctionException del SDK:
        // 'FunctionException(status: 409, details: {ok: false, error: El email ya existe})'
        const fakeToString =
            'FunctionException(status: 409, details: {ok: false, error: El email ya existe})';
        // Creamos un objeto cuyo toString devuelva esto
        const e = _FakeException(fakeToString);
        final result = humanizarError(e);
        expect(result, 'El email ya existe');
      });

      test('FunctionException toString con error que contiene dos puntos',
          () {
        const fakeToString =
            'FunctionException(status: 400, details: {ok: false, error: Error: usuario inválido})';
        const e = _FakeException(fakeToString);
        final result = humanizarError(e);
        // La regex captura todo hasta el primer } → 'Error: usuario inválido'
        expect(result, 'Error: usuario inválido');
      });

      test('FunctionException toString sin campo error — fallback a toString',
          () {
        const fakeToString =
            'FunctionException(status: 500, details: {ok: false, message: algo})';
        const e = _FakeException(fakeToString);
        final result = humanizarError(e);
        // No matchea la regex (no hay 'error:' en el string),
        // y no empieza con 'Exception: ', así que retorna raw.
        // Pero SÍ empieza con 'FunctionException' → entra al if,
        // regex no matchea → cae al replaceFirst que tampoco matchea.
        expect(result, fakeToString);
      });

      test('FunctionException toString con error vacío — fallback', () {
        const fakeToString =
            'FunctionException(status: 400, details: {ok: false, error: })';
        const e = _FakeException(fakeToString);
        final result = humanizarError(e);
        // La regex captura '' (vacío tras trim) → extracted.isEmpty →
        // no entra al if → cae al replaceFirst que no matchea.
        expect(result, fakeToString);
      });
    });

    group('Path 3: otras excepciones — toString tal cual', () {
      test('FormatException', () {
        const e = FormatException('bad format');
        final result = humanizarError(e);
        // FormatException.toString() → 'FormatException: bad format'
        expect(result, contains('bad format'));
      });

      test('StateError', () {
        final e = StateError('bad state');
        final result = humanizarError(e);
        expect(result, contains('bad state'));
      });

      test('String puro (throw "algo")', () {
        const e = 'Error de red inesperado';
        final result = humanizarError(e);
        expect(result, 'Error de red inesperado');
      });

      test('int (throw 42) — edge case', () {
        const e = 42;
        final result = humanizarError(e);
        expect(result, '42');
      });
    });
  });

  // =========================================================================
  // Tests de extractFromFunctionExceptionString — la lógica del generic
  // catch de invokeEdgeFunction (líneas 57-67).
  //
  // Misma regex que humanizarError pero con semántica distinta:
  // - Solo aplica si el toString contiene 'FunctionException' (no
  //   necesariamente al inicio — covers casos donde el SDK wrappea).
  // - Retorna null si no pudo extraer (en el source, hace rethrow).
  // =========================================================================
  group('extractFromFunctionExceptionString', () {
    test('extrae error de toString estándar de FunctionException', () {
      const s =
          'FunctionException(status: 409, details: {ok: false, error: Conflicto de datos})';
      expect(extractFromFunctionExceptionString(s), 'Conflicto de datos');
    });

    test('extrae error con acentos y ñ', () {
      const s =
          'FunctionException(status: 400, details: {ok: false, error: Año inválido — verifiqué})';
      expect(extractFromFunctionExceptionString(s),
          'Año inválido — verifiqué');
    });

    test('retorna null si no contiene FunctionException', () {
      const s = 'Exception: algo salió mal';
      expect(extractFromFunctionExceptionString(s), isNull);
    });

    test('retorna null si contiene FunctionException pero sin campo error',
        () {
      const s =
          'FunctionException(status: 500, details: {ok: false, msg: oops})';
      expect(extractFromFunctionExceptionString(s), isNull);
    });

    test('funciona cuando FunctionException está embebido en otro wrapper',
        () {
      // Caso defensivo del source: "si por algún motivo el `on
      // FunctionException` no capturó [...] wrap en otra exception".
      const s =
          'Unhandled: FunctionException(status: 422, details: {ok: false, error: Dato duplicado})';
      expect(
          extractFromFunctionExceptionString(s), 'Dato duplicado');
    });

    test('retorna null si error está vacío', () {
      const s =
          'FunctionException(status: 400, details: {ok: false, error: })';
      expect(extractFromFunctionExceptionString(s), isNull);
    });

    test('captura todo hasta el primer cierre de llave', () {
      const s =
          'FunctionException(status: 400, details: {ok: false, error: Mensaje con : y , y cosas raras})';
      expect(extractFromFunctionExceptionString(s),
          'Mensaje con : y , y cosas raras');
    });
  });

  // =========================================================================
  // Tests de invokeEdgeFunction — función pública del helper.
  //
  // NOTA: invokeEdgeFunction requiere un SupabaseClient real (o mock).
  // Sin mockito en dev_dependencies y sin poder modificar source files,
  // no podemos inyectar un FunctionsClient fake. Los tests anteriores
  // cubren la lógica pura de manejo de errores. Aquí documentamos los
  // escenarios que SÍ se podrían testear con mockito y los marcamos como
  // referencia para cuando se agregue la dependencia.
  //
  // Para testear invokeEdgeFunction end-to-end se necesitaría:
  //   1. Agregar `mockito` + `build_runner` a dev_dependencies, o
  //   2. Extraer la lógica de error-handling a una función pública
  //      (ej: `parseEdgeFunctionError`) y testearla directamente.
  //
  // Los escenarios pendientes son:
  //   - Respuesta exitosa (data con ok: true) → retorna el map
  //   - Respuesta con data null → lanza 'Sin respuesta del servidor'
  //   - Respuesta con ok != true y campo error → lanza el mensaje
  //   - Respuesta con ok != true sin campo error → lanza 'Error desconocido'
  //   - FunctionException con details map y campo error → lanza el mensaje
  //   - FunctionException con details sin campo error → lanza 'Error {status}'
  //   - FunctionException con details no-map → lanza 'Error {status}'
  //   - Generic catch con toString conteniendo FunctionException → extrae
  //   - Generic catch sin FunctionException → rethrow
  // =========================================================================
  group('invokeEdgeFunction — documentación de escenarios', () {
    // Placeholder: estos tests requieren mocking de SupabaseClient.
    // La lógica de error ya está cubierta arriba via humanizarError
    // y extractFromFunctionExceptionString.
    test('(pendiente mock) respuesta exitosa retorna el map', () {
      // Requiere: mock de client.functions.invoke que retorne
      // FunctionResponse con data: {'ok': true, 'id': '123'}
      // expect(result, {'ok': true, 'id': '123'});
    }, skip: 'Requiere mockito o fake de SupabaseClient');

    test('(pendiente mock) data null lanza "Sin respuesta del servidor"',
        () {
      // Requiere: mock que retorne FunctionResponse con data: null
      // expect(() => invokeEdgeFunction(...), throwsA(
      //   isA<Exception>().having((e) => e.toString(),
      //       'message', contains('Sin respuesta del servidor'))));
    }, skip: 'Requiere mockito o fake de SupabaseClient');

    test('(pendiente mock) ok != true con campo error lanza el mensaje',
        () {
      // Requiere: mock que retorne data: {'ok': false, 'error': 'msg'}
    }, skip: 'Requiere mockito o fake de SupabaseClient');

    test(
        '(pendiente mock) FunctionException con details.error lanza el mensaje',
        () {
      // Requiere: mock que lance FunctionException con details map
    }, skip: 'Requiere mockito o fake de SupabaseClient');
  });
}

/// Helper para tests: objeto cuyo [toString] retorna un string controlado.
/// Simula cómo se vería un `FunctionException` si llega al catch genérico
/// como `Object` (type mismatch del SDK, wrap en otra exception, etc.).
class _FakeException {
  final String _repr;
  const _FakeException(this._repr);

  @override
  String toString() => _repr;
}
