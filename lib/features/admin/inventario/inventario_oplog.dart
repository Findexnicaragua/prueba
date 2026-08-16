import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite_async/sqlite_async.dart' show SqliteWriteContext;

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;

/// Error de negocio del inventario con mensaje apto para mostrar al usuario
/// (ej. guard de estado roto dentro de un writeTransaction).
class InvError implements Exception {
  const InvError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Resuelve el actor del op_log a partir del usuario de sesión (System Admin si
/// es super_admin / impersonando). Centraliza el patrón actor+opId+ocurridoEn que
/// usan los CRUD del inventario al loguear su intención.
Future<OpLogActor> actorOpLog(WidgetRef ref) async {
  final me = ref.read(cobradorActualProvider).valueOrNull;
  return me != null
      ? await OpLog.actorDeUsuario(ps.db, me.id)
      : const OpLogActor.systemAdmin();
}

/// Emite el op_log de un movimiento de inventario recién insertado (ledger
/// append-only). Lee la fila por id y la loguea como ALTA de `inv_movimientos`
/// (diff = campos visibles del movimiento: tipo/cantidad/motivo/factura). El
/// movimiento es su propia entidad: el cambio del serial (cuando aplica) ya se
/// loguea aparte con su propio renglón bajo el mismo `opId`.
Future<void> opLogMovimiento(
  SqliteWriteContext tx,
  String movId, {
  required String tenantId,
  required String opId,
  required OpLogActor actor,
  required DateTime ocurridoEn,
}) async {
  final rows =
      await tx.getAll('SELECT * FROM inv_movimientos WHERE id = ?', [movId]);
  if (rows.isEmpty) return;
  await OpLog.escribirCambioEntidad(tx,
      tenantId: tenantId, opId: opId, entidad: 'inv_movimientos',
      entidadId: movId, antes: const {}, despues: rows.first, actor: actor,
      ocurridoEn: ocurridoEn);
}
