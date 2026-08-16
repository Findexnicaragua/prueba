import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/settings_repo.dart';
import '../../data/utils/cola_tecnico.dart';
import '../../data/utils/ticket_sla.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/ticket_sla_countdown.dart';
import '../../data/utils/errores.dart';

/// "Mis tickets" — lista de tickets asignados al técnico (Fase 3B). El SQLite
/// local ya viene acotado por el bucket `por_tecnico_tickets` (sólo los suyos),
/// así que la query no filtra por `asignado_a`: todo lo local es del técnico.
/// Filtro por grupo de estado EN SQL; tap → detalle (`/tecnico/tickets/:id`).
class MisTicketsScreen extends ConsumerStatefulWidget {
  const MisTicketsScreen({super.key});
  @override
  ConsumerState<MisTicketsScreen> createState() => _MisTicketsScreenState();
}

const _grupos = {
  'activos': {'abierto', 'asignado', 'en_progreso', 'en_espera', 'reabierto'},
  'cerrados': {'resuelto', 'cerrado', 'cancelado'},
};

/// Orden de la cola (0206), espejo SQL de `compararEnCola`: primero las que
/// tienen posición del coordinador, después el resto por antigüedad.
///
/// En "activos" es la cola de trabajo: la de arriba es la que toca AHORA. En
/// "cerrados" no hay cola, así que se muestra lo más reciente primero (es un
/// historial, y lo último que hiciste es lo que querés ver).
const _ordenSqlActivos =
    't.orden_cola IS NULL, t.orden_cola ASC, t.created_at ASC';
const _ordenSqlCerrados = 't.created_at DESC';

class _MisTicketsScreenState extends ConsumerState<MisTicketsScreen> {
  late Stream<List<Map<String, dynamic>>> _tickets;
  String _filtro = 'activos';

  String get _ordenSql =>
      _filtro == 'activos' ? _ordenSqlActivos : _ordenSqlCerrados;

  @override
  void initState() {
    super.initState();
    _tickets = _buildStream();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final estados = _grupos[_filtro]!.toList();
    final inClause = List.filled(estados.length, '?').join(', ');
    return ps.db.watch('''
      SELECT t.id, t.correlativo, t.titulo, t.estado, t.prioridad,
             t.cliente_id, t.created_at, t.segundos_pausado, t.orden_cola,
             tt.nombre AS tipo_nombre, tt.sla_horas,
             cl.nombre AS cliente_nombre
        FROM tickets t
   LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
   LEFT JOIN clientes cl ON cl.id = t.cliente_id
       WHERE t.estado IN ($inClause)
       ORDER BY $_ordenSql
       LIMIT 300
    ''', parameters: estados);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slaMap = ref.watch(appSettingsProvider).slaHorasPorPrioridad;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              for (final g in const ['activos', 'cerrados'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(g == 'activos' ? 'Activos' : 'Cerrados'),
                    selected: _filtro == g,
                    onSelected: (_) => setState(() {
                      _filtro = g;
                      _tickets = _buildStream();
                    }),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _tickets,
            initialData: const [],
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text(mensajeErrorHumano(snap.error!)));
              }
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                return EmptyState(
                  icon: Icons.confirmation_number_outlined,
                  titulo: _filtro == 'activos'
                      ? 'No tenés tickets activos'
                      : 'Sin tickets cerrados',
                  descripcion: _filtro == 'activos'
                      ? 'Cuando el admin te asigne un ticket, aparece acá.'
                      : null,
                );
              }
              // Cola: una orden a la vez (0206). La activa es la primera en
              // curso; las de atrás se VEN pero no se abren hasta resolverla.
              final idActiva = ordenActiva(rows);
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = rows[i];
                  final estado = t['estado'] as String? ?? 'abierto';
                  final bloqueada = ordenBloqueada(t, idActiva);
                  final prioridad = t['prioridad'] as String?;
                  final createdAt =
                      parseTicketWallClock(t['created_at'] as String);
                  final pausado = (t['segundos_pausado'] as int?) ?? 0;
                  final ef =
                      slaHorasEfectivas(t['sla_horas'] as int?, slaMap[prioridad]);
                  final sla = ticketSlaEstado(
                    estado: estado,
                    createdAt: createdAt,
                    slaHoras: ef,
                    prioridad: prioridad,
                    segundosPausado: pausado,
                  );
                  final cli = t['cliente_nombre'] as String?;
                  final tipo = t['tipo_nombre'] as String?;
                  final sub = [
                    if (tipo != null) tipo,
                    if (cli != null && cli.isNotEmpty) cli,
                  ].join(' · ');
                  final tenue = scheme.onSurfaceVariant;
                  return ListTile(
                    enabled: !bloqueada,
                    leading: bloqueada
                        ? Icon(Icons.lock_outline, size: 18, color: tenue)
                        : CircleAvatar(
                            radius: 6,
                            backgroundColor: estadoTicketColor(estado, scheme),
                          ),
                    title: Text(
                      '${ticketCodigo(t['correlativo'] as num?)} · ${t['titulo']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: bloqueada ? TextStyle(color: tenue) : null,
                    ),
                    subtitle: bloqueada
                        // Decir POR QUÉ está bloqueada, no solo que lo está:
                        // sin el motivo el técnico cree que la app falla.
                        ? Text('Se habilita al resolver la orden de arriba',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: tenue))
                        : (sub.isEmpty
                            ? null
                            : Text(sub,
                                maxLines: 1, overflow: TextOverflow.ellipsis)),
                    trailing: bloqueada
                        ? null
                        : (sla == SlaEstado.sinSla || sla == SlaEstado.cerrado
                            ? Text(estadoTicketLabel(estado),
                                style: TextStyle(
                                    color: estadoTicketColor(estado, scheme),
                                    fontSize: 12))
                            : TicketSlaCountdown(
                                estado: estado,
                                createdAt: createdAt,
                                slaHoras: ef,
                                prioridad: prioridad,
                                segundosPausado: pausado,
                                compact: true,
                              )),
                    onTap: bloqueada
                        ? null
                        : () => context.push('/tecnico/tickets/${t['id']}'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
