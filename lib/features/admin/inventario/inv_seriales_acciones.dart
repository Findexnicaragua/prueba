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
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/selector_buscable.dart';
import 'inventario_comun.dart';
import 'inventario_oplog.dart';

// ===========================================================================
// Acciones de un equipo serializado (asignar / devolver / transferir / baja).
// Funciones públicas top-level reusables por la pantalla vieja y la ficha nueva.
// ===========================================================================

Future<void> asignarEquipo(
    BuildContext context, WidgetRef ref, Map<String, dynamic> s) async {
  // Estas funciones se invocan desde varias pantallas: el guard va en la
  // ENTRADA para cubrir a todos los llamadores de una vez (0198).
  if (ref.read(soloLecturaProvider)) return;
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;

  // 1. Elegir cliente (carga en memoria + buscador por tokens; sin re-suscribir
  // un stream de PowerSync por cada tecla — patrón canónico, AGENTS #9/#10).
  final cliente = await _elegirClienteParaEquipo(context);
  if (cliente == null || !context.mounted) return;

  // 2. Aviso suave de red: el plan pide puerto_id para asignar equipos. Hasta
  // que la topología de red esté en producción, advertimos pero dejamos
  // seguir (se endurece a bloqueo cuando la red esté viva).
  final cli = await ps.db.getOptional(
      'SELECT puerto_id FROM clientes WHERE id = ?', [cliente.id]);
  if ((cli?['puerto_id'] as String?) == null) {
    if (!context.mounted) return;
    final seguir = await _confirmarAccion(
      context,
      titulo: 'Cliente sin red',
      mensaje: '${cliente.nombre} no tiene un puerto de red asignado. '
          'Conviene asignarle red antes del equipo. ¿Asignar igual?',
      confirmar: 'Asignar igual',
    );
    if (!seguir || !context.mounted) return;
  }

  // 3. Elegir contrato del cliente (auto si tiene uno; opcional si no tiene).
  final contratos = await ps.db.getAll('''
    SELECT ct.id, ct.codigo, ct.estado, pl.nombre AS plan
      FROM contratos ct
 LEFT JOIN planes pl ON pl.id = ct.plan_id
     WHERE ct.cliente_id = ?
     ORDER BY (ct.estado = 'activo') DESC, ct.created_at DESC
  ''', [cliente.id]);
  String? contratoId;
  if (contratos.length == 1) {
    contratoId = contratos.first['id'] as String;
  } else if (contratos.length > 1) {
    if (!context.mounted) return;
    final elegido = await showDialog<String>(
      context: context,
      builder: (_) => _ContratoPicker(contratos: contratos),
    );
    if (elegido == null || !context.mounted) return; // canceló
    contratoId = elegido;
  }

  // 4. Persistir atómico. Re-valida el estado DENTRO de la transacción para
  // evitar doble-asignación sobre data stale (otro tap / otra pestaña).
  final now = DateTime.now().toIso8601String();
  // ocurrido_en en UTC (convención B10; antes iba local-naive y el
  // historial del serial se desordenaba ±6h).
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  // op_log: 1 intención (opId) → cambio del serial + alta del movimiento.
  final opId = OpLog.nuevoOpId();
  final actor = await actorOpLog(ref);
  final ocurridoEnDt = DateTime.parse(ocurridoEn);
  final serialId = s['id'] as String;
  try {
    await ps.dbW.writeTransaction((tx) async {
      final cur = await tx.getOptional(
          'SELECT estado, ubicacion_id, producto_id FROM inv_seriales WHERE id = ?',
          [serialId]);
      if (cur == null || cur['estado'] != 'en_stock') {
        throw const InvError('El equipo ya no está disponible en stock.');
      }
      final antesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await tx.execute(
        "UPDATE inv_seriales SET estado = 'instalado', cliente_id = ?, "
        'contrato_id = ?, ubicacion_id = NULL WHERE id = ?',
        [cliente.id, contratoId, serialId],
      );
      final despuesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'inv_seriales',
          entidadId: serialId, antes: antesSerial, despues: despuesSerial,
          actor: actor, ocurridoEn: ocurridoEnDt);
      final movId = const Uuid().v4();
      await tx.execute(
        '''INSERT INTO inv_movimientos
           (id, tenant_id, tipo, producto_id, serial_id, cantidad,
            ubicacion_origen_id, cliente_id, contrato_id, hecho_por,
            ocurrido_en, created_at)
           VALUES (?, ?, 'asignacion', ?, ?, 1, ?, ?, ?, ?, ?, ?)''',
        [
          movId, tenantId, cur['producto_id'], serialId,
          cur['ubicacion_id'], cliente.id, contratoId, hechoPor, ocurridoEn,
          now,
        ],
      );
      await opLogMovimiento(tx, movId,
          tenantId: tenantId, opId: opId, actor: actor,
          ocurridoEn: ocurridoEnDt);
    });
    _snack(context, 'Equipo asignado a ${cliente.nombre}');
  } on InvError catch (e) {
    _snack(context, e.message);
  } catch (e) {
    _snack(context, mensajeErrorHumano(e));
  }
}

// Mandar a revisión un equipo que volvió del campo (instalado/dañado/retirado).
//
// Ciclo pedido por el nuevo dueño (0204): cliente/red → técnico → REVISIÓN →
// bodega si sirve, descarte si no. Revisión es un LIMBO: el equipo ya no está
// con el cliente pero todavía no entró a stock.
//
// DECISIÓN CLAVE — revisión NO toca el ledger de ubicación. El stock por
// ubicación es un neto `SUM(destino) − SUM(origen)` sobre `inv_movimientos`
// (ver `_reloadStock` en inv_stock_flows.dart), y `darDeBajaEquipo` solo
// descuenta del origen si el equipo estaba `en_stock` (línea `estabaEnStock`).
// Si al entrar a revisión lo depositáramos en una ubicación (+1 al ledger), un
// descarte posterior NO restaría —porque su estado ya no sería 'en_stock'— y
// esa ubicación quedaría inflada para siempre. Por eso acá `ubicacion_id` queda
// NULL y el movimiento se registra SIN destino: deja rastro de que volvió del
// cliente sin alterar ninguna cuenta. El +1 lo hace recién `devolverEquipo`
// cuando el equipo aprueba la revisión y aterriza en una bodega concreta.
Future<void> mandarARevisionEquipo(
    BuildContext context, WidgetRef ref, Map<String, dynamic> s) async {
  if (ref.read(soloLecturaProvider)) return;
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('¿Mandar a revisión?'),
      content: const Text(
          'El equipo sale del cliente y queda en revisión, sin entrar a stock. '
          'Desde ahí lo devolvés a una bodega si sirve, o lo mandás a descarte.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Mandar a revisión')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final now = DateTime.now().toIso8601String();
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  final opId = OpLog.nuevoOpId();
  final actor = await actorOpLog(ref);
  final ocurridoEnDt = DateTime.parse(ocurridoEn);
  final serialId = s['id'] as String;
  try {
    await ps.dbW.writeTransaction((tx) async {
      final cur = await tx.getOptional(
          'SELECT estado, cliente_id, ubicacion_id, producto_id '
          'FROM inv_seriales WHERE id = ?',
          [serialId]);
      if (cur == null) throw const InvError('Equipo no encontrado.');
      if (cur['estado'] == 'en_revision') {
        throw const InvError('El equipo ya está en revisión.');
      }
      if (cur['estado'] == 'en_stock') {
        throw const InvError(
            'El equipo está en stock: no volvió del campo, no hay qué revisar.');
      }
      if (cur['estado'] == 'baja') {
        throw const InvError('El equipo está descartado.');
      }
      // A1: mismo guard de concurrencia que el resto de las acciones — el menú
      // pudo haberse dibujado con un estado que otro device ya cambió.
      if (cur['estado'] != s['estado']) {
        throw const InvError('El equipo cambió de estado; recargá la lista.');
      }
      final antesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await tx.execute(
        "UPDATE inv_seriales SET estado = 'en_revision', cliente_id = NULL, "
        'contrato_id = NULL, ubicacion_id = NULL WHERE id = ?',
        [serialId],
      );
      final despuesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'inv_seriales',
          entidadId: serialId, antes: antesSerial, despues: despuesSerial,
          actor: actor, ocurridoEn: ocurridoEnDt);
      final movId = const Uuid().v4();
      // Movimiento NEUTRO en el ledger: sin origen y sin destino.
      //
      // El origen va en NULL A PROPÓSITO, no por olvido. Invariante del módulo:
      // TODA salida de 'en_stock' ya debitó su ubicación y dejó `ubicacion_id`
      // en NULL — `asignarEquipo` inserta 'asignacion' con
      // `ubicacion_origen_id = ubicacion_id`, y `darDeBajaEquipo` inserta
      // 'baja' con origen si `estabaEnStock`. Como a revisión solo se entra
      // desde instalado/dañado/retirado, la ubicación YA fue debitada: volver
      // a mandarla como origen la restaría dos veces y dejaría ese stock en
      // negativo. Queda solo el rastro de qué cliente lo devolvió.
      await tx.execute(
        '''INSERT INTO inv_movimientos
           (id, tenant_id, tipo, producto_id, serial_id, cantidad,
            cliente_id, motivo, hecho_por, ocurrido_en, created_at)
           VALUES (?, ?, 'devolucion', ?, ?, 1, ?, ?, ?, ?, ?)''',
        [
          movId, tenantId, cur['producto_id'], serialId,
          cur['cliente_id'], 'Enviado a revisión', hechoPor, ocurridoEn, now,
        ],
      );
      await opLogMovimiento(tx, movId,
          tenantId: tenantId, opId: opId, actor: actor,
          ocurridoEn: ocurridoEnDt);
    });
    _snack(context, 'Equipo en revisión');
  } on InvError catch (e) {
    _snack(context, e.message);
  } catch (e) {
    _snack(context, mensajeErrorHumano(e));
  }
}

// Devolver un equipo (instalado/dañado/retirado/en revisión) al stock, en una
// ubicación. Es también la salida "sirve" de la revisión.
Future<void> devolverEquipo(
    BuildContext context, WidgetRef ref, Map<String, dynamic> s) async {
  // Estas funciones se invocan desde varias pantallas: el guard va en la
  // ENTRADA para cubrir a todos los llamadores de una vez (0198).
  if (ref.read(soloLecturaProvider)) return;
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
  final destino =
      await _pickUbicacion(context, titulo: 'Devolver a qué ubicación');
  if (destino == null || !context.mounted) return;
  final now = DateTime.now().toIso8601String();
  // ocurrido_en en UTC (convención B10; antes iba local-naive y el
  // historial del serial se desordenaba ±6h).
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  // op_log: 1 intención (opId) → cambio del serial + alta del movimiento.
  final opId = OpLog.nuevoOpId();
  final actor = await actorOpLog(ref);
  final ocurridoEnDt = DateTime.parse(ocurridoEn);
  final serialId = s['id'] as String;
  try {
    await ps.dbW.writeTransaction((tx) async {
      final cur = await tx.getOptional(
          'SELECT estado, cliente_id, producto_id FROM inv_seriales WHERE id = ?',
          [serialId]);
      if (cur == null) throw const InvError('Equipo no encontrado.');
      if (cur['estado'] == 'en_stock') {
        throw const InvError('El equipo ya está en stock.');
      }
      if (cur['estado'] == 'baja') {
        throw const InvError('El equipo está descartado.');
      }
      // A1: re-validar el estado EXACTO que mostraba el menú (no solo "no
      // terminal") → evita un movimiento fantasma en el ledger si el equipo
      // cambió a otro estado intermedio en otra pestaña/device.
      if (cur['estado'] != s['estado']) {
        throw const InvError('El equipo cambió de estado; recargá la lista.');
      }
      final antesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await tx.execute(
        "UPDATE inv_seriales SET estado = 'en_stock', cliente_id = NULL, "
        'contrato_id = NULL, ubicacion_id = ? WHERE id = ?',
        [destino.id, serialId],
      );
      final despuesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'inv_seriales',
          entidadId: serialId, antes: antesSerial, despues: despuesSerial,
          actor: actor, ocurridoEn: ocurridoEnDt);
      final movId = const Uuid().v4();
      await tx.execute(
        '''INSERT INTO inv_movimientos
           (id, tenant_id, tipo, producto_id, serial_id, cantidad,
            ubicacion_destino_id, cliente_id, hecho_por, ocurrido_en, created_at)
           VALUES (?, ?, 'devolucion', ?, ?, 1, ?, ?, ?, ?, ?)''',
        [
          movId, tenantId, cur['producto_id'], serialId,
          destino.id, cur['cliente_id'], hechoPor, ocurridoEn, now,
        ],
      );
      await opLogMovimiento(tx, movId,
          tenantId: tenantId, opId: opId, actor: actor,
          ocurridoEn: ocurridoEnDt);
    });
    _snack(context, 'Equipo devuelto a ${destino.nombre}');
  } on InvError catch (e) {
    _snack(context, e.message);
  } catch (e) {
    _snack(context, mensajeErrorHumano(e));
  }
}

// Transferir un equipo en stock a otra ubicación.
Future<void> transferirEquipo(
    BuildContext context, WidgetRef ref, Map<String, dynamic> s) async {
  // Estas funciones se invocan desde varias pantallas: el guard va en la
  // ENTRADA para cubrir a todos los llamadores de una vez (0198).
  if (ref.read(soloLecturaProvider)) return;
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
  final destino = await _pickUbicacion(context,
      titulo: 'Transferir a qué ubicación',
      excluirId: s['ubicacion_id'] as String?);
  if (destino == null || !context.mounted) return;
  final now = DateTime.now().toIso8601String();
  // ocurrido_en en UTC (convención B10; antes iba local-naive y el
  // historial del serial se desordenaba ±6h).
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  // op_log: 1 intención (opId) → cambio del serial + alta del movimiento.
  final opId = OpLog.nuevoOpId();
  final actor = await actorOpLog(ref);
  final ocurridoEnDt = DateTime.parse(ocurridoEn);
  final serialId = s['id'] as String;
  try {
    await ps.dbW.writeTransaction((tx) async {
      final cur = await tx.getOptional(
          'SELECT estado, ubicacion_id, producto_id FROM inv_seriales WHERE id = ?',
          [serialId]);
      if (cur == null || cur['estado'] != 'en_stock') {
        throw const InvError('Solo se puede transferir un equipo en stock.');
      }
      final antesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await tx.execute(
        'UPDATE inv_seriales SET ubicacion_id = ? WHERE id = ?',
        [destino.id, serialId],
      );
      final despuesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'inv_seriales',
          entidadId: serialId, antes: antesSerial, despues: despuesSerial,
          actor: actor, ocurridoEn: ocurridoEnDt);
      final movId = const Uuid().v4();
      await tx.execute(
        '''INSERT INTO inv_movimientos
           (id, tenant_id, tipo, producto_id, serial_id, cantidad,
            ubicacion_origen_id, ubicacion_destino_id, hecho_por,
            ocurrido_en, created_at)
           VALUES (?, ?, 'transferencia', ?, ?, 1, ?, ?, ?, ?, ?)''',
        [
          movId, tenantId, cur['producto_id'], serialId,
          cur['ubicacion_id'], destino.id, hechoPor, ocurridoEn, now,
        ],
      );
      await opLogMovimiento(tx, movId,
          tenantId: tenantId, opId: opId, actor: actor,
          ocurridoEn: ocurridoEnDt);
    });
    _snack(context, 'Equipo transferido a ${destino.nombre}');
  } on InvError catch (e) {
    _snack(context, e.message);
  } catch (e) {
    _snack(context, mensajeErrorHumano(e));
  }
}

// Dar de baja un equipo (dañado/retirado/baja) → sale del stock activo.
Future<void> darDeBajaEquipo(
    BuildContext context, WidgetRef ref, Map<String, dynamic> s) async {
  // Estas funciones se invocan desde varias pantallas: el guard va en la
  // ENTRADA para cubrir a todos los llamadores de una vez (0198).
  if (ref.read(soloLecturaProvider)) return;
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
  // Si el equipo ya está dañado/retirado, esto es un cambio de estado, no una
  // baja (B3): adaptamos textos. La baja definitiva está bloqueada en el menú.
  final yaDeBaja = s['estado'] == 'danado' || s['estado'] == 'retirado';
  final res = await showDialog<({String estado, String? motivo})>(
    context: context,
    builder: (_) => _BajaDialog(esCambioEstado: yaDeBaja),
  );
  if (res == null || !context.mounted) return;
  final now = DateTime.now().toIso8601String();
  // ocurrido_en en UTC (convención B10; antes iba local-naive y el
  // historial del serial se desordenaba ±6h).
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  // op_log: 1 intención (opId) → cambio del serial + alta del movimiento.
  final opId = OpLog.nuevoOpId();
  final actor = await actorOpLog(ref);
  final ocurridoEnDt = DateTime.parse(ocurridoEn);
  final serialId = s['id'] as String;
  try {
    await ps.dbW.writeTransaction((tx) async {
      final cur = await tx.getOptional(
          'SELECT estado, ubicacion_id, cliente_id, producto_id FROM inv_seriales WHERE id = ?',
          [serialId]);
      if (cur == null) throw const InvError('Equipo no encontrado.');
      if (cur['estado'] == 'baja') {
        throw const InvError('El equipo ya está descartado.');
      }
      // A1: re-validar el estado EXACTO que mostraba el menú dentro de la tx.
      if (cur['estado'] != s['estado']) {
        throw const InvError('El equipo cambió de estado; recargá la lista.');
      }
      final estabaEnStock = cur['estado'] == 'en_stock';
      final antesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await tx.execute(
        'UPDATE inv_seriales SET estado = ?, cliente_id = NULL, ubicacion_id = NULL WHERE id = ?',
        [res.estado, serialId],
      );
      final despuesSerial = (await tx
              .getAll('SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
          .first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: tenantId, opId: opId, entidad: 'inv_seriales',
          entidadId: serialId, antes: antesSerial, despues: despuesSerial,
          actor: actor, ocurridoEn: ocurridoEnDt);
      final movId = const Uuid().v4();
      await tx.execute(
        '''INSERT INTO inv_movimientos
           (id, tenant_id, tipo, producto_id, serial_id, cantidad,
            ubicacion_origen_id, cliente_id, motivo, hecho_por,
            ocurrido_en, created_at)
           VALUES (?, ?, 'baja', ?, ?, 1, ?, ?, ?, ?, ?, ?)''',
        [
          movId, tenantId, cur['producto_id'], serialId,
          estabaEnStock ? cur['ubicacion_id'] : null,
          cur['cliente_id'], res.motivo, hechoPor, ocurridoEn, now,
        ],
      );
      await opLogMovimiento(tx, movId,
          tenantId: tenantId, opId: opId, actor: actor,
          ocurridoEn: ocurridoEnDt);
    });
    _snack(
        context,
        yaDeBaja
            ? 'Estado actualizado: ${kEstadoSerial[res.estado] ?? res.estado}'
            : 'Equipo enviado a descarte (${kEstadoSerial[res.estado] ?? res.estado})');
  } on InvError catch (e) {
    _snack(context, e.message);
  } catch (e) {
    _snack(context, mensajeErrorHumano(e));
  }
}

// ===========================================================================
// Pickers / diálogos exclusivos de las acciones de equipo.
// ===========================================================================

/// Elige un cliente activo para asignarle un equipo. Carga los clientes en
/// memoria UNA vez y filtra por tokens en el SelectorBuscable (nombre + código/
/// cédula/teléfono vía textoBusqueda) — sin re-suscribir un stream de PowerSync
/// por cada tecla (patrón canónico, AGENTS #9/#10). Devuelve (id, nombre) o null.
Future<({String id, String nombre})?> _elegirClienteParaEquipo(
    BuildContext context) async {
  final rows = await ps.db.getAll(
    'SELECT id, nombre, codigo, cedula, telefono FROM clientes '
    'WHERE activo = 1 ORDER BY nombre',
  );
  if (!context.mounted) return null;
  if (rows.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No hay clientes activos.')),
    );
    return null;
  }
  final elegido = await elegirConBuscador<Map<String, dynamic>>(
    context,
    titulo: 'Elegí un cliente',
    hint: 'Buscar por nombre, código, cédula o teléfono',
    opciones: rows.map((c) {
      final sub = [
        if ((c['codigo'] as String?)?.isNotEmpty ?? false) c['codigo'] as String,
        if ((c['cedula'] as String?)?.isNotEmpty ?? false) c['cedula'] as String,
      ].join(' · ');
      return OpcionSelector<Map<String, dynamic>>(
        valor: c,
        nombre: c['nombre'] as String,
        subtitulo: sub.isEmpty ? null : sub,
        textoBusqueda:
            '${c['codigo'] ?? ''} ${c['cedula'] ?? ''} ${c['telefono'] ?? ''}',
      );
    }).toList(),
  );
  if (elegido == null) return null;
  return (id: elegido['id'] as String, nombre: elegido['nombre'] as String);
}

/// Picker de contrato cuando el cliente tiene más de uno. Devuelve el id.
class _ContratoPicker extends StatelessWidget {
  const _ContratoPicker({required this.contratos});
  final List<Map<String, dynamic>> contratos;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Elegí el contrato'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: contratos.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final c = contratos[i];
            final cod = c['codigo'] as String?;
            final plan = c['plan'] as String?;
            final estado = c['estado'] as String? ?? '';
            final sub = [
              if (plan != null && plan.isNotEmpty) plan,
              if (estado.isNotEmpty) estado,
            ].join(' · ');
            return ListTile(
              title: Text(cod != null && cod.isNotEmpty
                  ? cod
                  : (plan ?? 'Contrato')),
              subtitle: sub.isEmpty ? null : Text(sub),
              onTap: () => Navigator.pop(context, c['id'] as String),
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
      ],
    );
  }
}

/// Elegí una ubicación activa (devolución / transferencia). `excluirId` saca
/// una de la lista (ej. la ubicación origen en una transferencia).
Future<({String id, String nombre})?> _pickUbicacion(
  BuildContext context, {
  String titulo = 'Elegí la ubicación',
  String? excluirId,
}) async {
  final ubis = await ps.db.getAll(
      'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
  final opciones = ubis.where((u) => u['id'] != excluirId).toList();
  if (!context.mounted) return null;
  if (opciones.isEmpty) {
    _snack(context, 'No hay ubicaciones disponibles. Creá una primero.');
    return null;
  }
  return showDialog<({String id, String nombre})>(
    context: context,
    builder: (_) => SimpleDialog(
      title: Text(titulo),
      children: [
        for (final u in opciones)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(
                context, (id: u['id'] as String, nombre: u['nombre'] as String)),
            child: Text(u['nombre'] as String),
          ),
      ],
    ),
  );
}

/// Diálogo de baja de un equipo serializado: estado destino + motivo opcional.
class _BajaDialog extends StatefulWidget {
  const _BajaDialog({this.esCambioEstado = false});
  // true si el equipo YA está dañado/retirado → es un cambio de estado, no baja.
  final bool esCambioEstado;
  @override
  State<_BajaDialog> createState() => _BajaDialogState();
}

class _BajaDialogState extends State<_BajaDialog> {
  String _estado = 'danado';
  final _motivo = TextEditingController();

  static const _opciones = {
    'danado': 'Dañado',
    'retirado': 'Retirado',
    // 'baja' es el valor en DB; se muestra como descarte (kEstadoSerial, 0204).
    'baja': 'Descarte definitivo',
  };

  @override
  void dispose() {
    _motivo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.esCambioEstado
          ? 'Cambiar estado del equipo'
          : 'Mandar el equipo a descarte'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _estado,
            decoration: const InputDecoration(labelText: 'Estado'),
            onChanged: (v) => setState(() => _estado = v ?? 'danado'),
            items: _opciones.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _motivo,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Motivo (opcional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final m = _motivo.text.trim();
            Navigator.pop(
                context, (estado: _estado, motivo: m.isEmpty ? null : m));
          },
          child: Text(widget.esCambioEstado ? 'Guardar' : 'Mandar a descarte'),
        ),
      ],
    );
  }
}

// ===========================================================================
// Helpers de UI (copias locales de los del catálogo: duplicación menor y
// aceptable de 2 helpers que la pantalla vieja sigue usando por su lado).
// ===========================================================================
void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// Confirmación genérica (título/mensaje/label propios). Para avisos suaves y
/// confirmaciones de movimientos (devolución, baja, etc.).
Future<bool> _confirmarAccion(
  BuildContext context, {
  required String titulo,
  required String mensaje,
  String confirmar = 'Confirmar',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(titulo),
      content: Text(mensaje),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(confirmar)),
      ],
    ),
  );
  return ok ?? false;
}
