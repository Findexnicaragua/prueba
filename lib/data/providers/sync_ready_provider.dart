import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_identity_provider.dart';
import 'sync_status_provider.dart';

/// Boolean derivado que indica si la UI puede mostrarse o si hay que
/// esperar a que PowerSync sincronice tras un cambio de identidad.
///
/// Retorna `true` cuando:
///   - No hay sesión (el router redirigirá a /login, no hay nada
///     que gatear).
///   - La identidad nunca cambió en este proceso ni cross-session
///     (`changedAt == null`, restore inicial del último user conocido).
///   - PowerSync confirmó un sync POSTERIOR al último cambio de
///     identidad (`lastSyncedAt > changedAt`).
///
/// Retorna `false` cuando hay un changedAt pero PowerSync aún no
/// confirmó un sync más reciente. En ese caso el router redirige a
/// `/sync-gate`.
///
/// No es `autoDispose` a propósito: el router escucha esta dependencia
/// continuamente y el cierre/reapertura causaría rebuilds raros.
final syncReadyProvider = Provider<bool>((ref) {
  final identity = ref.watch(authIdentityProvider);

  if (identity.userId == null) return true;
  if (identity.changedAt == null) return true;

  final lastSyncedAt =
      ref.watch(syncStatusProvider).valueOrNull?.lastSyncedAt;
  if (lastSyncedAt == null) return false;

  // Margen de 2 segundos: PowerSync puede emitir lastSyncedAt con un
  // timestamp muy cercano a changedAt (race de milisegundos en el
  // handshake inicial). Sin margen, el gate queda atascado porque
  // isAfter(changedAt) retorna false cuando los timestamps son iguales
  // o difieren por <1ms. El margen no compromete la seguridad del gate
  // (que protege contra cache stale de otro user, no contra ms de
  // timing). Bug reproducido 3+ veces en E2E sesión 2.
  final threshold = identity.changedAt!.subtract(const Duration(seconds: 2));
  return lastSyncedAt.isAfter(threshold);
});

/// Grace timeout del sync gate: vuelve `true` 8s después del último cambio de
/// identidad, aunque PowerSync no haya confirmado el sync. Evita que el gate
/// se quede esperando minutos con DB vacía / sync inicial lento del super_admin.
/// Es seguro: offline-first (la data aparece a medida que llega) y un fresh
/// install no tiene cache stale de otro user que proteger. Se auto-resetea
/// cuando cambia `changedAt` (nuevo login/switch) — el watch reconstruye y el
/// onDispose cancela el timer viejo.
final syncGateGraceProvider = Provider<bool>((ref) {
  final changedAt = ref.watch(authIdentityProvider).changedAt;
  if (changedAt == null) return true; // sin cambio de identidad, nada que esperar
  const grace = Duration(seconds: 8);
  final elapsed = DateTime.now().difference(changedAt);
  if (elapsed >= grace) return true;
  // Nadie re-evalúa el gate si no llega un sync nuevo; programamos el poke.
  final timer = Timer(grace - elapsed, () => ref.invalidateSelf());
  ref.onDispose(timer.cancel);
  return false;
});
