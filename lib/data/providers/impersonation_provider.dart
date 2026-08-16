import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import 'db_epoch_provider.dart';

/// Stream que indica si el super_admin está impersonando un tenant.
/// Retorna el tenant_id impersonado o null si no hay impersonación activa.
///
/// Lee de la tabla `super_admin_impersonation` en el SQLite local
/// (sincronizada por PowerSync vía el bucket `super_admin_self`).
///
/// Para users normales, el query retorna vacío (no tienen rows en
/// esta tabla) → null → sin efecto.
///
/// **No tiene funciones de enter/exit**: toda la lógica de escribir la
/// tabla vive en `ImpersonationService` (un solo write path). NOTA (audit
/// 2026-06-24): NO hay rastro forense de la impersonación — `audit_log` se
/// eliminó (0140) y `op_log` es client-written; antes este doc lo afirmaba.
final impersonatedTenantIdProvider = StreamProvider<String?>((ref) async* {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  yield* ps.db
      .watch('SELECT tenant_id FROM super_admin_impersonation LIMIT 1')
      .map((rows) =>
          rows.isEmpty ? null : rows.first['tenant_id'] as String?);
});

/// Estado OPTIMISTA de una impersonación en curso, hasta que la fila local
/// sincronizada (`impersonatedTenantIdProvider`) refleje el cambio.
///
/// Por qué (audit 2026-07-04): `enter()`/`exit()` escriben la fila en el
/// SERVER (directo, para que las sync rules del bucket `impersonated_tenant`
/// la vean), pero la fila LOCAL llega/se borra por sync con lag. El router
/// decide el landing por el estado de impersonación → con la fila local
/// desfasada, al ENTRAR flasheaba `/super/tenants` (leía impersonando=false)
/// y al SALIR rebotaba `/admin` (leía impersonando=true stale). Este flag da
/// el estado real YA, sin esperar el sync. Se limpia solo cuando la fila local
/// alcanza el estado esperado (lo hace el router con un `ref.listen`).
class PendingImpersonacion {
  const PendingImpersonacion.entrando(String this.tenantId) : saliendo = false;
  const PendingImpersonacion.saliendo()
      : tenantId = null,
        saliendo = true;
  final String? tenantId;
  final bool saliendo;
}

final pendingImpersonacionProvider =
    StateProvider<PendingImpersonacion?>((ref) => null);

/// Tenant impersonado EFECTIVO para ruteo y gating: el optimista mientras hay
/// una impersonación en curso, sino la fila local sincronizada.
final impersonatedTenantEfectivoProvider = Provider<String?>((ref) {
  final pending = ref.watch(pendingImpersonacionProvider);
  if (pending != null) return pending.saliendo ? null : pending.tenantId;
  return ref.watch(impersonatedTenantIdProvider).valueOrNull;
});

/// True si el super_admin está impersonando un tenant ahora mismo.
///
/// Usado para DESHABILITAR las acciones de campo (cobro / cargo manual /
/// registrar visita) mientras se impersona (#9): esos write-paths atribuyen
/// `cobrador_id`/`tenant_id` a la fila real del super_admin (tenant System),
/// no al tenant impersonado, lo que generaría pagos/recibos huérfanos en
/// System y rompería los invariantes de dinero. El super_admin impersona para
/// VER/GESTIONAR; la cobranza de campo la hace el cobrador del ISP.
///
/// **Guard de DINERO — NO usa el efectivo (audit 2026-07-04, punto 3).** El
/// efectivo optimista es SOLO para ruteo. Acá el guard debe seguir a la
/// ATRIBUCIÓN real: `tenantIdProvider` lee la fila LOCAL cruda, así que el
/// guard tiene que estar ON mientras esa fila diga impersonando. Por eso:
///   - ON si la fila local está presente (atribución = tenant impersonado), Y
///   - ON también si estamos ENTRANDO (pending optimista) — cierra la ventana
///     pre-existente donde la fila aún no bajó pero el super ya está adentro.
///   - Al SALIR NO se apaga por el optimista: sigue ON hasta que la fila local
///     REALMENTE se borre (evita que un cobro en la ventana de `exit()` quede
///     huérfano en System con el guard OFF — regresión que esto previene).
final estaImpersonandoProvider = Provider<bool>((ref) {
  final filaLocal = ref.watch(impersonatedTenantIdProvider).valueOrNull;
  if (filaLocal != null) return true;
  final pending = ref.watch(pendingImpersonacionProvider);
  return pending != null && !pending.saliendo;
});

/// Guard de UI para acciones sensibles del tenant (mueven dinero o estado):
/// si el super_admin está impersonando, muestra un aviso y devuelve `true`
/// (la acción debe abortar con `return`). Centraliza el patrón que antes se
/// duplicaba inline en cobro / cargo / anular / cancelar — toda acción sensible
/// debe quedar atribuida al admin REAL del tenant, no a la fila System del
/// super_admin. Usar al inicio del handler: `if (bloqueadoPorImpersonacion(...)) return;`.
bool bloqueadoPorImpersonacion(BuildContext context, WidgetRef ref) {
  if (!ref.read(estaImpersonandoProvider)) return false;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
          'Acción no disponible mientras gestionás un tenant como super_admin. '
          'Hacelo desde la cuenta del admin del tenant.'),
      duration: Duration(seconds: 4),
    ),
  );
  return true;
}
