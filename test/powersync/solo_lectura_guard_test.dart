import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/powersync/db.dart' as ps;

/// La guardia de escritura del rol `lectura` (0198) es el backstop de las 25+
/// acciones que la UI podría dejar pasar. Si alguien la desarma sin querer, el
/// síntoma no es un error visible sino un CAMBIO FANTASMA (se aplica local y
/// el connector lo descarta después, sin avisarle al usuario) — por eso vale
/// tenerla cubierta acá.
void main() {
  tearDown(() => ps.rolActualCache = null);

  group('guardia de solo lectura', () {
    test('el rol lectura no puede obtener la DB de escritura', () {
      ps.rolActualCache = 'lectura';
      expect(() => ps.dbW, throwsA(isA<ps.SoloLecturaException>()));
    });

    test('el mensaje es accionable y en español, sin jerga técnica', () {
      const e = ps.SoloLecturaException();
      expect(e.toString(), contains('solo lectura'));
      expect(e.toString(), isNot(contains('Exception:')));
    });

    test('los demás roles pasan la guardia', () {
      // No se toca `ps.db` (no hay DB abierta en tests): alcanza con que el
      // getter no lance para probar que la guardia solo frena a `lectura`.
      for (final rol in [
        'admin',
        'admin_cobranza',
        'admin_usuarios',
        'cobrador',
        'tecnico',
        'admin_tickets',
        'super_admin',
      ]) {
        ps.rolActualCache = rol;
        expect(() => ps.dbW, isNot(throwsA(isA<ps.SoloLecturaException>())),
            reason: 'el rol $rol debe poder escribir');
      }
    });

    test('sin rol cacheado NO bloquea (no perder writes de un rol válido)', () {
      // Fallback deliberado: si la fila de cobradores todavía no bajó, tragarse
      // un cobro offline sería peor que dejar pasar un write que RLS rechaza.
      ps.rolActualCache = null;
      expect(() => ps.dbW, isNot(throwsA(isA<ps.SoloLecturaException>())));
    });
  });
}
