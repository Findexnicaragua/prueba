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

  final status = ref.watch(syncStatusProvider).valueOrNull;
  if (status == null) return false;

  // Mientras PowerSync esté descargando activamente datos, el gate no debe abrirse.
  if (status.downloading) return false;

  final lastSyncedAt = status.lastSyncedAt;
  if (lastSyncedAt == null) return false;

  // Al entrar a una empresa (impersonando):
  // 1. El sync debe haber finalizado estrictamente DESPUÉS de que se ordenó entrar
  //    (changedAt), SIN margen hacia atrás, porque el tenant anterior (o System)
  //    sincronizó hace segundos y su lastSyncedAt satisfaría un margen de -2s.
  // 2. Para login normal: mantenemos el margen de 2s defensivo contra races de ms.
  final threshold = identity.entrandoATenant
      ? identity.changedAt!
      : identity.changedAt!.subtract(const Duration(seconds: 2));
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
  final identity = ref.watch(authIdentityProvider);
  final changedAt = identity.changedAt;
  if (changedAt == null) return true; // sin cambio de identidad, nada que esperar

  // 🔴 ENTRAR A UNA EMPRESA NO TIENE PLAZO DE GRACIA (2026-09-03).
  //
  // Los 8s de abajo se pensaron para un login: la app se abre rápido y el
  // delta sync corre por atrás. Pero al impersonar se baja la empresa ENTERA
  // —~190.000 filas en Telecable Mairena, ~34.000 en Telenet— y en 8 segundos
  // entra una fracción. El gate se abría solo, el super_admin caía en una app
  // con las pantallas vacías, y mientras el resto seguía bajando cada lote
  // re-disparaba las consultas del Resumen: los gráficos giraban sin resolver.
  //
  // El propio comentario de abajo decía que el plazo existía por el "sync
  // inicial lento del super_admin" — o sea que el problema ya se conocía y se
  // había resuelto dejándolo pasar. Se cambió una espera larga por una app
  // vacía, y para quien entra a mirar datos eso es peor.
  //
  // No deja a nadie atascado: `SyncGateScreen` muestra el progreso REAL de
  // descarga (registros bajados sobre el total), avisa si se cortó la conexión,
  // y ofrece reintentar a los 2 minutos y volver al login a los 3.
  //
  // Y se paga UNA vez por empresa: al reingresar, PowerSync baja sólo los
  // cambios desde la última visita (medido y aceptado por el dueño).
  if (identity.entrandoATenant) return false;

  const grace = Duration(seconds: 8);
  final elapsed = DateTime.now().difference(changedAt);
  if (elapsed >= grace) return true;
  // Nadie re-evalúa el gate si no llega un sync nuevo; programamos el poke.
  final timer = Timer(grace - elapsed, () => ref.invalidateSelf());
  ref.onDispose(timer.cancel);
  return false;
});
