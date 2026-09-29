@TestOn('vm')
library;

/// Quién VE la opción de cambiar de plan.
///
/// Existe por un bug de producto que costó caro: `admin_usuarios` veía
/// "Solicitar cancelación" pero NO "Cambiar plan", así que para un cambio de
/// servicio su única salida era cancelar el contrato y crear otro. Cada vez que
/// lo hacía, el cliente quedaba con dos contratos y dos cuotas en el mismo
/// ciclo — el descuadre "usuarios ≠ cuotas" del Resumen que reportó el dueño.
///
/// Medido en las solicitudes reales de los dos tenants antes del fix:
/// `admin_usuarios` metió 61 cancelaciones y 207 contratos nuevos, y CERO
/// cambios de plan. El rol que hace ~90% de la gestión no tenía la herramienta.
///
/// LA REGLA QUE FIJA ESTE TEST: **todo rol que pueda pedir una CANCELACIÓN
/// tiene que poder pedir un CAMBIO DE PLAN.** Si no, se lo empuja a cancelar.
/// Ya pasó dos veces (primero con `admin_cobranza`, después con
/// `admin_usuarios`); el test es para que no haya una tercera.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/cobrador.dart';
import 'package:isp_billing/data/models/setting.dart';
import 'package:isp_billing/data/providers/cobrador_provider.dart';
import 'package:isp_billing/data/repositories/settings_repo.dart';

Cobrador _con(String rol) => Cobrador(
      id: 'u-$rol',
      tenantId: 't1',
      nombre: rol,
      rol: rol,
      activo: true,
    );

/// El setting real que gatea la feature, armado a mano.
Map<String, Setting> _settings({required bool cambioPlanOn}) => {
      'cobranza.cambio_plan_habilitado': Setting(
        id: 's1',
        tenantId: 't1',
        clave: 'cobranza.cambio_plan_habilitado',
        valor: cambioPlanOn,
        tipo: 'bool',
        categoria: 'cobranza',
        editablePor: 'admin',
      ),
    };

/// Contenedor con el rol dado y la feature de cambio de plan encendida.
ProviderContainer _para(String rol, {bool featureOn = true}) {
  return ProviderContainer(overrides: [
    cobradorActualProvider.overrideWith((ref) => Stream.value(_con(rol))),
    appSettingsProvider
        .overrideWithValue(AppSettings(_settings(cambioPlanOn: featureOn))),
  ]);
}

void main() {
  /// Espera a que `cobradorActualProvider` (un stream) entregue su valor.
  Future<T> leer<T>(ProviderContainer c, ProviderListenable<T> p) async {
    await c.read(cobradorActualProvider.future);
    return c.read(p);
  }

  group('puedeVerCambiarPlan', () {
    for (final rol in ['admin', 'admin_cobranza', 'admin_usuarios']) {
      test('$rol VE cambiar plan', () async {
        final c = _para(rol);
        addTearDown(c.dispose);
        expect(await leer(c, puedeVerCambiarPlanProvider), isTrue,
            reason: '$rol gestiona contratos: sin este botón termina '
                'cancelando y creando otro');
      });
    }

    for (final rol in ['cobrador', 'tecnico', 'lectura']) {
      test('$rol NO ve cambiar plan', () async {
        final c = _para(rol);
        addTearDown(c.dispose);
        expect(await leer(c, puedeVerCambiarPlanProvider), isFalse);
      });
    }
  });

  group('la regla: quien puede cancelar, puede cambiar de plan', () {
    // El invariante de producto, no el detalle de implementación. Recorre TODOS
    // los roles: si mañana se agrega uno a la lista de "gestiona contratos" y
    // se olvida acá, este test lo caza.
    const roles = [
      'admin', 'admin_cobranza', 'admin_usuarios', 'super_admin',
      'cobrador', 'tecnico', 'lectura',
    ];
    for (final rol in roles) {
      test('$rol: coherencia entre cancelar y cambiar plan', () async {
        final c = _para(rol);
        addTearDown(c.dispose);
        final puedeCancelar =
            await leer(c, puedeGestionarEstadoContratoProvider);
        final puedeCambiarPlan = await leer(c, puedeVerCambiarPlanProvider);
        if (puedeCancelar) {
          expect(puedeCambiarPlan, isTrue,
              reason: 'a $rol se le ofrece cancelar el contrato pero no '
                  'cambiarle el plan: eso lo empuja a cancelar+crear, que '
                  'parte al cliente en dos contratos');
        }
      });
    }
  });

  test('con la feature APAGADA no lo ve nadie, ni el admin', () async {
    final c = _para('admin', featureOn: false);
    addTearDown(c.dispose);
    expect(await leer(c, puedeVerCambiarPlanProvider), isFalse,
        reason: 'el gate de la feature manda sobre el rol');
  });
}
