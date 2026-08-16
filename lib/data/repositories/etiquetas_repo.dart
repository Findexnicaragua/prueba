import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../utils/busqueda_cliente.dart';
import '../utils/op_log.dart';

/// Operaciones de escritura del módulo de Etiquetas (P5).
///
/// - Catálogo (`etiquetas`): crear / editar / activar-desactivar / eliminar.
/// - Asignación (`cliente_etiquetas`): asignar / quitar a un cliente.
///
/// La RLS limita las writes a admin/admin_cobranza. `cobrador_id` en
/// `cliente_etiquetas` se denormaliza EN EL INSERT (copiado del cliente) porque
/// el trigger server NO corre en el SQLite local offline (audit checklist #6);
/// el server lo re-confirma y la cascada de reasignación lo mantiene.
///
/// Cada operación emite `op_log` (rework change log) dentro de su
/// `writeTransaction`. El catálogo se loguea scoped a `etiquetas`; la asignación/
/// quita se loguea scoped al CLIENTE (su historial muestra la etiqueta puesta o
/// sacada). [usuarioId] = el admin que ejecuta (actor del log).
class EtiquetasRepo {
  const EtiquetasRepo();

  // ── Catálogo ──────────────────────────────────────────────────────────
  Future<void> crear({
    required String tenantId,
    required String nombre,
    required String colorHex,
    required String iconoKey,
    required String usuarioId,
    int orden = 0,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now();
    final ocurridoEn = now.toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, usuarioId);
    await ps.dbW.writeTransaction((tx) async {
      // Pre-check de duplicado: el UNIQUE(tenant, nombre) vive en Postgres, no
      // en el SQLite local → sin esto un nombre repetido pasa local, cierra OK
      // y al sincronizar el server lo rechaza (23505) y desaparece silencioso
      // + atasca la cola de upload. Fold-aware (patrón inv_categorias/geo_picker,
      // audit Fase 3). Dentro de la tx → atómico con el INSERT.
      final dup = await tx.getAll(
        "SELECT id FROM etiquetas WHERE tenant_id = ? AND ${foldSqlExpr('nombre')} = ? LIMIT 1",
        [tenantId, foldBusqueda(nombre)],
      );
      if (dup.isNotEmpty) {
        throw StateError('Ya existe una etiqueta "$nombre".');
      }
      await tx.execute(
        'INSERT INTO etiquetas (id, tenant_id, nombre, color, icono, orden, activo, created_at, ocurrido_en) '
        'VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)',
        [
          id, tenantId, nombre, colorHex, iconoKey, orden,
          now.toIso8601String(), ocurridoEn.toIso8601String(),
        ],
      );
      final despues =
          (await tx.getAll('SELECT * FROM etiquetas WHERE id = ?', [id])).first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'etiquetas', entidadId: id,
          antes: const {}, despues: despues, actor: actor, ocurridoEn: ocurridoEn);
    });
  }

  Future<void> actualizar({
    required String id,
    required String nombre,
    required String colorHex,
    required String iconoKey,
    required String usuarioId,
  }) async {
    final ocurridoEn = DateTime.now().toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, usuarioId);
    await ps.dbW.writeTransaction((tx) async {
      final antesRows =
          await tx.getAll('SELECT * FROM etiquetas WHERE id = ?', [id]);
      final antes =
          antesRows.isNotEmpty ? antesRows.first : const <String, dynamic>{};
      final tenantId = (antes['tenant_id'] as String?) ?? '';
      // Rename: mismo pre-check que crear(), excluyendo la propia fila.
      final dup = await tx.getAll(
        "SELECT id FROM etiquetas WHERE tenant_id = ? AND ${foldSqlExpr('nombre')} = ? AND id != ? LIMIT 1",
        [tenantId, foldBusqueda(nombre), id],
      );
      if (dup.isNotEmpty) {
        throw StateError('Ya existe una etiqueta "$nombre".');
      }
      await tx.execute(
        'UPDATE etiquetas SET nombre = ?, color = ?, icono = ?, ocurrido_en = ? WHERE id = ?',
        [nombre, colorHex, iconoKey, ocurridoEn.toIso8601String(), id],
      );
      final despues =
          (await tx.getAll('SELECT * FROM etiquetas WHERE id = ?', [id])).first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'etiquetas', entidadId: id,
          antes: antes, despues: despues, actor: actor, ocurridoEn: ocurridoEn);
    });
  }

  Future<void> setActivo(String id, bool activo,
      {required String usuarioId}) async {
    final ocurridoEn = DateTime.now().toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, usuarioId);
    await ps.dbW.writeTransaction((tx) async {
      final antesRows =
          await tx.getAll('SELECT * FROM etiquetas WHERE id = ?', [id]);
      final antes =
          antesRows.isNotEmpty ? antesRows.first : const <String, dynamic>{};
      final tenantId = (antes['tenant_id'] as String?) ?? '';
      await tx.execute(
        'UPDATE etiquetas SET activo = ?, ocurrido_en = ? WHERE id = ?',
        [activo ? 1 : 0, ocurridoEn.toIso8601String(), id],
      );
      final despues =
          (await tx.getAll('SELECT * FROM etiquetas WHERE id = ?', [id])).first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'etiquetas', entidadId: id,
          antes: antes, despues: despues, actor: actor, ocurridoEn: ocurridoEn);
    });
  }

  /// Elimina la etiqueta del catálogo. El FK `cliente_etiquetas.etiqueta_id` es
  /// ON DELETE CASCADE → se desasigna de todos los clientes (server).
  Future<void> eliminar(String id, {required String usuarioId}) async {
    final ocurridoEn = DateTime.now().toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, usuarioId);
    await ps.dbW.writeTransaction((tx) async {
      final antesRows =
          await tx.getAll('SELECT * FROM etiquetas WHERE id = ?', [id]);
      if (antesRows.isNotEmpty) {
        final antes = antesRows.first;
        await OpLog.escribirBaja(tx,
            tenantId: (antes['tenant_id'] as String?) ?? '', opId: opId,
            entidad: 'etiquetas', entidadId: id, snapshot: antes, actor: actor,
            ocurridoEn: ocurridoEn);
        // op_log (fix F1): el CASCADE server desasigna la etiqueta de N clientes
        // SIN dejar rastro. Emitir "Etiqueta quitada" por cada cliente afectado
        // (igual que quitar()), ANTES del DELETE — así su historial queda completo.
        final nombreEtq = antes['nombre'] as String?;
        final tId = (antes['tenant_id'] as String?) ?? '';
        final asignados = await tx.getAll(
          'SELECT cliente_id FROM cliente_etiquetas WHERE etiqueta_id = ?', [id]);
        for (final row in asignados) {
          await OpLog.escribir(tx,
              tenantId: tId, opId: opId, tipoOp: 'edicion_entidad',
              entidad: 'clientes', entidadId: row['cliente_id'] as String,
              accion: 'update',
              diff: {
                'campos': const [],
                'resumen': {'motivo': 'Etiqueta quitada: ${nombreEtq ?? id}'},
              },
              actor: actor, ocurridoEn: ocurridoEn);
        }
      }
      await tx.execute('DELETE FROM etiquetas WHERE id = ?', [id]);
    });
  }

  // ── Asignación a cliente ──────────────────────────────────────────────
  /// Asigna `etiquetaId` a `clienteId`. Denormaliza `cobrador_id` leyendo el
  /// del cliente (NULL = admin-managed → no baja a ningún cobrador).
  Future<void> asignar({
    required String tenantId,
    required String clienteId,
    required String etiquetaId,
    required String usuarioId,
  }) async {
    // Idempotencia: el toggle es idempotente por diseño y las tablas locales de
    // PowerSync NO enforced UNIQUE (el constraint vive en el server). Un
    // doble-tap rápido podría duplicar la fila local (la 2da la rechaza el
    // UNIQUE del server al sincronizar). Guardamos con un check previo.
    final yaAsignada = await ps.db.getAll(
      'SELECT 1 FROM cliente_etiquetas WHERE cliente_id = ? AND etiqueta_id = ? LIMIT 1',
      [clienteId, etiquetaId],
    );
    if (yaAsignada.isNotEmpty) return;
    final rows = await ps.db.getAll(
        'SELECT cobrador_id FROM clientes WHERE id = ?', [clienteId]);
    final cobradorId =
        rows.isEmpty ? null : rows.first['cobrador_id'] as String?;
    final etRows = await ps.db
        .getAll('SELECT nombre FROM etiquetas WHERE id = ?', [etiquetaId]);
    final etqNombre =
        etRows.isNotEmpty ? etRows.first['nombre'] as String? : null;
    final now = DateTime.now();
    final ocurridoEn = now.toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, usuarioId);
    await ps.dbW.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO cliente_etiquetas (id, tenant_id, cliente_id, etiqueta_id, cobrador_id, created_at, ocurrido_en) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          const Uuid().v4(), tenantId, clienteId, etiquetaId, cobradorId,
          now.toIso8601String(), ocurridoEn.toIso8601String(),
        ],
      );
      // Scoped al CLIENTE: su historial muestra la etiqueta asignada (el nombre
      // va en el resumen → no es un campo del cliente).
      await OpLog.escribir(tx,
          tenantId: tenantId, opId: opId, tipoOp: 'edicion_entidad',
          entidad: 'clientes', entidadId: clienteId, accion: 'update',
          diff: {
            'campos': const [],
            'resumen': {'motivo': 'Etiqueta asignada: ${etqNombre ?? etiquetaId}'},
          },
          actor: actor, ocurridoEn: ocurridoEn);
    });
  }

  Future<void> quitar({
    required String clienteId,
    required String etiquetaId,
    required String usuarioId,
  }) async {
    final etRows = await ps.db
        .getAll('SELECT nombre FROM etiquetas WHERE id = ?', [etiquetaId]);
    final etqNombre =
        etRows.isNotEmpty ? etRows.first['nombre'] as String? : null;
    final cRows = await ps.db
        .getAll('SELECT tenant_id FROM clientes WHERE id = ?', [clienteId]);
    final tenantId =
        cRows.isNotEmpty ? (cRows.first['tenant_id'] as String? ?? '') : '';
    final ocurridoEn = DateTime.now().toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, usuarioId);
    await ps.dbW.writeTransaction((tx) async {
      await tx.execute(
        'DELETE FROM cliente_etiquetas WHERE cliente_id = ? AND etiqueta_id = ?',
        [clienteId, etiquetaId],
      );
      await OpLog.escribir(tx,
          tenantId: tenantId, opId: opId, tipoOp: 'edicion_entidad',
          entidad: 'clientes', entidadId: clienteId, accion: 'update',
          diff: {
            'campos': const [],
            'resumen': {'motivo': 'Etiqueta quitada: ${etqNombre ?? etiquetaId}'},
          },
          actor: actor, ocurridoEn: ocurridoEn);
    });
  }
}

final etiquetasRepoProvider =
    Provider<EtiquetasRepo>((ref) => const EtiquetasRepo());
