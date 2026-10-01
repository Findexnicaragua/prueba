// Tarjeta-resumen del contrato (header reutilizable): plan o préstamo + estado,
// datos financieros, rango de cuotas y panel Total/Recaudado/Pendiente.
// Soporta tanto Préstamos Microfinancieros (Fase 1/2) como Contratos ISP legacy.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/contrato_providers.dart';
import '../../data/utils/formatters.dart';

String _duracionLabelHelper(DateTime inicio, DateTime? fin) {
  if (fin == null) return 'Indefinido';
  final meses = (fin.year - inicio.year) * 12 + (fin.month - inicio.month);
  if (meses <= 0) return '—';
  if (meses == 1) return '1 mes';
  if (meses == 12) return '1 año';
  if (meses == 24) return '2 años';
  if (meses % 12 == 0) return '${meses ~/ 12} años';
  return '$meses meses';
}

String _frecuenciaLabel(String? f) {
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

class ContratoHeaderCard extends StatelessWidget {
  const ContratoHeaderCard({
    super.key,
    required this.contrato,
    required this.esAdmin,
    required this.contratoId,
    required this.enImpersonacion,
    this.esAdminCobranza = false,
    this.onEstadoChanged,
    this.footer,
  });

  final Map<String, dynamic> contrato;
  final bool esAdmin;
  final bool esAdminCobranza;
  final String contratoId;
  final bool enImpersonacion;
  final ValueChanged<String>? onEstadoChanged;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estado = contrato['estado'] as String? ?? 'activo';
    final codigo = contrato['codigo'] as String?;
    final clienteNombre = contrato['cliente_nombre'] as String? ?? '—';
    final fechaInicio = DateTime.parse(contrato['fecha_inicio'] as String);
    final fechaFin = contrato['fecha_fin'] != null
        ? DateTime.parse(contrato['fecha_fin'] as String)
        : null;
    final diaPago = contrato['dia_pago'] as int? ?? 1;

    // Préstamo Microfinanciero vs Plan Legacy
    final esPrestamo = contrato['monto_prestado'] != null;
    final moneda = contrato['moneda'] as String? ?? 'NIO';
    final montoPrestado = (contrato['monto_prestado'] as num?)?.toDouble() ?? 0.0;
    final tasaInteres = (contrato['tasa_interes'] as num?)?.toDouble() ?? 0.0;
    final frecuencia = contrato['frecuencia'] as String?;
    final plazoCuotas = (contrato['plazo_cuotas'] as num?)?.toInt() ?? 0;
    final metodoCalculo = contrato['metodo_calculo'] as String?;
    final montoCuota = (contrato['monto_cuota'] as num?)?.toDouble() ?? 0.0;
    final totalInteres = (contrato['total_interes'] as num?)?.toDouble() ?? 0.0;
    final totalPagar = (contrato['total_pagar'] as num?)?.toDouble() ?? 0.0;

    // Campos Legacy
    final planNombre = contrato['plan_nombre'] as String? ?? '—';
    final precio = (contrato['precio_mensual'] as num?)?.toDouble() ?? 0;
    final costoInstalacion = (contrato['costo_instalacion'] as num?)?.toDouble();

    final (Color badgeColor, String badgeLabel) = switch (estado) {
      'activo' => (scheme.primary, 'Activo'),
      'suspendido' => (Colors.orange.shade800, 'Suspendido'),
      'cancelado' || 'completado' => (scheme.error, 'Cancelado'),
      _ => (scheme.outline, estado),
    };
    final esTerminal = estado == 'cancelado' || estado == 'completado';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fila superior: Título (Préstamo o Plan) + Badge Estado
            Row(
              children: [
                Icon(
                  esPrestamo ? Icons.account_balance_wallet : Icons.assignment,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    esPrestamo
                        ? 'Préstamo · ${Fmt.monto(montoPrestado, moneda)}'
                        : planNombre,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                if (esAdmin &&
                    onEstadoChanged != null &&
                    !esTerminal &&
                    !enImpersonacion)
                  PopupMenuButton<String>(
                    tooltip: 'Cambiar estado',
                    onSelected: onEstadoChanged,
                    itemBuilder: (_) => [
                      if (estado != 'activo' && estado != 'suspendido')
                        const PopupMenuItem(value: 'activo', child: Text('Activo')),
                      const PopupMenuItem(value: 'cancelado', child: Text('Cancelado')),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(badgeLabel,
                              style: TextStyle(
                                color: badgeColor,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              )),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_drop_down, size: 18, color: badgeColor),
                        ],
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(badgeLabel,
                        style: TextStyle(
                          color: badgeColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        )),
                  ),
              ],
            ),

            // Código del contrato/préstamo
            if (codigo != null && codigo.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.tag, size: 16, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text(codigo,
                      style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ],
            const SizedBox(height: 10),

            // Cliente
            Row(
              children: [
                Icon(Icons.person, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text(
                  clienteNombre,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // CUERPO: MODO PRÉSTAMO
            if (esPrestamo) ...[
              // Grid de métricas financieras del préstamo
              LayoutBuilder(
                builder: (context, constraints) {
                  // responsive width check
                  final _ = constraints.maxWidth;
                  return Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _LoanInfoTile(
                              label: 'Monto prestado',
                              value: Fmt.monto(montoPrestado, moneda),
                              icon: Icons.payments_outlined,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _LoanInfoTile(
                              label: 'Cuota programada',
                              value: '${Fmt.monto(montoCuota, moneda)} (${_frecuenciaLabel(frecuencia)})',
                              icon: Icons.event_repeat,
                              highlight: true,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _LoanInfoTile(
                              label: 'Tasa e interés',
                              value: '$tasaInteres% (${Fmt.monto(totalInteres, moneda)}) · ${metodoCalculo == 'cuota_nivelada' ? 'Nivelada' : 'Fijo'}',
                              icon: Icons.percent,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _LoanInfoTile(
                              label: 'Plazo / Total a pagar',
                              value: '$plazoCuotas cuotas · ${Fmt.monto(totalPagar, moneda)}',
                              icon: Icons.calendar_month,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.calendar_today_outlined, size: 15, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text(
                    'Desembolso: ${Fmt.fechaCorta(fechaInicio)}'
                    '${fechaFin != null ? ' · Vence: ${Fmt.fechaCorta(fechaFin)}' : ''}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ] else ...[
              // CUERPO: MODO LEGACY ISP
              Row(
                children: [
                  Icon(Icons.monetization_on, size: 16, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text('${Fmt.cordobas(precio)} / mes',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      )),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.timelapse, size: 16, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text('Duración: ${_duracionLabelHelper(fechaInicio, fechaFin)}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.build_circle_outlined, size: 16, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text('Instalación: ${Fmt.fechaCorta(fechaInicio)}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            ],

            const Divider(height: 20),

            // Rango de fechas de cuotas + día de pago
            _ContratoFechasChips(
              contratoId: contratoId,
              diaPago: diaPago,
              indefinido: fechaFin == null,
              frecuencia: frecuencia,
            ),

            if (costoInstalacion != null && !esPrestamo) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.build, size: 16, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text('Costo de instalación: ${Fmt.cordobas(costoInstalacion)}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            ],

            const SizedBox(height: 12),

            // Resumen financiero (Total / Recaudado / Saldo Pendiente)
            _ContratoResumen(
              contratoId: contratoId,
              precioMensual: esPrestamo ? montoCuota : precio,
              fechaInicio: fechaInicio,
              fechaFin: fechaFin,
              duracionMeses: esPrestamo ? plazoCuotas : (contrato['duracion_meses'] as num?)?.toInt(),
              esAdminCobranza: esAdminCobranza,
              moneda: moneda,
              esPrestamo: esPrestamo,
              totalNominalPrestamo: esPrestamo ? totalPagar : null,
            ),

            if (footer != null) ...[
              const SizedBox(height: 12),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}

class _LoanInfoTile extends StatelessWidget {
  const _LoanInfoTile({
    required this.label,
    required this.value,
    required this.icon,
    this.highlight = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primaryContainer.withValues(alpha: 0.35)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: highlight ? scheme.primary : scheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 10, color: scheme.outline),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: highlight ? scheme.primary : scheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Resumen financiero del contrato / préstamo
// ---------------------------------------------------------------------------

class _ContratoResumen extends ConsumerWidget {
  const _ContratoResumen({
    required this.contratoId,
    required this.precioMensual,
    required this.fechaInicio,
    required this.fechaFin,
    required this.duracionMeses,
    this.esAdminCobranza = false,
    this.moneda = 'NIO',
    this.esPrestamo = false,
    this.totalNominalPrestamo,
  });

  final String contratoId;
  final double precioMensual;
  final DateTime fechaInicio;
  final DateTime? fechaFin;
  final int? duracionMeses;
  final bool esAdminCobranza;
  final String moneda;
  final bool esPrestamo;
  final double? totalNominalPrestamo;

  double? _calcularTotalContrato() {
    if (esPrestamo && totalNominalPrestamo != null && totalNominalPrestamo! > 0) {
      return totalNominalPrestamo;
    }
    final meses = duracionMeses ??
        (fechaFin != null
            ? (fechaFin!.year - fechaInicio.year) * 12 +
                (fechaFin!.month - fechaInicio.month)
            : null);
    if (meses == null || meses <= 0) return null;
    return precioMensual * meses;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final esAdminUsuarios = ref
            .watch(cobradorActualProvider)
            .valueOrNull
            ?.esAdminUsuarios ??
        false;
    final totalContrato = _calcularTotalContrato();
    final esIndefinido = totalContrato == null;
    final soloRecaudado = esIndefinido;

    return ref.watch(contratoRecaudadoProvider(contratoId)).when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (rows) {
        final recaudado = rows.isEmpty
            ? 0.0
            : ((rows.first['recaudado'] as num?) ?? 0).toDouble();
        final pendiente = rows.isEmpty
            ? 0.0
            : ((rows.first['cobrable'] as num?) ?? 0).toDouble();
        final real = recaudado + pendiente;
        final vivas = rows.isEmpty ? null : (rows.first['vivas'] as num?)?.toInt();
        final pagadas = rows.isEmpty ? 0 : (rows.first['pagadas'] as num?)?.toInt() ?? 0;
        final dm = duracionMeses;
        final ajustado = dm != null && vivas != null && vivas < dm;
        final progreso = real > 0 ? (recaudado / real).clamp(0.0, 1.0) : 0.0;

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  if (esAdminUsuarios) ...[
                    Expanded(
                      child: _ResumenItem(
                        label: 'Cuotas pagadas',
                        value: vivas == null ? '$pagadas' : '$pagadas/$vivas',
                        color: Colors.green.shade700,
                      ),
                    ),
                    Container(width: 1, height: 36, color: scheme.outline.withValues(alpha: 0.3)),
                    Expanded(
                      child: _ResumenItem(
                        label: 'Cuotas pendientes',
                        value: '${(vivas ?? 0) - pagadas}',
                        color: scheme.onSurface,
                      ),
                    ),
                  ] else if (soloRecaudado) ...[
                    if (!esAdminCobranza)
                      Expanded(
                        child: _ResumenItem(
                          label: esPrestamo ? 'Total amortizado' : 'Total recaudado',
                          value: Fmt.monto(recaudado, moneda),
                          color: Colors.green.shade700,
                        ),
                      ),
                    if (esAdminCobranza)
                      Expanded(
                        child: _ResumenItem(
                          label: 'Total pendiente',
                          value: Fmt.monto(pendiente, moneda),
                          color: pendiente > 0 ? scheme.error : scheme.outline,
                        ),
                      ),
                  ] else if (esAdminCobranza) ...[
                    Expanded(
                      child: _ResumenItem(
                        label: 'Total pendiente',
                        value: Fmt.monto(pendiente, moneda),
                        color: pendiente > 0 ? scheme.error : scheme.outline,
                      ),
                    ),
                  ] else ...[
                    Expanded(
                      child: _ResumenItem(
                        label: esPrestamo ? 'Total a pagar' : 'Total contrato',
                        value: Fmt.monto(real, moneda),
                        color: scheme.onSurface,
                        hint: ajustado ? 'ajustado' : null,
                      ),
                    ),
                    Container(width: 1, height: 36, color: scheme.outline.withValues(alpha: 0.3)),
                    Expanded(
                      child: _ResumenItem(
                        label: esPrestamo ? 'Amortizado' : 'Recaudado',
                        value: Fmt.monto(recaudado, moneda),
                        color: Colors.green.shade700,
                      ),
                    ),
                    Container(width: 1, height: 36, color: scheme.outline.withValues(alpha: 0.3)),
                    Expanded(
                      child: _ResumenItem(
                        label: 'Saldo pendiente',
                        value: Fmt.monto(pendiente, moneda),
                        color: pendiente > 0 ? scheme.error : scheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
              if (esPrestamo && !esAdminUsuarios && real > 0) ...[
                const SizedBox(height: 10),
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
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Avance: ${(progreso * 100).toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 10, color: scheme.outline),
                    ),
                    if (vivas != null)
                      Text(
                        '$pagadas de $vivas cuotas',
                        style: TextStyle(fontSize: 10, color: scheme.outline),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ResumenItem extends StatelessWidget {
  const _ResumenItem({
    required this.label,
    required this.value,
    required this.color,
    this.hint,
  });

  final String label;
  final String value;
  final Color color;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label,
            style: TextStyle(fontSize: 10, color: scheme.outline),
            textAlign: TextAlign.center),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 13, color: color),
            textAlign: TextAlign.center),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(hint!,
                style: TextStyle(fontSize: 9, color: scheme.outline),
                textAlign: TextAlign.center),
          ),
      ],
    );
  }
}

// Chips de fechas: Primera cuota / Última cuota + Día de pago / Frecuencia
class _ContratoFechasChips extends ConsumerWidget {
  const _ContratoFechasChips({
    required this.contratoId,
    required this.diaPago,
    required this.indefinido,
    this.frecuencia,
  });

  final String contratoId;
  final int diaPago;
  final bool indefinido;
  final String? frecuencia;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows =
        ref.watch(contratoCuotasProvider(contratoId)).valueOrNull ?? const [];
    DateTime? primera;
    DateTime? ultima;
    for (final r in rows) {
      if ((r['estado'] as String?) == 'anulada') continue;
      final v = r['fecha_vencimiento'] as String?;
      if (v == null) continue;
      final d = DateTime.tryParse(v);
      if (d == null) continue;
      if (primera == null || d.isBefore(primera)) primera = d;
      if (ultima == null || d.isAfter(ultima)) ultima = d;
    }
    return Row(
      children: [
        _DetailChip(
          icon: Icons.calendar_today,
          label: 'Primera cuota',
          value: primera != null ? Fmt.fechaCorta(primera) : '—',
        ),
        const SizedBox(width: 16),
        _DetailChip(
          icon: Icons.event_available,
          label: 'Última cuota',
          value: indefinido
              ? 'Indefinido'
              : (ultima != null ? Fmt.fechaCorta(ultima) : '—'),
        ),
        const SizedBox(width: 16),
        _DetailChip(
          icon: Icons.today,
          label: frecuencia != null ? 'Frecuencia' : 'Día de pago',
          value: frecuencia != null ? _frecuenciaLabel(frecuencia) : '$diaPago',
        ),
      ],
    );
  }
}

class _DetailChip extends StatelessWidget {
  const _DetailChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: scheme.outline),
              const SizedBox(width: 4),
              Flexible(
                child: Text(label,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}
