import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/repositories/cuotas_repo.dart';
import '../../data/utils/cobro_puntual.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/montos.dart';

/// Diálogo de **COBRO PUNTUAL** — un cargo de una vez con recibo aparte. Dos modos:
///  - **Admin** (desde el cliente): el admin elige el concepto (Multa / Otro
///    cargo) y el monto. `ticketId == null`.
///  - **Ticket** (desde un ticket RESUELTO cobrable): el concepto viene FIJO del
///    tipo de ticket; el monto viene precargado con el precio del tipo (editable);
///    el cobro queda LIGADO al ticket. `ticketId != null`.
/// Devuelve el id de la cuota creada (para enrutar al cobro). Sin
/// showDialog-como-loading (regla #7); bloqueado al impersonar (la atribución del
/// cobro es al usuario real).
Future<String?> mostrarCobroPuntual(
  BuildContext context, {
  required String clienteId,
  String? ticketId,
  String? tipoFijo,
  String? descripcionInicial,
  double? montoInicial,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CobroPuntualDialog(
      clienteId: clienteId,
      ticketId: ticketId,
      tipoFijo: tipoFijo,
      descripcionInicial: descripcionInicial,
      montoInicial: montoInicial,
    ),
  );
}

class _CobroPuntualDialog extends ConsumerStatefulWidget {
  const _CobroPuntualDialog({
    required this.clienteId,
    this.ticketId,
    this.tipoFijo,
    this.descripcionInicial,
    this.montoInicial,
  });
  final String clienteId;
  final String? ticketId;
  final String? tipoFijo;
  final String? descripcionInicial;
  final double? montoInicial;
  @override
  ConsumerState<_CobroPuntualDialog> createState() =>
      _CobroPuntualDialogState();
}

class _CobroPuntualDialogState extends ConsumerState<_CobroPuntualDialog> {
  late String _tipo;
  late final TextEditingController _montoCtrl;
  late final TextEditingController _descCtrl;
  // Mientras el usuario no edite la descripción a mano (modo admin), la
  // auto-completamos con la etiqueta del concepto elegido.
  bool _descTocada = false;
  bool _guardando = false;
  String? _error;

  bool get _esTicket => widget.ticketId != null;

  @override
  void initState() {
    super.initState();
    _tipo =
        _esTicket ? (widget.tipoFijo ?? 'otro') : kCobroPuntualAdminTipos.first;
    _montoCtrl =
        TextEditingController(text: _fmtMontoInicial(widget.montoInicial));
    _descCtrl = TextEditingController(
        text: widget.descripcionInicial ?? etiquetaCobroPuntual(_tipo));
  }

  static String _fmtMontoInicial(double? m) {
    if (m == null || m <= 0) return '';
    return m == m.roundToDouble() ? m.toInt().toString() : m.toString();
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _elegirTipo(String t) {
    setState(() {
      _tipo = t;
      if (!_descTocada) _descCtrl.text = etiquetaCobroPuntual(t);
    });
  }

  Future<void> _continuar() async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final tenantId = ref.read(tenantIdProvider);
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final monto = parseMonto(_montoCtrl.text);
    if (tenantId == null || me == null) {
      setState(() => _error = 'No se pudo identificar la sesión.');
      return;
    }
    if (monto == null || monto <= 0) {
      setState(() => _error = 'Ingresá un monto válido.');
      return;
    }
    if (_descCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Describí el cobro (qué se está cobrando).');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final cuotaId = await CuotasRepo().crearCuotaManual(
        tenantId: tenantId,
        clienteId: widget.clienteId,
        tipo: _tipo,
        monto: monto,
        descripcion: _descCtrl.text,
        creadoPorId: me.id,
        ticketId: widget.ticketId,
      );
      if (mounted) Navigator.pop(context, cuotaId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = mensajeErrorHumano(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_esTicket ? 'Generar cobro del ticket' : 'Cobrar multa o cargo'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Concepto: chips solo en modo ADMIN; en modo ticket viene fijo (lo
            // muestra la descripción precargada).
            if (!_esTicket) ...[
              const Text('Concepto',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in kCobroPuntualAdminTipos)
                    ChoiceChip(
                      label: Text(etiquetaCobroPuntual(t)),
                      selected: _tipo == t,
                      onSelected: _guardando ? null : (_) => _elegirTipo(t),
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: _montoCtrl,
              enabled: !_guardando,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [montoInputFormatter],
              decoration: const InputDecoration(
                labelText: 'Monto',
                prefixText: 'C\$ ',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _descCtrl,
              enabled: !_guardando,
              onChanged: (_) => _descTocada = true,
              decoration: const InputDecoration(
                labelText: 'Descripción (sale en el recibo)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(color: scheme.error, fontSize: 12.5)),
            ],
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _esTicket
                    ? 'Se cobra y se emite el recibo, ligado a este ticket.'
                    : 'Se crea el cargo y pasás al cobro (efectivo o dólares) '
                        'para emitir el recibo.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _continuar,
          child: _guardando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Continuar al cobro'),
        ),
      ],
    );
  }
}
