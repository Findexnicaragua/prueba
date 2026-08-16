import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/deuda_snapshot.dart';
import '../../../data/models/solicitud_accion.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/solicitudes_repo.dart';
import 'deuda_contrato_bloque.dart';

/// Motivos predefinidos para las solicitudes de aprobación (suspender/cancelar).
/// El detalle específico va SIEMPRE en "Notas" (obligatorio — el tenant pidió
/// que toda solicitud lleve un motivo escrito).
const List<String> kMotivosSolicitud = [
  'Solicitud del cliente',
  'Falta de pago',
  'Mudanza / cambio de domicilio',
  'Otro',
];

Future<bool> solicitarAccion({
  required BuildContext context,
  required WidgetRef ref,
  required TipoSolicitud tipo,
  required String entidadId,
  Map<String, dynamic> datos = const {},
  String? descripcionExtra,
  List<String> motivos = kMotivosSolicitud,
  DeudaSnapshot? deuda,
}) async {
  final yo = ref.read(cobradorActualProvider).valueOrNull;
  if (yo == null) return false;

  final label = _labelTipo(tipo);
  // Motivo (dropdown) + notas, AMBOS obligatorios: sin notas no se puede enviar.
  final resultado = await showDialog<({String motivo, String notas})>(
    context: context,
    builder: (dctx) {
      var motivo = motivos.first;
      final notasCtrl = TextEditingController();
      String? errorNotas;
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          icon: Icon(Icons.approval, color: Colors.orange.shade700),
          title: Text('Solicitar: $label'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Esta acción requiere aprobación de un administrador.'),
                if (descripcionExtra != null) ...[
                  const SizedBox(height: 8),
                  Text(descripcionExtra, style: const TextStyle(fontSize: 13)),
                ],
                // Deuda que va a quedar cobrable después del corte. Se ve ANTES
                // del formulario: es el dato que hace la diferencia entre pedir
                // una suspensión con criterio y pedirla a ciegas. Sin `pieExtra`
                // — a diferencia del diálogo de suspensión directa, acá no se
                // guarda nada ni se genera ningún PDF, solo se pide.
                if (deuda != null) ...[
                  const SizedBox(height: 12),
                  DeudaContratoBloque(
                    total: deuda.total,
                    cuotas: deuda.cuotas,
                    diaPago: deuda.diaPago,
                    titulo: 'Deuda que quedaría cobrable',
                    vacioTexto: 'No queda deuda cobrable.',
                  ),
                ],
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: motivo,
                  decoration: const InputDecoration(
                      labelText: 'Motivo',
                      isDense: true,
                      border: OutlineInputBorder()),
                  items: [
                    for (final m in motivos)
                      DropdownMenuItem(value: m, child: Text(m)),
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => motivo = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notasCtrl,
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Notas',
                    hintText: 'Explicá el motivo…',
                    isDense: true,
                    border: const OutlineInputBorder(),
                    errorText: errorNotas,
                  ),
                  onChanged: (_) {
                    if (errorNotas != null) setLocal(() => errorNotas = null);
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  'El motivo y las notas son obligatorios. Recibirás una '
                  'notificación cuando sea procesada.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.send, size: 18),
              label: const Text('Enviar solicitud'),
              onPressed: () {
                final notas = notasCtrl.text.trim();
                if (notas.isEmpty) {
                  setLocal(
                      () => errorNotas = 'Escribí el motivo (obligatorio).');
                  return;
                }
                Navigator.of(dctx).pop((motivo: motivo, notas: notas));
              },
            ),
          ],
        ),
      );
    },
  );

  if (resultado == null || !context.mounted) return false;

  try {
    await ref.read(solicitudesRepoProvider).crear(
          tenantId: yo.tenantId,
          solicitanteId: yo.id,
          tipo: tipo,
          entidadId: entidadId,
          // `datos` queda SOLO para el payload de la entidad (su `notas` son
          // las del CONTRATO, contrato_form_screen). El motivo/notas de la
          // SOLICITUD van a sus columnas propias (0222): meterlos en el mismo
          // mapa fue el bug de v0.31.20 — se pisaban entre sí.
          datos: datos,
          motivo: resultado.motivo,
          notas: resultado.notas,
          deudaSnapshot: deuda,
          solicitanteLabel: yo.nombre,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Solicitud de "$label" enviada'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al enviar solicitud: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
    return false;
  }
}

/// Delegado al modelo: era una COPIA literal de `SolicitudAccion.tipoLabel`.
String _labelTipo(TipoSolicitud tipo) => SolicitudAccion.tipoLabelDe(tipo);
