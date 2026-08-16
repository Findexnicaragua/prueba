import 'dart:convert';

import 'package:sqlite_async/sqlite_async.dart' show SqliteWriteContext;
import 'package:uuid/uuid.dart';

import 'audit_changelog.dart' show kAuditCamposVisiblesDefault, kAuditSkipKeys;

/// Helper del **log de INTENCIÓN** del usuario (rework de change log —
/// CHANGELOG-REWORK.md). El cliente lo llama DENTRO de su `writeTransaction`:
/// emite UNA fila `op_log` por cada OBJETO afectado por la intención, scoped a
/// los atributos de ESE objeto (la cuota no hereda del contrato). Todas las
/// filas de una misma intención comparten `op_id`, `actor` y `ocurrido_en`.
///
/// A diferencia del `audit_changelog_trg` server (que fan-outea una fila por
/// fila física), `op_log` es 1 entrada por objeto por intención. Offline-first:
/// se escribe en el SQLite local junto a los datos; el cobrador la escribe sin
/// descargarla (verificado en test/powersync/oplog_offline_test.dart).
class OpLog {
  const OpLog._();

  static const _uuid = Uuid();

  /// Genera el id de operación al ENTRAR a una writeTransaction (generaliza el
  /// `grupo_cobro` existente). Todas las filas op_log de esa intención lo comparten.
  static String nuevoOpId() => _uuid.v4();

  /// Construye el actor a partir del usuario de sesión (lee su nombre del SQLite
  /// local). El super_admin —impersonando o no— se registra como **"System
  /// Admin"** (actor_id NULL), nunca con su nombre real, para no filtrar su
  /// identidad en el change log del tenant (diseño 0128). [db] puede ser la
  /// PowerSyncDatabase global o un tx; solo hace un SELECT de lectura.
  static Future<OpLogActor> actorDeUsuario(dynamic db, String usuarioId) async {
    final rows = await db.getAll(
        'SELECT nombre, rol FROM cobradores WHERE id = ?', [usuarioId]);
    final nombre = rows.isNotEmpty ? rows.first['nombre'] as String? : null;
    final rol = rows.isNotEmpty ? rows.first['rol'] as String? : null;
    if (rol == 'super_admin') return const OpLogActor.systemAdmin();
    return OpLogActor.usuario(usuarioId, nombre ?? 'Usuario');
  }

  /// Escribe una fila `op_log` para UN objeto afectado. `diff` ya curado:
  /// `{campos:[{campo,antes,despues}], resumen:{...}}`.
  static Future<void> escribir(
    SqliteWriteContext tx, {
    required String tenantId,
    required String opId,
    required String tipoOp,
    required String entidad,
    required String entidadId,
    required String accion, // 'create' | 'update' | 'delete'
    required Map<String, dynamic> diff,
    required OpLogActor actor,
    DateTime? ocurridoEn,
  }) async {
    final cuando = (ocurridoEn ?? DateTime.now()).toUtc().toIso8601String();
    await tx.execute(
      'INSERT INTO op_log (id, tenant_id, op_id, tipo_op, entidad, entidad_id, '
      'actor_id, actor_label, accion, diff, ocurrido_en) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        _uuid.v4(), tenantId, opId, tipoOp, entidad, entidadId,
        actor.id, actor.label, accion, jsonEncode(diff), cuando,
      ],
    );
  }

  /// Conveniencia para un ALTA o EDICIÓN simple: computa el diff visible (solo
  /// lo cambiado, solo campos del formulario) entre `antes` y `despues` y
  /// escribe. Si nada visible cambió, NO loguea (no ensucia el historial).
  /// `antes` vacío = creación.
  static Future<void> escribirCambioEntidad(
    SqliteWriteContext tx, {
    required String tenantId,
    required String opId,
    required String entidad,
    required String entidadId,
    required Map<String, dynamic> antes,
    required Map<String, dynamic> despues,
    required OpLogActor actor,
    DateTime? ocurridoEn,
  }) async {
    final esAlta = antes.isEmpty;
    final campos = diffVisible(entidad, antes, despues);
    if (campos.isEmpty) return;
    await escribir(
      tx,
      tenantId: tenantId,
      opId: opId,
      tipoOp: esAlta ? 'alta_entidad' : 'edicion_entidad',
      entidad: entidad,
      entidadId: entidadId,
      accion: esAlta ? 'create' : 'update',
      diff: {'campos': campos},
      actor: actor,
      ocurridoEn: ocurridoEn,
    );
  }

  /// Conveniencia para una BAJA (borrado físico): registra la eliminación con
  /// los campos visibles del objeto en el diff (antes → —), para que su
  /// historial siga apareciendo filtrando por `entidad_id` (no `IN (SELECT)`).
  /// `snapshot` = la fila ANTES de borrar (SELECT *). Siempre escribe (aunque
  /// el diff quede vacío) — una baja es un evento que debe constar.
  static Future<void> escribirBaja(
    SqliteWriteContext tx, {
    required String tenantId,
    required String opId,
    required String entidad,
    required String entidadId,
    required Map<String, dynamic> snapshot,
    required OpLogActor actor,
    DateTime? ocurridoEn,
  }) async {
    final campos = diffVisible(entidad, snapshot, const {});
    await escribir(
      tx,
      tenantId: tenantId,
      opId: opId,
      tipoOp: 'baja_entidad',
      entidad: entidad,
      entidadId: entidadId,
      accion: 'delete',
      diff: {'campos': campos},
      actor: actor,
      ocurridoEn: ocurridoEn,
    );
  }
}

/// Actor de un `op_log`: el usuario REAL de la sesión, o **"System Admin"** para
/// el super_admin (impersonando o no — decisión de Rubén 2026-06-19). Se setea
/// en el cliente (no `auth.uid()`), porque offline ya se conoce el usuario.
class OpLogActor {
  const OpLogActor.usuario(String this.id, this.label) : esSystem = false;
  const OpLogActor.systemAdmin()
      : id = null,
        label = 'System Admin',
        esSystem = true;

  /// uid del usuario; NULL para System Admin (la RLS exige `actor_id = auth.uid()
  /// OR actor_id IS NULL`).
  final String? id;
  final String label;
  final bool esSystem;
}

/// Computa el diff VISIBLE entre dos estados de una entidad: SOLO los campos del
/// formulario (allowlist `kAuditCamposVisiblesDefault` de audit_changelog.dart),
/// SOLO los que cambiaron, con valores CRUDOS (el render aplica labels/formato
/// con `auditFieldLabel`/`_fmtField`). Cierra el "fallback permisivo": si la
/// entidad NO está registrada en la allowlist, NO loguea columnas crudas
/// (`assert` en debug para forzar el registro).
List<Map<String, dynamic>> diffVisible(
  String entidad,
  Map<String, dynamic> antes,
  Map<String, dynamic> despues,
) {
  final allow = kAuditCamposVisiblesDefault[entidad];
  assert(
    allow != null,
    'op_log: la entidad "$entidad" no está registrada en '
    'kAuditCamposVisiblesDefault (audit_changelog.dart). Registrala antes de '
    'loguear para no volcar columnas crudas.',
  );
  if (allow == null) return const [];

  final esAlta = antes.isEmpty;
  final campos = <Map<String, dynamic>>[];
  for (final k in allow) {
    if (kAuditSkipKeys.contains(k)) continue;
    final a = antes[k];
    final d = despues[k];
    if (a == d) continue; // solo lo que cambió
    // En un alta, omitir vacíos/ceros (no listar campos que el form dejó en blanco).
    if (esAlta && (d == null || d == '' || d == 0)) continue;
    campos.add({'campo': k, 'antes': a, 'despues': d});
  }
  return campos;
}
