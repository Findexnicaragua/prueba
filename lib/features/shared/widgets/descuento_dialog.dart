import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/cuotas_repo.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';

/// EL diálogo de descuento de la app (rediseño 2026-06-11/12): el ADMIN lo
/// abre desde el detalle del contrato (sheet de la cuota) y graba un
/// cargos_extra origen 'ajuste' o 'promo' vía CuotasRepo. Motivo SIEMPRE
/// obligatorio (con chips rápidos), preview del saldo antes de confirmar,
/// topes `ajuste_max_*`. El cobrador NO descuenta (decisión 2026-06-12: el
/// cobro solo referencia lo aplicado). El guard real es server-side
/// (trg_cargos_ajuste_guard, 0115/0117); acá se valida lo mismo para
/// feedback inmediato offline.
class DescuentoDialog extends ConsumerStatefulWidget {
  const DescuentoDialog({
    super.key,
    required this.cuotaId,
    required this.montoCuota,
    required this.saldoActual,
  });

  final String cuotaId;
  final double montoCuota;
  final double saldoActual;

  @override
  ConsumerState<DescuentoDialog> createState() => _DescuentoDialogState();
}

class _DescuentoDialogState extends ConsumerState<DescuentoDialog> {
  // Chips por semántica (audit F4): un ajuste es una corrección; una promo,
  // un beneficio — sugerir "Sin servicio" para una promo era contradictorio.
  static const _motivosAjuste = [
    'Sin servicio',
    'Promesa de pago',
    'Acuerdo con el cliente',
  ];
  static const _motivosPromo = [
    'Promo de temporada',
    'Cliente referido',
    'Acuerdo comercial',
  ];

  List<String> get _motivosRapidos =>
      _esPromo ? _motivosPromo : _motivosAjuste;

  bool _esPorcentaje = false;
  bool _esPromo = false;
  final _valor = TextEditingController();
  final _motivo = TextEditingController();
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _valor.dispose();
    _motivo.dispose();
    super.dispose();
  }

  double? _parseValor() {
    final v = parseMonto(_valor.text); // coma o punto decimal (M8)
    return (v == null || v <= 0) ? null : v;
  }

  /// Monto del descuento en C$ según el modo, o null si el input no parsea.
  double? get _montoDescuento {
    final v = _parseValor();
    if (v == null) return null;
    return _esPorcentaje ? widget.montoCuota * v / 100 : v;
  }

  Future<void> _aplicar() async {
    // Guard de impersonación: el cargo se atribuiría a la fila real del
    // super_admin (tenant System), no al impersonado.
    if (ref.read(estaImpersonandoProvider)) {
      setState(() => _error =
          'No se pueden aplicar descuentos mientras gestionás un tenant como super_admin.');
      return;
    }
    final s = ref.read(appSettingsProvider);

    final v = _parseValor();
    if (v == null) {
      setState(() => _error = 'Valor inválido');
      return;
    }
    if (_esPorcentaje && v > 100) {
      setState(() => _error = 'El porcentaje no puede exceder 100');
      return;
    }
    // Topes del súper (0 = sin tope) — espejo del guard server 0115/0117.
    if (_esPorcentaje && s.ajusteMaxPorcentaje > 0 && v > s.ajusteMaxPorcentaje) {
      setState(() => _error =
          'Excede el tope de ${s.ajusteMaxPorcentaje.toStringAsFixed(0)}% configurado');
      return;
    }
    final monto = _montoDescuento!;
    if (s.ajusteMaxMonto > 0 && monto > s.ajusteMaxMonto) {
      setState(() => _error =
          'Excede el tope de ${Fmt.cordobas(s.ajusteMaxMonto)} configurado');
      return;
    }
    if (monto > widget.saldoActual + 0.01) {
      setState(() => _error =
          'El descuento no puede exceder el saldo (${Fmt.cordobas(widget.saldoActual)})');
      return;
    }
    if (_motivo.text.trim().isEmpty) {
      setState(() => _error = 'El motivo es obligatorio');
      return;
    }
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) {
      // Audit F4: antes el return silencioso dejaba el botón "muerto".
      setState(() => _error =
          'Tus datos de usuario todavía no cargaron. Probá de nuevo en unos segundos.');
      return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(cuotasRepoProvider).aplicarAjuste(
            tenantId: me.tenantId,
            cuotaId: widget.cuotaId,
            esPorcentaje: _esPorcentaje,
            valor: v,
            motivo: _motivo.text,
            aplicadoPorId: me.id,
            origen: _esPromo ? 'promo' : 'ajuste',
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;

    final monto = _montoDescuento;
    final nuevoSaldo = monto == null
        ? null
        : (widget.saldoActual - monto).clamp(0.0, double.infinity);

    // Rótulo de paso (UX 2026-06-29): numerar la secuencia para un no-técnico.
    Widget paso(String t) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(t,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant)),
        );

    return AlertDialog(
      title: const Text('Descontar cuota'),
      content: SizedBox(
        width: dialogW,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Semántica clara ajuste vs promo (decisión Rubén 2026-06-11):
              // mismo flujo, etiqueta distinta en historial/recibo/reportes.
              paso('Paso 1 · ¿Qué tipo de descuento?'),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Ajuste')),
                  ButtonSegment(value: true, label: Text('Promo')),
                ],
                selected: {_esPromo},
                onSelectionChanged: (sel) =>
                    setState(() => _esPromo = sel.first),
              ),
              const SizedBox(height: 4),
              Text(
                _esPromo
                    ? 'Beneficio comercial — queda etiquetado como promoción.'
                    : 'Corrección puntual: días sin servicio, error, acuerdo.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.outline),
              ),
              const SizedBox(height: 12),
              paso('Paso 2 · ¿Cuánto?'),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Monto C\$')),
                  ButtonSegment(value: true, label: Text('Porcentaje %')),
                ],
                selected: {_esPorcentaje},
                onSelectionChanged: (sel) =>
                    setState(() => _esPorcentaje = sel.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _valor,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: _esPorcentaje
                      ? 'Porcentaje a descontar (0-100)'
                      : 'Monto a descontar (C\$)',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [montoInputFormatter],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              paso('Paso 3 · ¿Por qué?'),
              TextField(
                controller: _motivo,
                decoration: InputDecoration(
                  labelText: 'Motivo *',
                  hintText: _esPromo
                      ? 'Ej. Promo 3 meses a mitad de precio'
                      : 'Ej. Sin servicio 5 días',
                ),
                maxLines: 2,
                onChanged: (_) => setState(() {}),
              ),
              // Chips de motivos comunes: un toque y listo (el texto sigue
              // siendo editable).
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 0,
                children: [
                  for (final m in _motivosRapidos)
                    ActionChip(
                      label: Text(m, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _motivo.text = m),
                    ),
                ],
              ),
              // Preview SIEMPRE visible antes de confirmar (pedido de Rubén:
              // intuitivo y sin sorpresas contables).
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Resultado',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(
                      monto == null
                          ? 'Saldo actual: ${Fmt.cordobas(widget.saldoActual)}'
                          : 'Descuento: −${Fmt.cordobas(monto)}\n'
                              'Saldo: ${Fmt.cordobas(widget.saldoActual)} → '
                              '${Fmt.cordobas(nuevoSaldo!)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _aplicar,
          child: Text(_guardando ? 'Aplicando...' : 'Aplicar descuento'),
        ),
      ],
    );
  }
}
