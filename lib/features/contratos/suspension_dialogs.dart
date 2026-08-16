import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/repositories/contratos_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../shared/widgets/deuda_contrato_bloque.dart';
import '../shared/widgets/selector_fecha_rapido.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';

/// Motivos predefinidos de suspensión (el detalle libre va en "Notas").
const List<String> kMotivosSuspension = [
  'Solicitud del cliente',
  'Falta de pago',
  'Suspensión por mantenimiento',
  'Otro',
];

/// Diálogo para SUSPENDER un contrato (admin/admin_cobranza). Motivo + notas
/// libres + fecha; muestra la deuda sobreviviente (preview = snapshot, vía
/// `ContratosRepo.previewDeudaSuspension`). Devuelve `true` por `Navigator.pop`
/// si se suspendió. Sin showDialog-como-loading: usa `_enviando` + overlay de
/// botones (checklist #7).
class SuspenderContratoDialog extends ConsumerStatefulWidget {
  const SuspenderContratoDialog({
    super.key,
    required this.contratoId,
    required this.precioMensual,
    this.diaPago,
    this.clienteNombre,
  });
  final String contratoId;
  final double precioMensual;
  final int? diaPago;
  final String? clienteNombre;

  @override
  ConsumerState<SuspenderContratoDialog> createState() =>
      _SuspenderContratoDialogState();
}

class _SuspenderContratoDialogState
    extends ConsumerState<SuspenderContratoDialog> {
  String _motivo = kMotivosSuspension.first;
  final _notasCtrl = TextEditingController();
  late DateTime _fecha;
  bool _enviando = false;
  Future<({double total, List<Map<String, dynamic>> cuotas})>? _deudaFuture;
  // Crédito por excedente (0127): la decisión sobre lo pagado por adelantado.
  Future<({double total, List<Map<String, dynamic>> cuotas})>? _excedenteFuture;
  String _disposicion = 'acreditar';
  final _motivoExcedenteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // UTC-6 (Nicaragua) para el día por defecto — un device con otro timezone o
    // entre 00-06h elegía el día calendario equivocado (regla #1b, audit 2026-06-30).
    _fecha = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    _recalcDeuda();
  }

  @override
  void dispose() {
    _notasCtrl.dispose();
    _motivoExcedenteCtrl.dispose();
    super.dispose();
  }

  void _recalcDeuda() {
    _deudaFuture = ContratosRepo().previewDeudaSuspension(
      contratoId: widget.contratoId,
      fechaSuspension: _fecha,
      precioMensual: widget.precioMensual,
    );
    _excedenteFuture = ContratosRepo().previewExcedente(
      contratoId: widget.contratoId,
      fechaCorte: _fecha,
      precioMensual: widget.precioMensual,
    );
  }

  Future<void> _elegirFecha() async {
    final f = await elegirFechaRapida(
      context,
      initialDate: _fecha,
      firstDate: DateTime(_fecha.year - 1),
      lastDate: DateTime(_fecha.year + 2),
      helpText: 'Fecha de suspensión',
    );
    if (f != null && mounted) {
      setState(() {
        _fecha = f;
        _recalcDeuda();
      });
    }
  }

  Future<void> _suspender() async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final tenantId = ref.read(tenantIdProvider);
    if (me == null || tenantId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se pudo identificar el usuario o el tenant.')));
      return;
    }
    final creditoOn = ref.read(appSettingsProvider).creditoExcedenteHabilitado;
    final motivoExc = _motivoExcedenteCtrl.text.trim();
    setState(() => _enviando = true);
    try {
      final suspId = await ContratosRepo().suspenderContrato(
        tenantId: tenantId,
        contratoId: widget.contratoId,
        cobradorId: me.id,
        fechaSuspension: _fecha,
        precioMensual: widget.precioMensual,
        motivo: _motivo,
        notas: _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text.trim(),
      );
      // Decisión sobre el excedente (no-op si no hay o el setting está OFF).
      if (creditoOn) {
        await ContratosRepo().registrarDisposicionExcedente(
          contratoId: widget.contratoId,
          fechaCorte: _fecha,
          precioMensual: widget.precioMensual,
          disposicion: _disposicion,
          cobradorId: me.id,
          origenEventoId: suspId,
          motivo: motivoExc.isEmpty ? null : motivoExc,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _enviando = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(mensajeErrorHumano(e, contexto: 'suspender el contrato'))));
      }
    }
  }

  // `_filaCuota` se mudó a `filaCuotaDeuda` (deuda_contrato_bloque.dart): era
  // un método privado de este State, así que ni el que PIDE la suspensión ni el
  // admin que la aprueba podían ver el desglose. Ahora los tres usan el mismo.

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final creditoOn = ref.watch(appSettingsProvider).creditoExcedenteHabilitado;
    return AlertDialog(
      title: const Text('Suspender contrato'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.clienteNombre != null)
                Text(widget.clienteNombre!,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              // Encabezado-guía "¿Qué va a pasar?" (UX admin_cobranza 2026-06-29):
              // explica el efecto en plata ANTES del formulario, en pasos.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('¿Qué va a pasar?',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: scheme.onSurface)),
                    const SizedBox(height: 4),
                    Text(
                        '1. Se cobra la deuda hasta hoy (la ves abajo).\n'
                        '2. Los meses futuros NO se facturan mientras esté suspendido.\n'
                        '3. Al reactivar, su fecha de pago mensual pasa a ser ese día (no estira el contrato).',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _motivo,
                decoration: const InputDecoration(
                    labelText: 'Motivo',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  for (final m in kMotivosSuspension)
                    DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: _enviando
                    ? null
                    : (v) {
                        if (v != null) setState(() => _motivo = v);
                      },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notasCtrl,
                enabled: !_enviando,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notas (opcional)',
                  hintText: 'Detalle del porqué…',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _enviando ? null : _elegirFecha,
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: 'Fecha de suspensión',
                      isDense: true,
                      border: OutlineInputBorder()),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(Fmt.fechaCorta(_fecha)),
                      Icon(Icons.calendar_today, size: 18, color: scheme.outline),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FutureBuilder<({double total, List<Map<String, dynamic>> cuotas})>(
                future: _deudaFuture,
                builder: (context, snap) => DeudaContratoBloque(
                  total: snap.data?.total ?? 0,
                  cuotas: snap.data?.cuotas ?? const [],
                  diaPago: widget.diaPago,
                  pieExtra: 'se guarda y se genera el PDF',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                  'Los meses suspendidos no se facturan. Al reactivar, su fecha de pago mensual pasa a ese día (no estira el contrato).',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
              if (creditoOn)
                FutureBuilder<({double total, List<Map<String, dynamic>> cuotas})>(
                  future: _excedenteFuture,
                  builder: (context, snap) {
                    final total = snap.data?.total ?? 0;
                    if (total <= 0.005) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: DisposicionExcedenteSelector(
                        total: total,
                        disposicion: _disposicion,
                        onDisposicion: (v) => setState(() => _disposicion = v),
                        motivoController: _motivoExcedenteCtrl,
                        enabled: !_enviando,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _enviando ? null : () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: _enviando ? null : _suspender,
          child: _enviando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Suspender'),
        ),
      ],
    );
  }
}

/// Diálogo para REACTIVAR un contrato suspendido. Fecha de reactivación (re-ancla
/// el día de pago); devuelve `true` por `Navigator.pop` si se reactivó.
class ReactivarContratoDialog extends ConsumerStatefulWidget {
  const ReactivarContratoDialog({
    super.key,
    required this.contratoId,
    required this.precioMensual,
    this.suspendidoEn,
  });
  final String contratoId;
  final double precioMensual;
  final DateTime? suspendidoEn;

  @override
  ConsumerState<ReactivarContratoDialog> createState() =>
      _ReactivarContratoDialogState();
}

class _ReactivarContratoDialogState
    extends ConsumerState<ReactivarContratoDialog> {
  late DateTime _fecha;
  late DateTime _minFecha;
  bool _enviando = false;

  @override
  void initState() {
    super.initState();
    // UTC-6 (Nicaragua) para el día por defecto/mínimo (regla #1b, audit 2026-06-30).
    final now = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    final susp = widget.suspendidoEn;
    // Se puede reactivar CUALQUIER día POSTERIOR a la suspensión (el mismo día →
    // Revertir). Espeja el guard del repo. Por defecto: hoy.
    _minFecha = susp != null
        ? DateTime(susp.year, susp.month, susp.day + 1)
        : DateTime(now.year - 1, now.month, now.day);
    _fecha = now.isAfter(_minFecha) ? now : _minFecha;
  }

  Future<void> _elegirFecha() async {
    final f = await elegirFechaRapida(
      context,
      initialDate: _fecha,
      firstDate: _minFecha,
      lastDate: DateTime(_fecha.year + 2),
      helpText: 'Fecha de reactivación',
    );
    if (f != null && mounted) setState(() => _fecha = f);
  }

  Future<void> _reactivar() async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se pudo identificar el usuario.')));
      return;
    }
    setState(() => _enviando = true);
    try {
      await ContratosRepo().reactivarContrato(
        contratoId: widget.contratoId,
        cobradorId: me.id,
        fechaReactivacion: _fecha,
        precioMensual: widget.precioMensual,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _enviando = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                mensajeErrorHumano(e, contexto: 'reactivar el contrato'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Reactivar contrato'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.suspendidoEn != null)
              Text('Suspendido desde el ${Fmt.fechaCorta(widget.suspendidoEn!)}',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            InkWell(
              onTap: _enviando ? null : _elegirFecha,
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Fecha de reactivación',
                    isDense: true,
                    border: OutlineInputBorder()),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(Fmt.fechaCorta(_fecha)),
                    Icon(Icons.calendar_today, size: 18, color: scheme.outline),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'El día de pago pasa a ${_fecha.day}. El servicio se reactiva desde '
                'esta fecha y se factura hasta el fin original del contrato (sin '
                'estirar). El tiempo en pausa no se cobra.',
                style: TextStyle(fontSize: 12, color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _enviando ? null : () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: _enviando ? null : _reactivar,
          child: _enviando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Reactivar'),
        ),
      ],
    );
  }
}

/// Bloque reusable (suspender + cancelar) para decidir el EXCEDENTE pagado por
/// adelantado: muestra "A favor C$X" + las 3 opciones (acreditar/devolver/
/// condonar) + motivo. El padre es dueño del estado (`disposicion`/motivo) y los
/// lee al confirmar. Solo se muestra si el setting está ON y el excedente > 0.
class DisposicionExcedenteSelector extends StatelessWidget {
  const DisposicionExcedenteSelector({
    super.key,
    required this.total,
    required this.disposicion,
    required this.onDisposicion,
    required this.motivoController,
    this.enabled = true,
  });

  final double total;
  final String disposicion; // 'acreditar' | 'devolver' | 'condonar'
  final ValueChanged<String> onDisposicion;
  final TextEditingController motivoController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget opcion(String value, IconData icon, String titulo, String sub) =>
        RadioListTile<String>(
          value: value,
          dense: true,
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          title: Row(children: [
            Icon(icon, size: 16, color: Colors.green.shade800),
            const SizedBox(width: 6),
            Text(titulo, style: const TextStyle(fontSize: 13)),
          ]),
          subtitle: Text(sub,
              style: TextStyle(fontSize: 11, color: Colors.green.shade800)),
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('A favor del cliente',
                  style:
                      TextStyle(fontSize: 12, color: Colors.green.shade900)),
              Text(Fmt.cordobas(total),
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.green.shade900)),
            ],
          ),
          Text('Pagó por adelantado servicio que no se prestará. ¿Qué hacés?',
              style: TextStyle(fontSize: 11, color: Colors.green.shade800)),
          const SizedBox(height: 4),
          IgnorePointer(
            ignoring: !enabled,
            child: RadioGroup<String>(
              groupValue: disposicion,
              onChanged: (String? v) {
                if (v != null) onDisposicion(v);
              },
              child: Column(
                children: [
                  opcion('acreditar', Icons.savings_outlined, 'Acreditar',
                      'Saldo a favor para sus próximas cuotas (no caduca).'),
                  opcion('devolver', Icons.payments_outlined,
                      'Devolver en efectivo',
                      'Sale de la caja. Genera comprobante de devolución.'),
                  opcion('condonar', Icons.volunteer_activism_outlined,
                      'Condonar',
                      'El cliente cede el saldo. Queda en caja, registrado.'),
                ],
              ),
            ),
          ),
          // Devolver = la ÚNICA opción donde sale plata real → repetir el monto
          // y avisar que baja la caja de hoy (audit UX 2026-06-30).
          if (disposicion == 'devolver')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.payments, size: 16, color: Colors.red.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Vas a entregar ${Fmt.cordobas(total)} en efectivo — '
                      'sale de la caja de hoy.',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.red.shade800),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: motivoController,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'Motivo (opcional)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}
