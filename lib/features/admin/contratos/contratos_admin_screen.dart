import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../../data/utils/errores.dart';
export 'contrato_form_screen.dart';

class ContratosAdminScreen extends ConsumerStatefulWidget {
  const ContratosAdminScreen({super.key});

  @override
  ConsumerState<ContratosAdminScreen> createState() =>
      _ContratosAdminScreenState();
}

class _ContratosAdminScreenState extends ConsumerState<ContratosAdminScreen> {
  bool _soloActivos = true;
  late Stream<List<Map<String, dynamic>>> _contratosStream;

  @override
  void initState() {
    super.initState();
    _contratosStream = _buildStream();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      '''
      SELECT ct.id, ct.codigo, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
             ct.estado, ct.documento_path,
             c.id AS cliente_id, c.nombre AS cliente,
             p.nombre AS plan, p.precio_mensual,
             co.nombre AS cobrador,
             COUNT(cu.id) AS total_cuotas,
             COALESCE(SUM(CASE WHEN cu.estado = 'pagada' THEN 1 ELSE 0 END), 0) AS cuotas_pagadas
        FROM contratos ct
        JOIN clientes c   ON c.id = ct.cliente_id
        JOIN planes   p   ON p.id = ct.plan_id
   LEFT JOIN cobradores co ON co.id = ct.cobrador_id
   LEFT JOIN cuotas    cu ON cu.contrato_id = ct.id AND cu.estado <> 'anulada'
       WHERE ${_soloActivos ? "ct.estado = 'activo'" : '1=1'}
       GROUP BY ct.id, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
                ct.estado, ct.documento_path, c.id, c.nombre,
                p.nombre, p.precio_mensual, co.nombre
       ORDER BY ct.estado ASC, c.nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Solo activos'),
                selected: _soloActivos,
                onSelected: (v) => setState(() {
                  _soloActivos = v;
                  _contratosStream = _buildStream();
                }),
              ),
              const Spacer(),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Nuevo contrato'),
                onPressed: () => context.push('/admin/contratos/nuevo'),
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
              final rows = snap.data!;
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.assignment_outlined,
                  titulo: 'Sin contratos',
                  descripcion: 'Creá un contrato para empezar a generar cuotas.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
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
    final activo = (row['estado'] as String? ?? 'activo') == 'activo';
    final fechaInicio = DateTime.parse(row['fecha_inicio'] as String);
    final fechaFin = row['fecha_fin'] != null
        ? DateTime.parse(row['fecha_fin'] as String)
        : null;
    final duracion = fechaFin == null
        ? 'Indefinido'
        : _mesesEntre(fechaInicio, fechaFin) == 12
            ? '1 año'
            : _mesesEntre(fechaInicio, fechaFin) == 24
                ? '2 años'
                : '${_mesesEntre(fechaInicio, fechaFin)} meses';
    final totalCuotas = row['total_cuotas'] as int? ?? 0;
    final pagadas = row['cuotas_pagadas'] as int? ?? 0;

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: activo
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Icon(
            activo ? Icons.check : Icons.archive,
            color: activo ? scheme.primary : scheme.outline,
          ),
        ),
        title: Text(row['cliente'] as String),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (row['codigo'] != null)
              Text(row['codigo'] as String,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                      letterSpacing: 0.5)),
            Text('${row['plan']} · ${Fmt.cordobas(row['precio_mensual'] as num)}'),
            Text(
              '$duracion · Día de pago: ${row['dia_pago']} · '
              'Cuotas: $pagadas/$totalCuotas',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (row['documento_path'] != null)
              Tooltip(
                message: 'Tiene documento adjunto',
                child: Icon(Icons.folder_zip,
                    size: 18, color: scheme.primary),
              ),
            if (row['documento_path'] != null && row['cobrador'] != null)
              const SizedBox(width: 8),
            if (row['cobrador'] != null)
              Chip(
                label: Text(row['cobrador'] as String,
                    style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        onTap: () => context.push('/admin/contratos/${row['id']}'),
      ),
    );
  }

  int _mesesEntre(DateTime a, DateTime b) {
    return (b.year - a.year) * 12 + (b.month - a.month);
  }
}
