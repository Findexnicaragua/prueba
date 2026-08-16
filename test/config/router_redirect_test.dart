import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/config/router.dart';

/// Tests del redirect inicial por rol (landing de `/` + guards de shell por
/// rol). Es la lógica que más regresiones de routing produjo; acá queda
/// blindada sin necesidad de montar GoRouter ni PowerSync.
void main() {
  String? r(String? rol, String loc, {bool impersonating = false}) =>
      redirectInicialPorRol(rol: rol, loc: loc, impersonating: impersonating);

  group('landing en "/"', () {
    test('super_admin normal → /super/tenants', () {
      expect(r('super_admin', '/'), '/super/tenants');
    });
    test('super_admin impersonando → /admin', () {
      expect(r('super_admin', '/', impersonating: true), '/admin');
    });
    test('admin → /admin', () => expect(r('admin', '/'), '/admin'));
    test('admin_cobranza → /admin',
        () => expect(r('admin_cobranza', '/'), '/admin'));
    test('admin_tickets → /admin-tickets',
        () => expect(r('admin_tickets', '/'), '/admin-tickets'));
    test('cobrador → null (se queda en su shell "/")',
        () => expect(r('cobrador', '/'), isNull));
    test('tecnico → /tecnico', () => expect(r('tecnico', '/'), '/tecnico'));
    test('rol null (sin resolver) → null',
        () => expect(r(null, '/'), isNull));
    // El rol nace en 0198 y su landing se olvidó en la primera pasada: caía al
    // shell del COBRADOR y no llegaba nunca al panel que se le construyó.
    test('lectura → /admin', () => expect(r('lectura', '/'), '/admin'));
  });

  group('rol lectura (0198)', () {
    test('el form de cobro lo rebota al panel',
        () => expect(r('lectura', '/cobro/abc'), '/admin'));
    test('los formularios de alta lo rebotan al panel', () {
      expect(r('lectura', '/admin/clientes/nuevo'), '/admin');
      expect(r('lectura', '/admin/contratos/nuevo'), '/admin');
      expect(r('lectura', '/admin/tickets/nuevo'), '/admin');
    });
    test('los formularios de edición lo rebotan al panel',
        () => expect(r('lectura', '/admin/clientes/abc/editar'), '/admin'));
    test('el recibo NO lo rebota: es documento de consulta',
        () => expect(r('lectura', '/recibo/abc'), isNull));
    test('las pantallas de consulta lo dejan pasar', () {
      expect(r('lectura', '/admin/clientes'), isNull);
      expect(r('lectura', '/admin/reportes'), isNull);
      expect(r('lectura', '/admin/mapa'), isNull);
      expect(r('lectura', '/admin/cobros'), isNull);
    });
    // El bloqueo de `/super/*` no se testea acá: vive en el `redirect` del
    // GoRouter (junto al de impersonación), no en esta función pura. Aplica a
    // todos los roles por igual, no es específico de `lectura`.
  });

  group('guard del técnico', () {
    test('en /admin → /tecnico', () => expect(r('tecnico', '/admin'), '/tecnico'));
    test('en su shell /tecnico → null',
        () => expect(r('tecnico', '/tecnico'), isNull));
    test('en /tecnico/mapa → null',
        () => expect(r('tecnico', '/tecnico/mapa'), isNull));
    test('en /perfil/impresora (compartida) → null',
        () => expect(r('tecnico', '/perfil/impresora'), isNull));
  });

  group('guard de coordinador (0207)', () {
    test('landing → /admin-tickets',
        () => expect(r('coordinador', '/'), '/admin-tickets'));
    test('en su shell → null',
        () => expect(r('coordinador', '/admin-tickets'), isNull));
    test('en el detalle de una orden → null',
        () => expect(r('coordinador', '/admin-tickets/tickets/123'), isNull));
    test('en /admin (panel de plata) → lo saca',
        () => expect(r('coordinador', '/admin'), '/admin-tickets'));
    test('en /super/tenants → lo saca',
        () => expect(r('coordinador', '/super/tenants'), '/admin-tickets'));
    test('en el shell del tecnico → lo saca',
        () => expect(r('coordinador', '/tecnico'), '/admin-tickets'));
    test('impresora compartida → null',
        () => expect(r('coordinador', '/perfil/impresora'), isNull));
    test('NO se confunde /admin con /admin-tickets',
        () => expect(r('coordinador', '/admin/clientes'), '/admin-tickets'));
  });

  group('guard de admin_tickets', () {
    test('en /admin → /admin-tickets',
        () => expect(r('admin_tickets', '/admin'), '/admin-tickets'));
    test('en /super/tenants → /admin-tickets',
        () => expect(r('admin_tickets', '/super/tenants'), '/admin-tickets'));
    test('en su shell /admin-tickets → null',
        () => expect(r('admin_tickets', '/admin-tickets'), isNull));
    test('en /admin-tickets/mapa → null',
        () => expect(r('admin_tickets', '/admin-tickets/mapa'), isNull));
    test('en /admin-tickets/tickets/123 → null',
        () => expect(r('admin_tickets', '/admin-tickets/tickets/123'), isNull));
    test('en /perfil/impresora (compartida) → null',
        () => expect(r('admin_tickets', '/perfil/impresora'), isNull));
    test('NO se confunde /admin con /admin-tickets',
        () => expect(r('admin_tickets', '/admin/clientes'), '/admin-tickets'));
  });

  group('guard del cobrador', () {
    test('en /admin → /', () => expect(r('cobrador', '/admin'), '/'));
    test('en /admin/clientes → /',
        () => expect(r('cobrador', '/admin/clientes'), '/'));
    test('en /clientes (su shell) → null',
        () => expect(r('cobrador', '/clientes'), isNull));
    test('en /mapa (su shell) → null',
        () => expect(r('cobrador', '/mapa'), isNull));
  });

  group('admin no se rebota de sus sub-rutas (lo maneja el caller)', () {
    test('admin en /admin/clientes → null',
        () => expect(r('admin', '/admin/clientes'), isNull));
    test('admin en /admin/tickets → null',
        () => expect(r('admin', '/admin/tickets'), isNull));
  });
}
