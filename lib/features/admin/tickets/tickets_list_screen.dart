import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/ticket_sla_countdown.dart';
import '../../../data/utils/errores.dart';
import 'colas_servicio_panel.dart';
import '../../../data/providers/cobrador_provider.dart';

/// Lista de tickets del tenant (admin). Filtro por grupo de estado + acceso a
/// los tipos. Tap → detalle. FAB → nuevo ticket.
class TicketsListScreen extends ConsumerStatefulWidget {
  const TicketsListScreen({super.key});
  @override
  ConsumerState<TicketsListScreen> createState() => _TicketsListScreenState();
}

// Grupos de filtro (estado → grupo).
const _grupos = {
  'activos': {'abierto', 'asignado', 'en_progreso', 'en_espera', 'reabierto'},
  // Bandeja del call center (0208): el trabajo ya está hecho y falta confirmar
  // con el cliente para poder cerrar. Va SEPARADO de 'resueltos' —que incluye
  // las ya cerradas— porque mezclado no sirve como cola de trabajo: lo que el
  // operador necesita ver es exactamente lo que le falta llamar.
  'por_cerrar': {'resuelto'},
  'resueltos': {'resuelto', 'cerrado'},
  'cancelados': {'cancelado'},
};

class _TicketsListScreenState extends ConsumerState<TicketsListScreen> {
  late Stream<List<Map<String, dynamic>>> _tickets;
  String _filtro = 'activos';

  @override
  void initState() {
    super.initState();
    _tickets = _buildStream();
  }

  // Filtra por grupo de estado EN SQL (no en memoria) + LIMIT acotado. El stream
  // se recrea al cambiar el filtro.
  Stream<List<Map<String, dynamic>>> _buildStream() {
    final estados = _grupos[_filtro]!.toList();
    final inClause = List.filled(estados.length, '?').join(', ');
    return ps.db.watch('''
      SELECT t.id, t.correlativo, t.titulo, t.estado, t.prioridad,
             t.cliente_id, t.created_at, t.segundos_pausado,
             tt.nombre AS tipo_nombre, tt.sla_horas,
             cl.nombre AS cliente_nombre, co.nombre AS asignado_nombre
        FROM tickets t
   LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
   LEFT JOIN clientes cl ON cl.id = t.cliente_id
   LEFT JOIN cobradores co ON co.id = t.asignado_a
       WHERE t.estado IN ($inClause)
       ORDER BY t.created_at DESC
       LIMIT 300
    ''', parameters: estados);
  }

  /// Roles que NO pueden dar de alta una orden: `lectura` no escribe nada, y el
  /// coordinador solo tiene policy de UPDATE (0207). Se centraliza acá para que
  /// las DOS entradas al form —el FAB y el botón del estado vacío— usen la misma
  /// regla; tenerlas separadas fue justamente cómo se coló la segunda.
  bool _noCreaOrdenes(WidgetRef ref) =>
      ref.watch(soloLecturaProvider) ||
      (ref.watch(cobradorActualProvider).valueOrNull?.esCoordinador ?? false);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slaMap = ref.watch(appSettingsProvider).slaHorasPorPrioridad;
    // Base de navegación según el shell: el admin de tickets vive en
    // /admin-tickets/*, el admin normal en /admin/*. Así la misma pantalla
    // se reusa en ambos sin mandar al admin_tickets a /admin (el router lo
    // rebotaría). Mismo patrón que las pantallas de clientes.
    final base = GoRouterState.of(context).matchedLocation.startsWith('/admin-tickets')
        ? '/admin-tickets/tickets'
        : '/admin/tickets';
    return Scaffold(
      // El coordinador NO crea órdenes: su única policy es FOR UPDATE (0207).
      // Sin este gate veía el botón, llenaba el form y el INSERT se le rechazaba
      // al sincronizar (audit 2026-07-26).
      floatingActionButton: _noCreaOrdenes(ref)
          ? null
          : FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Ticket'),
        onPressed: () => context.push('$base/nuevo'),
      ),
      body: Column(
        children: [
          // Colas de facturación derivadas de las órdenes de trabajo (0172):
          // solo en el shell del admin (navega a /admin/contratos; admin_tickets
          // no gestiona contratos). Vacío → no renderiza nada.
          if (base == '/admin/tickets') const ColasServicioPanel(),
          // Salud del cierre (audit 2026-07-26): hasta acá `cerrado_sin_confirmar`
          // se guardaba y NADIE lo veía, así que la promesa de "poder medir
          // cuántas se cierran a ciegas" no se cumplía. Solo en la bandeja "Por
          // cerrar" y en "Resueltos", que es donde el dato tiene contexto.
          if (_filtro == 'por_cerrar' || _filtro == 'resueltos')
            const _SaludDelCierre(),
          // Filtros + acceso a tipos.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final g in const [
                        'activos',
                        'por_cerrar',
                        'resueltos',
                        'cancelados'
                      ])
                        ChoiceChip(
                          label: Text(switch (g) {
                            'activos' => 'Activos',
                            'por_cerrar' => 'Por cerrar',
                            'resueltos' => 'Resueltos',
                            _ => 'Cancelados',
                          }),
                          selected: _filtro == g,
                          onSelected: (_) => setState(() {
                            _filtro = g;
                            _tickets = _buildStream();
                          }),
                        ),
                    ],
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.label_outline, size: 18),
                  label: const Text('Tipos'),
                  // Ídem detalle: go en el shell admin, push para admin_tickets.
                  onPressed: () => base == '/admin/tickets'
                      ? context.go('$base/tipos')
                      : context.push('$base/tipos'),
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
                // El filtro por grupo de estado ya se aplicó en SQL (_buildStream).
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return EmptyState(
                    icon: Icons.confirmation_number_outlined,
                    titulo: switch (_filtro) {
                      'activos' => 'Sin tickets activos',
                      'por_cerrar' => 'Nada por cerrar',
                      'resueltos' => 'Sin tickets resueltos',
                      _ => 'Sin tickets cancelados',
                    },
                    descripcion: _filtro == 'activos'
                        ? 'Creá un ticket para una instalación, reparación o reclamo.'
                        : null,
                    // Gateado por rol igual que el FAB: sin esto el
                    // coordinador —y el rol `lectura`, que lo arrastraba desde
                    // antes de este paquete— veían "Nuevo ticket" acá aunque el
                    // server les rechace el alta (audit profundo 2026-07-26).
                    accion: (_filtro == 'activos' && !_noCreaOrdenes(ref))
                        ? FilledButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Nuevo ticket'),
                            onPressed: () =>
                                context.push('$base/nuevo'),
                          )
                        : null,
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final t = rows[i];
                    final estado = t['estado'] as String? ?? 'abierto';
                    final prioridad = t['prioridad'] as String?;
                    final createdAt =
                        parseTicketWallClock(t['created_at'] as String);
                    final pausado = (t['segundos_pausado'] as int?) ?? 0;
                    final ef = slaHorasEfectivas(
                        t['sla_horas'] as int?, slaMap[prioridad]);
                    final sla = ticketSlaEstado(
                      estado: estado,
                      createdAt: createdAt,
                      slaHoras: ef,
                      prioridad: prioridad,
                      segundosPausado: pausado,
                    );
                    final cli = t['cliente_nombre'] as String?;
                    final asig = t['asignado_nombre'] as String?;
                    final tipo = t['tipo_nombre'] as String?;
                    final sub = [
                      if (tipo != null) tipo,
                      if (cli != null && cli.isNotEmpty) cli,
                      if (asig != null && asig.isNotEmpty) '→ $asig',
                    ].join(' · ');
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 6,
                        backgroundColor: estadoTicketColor(estado, scheme),
                      ),
                      title: Text(
                        '${ticketCodigo(t['correlativo'] as num?)} · ${t['titulo']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: sub.isEmpty ? null : Text(sub,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: sla == SlaEstado.sinSla || sla == SlaEstado.cerrado
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
                            ),
                      // En el shell admin (/admin/tickets) el detalle es ruta
                      // del shell → go (regla #12). Para admin_tickets
                      // (/admin-tickets/*) el detalle tiene Scaffold propio
                      // fuera del shell → push (su back propio).
                      onTap: () => base == '/admin/tickets'
                          ? context.go('$base/${t['id']}')
                          : context.push('$base/${t['id']}'),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Salud del cierre: qué proporción de las órdenes cerradas este mes se cerró
/// SIN que el cliente confirmara (0208 + audit 2026-07-26).
///
/// Un porcentaje bajo es normal — siempre hay gente que no atiende. Uno alto
/// significa que alguien está cerrando órdenes para sacárselas de encima, y sin
/// esta tarjeta eso era invisible: el dato estaba en la base y ninguna pantalla
/// lo mostraba.
class _SaludDelCierre extends ConsumerStatefulWidget {
  const _SaludDelCierre();
  @override
  ConsumerState<_SaludDelCierre> createState() => _SaludDelCierreState();
}

class _SaludDelCierreState extends ConsumerState<_SaludDelCierre> {
  late final Stream<List<Map<String, dynamic>>> _resumen;

  @override
  void initState() {
    super.initState();
    // Mes en curso en día Nicaragua (UTC-6, regla #1b): sin el -6h, las órdenes
    // cerradas después de las 18:00 del último día del mes caerían en el
    // siguiente y el corte mensual quedaría corrido.
    _resumen = ps.db.watch('''
      SELECT COUNT(*) AS total,
             SUM(CASE WHEN cerrado_sin_confirmar = 1 THEN 1 ELSE 0 END) AS ciegas
        FROM tickets
       WHERE estado = 'cerrado'
         AND cerrado_en IS NOT NULL
         AND date(cerrado_en, '-6 hours')
             >= date('now', '-6 hours', 'start of month')
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _resumen,
      initialData: const [],
      builder: (context, snap) {
        final r = (snap.data ?? const []).isEmpty ? null : snap.data!.first;
        final total = (r?['total'] as int?) ?? 0;
        final ciegas = (r?['ciegas'] as int?) ?? 0;
        // Sin cierres en el mes no hay nada que evaluar: la tarjeta se calla en
        // vez de mostrar un 0% que no significa nada.
        if (total == 0) return const SizedBox.shrink();
        final pct = (ciegas * 100 / total).round();
        final scheme = Theme.of(context).colorScheme;
        // >30% deja de ser "gente que no atiende" y pasa a ser un síntoma.
        final alerta = pct > 30;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cerradas sin confirmar · este mes',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('$pct%',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                  color: alerta ? scheme.error : null)),
                      const SizedBox(width: 8),
                      Text('$ciegas de $total órdenes',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ciegas / total,
                      minHeight: 7,
                      backgroundColor: scheme.surfaceContainerHighest,
                      color: alerta ? scheme.error : scheme.primary,
                    ),
                  ),
                  if (alerta) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Más de una de cada tres se cierra sin hablar con el '
                      'cliente. Vale la pena revisar por qué.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
