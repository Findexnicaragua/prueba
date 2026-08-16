import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/repositories/pagos_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/montos.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/cargar_mas_button.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/rango_fechas_dialog.dart';

class MisCobrosScreen extends ConsumerStatefulWidget {
  const MisCobrosScreen({super.key});

  @override
  ConsumerState<MisCobrosScreen> createState() => _MisCobrosScreenState();
}

const int _kPageSize = 100;

class _MisCobrosScreenState extends ConsumerState<MisCobrosScreen> {
  late Stream<List<Map<String, dynamic>>> _historialStream;
  late Stream<List<Map<String, dynamic>>> _resumenStream;
  int _pageSize = _kPageSize;
  bool _loadingMore = false;

  _RangoPreset _presetActivo = _RangoPreset.hoy;
  DateTimeRange? _rangoCustom;

  @override
  void initState() {
    super.initState();
    _rebuildStreams();
  }

  DateTimeRange get _rangoEfectivo {
    if (_presetActivo == _RangoPreset.custom && _rangoCustom != null) {
      return _rangoCustom!;
    }
    return _presetActivo.calcular();
  }

  void _rebuildStreams() {
    final r = _rangoEfectivo;
    final desde = r.start.toIso8601String().substring(0, 10);
    final hasta = r.end.toIso8601String().substring(0, 10);
    final miId = ref.read(cobradorActualProvider).valueOrNull?.id;

    _historialStream = ps.db.watch(
      '''
      SELECT p.id, p.monto_cordobas, p.vuelto_cordobas, p.moneda,
             p.monto_original, p.metodo, p.fecha_pago, p.notas, p.grupo_cobro,
             c.nombre AS cliente_nombre,
             r.id AS recibo_id, r.numero_completo
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN recibos r ON r.pago_id = p.id AND r.anulado = 0
       WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
         AND p.cobrador_id = ?
         AND date(p.fecha_pago) >= ?
         AND date(p.fecha_pago) <= ?
       ORDER BY p.fecha_pago DESC
       LIMIT ?
      ''',
      parameters: [miId, desde, hasta, _pageSize],
    );

    _resumenStream = ps.db.watch(
      '''
      SELECT
        COALESCE(SUM(monto_cordobas), 0) AS total,
        COUNT(*) AS qty,
        COALESCE(SUM(CASE WHEN metodo = 'efectivo' AND moneda = 'NIO'
                          THEN monto_cordobas ELSE 0 END), 0) AS efectivo_nio,
        COALESCE(SUM(CASE WHEN metodo = 'efectivo' AND moneda = 'USD'
                          THEN monto_cordobas ELSE 0 END), 0) AS efectivo_usd,
        COALESCE(SUM(CASE WHEN metodo = 'transferencia'
                          THEN monto_cordobas ELSE 0 END), 0) AS transferencia,
        COALESCE(SUM(CASE WHEN metodo = 'deposito'
                          THEN monto_cordobas ELSE 0 END), 0) AS deposito,
        COALESCE(SUM(CASE WHEN metodo = 'tarjeta'
                          THEN monto_cordobas ELSE 0 END), 0) AS tarjeta,
        COALESCE(SUM(vuelto_cordobas), 0) AS vuelto
      FROM pagos
      WHERE COALESCE(anulado, 0) = 0 AND COALESCE(en_revision, 0) = 0
        AND cobrador_id = ?
        AND date(fecha_pago) >= ?
        AND date(fecha_pago) <= ?
      ''',
      parameters: [miId, desde, hasta],
    );
  }

  void _seleccionarPreset(_RangoPreset p) {
    setState(() {
      _presetActivo = p;
      _pageSize = _kPageSize;
      _rebuildStreams();
    });
  }

  Future<void> _elegirRango() async {
    final r = await mostrarRangoFechas(context, inicial: _rangoCustom);
    if (r == null || !mounted) return;
    setState(() {
      _presetActivo = _RangoPreset.custom;
      _rangoCustom = r;
      _pageSize = _kPageSize;
      _rebuildStreams();
    });
  }

  void _onLoadMore() {
    setState(() {
      _pageSize += _kPageSize;
      _loadingMore = true;
      _rebuildStreams();
    });
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _loadingMore = false);
    });
  }

  String get _rangoLabel {
    if (_presetActivo != _RangoPreset.custom) return _presetActivo.label;
    if (_rangoCustom == null) return 'Periodo';
    return '${Fmt.fechaCorta(_rangoCustom!.start)} — ${Fmt.fechaCorta(_rangoCustom!.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final puedeAnular = settings.cobradorAnulaCobros;
    final puedeEditar = settings.cobradorEditaCobros;

    return Column(
      children: [
        // Filtro de presets
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              for (final p in _RangoPreset.values.where((p) => p != _RangoPreset.custom))
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.label),
                    selected: _presetActivo == p,
                    onSelected: (_) => _seleccionarPreset(p),
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.calendar_today, size: 16),
                label: Text(_presetActivo == _RangoPreset.custom
                    ? _rangoLabel
                    : 'Elegir'),
                onPressed: _elegirRango,
              ),
            ],
          ),
        ),

        // Resumen
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _resumenStream,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final r = snap.data!.first;
            final total = r['total'] as num;
            final qty = (r['qty'] as num).toInt();
            final efectivoNio = r['efectivo_nio'] as num;
            final efectivoUsd = r['efectivo_usd'] as num;
            final transferencia = r['transferencia'] as num;
            final deposito = r['deposito'] as num;
            final tarjeta = r['tarjeta'] as num;
            final vuelto = r['vuelto'] as num;

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  // Total
                  Card(
                    color: scheme.primaryContainer.withValues(alpha: 0.3),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_rangoLabel,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: scheme.onSurfaceVariant,
                                    )),
                                const SizedBox(height: 4),
                                Text(Fmt.cordobas(total),
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w600)),
                                Text('$qty cobros',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                    )),
                              ],
                            ),
                          ),
                          Icon(Icons.account_balance_wallet,
                              size: 36, color: scheme.primary.withValues(alpha: 0.5)),
                        ],
                      ),
                    ),
                  ),
                  // Desglose por método (solo si hay 2+ con datos)
                  Builder(builder: (_) {
                    final pills = <(String, num)>[
                      if (efectivoNio > 0) ('Efectivo', efectivoNio),
                      if (efectivoUsd > 0) ('USD', efectivoUsd),
                      if (transferencia > 0) ('Transfer.', transferencia),
                      if (deposito > 0) ('Depósito', deposito),
                      if (tarjeta > 0) ('Tarjeta', tarjeta),
                    ];
                    if (pills.length < 2) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          for (var i = 0; i < pills.length; i++) ...[
                            if (i > 0) const SizedBox(width: 6),
                            _MetodoPill(pills[i].$1, pills[i].$2, scheme),
                          ],
                        ],
                      ),
                    );
                  }),
                  if (vuelto > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Vuelto entregado: ${Fmt.cordobas(vuelto)}',
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                ],
              ),
            );
          },
        ),

        const SizedBox(height: 8),
        const Divider(height: 1, indent: 16, endIndent: 16),

        // Lista de pagos agrupados por día
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _historialStream,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text(mensajeErrorHumano(snap.error!)));
              }
              if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.receipt_long,
                  titulo: 'Sin cobros en este periodo',
                  descripcion: 'Elegí otro rango o registrá un cobro.',
                );
              }
              final byDay = groupBy<Map<String, dynamic>, String>(
                rows,
                (r) => (r['fecha_pago'] as String).substring(0, 10),
              );
              final hayMas = rows.length >= _pageSize;

              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: byDay.length + (hayMas ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == byDay.length) {
                    return CargarMasButton(
                      loading: _loadingMore,
                      onPressed: _onLoadMore,
                    );
                  }
                  final entry = byDay.entries.elementAt(i);
                  final dia = DateTime.parse(entry.key);
                  final total = entry.value.fold<double>(
                    0,
                    (sum, r) => sum + (r['monto_cordobas'] as num).toDouble(),
                  );
                  return _GrupoDia(
                    dia: dia,
                    total: total,
                    pagos: entry.value,
                    puedeEditar: puedeEditar,
                    puedeAnular: puedeAnular,
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

// ── Presets de rango ─────────────────────────────────────────────────────────

enum _RangoPreset {
  hoy,
  semana,
  mes,
  custom;

  String get label => switch (this) {
        hoy => 'Hoy',
        semana => 'Esta semana',
        mes => 'Este mes',
        custom => 'Periodo',
      };

  DateTimeRange calcular() {
    final now = DateTime.now();
    final h = DateTime(now.year, now.month, now.day);
    return switch (this) {
      hoy => DateTimeRange(start: h, end: h),
      semana => DateTimeRange(
          start: h.subtract(Duration(days: h.weekday - 1)), end: h),
      mes => DateTimeRange(start: DateTime(h.year, h.month, 1), end: h),
      custom => DateTimeRange(start: h, end: h),
    };
  }
}

// ── Pill de método de pago ──────────────────────────────────────────────────

class _MetodoPill extends StatelessWidget {
  const _MetodoPill(this.label, this.monto, this.scheme);
  final String label;
  final num monto;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(label,
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
            Text(Fmt.cordobas(monto),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// ── Grupo de pagos por día ──────────────────────────────────────────────────

class _GrupoDia extends ConsumerWidget {
  const _GrupoDia({
    required this.dia,
    required this.total,
    required this.pagos,
    required this.puedeEditar,
    required this.puedeAnular,
  });
  final DateTime dia;
  final double total;
  final List<Map<String, dynamic>> pagos;
  final bool puedeEditar;
  final bool puedeAnular;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Row(
              children: [
                Text(Fmt.fechaRelativa(dia),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text(Fmt.fechaCorta(dia),
                    style: TextStyle(color: scheme.outline, fontSize: 12)),
                const Spacer(),
                Text(Fmt.cordobas(total),
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: scheme.primary)),
              ],
            ),
          ),
          Card(
            child: Column(
              children: pagos.mapIndexed((i, p) {
                return Column(
                  children: [
                    if (i > 0)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      dense: true,
                      leading: Icon(_iconForMethod(p['metodo'] as String)),
                      title: Text(p['cliente_nombre'] as String),
                      subtitle: Text(
                        [
                          MetodoPago.fromString(p['metodo'] as String).label,
                          if (p['numero_completo'] != null) p['numero_completo'],
                        ].join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(Fmt.cordobas(p['monto_cordobas'] as num),
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (puedeEditar) ...[
                            const SizedBox(width: 4),
                            if (((p['vuelto_cordobas'] as num?) ?? 0) > 0)
                              _editIcon(context, scheme.outline,
                                  'No se puede editar: este pago tiene vuelto',
                                  () => _avisarVuelto(context, p))
                            else if ((p['moneda'] as String? ?? 'NIO') != 'NIO')
                              _editIcon(context, scheme.outline,
                                  'No se puede editar: pago en moneda extranjera',
                                  () => _avisarMoneda(context))
                            else
                              _editIcon(context, scheme.primary, 'Editar pago',
                                  () => _editar(context, ref, p)),
                          ],
                          if (puedeAnular) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              icon: Icon(Icons.block, size: 20, color: scheme.error),
                              tooltip: 'Anular pago',
                              onPressed: () => _anular(context, ref, p),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 40, minHeight: 40),
                            ),
                          ],
                        ],
                      ),
                      onTap: p['recibo_id'] != null
                          ? () {
                              final grupo = p['grupo_cobro'] as String?;
                              final ruta = grupo != null
                                  ? '/recibo/${p['recibo_id']}?grupo=$grupo'
                                  : '/recibo/${p['recibo_id']}';
                              context.push(ruta);
                            }
                          : null,
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editIcon(BuildContext ctx, Color color, String tooltip, VoidCallback onPressed) {
    return IconButton(
      icon: Icon(Icons.edit, size: 20, color: color),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    );
  }

  Future<void> _editar(BuildContext context, WidgetRef ref, Map<String, dynamic> pago) async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final resultado = await showDialog<_EditarCobroResult?>(
      context: context,
      builder: (_) => _EditarCobroDialog(
        montoActual: (pago['monto_cordobas'] as num).toDouble(),
        metodoActual: MetodoPago.fromString(pago['metodo'] as String),
        notasActuales: pago['notas'] as String?,
      ),
    );
    if (resultado == null || !context.mounted) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;
    try {
      await ref.read(pagosRepoProvider).editarPago(
            pagoId: pago['id'] as String,
            editadoPorId: me.id,
            montoCordobas: resultado.monto,
            montoOriginal: resultado.monto,
            tasaConversion: 1.0,
            metodo: resultado.metodo,
            notas: resultado.notas,
            limpiarNotas: resultado.notas == null,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Pago editado')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }

  void _avisarVuelto(BuildContext context, Map<String, dynamic> pago) {
    final vuelto = (pago['vuelto_cordobas'] as num?) ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        'Este pago tiene vuelto (${Fmt.cordobas(vuelto)}). Para corregirlo, '
        'anulalo y registrá el cobro de nuevo.',
      ),
      duration: const Duration(seconds: 4),
    ));
  }

  void _avisarMoneda(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text(
        'Este pago fue en moneda extranjera. El editor solo maneja córdobas '
        'y perdería la conversión. Para corregirlo, anulalo y registrá el '
        'cobro de nuevo.',
      ),
      duration: Duration(seconds: 4),
    ));
  }

  Future<void> _anular(BuildContext context, WidgetRef ref, Map<String, dynamic> pago) async {
    if (ref.read(estaImpersonandoProvider)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'No se puede anular mientras gestionás un tenant como super_admin.'),
      ));
      return;
    }
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => _AnularCobroDialog(
        cliente: pago['cliente_nombre'] as String,
        monto: (pago['monto_cordobas'] as num).toDouble(),
        numeroRecibo: pago['numero_completo'] as String?,
      ),
    );
    if (motivo == null || motivo.trim().isEmpty || !context.mounted) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;
    try {
      await ref.read(pagosRepoProvider).anularPago(
            pagoId: pago['id'] as String,
            anuladoPorId: me.id,
            motivo: motivo.trim(),
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Pago anulado')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }

  IconData _iconForMethod(String m) => switch (m) {
        'efectivo' => Icons.payments,
        'transferencia' => Icons.swap_horiz,
        'deposito' => Icons.account_balance,
        'tarjeta' => Icons.credit_card,
        _ => Icons.payments,
      };
}

// ── Diálogos (reutilizados de historial_screen) ─────────────────────────────

class _EditarCobroResult {
  const _EditarCobroResult({required this.monto, required this.metodo, this.notas});
  final double monto;
  final MetodoPago metodo;
  final String? notas;
}

class _EditarCobroDialog extends StatefulWidget {
  const _EditarCobroDialog({
    required this.montoActual,
    required this.metodoActual,
    this.notasActuales,
  });
  final double montoActual;
  final MetodoPago metodoActual;
  final String? notasActuales;

  @override
  State<_EditarCobroDialog> createState() => _EditarCobroDialogState();
}

class _EditarCobroDialogState extends State<_EditarCobroDialog> {
  String? _montoError;
  late final TextEditingController _montoCtrl;
  late final TextEditingController _notasCtrl;
  late MetodoPago _metodo;

  @override
  void initState() {
    super.initState();
    _montoCtrl = TextEditingController(text: widget.montoActual.toStringAsFixed(2));
    _notasCtrl = TextEditingController(text: widget.notasActuales ?? '');
    _metodo = widget.metodoActual;
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _montoCtrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [montoInputFormatter],
            decoration: InputDecoration(
              labelText: 'Monto (C\$)',
              prefixText: 'C\$ ',
              errorText: _montoError,
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<MetodoPago>(
            initialValue: _metodo,
            decoration: const InputDecoration(labelText: 'Método de pago'),
            items: MetodoPago.values
                .map((m) => DropdownMenuItem(value: m, child: Text(m.label)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _metodo = v);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _notasCtrl,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Notas (opcional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final monto = parseMonto(_montoCtrl.text);
            if (monto == null || monto <= 0) {
              setState(() => _montoError = 'Monto inválido');
              return;
            }
            Navigator.pop(
              context,
              _EditarCobroResult(
                monto: monto,
                metodo: _metodo,
                notas: _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text.trim(),
              ),
            );
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _AnularCobroDialog extends StatefulWidget {
  const _AnularCobroDialog({
    required this.cliente,
    required this.monto,
    this.numeroRecibo,
  });
  final String cliente;
  final double monto;
  final String? numeroRecibo;

  @override
  State<_AnularCobroDialog> createState() => _AnularCobroDialogState();
}

class _AnularCobroDialogState extends State<_AnularCobroDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recibo =
        widget.numeroRecibo != null ? ' (recibo ${widget.numeroRecibo})' : '';
    return AlertDialog(
      title: const Text('Anular pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Anular pago de ${widget.cliente} por '
            '${Fmt.cordobas(widget.monto)}$recibo.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
              'Esta acción queda registrada en auditoría. La cuota volverá '
              'a su estado anterior y el recibo emitido queda inválido. '
              'Para volver a cobrar, registrá el cobro de nuevo desde la cuota.'),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo de anulación *',
              hintText: 'Ej. Monto incorrecto, registrado por error...',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (_ctrl.text.trim().isEmpty) return;
            Navigator.pop(context, _ctrl.text);
          },
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          child: const Text('Anular'),
        ),
      ],
    );
  }
}
