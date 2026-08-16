import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/pago.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/pagos_repo.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/busqueda_cliente.dart'
    show foldSqlExpr, tokensBusqueda;
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/cargar_mas_button.dart';
import '../../shared/widgets/historial_op_log.dart';
import '../../shared/widgets/empty_state.dart';

class PagosAdminScreen extends ConsumerStatefulWidget {
  const PagosAdminScreen({super.key});

  @override
  ConsumerState<PagosAdminScreen> createState() => _PagosAdminScreenState();
}

const int _kPageSize = 50;
const int _kSearchPageSize = 200;

class _PagosAdminScreenState extends ConsumerState<PagosAdminScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _verAnulados = false;
  Timer? _debounce;
  late Stream<List<Map<String, dynamic>>> _pagosStream;
  int _pageSize = _kPageSize;
  bool _loadingMore = false;
  Timer? _loadingMoreTimer;

  @override
  void initState() {
    super.initState();
    _pagosStream = _buildStream();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final where = <String>[];
    final params = <Object?>[];
    if (!_verAnulados) where.add('p.anulado = 0');
    if (_query.isNotEmpty) {
      // Búsqueda por TOKENS sobre nombre del cliente + número de recibo: cada
      // palabra debe matchear en alguno (OR), todas deben estar (AND), en
      // cualquier orden. Plegado ñ/acentos (#1d).
      final nombreExpr = foldSqlExpr('c.nombre');
      final reciboExpr = foldSqlExpr('r.numero_completo');
      for (final tok in tokensBusqueda(_query)) {
        where.add('($nombreExpr LIKE ? OR $reciboExpr LIKE ?)');
        final like = '%$tok%';
        params
          ..add(like)
          ..add(like);
      }
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    // LIMIT como último parámetro posicional.
    params.add(_pageSize);

    return ps.db.watch(
      '''
      SELECT p.id, p.cuota_id, p.monto_cordobas, p.vuelto_cordobas, p.moneda, p.monto_original,
             p.metodo, p.fecha_pago, p.referencia, p.notas,
             p.anulado, p.anulado_en, p.motivo_anulacion,
             p.grupo_cobro,
             -- Vuelto TOTAL del grupo (imputado a UN pago del grupo). Sirve para
             -- bloquear la edición de CUALQUIER pago de un grupo con vuelto: su
             -- vuelto propio puede ser 0 pero editarlo descuadra el grupo
             -- (audit 2026-06-30). NULL grupo_cobro → no matchea → 0.
             (SELECT COALESCE(SUM(p2.vuelto_cordobas), 0) FROM pagos p2
                WHERE p2.grupo_cobro = p.grupo_cobro AND p2.anulado = 0)
               AS grupo_vuelto,
             c.nombre AS cliente,
             co.nombre AS cobrador,
             r.numero_completo
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN cobradores co ON co.id = p.cobrador_id
   LEFT JOIN recibos r ON r.pago_id = p.id
       $whereSql
       ORDER BY p.fecha_pago DESC
       LIMIT ?
      ''',
      parameters: params,
    );
  }

  int get _baseSize => _query.isEmpty ? _kPageSize : _kSearchPageSize;

  void _onLoadMore() {
    setState(() {
      _pageSize += _baseSize;
      _loadingMore = true;
      _pagosStream = _buildStream();
    });
    _loadingMoreTimer?.cancel();
    _loadingMoreTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _loadingMore = false);
    });
  }

  void _resetPagination() {
    _pageSize = _baseSize;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    _loadingMoreTimer?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          // Guardar el término CRUDO (solo trim): `_buildStream` lo tokeniza con
          // `tokensBusqueda` (pliega ñ/acentos por token) y pliega las columnas
          // con `foldSqlExpr` (regla #1d). Es el único punto de plegado/split.
          _query = v.trim();
          _resetPagination();
          _pagosStream = _buildStream();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Pantalla opcional gateada por super_admin (cobranza.pantalla_pagos). Si
    // está OFF el menú no la muestra; este guard bloquea el acceso por URL
    // directa (defensa en profundidad — la RLS 0085 ya impide que el admin la
    // active). El super_admin la habilita desde el panel de settings.
    if (!ref.watch(appSettingsProvider).pantallaPagosHabilitada) {
      return const EmptyState(
        icon: Icons.lock_outline,
        titulo: 'Sección no habilitada',
        descripcion: 'Esta sección no está habilitada para tu empresa. '
            'El administrador del sistema puede activarla.',
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearch,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Buscar por cliente o número de recibo',
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {
                                _query = '';
                                _resetPagination();
                                _pagosStream = _buildStream();
                              });
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: const Text('Ver anulados'),
                selected: _verAnulados,
                onSelected: (v) => setState(() {
                  _verAnulados = v;
                  _resetPagination();
                  _pagosStream = _buildStream();
                }),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _pagosStream,
            initialData: const [],
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text(mensajeErrorHumano(snap.error!)));
              }
              final rows = snap.data!;
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.payments_outlined,
                  titulo: 'Sin pagos',
                );
              }
              final hayMas = rows.length >= _pageSize;
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: rows.length + (hayMas ? 1 : 0),
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  if (i == rows.length) {
                    return CargarMasButton(
                      loading: _loadingMore,
                      onPressed: _onLoadMore,
                    );
                  }
                  return _PagoCard(row: rows[i]);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PagoCard extends ConsumerWidget {
  const _PagoCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final anulado = (row['anulado'] as int? ?? 0) == 1;
    final fecha = DateTime.parse(row['fecha_pago'] as String);
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final settings = ref.watch(appSettingsProvider);
    final esAdmin = cobrador?.rol == 'admin';
    final puedeVerHistorial = esAdmin || settings.auditVisibleAdminCobranza;

    return Card(
      color: anulado ? scheme.surfaceContainerHighest.withValues(alpha: 0.5) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: anulado
                  ? scheme.outlineVariant
                  : scheme.primaryContainer,
              child: Icon(
                anulado ? Icons.block : _iconMetodo(row['metodo'] as String),
                color: anulado ? scheme.outline : scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          row['cliente'] as String,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            decoration: anulado ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            Fmt.cordobas(row['monto_cordobas'] as num),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              decoration: anulado ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          if (((row['vuelto_cordobas'] as num?) ?? 0) > 0)
                            Text(
                              '+ vuelto ${Fmt.cordobas(row['vuelto_cordobas'] as num)}',
                              style: TextStyle(
                                  color: scheme.outline, fontSize: 11),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      row['numero_completo'] ?? '—',
                      MetodoPago.fromString(row['metodo'] as String).label,
                      Fmt.fechaCorta(fecha),
                      if (row['cobrador'] != null) row['cobrador'],
                    ].join(' · '),
                    style: TextStyle(color: scheme.outline, fontSize: 12),
                  ),
                  // Monto entregado + moneda: se muestra cuando difiere del
                  // aplicado — pago en USD (otra moneda) o cuando hubo vuelto.
                  if ((row['moneda'] as String) == 'USD' ||
                      ((row['vuelto_cordobas'] as num?) ?? 0) > 0)
                    Text(
                      'Entregado: ${Fmt.monto(row['monto_original'] as num, row['moneda'] as String)}',
                      style: TextStyle(color: scheme.outline, fontSize: 12),
                    ),
                  if (row['grupo_cobro'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Cobro agrupado · Ref ${(row['grupo_cobro'] as String).substring(0, 8)}',
                          style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  if (anulado && row['motivo_anulacion'] != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Anulado: ${row['motivo_anulacion']}',
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (puedeVerHistorial)
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: 'Historial de cambios',
                onPressed: () => _verHistorial(context),
              ),
            // `lectura` (0198) no edita ni anula pagos: sin esto recorría
            // todo el flujo destructivo para que la guardia lo frenara al final.
            if (!anulado && !ref.watch(soloLecturaProvider)) ...[
              if (((row['vuelto_cordobas'] as num?) ?? 0) > 0)
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'No se puede editar: este pago tiene vuelto',
                  color: scheme.outline,
                  onPressed: () => _avisarVuelto(context),
                )
              // Pago de un cobro AGRUPADO con vuelto (aunque su vuelto propio sea
              // 0, el vuelto del grupo está en otro pago): editarlo descuadraría
              // el grupo. Se corrige anulando y recobrando (audit 2026-06-30).
              else if (((row['grupo_vuelto'] as num?) ?? 0) > 0)
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'No se puede editar: cobro agrupado con vuelto',
                  color: scheme.outline,
                  onPressed: () => _avisarGrupoVuelto(context),
                )
              // El editor solo maneja córdobas (monto C$ + método + notas);
              // editar un pago USD lo dejaría con monto_original=C$ y tasa=1.0,
              // corrompiendo el rastro de moneda (F1). Se deshabilita.
              else if ((row['moneda'] as String) == 'USD')
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'No se puede editar: pago en dólares',
                  color: scheme.outline,
                  onPressed: () => _avisarUsd(context),
                )
              else
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Editar pago',
                  onPressed: () => _editar(context, ref),
                ),
              IconButton(
                icon: const Icon(Icons.block),
                tooltip: 'Anular pago',
                onPressed: () => _anular(context, ref),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _verHistorial(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Historial de cambios',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                child: HistorialOpLog(
                  entidad: 'cuotas',
                  entidadId: row['cuota_id'] as String,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconMetodo(String m) => switch (m) {
        'efectivo' => Icons.payments,
        'transferencia' => Icons.swap_horiz,
        'deposito' => Icons.account_balance,
        'tarjeta' => Icons.credit_card,
        _ => Icons.payments,
      };

  void _avisarVuelto(BuildContext context) {
    final vuelto = (row['vuelto_cordobas'] as num?) ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Este pago tiene vuelto (${Fmt.cordobas(vuelto)}). Para corregirlo, '
          'anulalo y registrá el cobro de nuevo.',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _avisarGrupoVuelto(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Este pago es parte de un cobro agrupado que tiene vuelto. Editar uno '
          'solo descuadraría el grupo. Para corregirlo, anulá el cobro y '
          'registralo de nuevo.',
        ),
        duration: Duration(seconds: 5),
      ),
    );
  }

  void _avisarUsd(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Este pago fue en dólares. El editor solo maneja córdobas y '
          'perdería la conversión. Para corregirlo, anulalo y registrá el '
          'cobro de nuevo.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }

  Future<void> _editar(BuildContext context, WidgetRef ref) async {
    // No editar pagos del tenant mientras el super_admin impersona (M3).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;
    final resultado = await showDialog<_EditarPagoResult?>(
      context: context,
      builder: (_) => _EditarPagoDialog(
        montoActual: (row['monto_cordobas'] as num).toDouble(),
        metodoActual: MetodoPago.fromString(row['metodo'] as String),
        notasActuales: row['notas'] as String?,
      ),
    );
    if (resultado == null || !context.mounted) return;

    try {
      await ref.read(pagosRepoProvider).editarPago(
            pagoId: row['id'] as String,
            editadoPorId: me.id,
            montoCordobas: resultado.monto,
            montoOriginal: resultado.monto,
            tasaConversion: 1.0,
            metodo: resultado.metodo,
            notas: resultado.notas,
            limpiarNotas: resultado.notas == null,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pago editado')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          // M14: saca el "Exception: " a los guards del repo (su mensaje ya
          // viene en español) y humaniza los errores técnicos.
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
    }
  }

  Future<void> _anular(BuildContext context, WidgetRef ref) async {
    // No anular pagos del tenant mientras el super_admin impersona (M3).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => const _AnularDialog(),
    );
    if (motivo == null || motivo.trim().isEmpty || !context.mounted) return;

    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;

    try {
      await ref.read(pagosRepoProvider).anularPago(
            pagoId: row['id'] as String,
            anuladoPorId: me.id,
            motivo: motivo.trim(),
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pago anulado')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          // M14: ídem _editar — guards del repo pasan tal cual, técnico no.
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
    }
  }
}

class _AnularDialog extends StatefulWidget {
  const _AnularDialog();

  @override
  State<_AnularDialog> createState() => _AnularDialogState();
}

class _AnularDialogState extends State<_AnularDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anular pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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

/// Resultado de la edición de un pago (admin).
class _EditarPagoResult {
  const _EditarPagoResult({
    required this.monto,
    required this.metodo,
    this.notas,
  });
  final double monto;
  final MetodoPago metodo;
  final String? notas;
}

class _EditarPagoDialog extends StatefulWidget {
  const _EditarPagoDialog({
    required this.montoActual,
    required this.metodoActual,
    this.notasActuales,
  });
  final double montoActual;
  final MetodoPago metodoActual;
  final String? notasActuales;

  @override
  State<_EditarPagoDialog> createState() => _EditarPagoDialogState();
}

class _EditarPagoDialogState extends State<_EditarPagoDialog> {
  String? _montoError;
  late final TextEditingController _montoCtrl;
  late final TextEditingController _notasCtrl;
  late MetodoPago _metodo;

  @override
  void initState() {
    super.initState();
    _montoCtrl = TextEditingController(
      text: widget.montoActual.toStringAsFixed(2),
    );
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
              // M8: coma decimal aceptada; parse fallido avisa (antes mudo).
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
            decoration: const InputDecoration(
              labelText: 'Notas (opcional)',
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
            final monto = parseMonto(_montoCtrl.text);
            if (monto == null || monto <= 0) {
              setState(() => _montoError = 'Monto inválido');
              return;
            }
            Navigator.pop(
              context,
              _EditarPagoResult(
                monto: monto,
                metodo: _metodo,
                notas: _notasCtrl.text.trim().isEmpty
                    ? null
                    : _notasCtrl.text.trim(),
              ),
            );
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
