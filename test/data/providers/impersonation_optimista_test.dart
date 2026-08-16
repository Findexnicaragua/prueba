import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/providers/impersonation_provider.dart';

/// Fija el contrato del estado OPTIMISTA de impersonación (fix audit 2026-07-04):
///   - `impersonatedTenantEfectivoProvider` = para RUTEO (optimista los 2 lados).
///   - `estaImpersonandoProvider` = guard de DINERO: sigue la fila local cruda,
///     ON también al ENTRAR, y NUNCA se apaga al SALIR hasta que la fila real
///     se borre (sino un cobro en la ventana de `exit()` quedaría huérfano en
///     System — la regresión que este desacople previene).
///
/// `impersonatedTenantIdProvider` (la fila local, StreamProvider) se overridea
/// para controlar el valor "crudo" sin tocar PowerSync.
void main() {
  const tenantA = 'aaaaaaaa-0000-0000-0000-000000000001';

  /// Construye un container con un valor crudo dado + un pending opcional, y
  /// devuelve (efectivo-para-ruteo, estaImpersonando-guard-dinero).
  Future<({String? efectivo, bool guard})> evaluar({
    required String? filaLocal,
    PendingImpersonacion? pending,
  }) async {
    final container = ProviderContainer(overrides: [
      impersonatedTenantIdProvider.overrideWith((ref) => Stream.value(filaLocal)),
    ]);
    addTearDown(container.dispose);
    // Materializa el StreamProvider (emite el primer valor).
    await container.read(impersonatedTenantIdProvider.future);
    if (pending != null) {
      container.read(pendingImpersonacionProvider.notifier).state = pending;
    }
    return (
      efectivo: container.read(impersonatedTenantEfectivoProvider),
      guard: container.read(estaImpersonandoProvider),
    );
  }

  group('estado optimista de impersonación', () {
    test('sin pending, fila null → no impersona (ruteo y guard)', () async {
      final r = await evaluar(filaLocal: null);
      expect(r.efectivo, isNull);
      expect(r.guard, isFalse);
    });

    test('sin pending, fila=A → impersona A (ruteo y guard)', () async {
      final r = await evaluar(filaLocal: tenantA);
      expect(r.efectivo, tenantA);
      expect(r.guard, isTrue);
    });

    test('ENTRANDO(A), fila aún null (no sincronizó) → ruteo optimista A + '
        'guard de dinero YA ON', () async {
      final r = await evaluar(
          filaLocal: null, pending: const PendingImpersonacion.entrando(tenantA));
      expect(r.efectivo, tenantA, reason: 'ruteo: landing a /admin sin flash');
      expect(r.guard, isTrue, reason: 'dinero: bloqueado desde el primer frame');
    });

    test('ENTRANDO(A), fila ya=A (sincronizó) → A en ambos', () async {
      final r = await evaluar(
          filaLocal: tenantA,
          pending: const PendingImpersonacion.entrando(tenantA));
      expect(r.efectivo, tenantA);
      expect(r.guard, isTrue);
    });

    test('SALIENDO, fila todavía=A (no se borró) → ruteo optimista null (sin '
        'rebote) PERO guard de dinero SIGUE ON (no huérfano en System)',
        () async {
      final r = await evaluar(
          filaLocal: tenantA, pending: const PendingImpersonacion.saliendo());
      expect(r.efectivo, isNull,
          reason: 'ruteo: queda en /super/tenants, sin rebotar a /admin');
      expect(r.guard, isTrue,
          reason: 'DINERO: la atribución sigue en el tenant → guard ON hasta '
              'que la fila real se borre');
    });

    test('SALIENDO, fila ya null (se borró) → no impersona en ambos', () async {
      final r = await evaluar(
          filaLocal: null, pending: const PendingImpersonacion.saliendo());
      expect(r.efectivo, isNull);
      expect(r.guard, isFalse);
    });
  });
}
