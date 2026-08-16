import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import '../../../data/utils/errores.dart';

/// Detalle de un incidente: header (estado/alcance/fechas), clientes afectados
/// DERIVADOS de la topología de red, tickets agrupados, resolver e historial.
class IncidenteDetailScreen extends ConsumerStatefulWidget {
  const IncidenteDetailScreen({super.key, required this.incidenteId});
  final String incidenteId;
  @override
  ConsumerState<IncidenteDetailScreen> createState() =>
      _IncidenteDetailScreenState();
}

class _IncidenteDetailScreenState extends ConsumerState<IncidenteDetailScreen> {
  late final Stream<List<Map<String, dynamic>>> _incidente;
  late final Stream<List<Map<String, dynamic>>> _tickets;

  @override
  void initState() {
    super.initState();
    _incidente = ps.db.watch('''
      SELECT i.*, n.nombre AS nodo, h.nombre AS hub, p.nombre AS puerto
        FROM incidentes i
   LEFT JOIN red_nodos   n ON n.id = i.nodo_id
   LEFT JOIN red_hubs    h ON h.id = i.hub_id
   LEFT JOIN red_puertos p ON p.id = i.puerto_id
       WHERE i.id = ?
    ''', parameters: [widget.incidenteId]);
    _tickets = ps.db.watch('''
      SELECT id, correlativo, titulo, estado
        FROM tickets WHERE incidente_id = ?
       ORDER BY created_at DESC
    ''', parameters: [widget.incidenteId]);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _incidente,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text(mensajeErrorHumano(snap.error!)));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
              icon: Icons.cell_tower_outlined,
              titulo: 'Incidente no encontrado');
        }
        final inc = rows.first;
        final tenantId = ref.read(tenantIdProvider);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
              children: [
                _header(context, inc),
                const SizedBox(height: 16),
                _ClientesAfectados(inc: inc, tenantId: tenantId),
                const SizedBox(height: 16),
                _ticketsCard(context),
                const SizedBox(height: 16),
                HistorialOpLog(
                    entidad: 'incidentes', entidadId: widget.incidenteId),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, Map<String, dynamic> inc) {
    final scheme = Theme.of(context).colorScheme;
    final abierto = inc['estado'] == 'abierto';
    final fin = inc['fin'] as String?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(inc['titulo'] as String? ?? '—',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (abierto ? scheme.error : Colors.green)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(abierto ? 'Abierto' : 'Resuelto',
                      style: TextStyle(
                          color: abierto ? scheme.error : Colors.green,
                          fontWeight: FontWeight.w600,
                          fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if ((inc['descripcion'] as String?)?.isNotEmpty ?? false) ...[
              Text(inc['descripcion'] as String),
              const SizedBox(height: 8),
            ],
            _row(Icons.cell_tower, 'Alcance', _alcance(inc)),
            _row(Icons.play_arrow, 'Inicio',
                Fmt.fechaCorta(DateTime.parse(inc['inicio'] as String).toLocal())),
            if (fin != null)
              _row(Icons.stop, 'Fin',
                  Fmt.fechaCorta(DateTime.parse(fin).toLocal())),
            if (abierto && !ref.watch(soloLecturaProvider)) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Marcar resuelto'),
                onPressed: _resolver,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 12),
            SizedBox(width: 90, child: Text(label)),
            Expanded(child: Text(value)),
          ],
        ),
      );

  String _alcance(Map<String, dynamic> inc) {
    if (inc['puerto_id'] != null) return 'Puerto: ${inc['puerto'] ?? '—'}';
    if (inc['hub_id'] != null) return 'Hub: ${inc['hub'] ?? '—'}';
    if (inc['nodo_id'] != null) return 'Nodo: ${inc['nodo'] ?? '—'}';
    // FK borrado: usar el snapshot del alcance si lo hay (no es general real).
    final snap = inc['alcance_label'] as String?;
    if (snap != null && snap.isNotEmpty && snap != 'Corte general') return snap;
    return 'Corte general (todo el tenant)';
  }

  Widget _ticketsCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tickets del incidente',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _tickets,
              initialData: const [],
              builder: (context, snap) {
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('Ningún ticket vinculado a este incidente.',
                        style: TextStyle(color: scheme.outline)),
                  );
                }
                return Column(
                  children: [
                    for (final t in rows)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: CircleAvatar(
                            radius: 5,
                            backgroundColor: estadoTicketColor(
                                t['estado'] as String? ?? 'abierto', scheme)),
                        title: Text(
                            '${ticketCodigo(t['correlativo'] as num?)} · ${t['titulo']}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Text(
                            estadoTicketLabel(t['estado'] as String? ?? 'abierto'),
                            style: const TextStyle(fontSize: 12)),
                        onTap: () =>
                            context.push('/admin/tickets/${t['id']}'),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resolver() async {
    // Resolución atribuida al usuario (op_log) → bloqueada al impersonar
    // (audit 2026-06-30).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    // Confirmación: resolver cierra el incidente y NO hay reabrir desde la app
    // (audit 2026-06-30).
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Marcar resuelto'),
        content: const Text('El incidente queda cerrado y no se puede reabrir '
            'desde la app. ¿Confirmás?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Marcar resuelto')),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    // fin = ocurrido_en = device-time UTC (offline-first, alimenta el change-log).
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    // op_log: actor + id de intención (estado es campo visible → diff antes→después).
    final tenantId = ref.read(tenantIdProvider);
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    try {
      await ps.dbW.writeTransaction((tx) async {
        final antesRows = await tx
            .getAll('SELECT * FROM incidentes WHERE id = ?', [widget.incidenteId]);
        final antes =
            antesRows.isNotEmpty ? antesRows.first : const <String, dynamic>{};
        await tx.execute(
          "UPDATE incidentes SET estado = 'resuelto', fin = ?, ocurrido_en = ? "
          'WHERE id = ?',
          [ocurrido, ocurrido, widget.incidenteId],
        );
        if (tenantId != null) {
          final despues = (await tx.getAll(
                  'SELECT * FROM incidentes WHERE id = ?', [widget.incidenteId]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'incidentes',
              entidadId: widget.incidenteId, antes: antes, despues: despues,
              actor: actor, ocurridoEn: DateTime.parse(ocurrido));
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Incidente resuelto')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }
}

/// Clientes afectados DERIVADOS del alcance del incidente (clientes.puerto_id →
/// red_puertos.hub_id → red_hubs.nodo_id). Conteo + lista.
class _ClientesAfectados extends StatefulWidget {
  const _ClientesAfectados({required this.inc, this.tenantId});
  final Map<String, dynamic> inc;
  final String? tenantId;
  @override
  State<_ClientesAfectados> createState() => _ClientesAfectadosState();
}

class _ClientesAfectadosState extends State<_ClientesAfectados> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _build();
  }

  @override
  void didUpdateWidget(_ClientesAfectados old) {
    super.didUpdateWidget(old);
    // Si cambió el alcance (poco común), recomputar.
    if (old.inc['puerto_id'] != widget.inc['puerto_id'] ||
        old.inc['hub_id'] != widget.inc['hub_id'] ||
        old.inc['nodo_id'] != widget.inc['nodo_id']) {
      setState(() => _stream = _build());
    }
  }

  Stream<List<Map<String, dynamic>>> _build() {
    final inc = widget.inc;
    if (inc['puerto_id'] != null) {
      return ps.db.watch(
        'SELECT id, nombre, telefono FROM clientes '
        'WHERE puerto_id = ? AND activo = 1 ORDER BY nombre',
        parameters: [inc['puerto_id']],
      );
    }
    if (inc['hub_id'] != null) {
      return ps.db.watch('''
        SELECT c.id, c.nombre, c.telefono FROM clientes c
          JOIN red_puertos p ON p.id = c.puerto_id
         WHERE p.hub_id = ? AND c.activo = 1 ORDER BY c.nombre
      ''', parameters: [inc['hub_id']]);
    }
    if (inc['nodo_id'] != null) {
      return ps.db.watch('''
        SELECT c.id, c.nombre, c.telefono FROM clientes c
          JOIN red_puertos p ON p.id = c.puerto_id
          JOIN red_hubs h ON h.id = p.hub_id
         WHERE h.nodo_id = ? AND c.activo = 1 ORDER BY c.nombre
      ''', parameters: [inc['nodo_id']]);
    }
    // Corte general: todos los clientes activos del tenant (filtro explícito de
    // tenant_id por defensa en profundidad, aunque el SQLite local ya es mono-tenant).
    return ps.db.watch(
        'SELECT id, nombre, telefono FROM clientes '
        'WHERE activo = 1 AND tenant_id = ? ORDER BY nombre',
        parameters: [widget.tenantId]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _stream,
          initialData: const [],
          builder: (context, snap) {
            final rows = snap.data ?? const [];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.people_outline, size: 20, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text('Clientes afectados (${rows.length})',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                // Hub/nodo derivan el alcance por el PUERTO del cliente; un cliente
                // sin puerto asignado no cuelga de ningún hub/nodo (no lo alcanza el
                // corte), pero si está conectado y su puerto no se cargó, quedaría
                // fuera de la cuenta — se aclara el alcance (audit 2026-06-30).
                if (widget.inc['hub_id'] != null ||
                    widget.inc['nodo_id'] != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, bottom: 2),
                    child: Text(
                      'Solo cuenta clientes con puerto asignado bajo ese '
                      '${widget.inc['hub_id'] != null ? 'hub' : 'nodo'}.',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                const SizedBox(height: 4),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                        'Sin clientes en el alcance (¿puerto/hub/nodo sin clientes asignados?).',
                        style: TextStyle(color: scheme.outline)),
                  )
                else
                  ...rows.take(50).map((c) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.person_outline, size: 20),
                        title: Text(c['nombre'] as String? ?? '—'),
                        subtitle: (c['telefono'] as String?)?.isNotEmpty ?? false
                            ? Text(c['telefono'] as String)
                            : null,
                      )),
                if (rows.length > 50)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('y ${rows.length - 50} más…',
                        style: TextStyle(color: scheme.outline)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
