@TestOn('vm')
library;

/// El plazo de gracia del sync gate NO aplica al entrar a una empresa.
///
/// ## El bug que este test existe para cazar (2026-09-03)
///
/// `syncGateGraceProvider` abre el gate **8 segundos** después de un cambio de
/// identidad, haya terminado el sync o no. Para un login está bien: la app se
/// abre rápido y el delta corre por atrás.
///
/// Pero al impersonar se baja la empresa ENTERA — **~190.000 filas** en
/// Telecable Mairena. En 8 segundos entra una fracción, así que el gate se
/// abría solo y el super_admin caía en una app con las pantallas vacías. El
/// dueño lo reportó con estas palabras: *"siempre me hace una transición que me
/// permite entrar al app sin nada cargado y yo como dev necesito ver data"*.
///
/// Lo irónico es que el plazo existía **por** ese mismo caso: su comentario
/// decía que era para evitar "esperar minutos con DB vacía / sync inicial lento
/// del super_admin". O sea que se cambió una espera larga por una app vacía.
///
/// ## Por qué es seguro esperar
///
/// `SyncGateScreen` muestra progreso REAL de descarga, avisa si se cortó la
/// conexión, y ofrece reintentar a los 2 minutos y volver al login a los 3.
/// Nadie queda atascado en silencio. Y el costo se paga UNA vez por empresa:
/// al reingresar sólo bajan los cambios desde la última visita.
///
/// ## Qué se prueba, y por qué así
///
/// El plazo depende del reloj, así que un test que espere 8 segundos de verdad
/// sería lento y frágil. Se prueba la DECISIÓN, que es lo que cambió: con la
/// bandera puesta el plazo no libera **nunca**, independientemente del tiempo.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/providers/auth_identity_provider.dart';
import 'package:isp_billing/data/providers/sync_ready_provider.dart';
import 'package:isp_billing/data/providers/sync_status_provider.dart';
import 'package:powersync/powersync.dart';

void main() {
  /// Un contenedor con la identidad ya puesta en el estado que se quiere
  /// probar. Se sobreescribe el notifier entero: construirlo y después llamar
  /// a `onImpersonationChanged()` dejaría `changedAt` en "ahora", que es
  /// justamente lo que hace que el plazo todavía no haya vencido — y el test
  /// pasaría por el motivo equivocado.
  bool graceCon({required bool entrandoATenant, required Duration hace}) {
    final container = ProviderContainer(overrides: [
      authIdentityProvider.overrideWith((ref) => _NotifierFijo(
            AuthIdentityState(
              userId: 'u1',
              changedAt: DateTime.now().subtract(hace),
              entrandoATenant: entrandoATenant,
            ),
          )),
    ]);
    addTearDown(container.dispose);
    return container.read(syncGateGraceProvider);
  }

  group('el plazo de gracia del sync gate', () {
    test('🔴 al ENTRAR A UNA EMPRESA no libera, ni recién ni mucho después',
        () {
      // Recién entrado: con o sin el arreglo daría false (no pasaron los 8s).
      expect(graceCon(entrandoATenant: true, hace: const Duration(seconds: 1)),
          isFalse);

      // ACÁ está el cambio. Al minuto, el plazo viejo ya habría liberado hace
      // rato y el super_admin estaría adentro con la app vacía. Ahora espera.
      expect(graceCon(entrandoATenant: true, hace: const Duration(minutes: 1)),
          isFalse,
          reason: 'el plazo liberó al entrar a una empresa: el super_admin va a '
              'caer en una app vacía mientras se descargan ~190.000 filas');

      // Y no es que "todavía no llegó": a la hora sigue sin liberar. El gate lo
      // abre el sync de verdad, no el reloj.
      expect(graceCon(entrandoATenant: true, hace: const Duration(hours: 1)),
          isFalse);
    });

    test('en un LOGIN normal sigue liberando a los 8 segundos', () {
      // La contraprueba: si el arreglo hubiera desactivado el plazo para todos,
      // cada login volvería a esperar el sync completo — una regresión de UX
      // para los cobradores, que es a quienes el plazo protege.
      expect(graceCon(entrandoATenant: false, hace: const Duration(seconds: 2)),
          isFalse,
          reason: 'antes de los 8s todavía no libera');
      expect(graceCon(entrandoATenant: false, hace: const Duration(seconds: 30)),
          isTrue,
          reason: 'pasados los 8s, un login normal entra y el delta corre '
              'por atrás');
    });

    test('sin cambio de identidad no hay nada que esperar', () {
      final container = ProviderContainer(overrides: [
        authIdentityProvider.overrideWith(
            (ref) => _NotifierFijo(const AuthIdentityState(userId: 'u1'))),
      ]);
      addTearDown(container.dispose);
      expect(container.read(syncGateGraceProvider), isTrue);
    });
  });

  test('onImpersonationChanged marca la bandera; los demás no', () {
    final n = AuthIdentityNotifier(lastKnownUserId: 'u1');
    expect(n.state.entrandoATenant, isFalse);

    n.onImpersonationChanged();
    expect(n.state.entrandoATenant, isTrue,
        reason: 'sin esta bandera el gate vuelve a abrirse a los 8s');
    expect(n.state.changedAt, isNotNull);

    // Salir de la empresa / cerrar sesión NO debe dejar la bandera pegada: si
    // quedara, el próximo login normal esperaría el sync completo.
    n.onSignOut();
    expect(n.state.entrandoATenant, isFalse,
        reason: 'la bandera quedó pegada después de cerrar sesión');

    n.onImpersonationChanged();
    expect(n.state.entrandoATenant, isTrue);
    n.onSyncCompletado();
    expect(n.state.entrandoATenant, isFalse);
    expect(n.state.changedAt, isNull);

    n.onImpersonationChanged();
    expect(n.state.entrandoATenant, isTrue);
    n.onImpersonationFailed();
    expect(n.state.entrandoATenant, isFalse);
    expect(n.state.changedAt, isNull);
  });

  group('syncReadyProvider al entrar a un tenant impersonando', () {
    test('NO da listo si PowerSync sigue descargando datos', () async {
      final ahora = DateTime.now();
      final container = ProviderContainer(overrides: [
        authIdentityProvider.overrideWith((ref) => _NotifierFijo(
              AuthIdentityState(
                userId: 'u1',
                changedAt: ahora,
                entrandoATenant: true,
              ),
            )),
        syncStatusProvider.overrideWith((ref) => Stream.value(
              SyncStatus(
                connected: true,
                downloading: true,
                lastSyncedAt: ahora.add(const Duration(seconds: 5)),
              ),
            )),
      ]);
      addTearDown(container.dispose);
      await container.read(syncStatusProvider.future);
      expect(container.read(syncReadyProvider), isFalse,
          reason: 'mientras downloading=true, la DB no tiene todos los registros');
    });

    test('NO da listo si lastSyncedAt es anterior al cambio (sync del tenant viejo)', () async {
      final ahora = DateTime.now();
      final container = ProviderContainer(overrides: [
        authIdentityProvider.overrideWith((ref) => _NotifierFijo(
              AuthIdentityState(
                userId: 'u1',
                changedAt: ahora,
                entrandoATenant: true,
              ),
            )),
        syncStatusProvider.overrideWith((ref) => Stream.value(
              SyncStatus(
                connected: true,
                downloading: false,
                // Sincronizado hace 1 segundo (del tenant viejo, antes de cambiar)
                lastSyncedAt: ahora.subtract(const Duration(seconds: 1)),
              ),
            )),
      ]);
      addTearDown(container.dispose);
      await container.read(syncStatusProvider.future);
      expect(container.read(syncReadyProvider), isFalse,
          reason: 'el sync del tenant viejo no debe engañar al gate');
    });

    test('DA LISTO sólo cuando downloading=false y lastSyncedAt es posterior al cambio', () async {
      final ahora = DateTime.now();
      final container = ProviderContainer(overrides: [
        authIdentityProvider.overrideWith((ref) => _NotifierFijo(
              AuthIdentityState(
                userId: 'u1',
                changedAt: ahora,
                entrandoATenant: true,
              ),
            )),
        syncStatusProvider.overrideWith((ref) => Stream.value(
              SyncStatus(
                connected: true,
                downloading: false,
                lastSyncedAt: ahora.add(const Duration(seconds: 2)),
              ),
            )),
      ]);
      addTearDown(container.dispose);
      await container.read(syncStatusProvider.future);
      expect(container.read(syncReadyProvider), isTrue,
          reason: 'descarga terminada y posterior al cambio');
    });
  });
}

/// Notifier de prueba con un estado fijo. `StateNotifier` no permite construir
/// con un estado arbitrario desde afuera, así que se envuelve.
class _NotifierFijo extends StateNotifier<AuthIdentityState>
    implements AuthIdentityNotifier {
  _NotifierFijo(super.estado);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
