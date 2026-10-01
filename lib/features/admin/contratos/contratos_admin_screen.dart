import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
export 'contrato_form_screen.dart';

class ContratosAdminScreen extends ConsumerStatefulWidget {
  const ContratosAdminScreen({super.key});

  @override
  ConsumerState<ContratosAdminScreen> createState() =>
      _ContratosAdminScreenState();
}

class _ContratosAdminScreenState extends ConsumerState<ContratosAdminScreen> {
  bool _soloActivos = true;
  String _busqueda = '';
  final _searchCtrl = TextEditingController();
  late Stream<List<Map<String, dynamic>>> _contratosStream;

  @override
  void initState() {
    super.initState();
    _contratosStream = _buildStream();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      '''
      SELECT ct.id, ct.codigo, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
             ct.estado, ct.documento_path,
             ct.monto_prestado, ct.tasa_interes, ct.frecuencia, ct.plazo_cuotas,
             ct.metodo_calculo, ct.monto_cuota, ct.total_interes, ct.total_pagar, ct.moneda,
             c.id AS cliente_id, c.nombre AS cliente,
             p.nombre AS plan, p.precio_mensual,
             co.nombre AS cobrador,
             COUNT(cu.id) AS total_cuotas,
             COALESCE(SUM(CASE WHEN cu.estado = 'pagada' THEN 1 ELSE 0 END), 0) AS cuotas_pagadas,
             COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente', 'parcial')
                               THEN max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)
                               ELSE 0 END), 0) AS saldo_pendiente,
             COALESCE(SUM(CASE WHEN cu.estado = 'pagada' THEN cu.monto ELSE COALESCE(cu.monto_pagado, 0) END), 0) AS total_recaudado
        FROM contratos ct
        JOIN clientes c    ON c.id = ct.cliente_id
   LEFT JOIN planes   p    ON p.id = ct.plan_id
   LEFT JOIN cobradores co ON co.id = ct.cobrador_id
   LEFT JOIN cuotas    cu  ON cu.contrato_id = ct.id AND cu.estado <> 'anulada'
       WHERE ${_soloActivos ? "ct.estado = 'activo'" : '1=1'}
       GROUP BY ct.id, ct.codigo, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
                ct.estado, ct.documento_path,
                ct.monto_prestado, ct.tasa_interes, ct.frecuencia, ct.plazo_cuotas,
                ct.metodo_calculo, ct.monto_cuota, ct.total_interes, ct.total_pagar, ct.moneda,
                c.id, c.nombre, p.nombre, p.precio_mensual, co.nombre
       ORDER BY ct.estado ASC, ct.created_at DESC, c.nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: SearchBar(
                      controller: _searchCtrl,
                      hintText: 'Buscar por cliente o código...',
                      leading: const Icon(Icons.search, size: 20),
                      trailing: _busqueda.isNotEmpty
                          ? [
                              IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _busqueda = '');
                                },
                              ),
                            ]
                          : null,
                      elevation: const WidgetStatePropertyAll(0.5),
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onChanged: (v) => setState(() => _busqueda = v.trim().toLowerCase()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Nuevo préstamo'),
                    onPressed: () => context.push('/admin/contratos/nuevo'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilterChip(
                    label: const Text('Solo activos'),
                    selected: _soloActivos,
                    onSelected: (v) => setState(() {
                      _soloActivos = v;
                      _contratosStream = _buildStream();
                    }),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _contratosStream,
            initialData: const [],
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text(mensajeErrorHumano(snap.error!)));
              }
              final allRows = snap.data!;
              final rows = _busqueda.isEmpty
                  ? allRows
                  : allRows.where((r) {
                      final cliente = (r['cliente'] as String? ?? '').toLowerCase();
                      final codigo = (r['codigo'] as String? ?? '').toLowerCase();
                      return cliente.contains(_busqueda) || codigo.contains(_busqueda);
                    }).toList();

              if (rows.isEmpty) {
                return EmptyState(
                  icon: Icons.account_balance_wallet_outlined,
                  titulo: _busqueda.isEmpty ? 'Sin préstamos' : 'Sin resultados',
                  descripcion: _busqueda.isEmpty
                      ? 'Creá un nuevo préstamo para emitir su calendario de cuotas.'
                      : 'No se encontraron préstamos que coincidan con la búsqueda.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _ContratoCard(row: rows[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ContratoCard extends StatelessWidget {
  const _ContratoCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estado = (row['estado'] as String? ?? 'activo');
    final activo = estado == 'activo';
    final esPrestamo = row['monto_prestado'] != null;
    final totalCuotas = (row['total_cuotas'] as num?)?.toInt() ?? 0;
    final pagadas = (row['cuotas_pagadas'] as num?)?.toInt() ?? 0;
    final saldoPendiente = (row['saldo_pendiente'] as num?)?.toDouble() ?? 0.0;
    final moneda = row['moneda'] as String? ?? 'NIO';

    final Color badgeBg;
    final Color badgeText;
    final String badgeLabel;
    switch (estado) {
      case 'activo':
        badgeBg = scheme.primaryContainer;
        badgeText = scheme.primary;
        badgeLabel = 'Activo';
        break;
      case 'suspendido':
        badgeBg = Colors.orange.shade100;
        badgeText = Colors.orange.shade900;
        badgeLabel = 'Suspendido';
        break;
      case 'cancelado':
        badgeBg = scheme.errorContainer;
        badgeText = scheme.error;
        badgeLabel = 'Cancelado';
        break;
      default:
        badgeBg = scheme.surfaceContainerHighest;
        badgeText = scheme.outline;
        badgeLabel = estado;
    }

    final progreso = totalCuotas > 0 ? (pagadas / totalCuotas).clamp(0.0, 1.0) : 0.0;

    return Card(
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/admin/contratos/${row['id']}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Fila superior: Cliente + Badge Estado
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: activo
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    child: Icon(
                      esPrestamo ? Icons.payments_outlined : Icons.description_outlined,
                      size: 20,
                      color: activo ? scheme.primary : scheme.outline,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row['cliente'] as String? ?? 'Sin cliente',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (row['codigo'] != null)
                          Text(
                            row['codigo'] as String,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                              letterSpacing: 0.5,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      badgeLabel,
                      style: TextStyle(
                        color: badgeText,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Contenido específico de Préstamo vs Plan Legacy
              if (esPrestamo) ...[
                // Fila de montos: Préstamo y Cuota
                Row(
                  children: [
                    Expanded(
                      child: _MetricBadge(
                        label: 'Préstamo',
                        value: Fmt.monto(row['monto_prestado'] as num, moneda),
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MetricBadge(
                        label: 'Cuota (${_frecuenciaLabel(row['frecuencia'] as String?)})',
                        value: row['monto_cuota'] != null ? Fmt.monto(row['monto_cuota'] as num, moneda) : '—',
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Progreso de cuotas y saldo pendiente
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Cuotas: $pagadas de $totalCuotas pagadas',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    Text(
                      'Saldo: ${Fmt.monto(saldoPendiente, moneda)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: saldoPendiente > 0 && activo ? scheme.error : Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progreso,
                    minHeight: 6,
                    backgroundColor: scheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation(
                      progreso >= 1.0 ? Colors.green.shade600 : scheme.primary,
                    ),
                  ),
                ),
              ] else ...[
                // Fallback Legacy (Planes ISP)
                Text(
                  '${row['plan'] ?? 'Sin plan'} · ${Fmt.cordobas(row['precio_mensual'] as num? ?? 0)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Día de pago: ${row['dia_pago']} · Cuotas: $pagadas/$totalCuotas',
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
              ],

              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // Pie de la tarjeta: Cobrador, Documento, Fechas
              Row(
                children: [
                  if (row['fecha_inicio'] != null)
                    Text(
                      'Inicio: ${Fmt.fechaCorta(DateTime.parse(row['fecha_inicio'] as String))}',
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                    ),
                  const Spacer(),
                  if (row['documento_path'] != null) ...[
                    Tooltip(
                      message: 'Tiene documento adjunto',
                      child: Icon(Icons.attach_file, size: 16, color: scheme.primary),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (row['cobrador'] != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person_pin, size: 12, color: scheme.outline),
                          const SizedBox(width: 4),
                          Text(
                            row['cobrador'] as String,
                            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _frecuenciaLabel(String? f) {
    switch (f) {
      case 'diario':
        return 'Diario';
      case 'semanal':
        return 'Semanal';
      case 'quincenal':
        return 'Quincenal';
      case 'mensual':
        return 'Mensual';
      case 'bimensual':
        return 'Bimensual';
      default:
        return f ?? 'Mensual';
    }
  }
}

class _MetricBadge extends StatelessWidget {
  const _MetricBadge({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10, color: scheme.outline),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
