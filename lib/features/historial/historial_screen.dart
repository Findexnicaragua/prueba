import 'dart:async';

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

class HistorialScreen extends ConsumerStatefulWidget {
  const HistorialScreen({super.key});

  @override
  ConsumerState<HistorialScreen> createState() => _HistorialScreenState();
}

/// Página inicial del historial; "Cargar más" agrega de a esta cantidad
/// (C12: antes era un LIMIT 100 fijo y los cobros viejos eran inalcanzables).
const int _kPageSize = 100;

class _HistorialScreenState extends ConsumerState<HistorialScreen> {
  // Cacheamos el stream de PowerSync en el state para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline);
  // solo se reconstruye al paginar, vía setState (patrón cuotas_admin).
  late Stream<List<Map<String, dynamic>>> _historialStream;
  int _pageSize = _kPageSize;
  bool _loadingMore = false;
  Timer? _loadingMoreTimer;

  @override
  void initState() {
    super.initState();
    _historialStream = _buildStream();
  }

  @override
  void dispose() {
    _loadingMoreTimer?.cancel();
    super.dispose();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    // M15: vuelto_cordobas y moneda alimentan el gate de edición (un pago
    // con vuelto o en moneda extranjera no se edita, igual que pagos_admin).
    return ps.db.watch(
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
       ORDER BY p.fecha_pago DESC
       LIMIT ?
      ''',
      parameters: [_pageSize],
    );
  }

  void _onLoadMore() {
    setState(() {
      _pageSize += _kPageSize;
      _loadingMore = true;
      _historialStream = _buildStream();
    });
    _loadingMoreTimer?.cancel();
    _loadingMoreTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _loadingMore = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historial de cobros')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _historialStream,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text(mensajeErrorHumano(snap.error!)));
          }
          // M11: sin initialData, el primer frame muestra carga en vez de
          // flashear "Sin cobros aún" antes de que llegue la data real.
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.history,
              titulo: 'Sin cobros aún',
              descripcion: 'Tus cobros van a aparecer acá.',
            );
          }
          final byDay = groupBy<Map<String, dynamic>, String>(
            rows,
            (r) => (r['fecha_pago'] as String).substring(0, 10),
          );
          // "Probablemente hay más" si trajimos exactamente _pageSize rows;
          // en el último tap puede traer 0 nuevos y el botón desaparece.
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
              );
            },
          );
        },
      ),
    );
  }
}

class _GrupoDia extends ConsumerWidget {
  const _GrupoDia({required this.dia, required this.total, required this.pagos});
  final DateTime dia;
  final double total;
  final List<Map<String, dynamic>> pagos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final puedeAnular = settings.cobradorAnulaCobros;
    final puedeEditar = settings.cobradorEditaCobros;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Row(
              children: [
                Text(
                  Fmt.fechaRelativa(dia),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Text(
                  Fmt.fechaCorta(dia),
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
                const Spacer(),
                Text(
                  Fmt.cordobas(total),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: pagos.mapIndexed((i, p) => Column(
                    children: [
                      if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
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
                            Text(
                              Fmt.cordobas(p['monto_cordobas'] as num),
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (puedeEditar) ...[
                              const SizedBox(width: 4),
                              // M15: mismos gates que pagos_admin — el editor
                              // solo maneja córdobas sin vuelto; editar un
                              // pago con vuelto o en otra moneda corrompería
                              // monto_original/tasa (deja tasa=1.0).
                              if (((p['vuelto_cordobas'] as num?) ?? 0) > 0)
                                IconButton(
                                  icon: Icon(Icons.edit, size: 20, color: scheme.outline),
                                  tooltip: 'No se puede editar: este pago tiene vuelto',
                                  onPressed: () => _avisarVuelto(context, p),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                                )
                              else if ((p['moneda'] as String? ?? 'NIO') != 'NIO')
                                IconButton(
                                  icon: Icon(Icons.edit, size: 20, color: scheme.outline),
                                  tooltip: 'No se puede editar: pago en moneda extranjera',
                                  onPressed: () => _avisarMoneda(context),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                                )
                              else
                                IconButton(
                                  icon: Icon(Icons.edit, size: 20, color: scheme.primary),
                                  tooltip: 'Editar pago',
                                  onPressed: () => _editar(context, ref, p),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  // M15: 32px quedaba bajo el mínimo táctil;
                                  // 40 + densidad compacta sin romper la fila.
                                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                                ),
                            ],
                            if (puedeAnular) ...[
                              const SizedBox(width: 4),
                              IconButton(
                                icon: Icon(Icons.block, size: 20, color: scheme.error),
                                tooltip: 'Anular pago',
                                onPressed: () => _anular(context, ref, p),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                              ),
                            ],
                          ],
                        ),
                        onTap: p['recibo_id'] != null
                            ? () {
                                // Si el pago es parte de un cobro agrupado,
                                // abrir el recibo COMBINADO (todas las cuotas
                                // del grupo + vuelto), no solo esta cuota.
                                final grupo = p['grupo_cobro'] as String?;
                                final ruta = grupo != null
                                    ? '/recibo/${p['recibo_id']}?grupo=$grupo'
                                    : '/recibo/${p['recibo_id']}';
                                context.push(ruta);
                              }
                            : null,
                      ),
                    ],
                  )).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editar(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> pago,
  ) async {
    // No editar pagos del tenant mientras el super_admin impersona (se
    // atribuiría a su identidad); consistente con pagos_admin_screen.
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

  // M15: avisos de los gates de edición (mismos textos que pagos_admin).
  void _avisarVuelto(BuildContext context, Map<String, dynamic> pago) {
    final vuelto = (pago['vuelto_cordobas'] as num?) ?? 0;
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

  void _avisarMoneda(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Este pago fue en moneda extranjera. El editor solo maneja córdobas '
          'y perdería la conversión. Para corregirlo, anulalo y registrá el '
          'cobro de nuevo.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }

  Future<void> _anular(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> pago,
  ) async {
    // Guard de impersonación (consistencia con cobro/cargo/visita): el
    // super_admin impersonando no opera en campo. anularPago no mueve tenant,
    // pero se bloquea por coherencia.
    if (ref.read(estaImpersonandoProvider)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'No se puede anular mientras gestionás un tenant como super_admin.'),
      ));
      return;
    }
    // M15: el diálogo dice a quién/cuánto se anula — con varios cobros del
    // día era fácil anular la fila equivocada sin darse cuenta.
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

  IconData _iconForMethod(String m) => switch (m) {
        'efectivo' => Icons.payments,
        'transferencia' => Icons.swap_horiz,
        'deposito' => Icons.account_balance,
        'tarjeta' => Icons.credit_card,
        _ => Icons.payments,
      };
}

/// Resultado de la edición de un cobro.
class _EditarCobroResult {
  const _EditarCobroResult({
    required this.monto,
    required this.metodo,
    this.notas,
  });
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
              // M8/M15: antes el parse fallido hacía return EN SILENCIO y
              // "Guardar" parecía colgado.
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
              _EditarCobroResult(
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

class _AnularCobroDialog extends StatefulWidget {
  const _AnularCobroDialog({
    required this.cliente,
    required this.monto,
    this.numeroRecibo,
  });

  /// M15: contexto de QUÉ se anula (cliente, monto y recibo) para que el
  /// cobrador confirme sobre el pago correcto.
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
