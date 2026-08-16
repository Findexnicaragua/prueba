import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/cuotas_repo.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';

/// Diálogo de CARGO extra (lo que SUMA: reconexión / otro). El ADMIN lo
/// abre desde el sheet de la cuota en el detalle del contrato (rediseño
/// 2026-06-12: el cobro quedó solo como referencia) y graba un cargos_extra
/// vía CuotasRepo.aplicarCargo — sin pago_id, así anular un cobro no lo
/// toca y se puede quitar desde el mismo sheet.
class CargoDialog extends ConsumerStatefulWidget {
  const CargoDialog({
    super.key,
    required this.cuotaId,
    required this.saldoActual,
  });

  final String cuotaId;
  final double saldoActual;

  @override
  ConsumerState<CargoDialog> createState() => _CargoDialogState();
}

class _CargoDialogState extends ConsumerState<CargoDialog> {
  /// true = reconexión, false = otro cargo.
  bool _esReconexion = false;
  final _valor = TextEditingController();
  final _descripcion = TextEditingController();
  bool _guardando = false;
  String? _error;
  bool _prefillHecho = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appSettingsProvider);
    if (s.reconexionHabilitada) {
      _esReconexion = true;
      _prefillReconexion(s);
    }
  }

  @override
  void dispose() {
    _valor.dispose();
    _descripcion.dispose();
    super.dispose();
  }

  void _prefillReconexion(AppSettings s) {
    // El setting es solo un default pre-poblado; el usuario puede editarlo.
    if (!_prefillHecho && s.montoReconexion > 0 && _valor.text.trim().isEmpty) {
      _valor.text = s.montoReconexion.toStringAsFixed(2);
      _prefillHecho = true;
    }
  }

  Future<void> _aplicar() async {
    if (ref.read(estaImpersonandoProvider)) {
      setState(() => _error =
          'No se pueden aplicar cargos mientras gestionás un tenant como super_admin.');
      return;
    }
    final v = parseMonto(_valor.text); // coma o punto decimal (M8)
    if (v == null || v <= 0) {
      setState(() => _error = 'Valor inválido');
      return;
    }
    final descripcion = _descripcion.text.trim();
    if (!_esReconexion && descripcion.isEmpty) {
      setState(() => _error = 'Describí el cargo (qué se está cobrando)');
      return;
    }
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) {
      setState(() => _error =
          'Tus datos de usuario todavía no cargaron. Probá de nuevo en unos segundos.');
      return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(cuotasRepoProvider).aplicarCargo(
            tenantId: me.tenantId,
            cuotaId: widget.cuotaId,
            tipo: _esReconexion ? 'reconexion' : 'otro',
            monto: v,
            descripcion: descripcion.isEmpty ? null : descripcion,
            aplicadoPorId: me.id,
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
    final s = ref.watch(appSettingsProvider);
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;

    final v = parseMonto(_valor.text);
    final monto = (v == null || v <= 0) ? null : v;

    return AlertDialog(
      title: const Text('Cargo extra'),
      content: SizedBox(
        width: dialogW,
        // Scroll: en 360px con teclado abierto el contenido no entra
        // (audit F4 — mismo patrón que DescuentoDialog).
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s.reconexionHabilitada) ...[
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: true, label: Text('Reconexión')),
                    ButtonSegment(value: false, label: Text('Otro cargo')),
                  ],
                  selected: {_esReconexion},
                  onSelectionChanged: (sel) => setState(() {
                    _esReconexion = sel.first;
                    if (_esReconexion) _prefillReconexion(s);
                  }),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _valor,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Monto (C\$)',
                  helperText: _esReconexion && s.montoReconexion > 0
                      ? 'Default: ${Fmt.cordobas(s.montoReconexion)}'
                      : null,
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [montoInputFormatter],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descripcion,
                decoration: InputDecoration(
                  labelText: _esReconexion ? 'Descripción' : 'Descripción *',
                  hintText: _esReconexion
                      ? 'Default: Cargo por reconexión'
                      : 'Ej. Cambio de equipo, instalación, etc.',
                ),
                maxLines: 2,
              ),
              // Preview: el cargo SUBE el saldo (en espejo del descuento).
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
                          : 'Cargo: +${Fmt.cordobas(monto)}\n'
                              'Saldo: ${Fmt.cordobas(widget.saldoActual)} → '
                              '${Fmt.cordobas(widget.saldoActual + monto)}',
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
          child: Text(_guardando ? 'Aplicando...' : 'Aplicar cargo'),
        ),
      ],
    );
  }
}
