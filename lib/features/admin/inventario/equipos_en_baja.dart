// ignore_for_file: use_build_context_synchronously
//
// Los avisos de este archivo son FALSA ALARMA, verificados uno por uno: el
// `context` se pasa a `_snack`, que chequea `context.mounted` ADENTRO antes
// de tocarlo. El analizador no puede ver a través de la función, así que
// flaggea el call-site igual.
//
// REGLA PARA ESTE ARCHIVO: si agregás un uso DIRECTO del context después de un
// await (sin pasar por `_snack`), sacá este ignore y poné el guard donde va —
// si no, el aviso que sí importa queda tapado.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite_async/sqlite_async.dart' show SqliteWriteContext;
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../../data/utils/errores.dart';

/// Cuando se CANCELA un contrato o se DESACTIVA un cliente que tiene equipos de
/// inventario INSTALADOS, ofrece (no bloqueante) devolverlos a stock o
/// retirarlos, para que no queden "fantasma" instalados en una entidad inactiva
/// (hallazgo ALTA del audit de lifecycle cross-módulo).
///
/// Filtra por `contratoId` (los de ese contrato + los del cliente sin contrato,
/// p.ej. instalados vía ticket en 3C) o por `clienteId` (todos los del cliente).
/// No hace nada si el módulo inventario está off o si no hay equipos instalados.
Future<void> ofrecerGestionEquiposEnBaja(
  BuildContext context,
  WidgetRef ref, {
  String? clienteId,
  String? contratoId,
  required String entidad, // 'contrato' | 'cliente' (para el texto)
}) async {
  // Estas funciones se invocan desde varias pantallas: el guard va en la
  // ENTRADA para cubrir a todos los llamadores de una vez (0198).
  if (ref.read(soloLecturaProvider)) return;
  final modulos = ref.read(modulosHabilitadosProvider).valueOrNull ?? {};
  if (!modulos.contains('inventario')) return;
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final me = ref.read(cobradorActualProvider).valueOrNull;
  final hechoPor = me?.id;
  // op_log: actor de la intención (System Admin si super_admin / impersonando).
  final actor = me != null
      ? await OpLog.actorDeUsuario(ps.db, me.id)
      : const OpLogActor.systemAdmin();

  // Filtro de los equipos instalados a gestionar:
  //  · Cancelar CONTRATO → los de ese contrato MÁS los del mismo cliente SIN
  //    contrato (instalados vía ticket: el consumo de 3C setea cliente_id pero
  //    NO contrato_id, así que de otro modo quedarían fantasma al cancelar).
  //  · Desactivar CLIENTE → todos los del cliente (ya incluye los sin contrato).
  // Es un OFRECIMIENTO no bloqueante (el admin confirma), así que sumar los
  // sin-contrato es seguro; en un cliente multi-contrato el admin decide.
  final String where;
  final List<Object?> params;
  if (contratoId != null) {
    final cli = await ps.db.getOptional(
        'SELECT cliente_id FROM contratos WHERE id = ?', [contratoId]);
    final clienteDelContrato = cli?['cliente_id'] as String?;
    where = '(s.contrato_id = ? OR (s.cliente_id = ? AND s.contrato_id IS NULL))';
    params = [contratoId, clienteDelContrato];
  } else if (clienteId != null) {
    where = 's.cliente_id = ?';
    params = [clienteId];
  } else {
    return;
  }

  final equipos = await ps.db.getAll(
    '''
    SELECT s.id, s.serial, s.producto_id, p.nombre AS producto
      FROM inv_seriales s
      JOIN inv_productos p ON p.id = s.producto_id
     WHERE $where AND s.estado = 'instalado'
     ORDER BY p.nombre, s.serial
    ''',
    params,
  );
  if (equipos.isEmpty || !context.mounted) return;

  final accion = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _GestionEquiposSheet(entidad: entidad, equipos: equipos),
  );
  if (accion == null || !context.mounted) return;

  if (accion == 'devolver') {
    final destino = await _pickUbicacionSimple(context);
    if (destino == null || !context.mounted) return;
    try {
      await _aplicarATodos(equipos, tenantId, hechoPor, actor,
          tipo: 'devolucion', nuevoEstado: 'en_stock', ubicacion: destino.id);
      _snack(context, 'Equipos devueltos a ${destino.nombre}');
    } catch (e) {
      _snack(context, mensajeErrorHumano(e));
    }
  } else if (accion == 'retirar') {
    try {
      await _aplicarATodos(equipos, tenantId, hechoPor, actor,
          tipo: 'baja', nuevoEstado: 'retirado', ubicacion: null);
      _snack(context, 'Equipos retirados');
    } catch (e) {
      _snack(context, mensajeErrorHumano(e));
    }
  }
}

/// Aplica la transición a TODOS los equipos en una sola transacción atómica.
/// Re-valida que cada uno siga 'instalado' (idempotente si algo cambió).
///
/// op_log: 1 intención (un `opId` para todo el lote) → por cada equipo, un
/// renglón de cambio del serial (instalado→en_stock/retirado) + un renglón de
/// alta del movimiento. inv_movimientos tiene `ocurrido_en` (ya se escribe).
Future<void> _aplicarATodos(
  List<Map<String, dynamic>> equipos,
  String tenantId,
  String? hechoPor,
  OpLogActor actor, {
  required String tipo,
  required String nuevoEstado,
  String? ubicacion,
}) async {
  final now = DateTime.now().toIso8601String();
  // ocurrido_en en UTC (convención B10; antes iba local-naive y el
  // historial del serial se desordenaba ±6h).
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  final ocurridoEnDt = DateTime.parse(ocurridoEn);
  final opId = OpLog.nuevoOpId();
  await ps.dbW.writeTransaction((tx) async {
    for (final e in equipos) {
      final serialId = e['id'] as String;
      final cur = await tx.getOptional(
          'SELECT estado, cliente_id, producto_id FROM inv_seriales WHERE id = ?',
          [serialId]);
      if (cur == null || cur['estado'] != 'instalado') continue;
      final antesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      String movId;
      if (tipo == 'devolucion') {
        await tx.execute(
          "UPDATE inv_seriales SET estado = 'en_stock', cliente_id = NULL, "
          'contrato_id = NULL, ubicacion_id = ? WHERE id = ?',
          [ubicacion, serialId],
        );
        movId = const Uuid().v4();
        await tx.execute(
          '''INSERT INTO inv_movimientos
             (id, tenant_id, tipo, producto_id, serial_id, cantidad,
              ubicacion_destino_id, cliente_id, hecho_por, ocurrido_en, created_at)
             VALUES (?, ?, 'devolucion', ?, ?, 1, ?, ?, ?, ?, ?)''',
          [
            movId, tenantId, cur['producto_id'], serialId,
            ubicacion, cur['cliente_id'], hechoPor, ocurridoEn, now,
          ],
        );
      } else {
        await tx.execute(
          'UPDATE inv_seriales SET estado = ?, cliente_id = NULL, ubicacion_id = NULL WHERE id = ?',
          [nuevoEstado, serialId],
        );
        movId = const Uuid().v4();
        await tx.execute(
          '''INSERT INTO inv_movimientos
             (id, tenant_id, tipo, producto_id, serial_id, cantidad,
              cliente_id, motivo, hecho_por, ocurrido_en, created_at)
             VALUES (?, ?, 'baja', ?, ?, 1, ?, ?, ?, ?, ?)''',
          [
            movId, tenantId, cur['producto_id'], serialId,
            cur['cliente_id'], 'Retirado al dar de baja el servicio',
            hechoPor, ocurridoEn, now,
          ],
        );
      }
      final despuesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'inv_seriales',
          entidadId: serialId, antes: antesSerial, despues: despuesSerial,
          actor: actor, ocurridoEn: ocurridoEnDt);
      await _opLogMovimiento(tx, movId,
          tenantId: tenantId, opId: opId, actor: actor,
          ocurridoEn: ocurridoEnDt);
    }
  });
}

/// Emite el op_log de un movimiento recién insertado (ledger append-only),
/// como ALTA de `inv_movimientos`. Espeja el helper del inventario_screen.
Future<void> _opLogMovimiento(
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

class _GestionEquiposSheet extends StatelessWidget {
  const _GestionEquiposSheet({required this.entidad, required this.equipos});
  final String entidad;
  final List<Map<String, dynamic>> equipos;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Este $entidad tiene ${equipos.length} equipo'
                '${equipos.length != 1 ? 's' : ''} instalado'
                '${equipos.length != 1 ? 's' : ''}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...equipos.take(6).map((e) => ListTile(
                  dense: true,
                  leading: Icon(Icons.qr_code_2, color: scheme.outline, size: 20),
                  title: Text(e['serial'] as String),
                  subtitle: Text(e['producto'] as String? ?? ''),
                )),
            if (equipos.length > 6)
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: Text('y ${equipos.length - 6} más…',
                    style: TextStyle(color: scheme.outline)),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.inventory),
              label: const Text('Devolver a stock'),
              onPressed: () => Navigator.pop(context, 'devolver'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('Retirar (dar de baja)'),
              onPressed: () => Navigator.pop(context, 'retirar'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Dejar como están'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Selector simple de ubicación activa (para la devolución masiva).
Future<({String id, String nombre})?> _pickUbicacionSimple(
    BuildContext context) async {
  final ubis = await ps.db.getAll(
      'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
  if (!context.mounted) return null;
  if (ubis.isEmpty) {
    _snack(context, 'No hay ubicaciones. Creá una en Inventario primero.');
    return null;
  }
  return showDialog<({String id, String nombre})>(
    context: context,
    builder: (_) => SimpleDialog(
      title: const Text('Devolver a qué ubicación'),
      children: [
        for (final u in ubis)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(
                context, (id: u['id'] as String, nombre: u['nombre'] as String)),
            child: Text(u['nombre'] as String),
          ),
      ],
    ),
  );
}

void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
