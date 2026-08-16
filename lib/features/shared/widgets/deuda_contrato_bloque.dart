import 'package:flutter/material.dart';

import '../../../data/utils/formatters.dart';

/// Bloque "Deuda a la fecha": total + desglose mes por mes de lo que va a
/// quedar COBRABLE si se suspende o cancela el contrato.
///
/// Vive acá porque lo comparten tres pantallas que tienen que mostrar el MISMO
/// número: el diálogo de suspensión directa, el diálogo de solicitud (para el
/// rol que necesita aprobación) y la tarjeta donde el admin aprueba. Antes era
/// un método privado del State del diálogo de suspensión — o sea que el que
/// pedía permiso y el que aprobaba no veían nada.
///
/// Los datos salen siempre de `ContratosRepo.previewDeudaSuspension` (o su
/// gemela de cancelación, que delega en la misma función). NUNCA de
/// `contratoRecaudadoProvider.cobrable`: ése es la deuda viva TOTAL, sin
/// clasificar por ventana de servicio, así que incluye los meses futuros que la
/// suspensión va a anular. Mezclarlos daría una diferencia enorme y falsa.
class DeudaContratoBloque extends StatelessWidget {
  const DeudaContratoBloque({
    super.key,
    required this.total,
    required this.cuotas,
    required this.diaPago,
    this.titulo = 'Deuda a la fecha',
    this.vacioTexto = 'Sin deuda a la fecha.',
    this.pieExtra,
    this.compacto = false,
  });

  final double total;
  final List<Map<String, dynamic>> cuotas;
  final int? diaPago;
  final String titulo;
  final String vacioTexto;

  /// Se anexa al pie después del conteo de cuotas. El diálogo de suspensión
  /// directa avisa acá que se genera el PDF; el de SOLICITUD no debe decirlo
  /// (pedir no guarda ni imprime nada).
  final String? pieExtra;

  /// Sin desglose por cuota, solo el total y el conteo. Para la tarjeta de
  /// aprobación, donde el detalle mes a mes tapa el resto del pedido.
  final bool compacto;

  @override
  Widget build(BuildContext context) {
    final n = cuotas.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(titulo,
                  style:
                      TextStyle(fontSize: 12, color: Colors.orange.shade900)),
              Text(Fmt.cordobas(total),
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.orange.shade900)),
            ],
          ),
          if (!compacto)
            for (final c in cuotas) filaCuotaDeuda(context, c, diaPago),
          if (n == 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(vacioTexto,
                  style:
                      TextStyle(fontSize: 12, color: Colors.orange.shade800)),
            ),
          // El pie sale también con 0 cuotas cuando hay `pieExtra`: ahí está el
          // aviso de que la suspensión igual se guarda y genera el PDF. Sin él,
          // suspender un contrato al día se leía como si no fuera a pasar nada.
          if (n > 0 || pieExtra != null) ...[
            const SizedBox(height: 8),
            Text(
              [
                if (n > 0) '$n ${n == 1 ? "cuota" : "cuotas"}',
                if (pieExtra != null) pieExtra!,
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
            ),
          ],
        ],
      ),
    );
  }
}

/// Fila del desglose: mes de servicio + (vence · prorrateo · abono) + saldo.
///
/// El prorrateo del mes en curso y el abono parcial se muestran para poder
/// explicárselo al cliente. El mes se rotula con `diaPago` porque el "mes de
/// servicio" es la ventana anclada al día de pago, NO el mes calendario
/// (regla #1c): con `dia_pago = 15`, el período que arranca el 15/07 es
/// "agosto", no "julio".
Widget filaCuotaDeuda(
    BuildContext context, Map<String, dynamic> c, int? diaPago) {
  final periodo = DateTime.parse(c['periodo'] as String);
  final saldo = (c['saldo'] as num).toDouble();
  final pagado = (c['monto_pagado'] as num?)?.toDouble() ?? 0;
  final mesLabel = Fmt.mesServicioLabel(periodo, diaPago);
  final vencRaw = c['fecha_vencimiento'] as String?;
  // El período EN CURSO (su ventana de servicio contiene la fecha) lo marca el
  // preview con `en_curso` + días reales del ciclo. NO se infiere por mes
  // calendario.
  final enCurso = c['en_curso'] == true;
  final diasCons = (c['dias_consumidos'] as num?)?.toInt();
  final diasCiclo = (c['dias_ciclo'] as num?)?.toInt();
  final detalle = <String>[
    if (vencRaw != null) 'vence ${Fmt.fechaCorta(DateTime.parse(vencRaw))}',
    if (enCurso && diasCons != null && diasCiclo != null)
      'prorrateado $diasCons/$diasCiclo días',
    if (pagado > 0.009) 'abonó ${Fmt.cordobas(pagado)}',
  ];
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(mesLabel, style: const TextStyle(fontSize: 13)),
              if (detalle.isNotEmpty)
                Text(detalle.join(' · '),
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(Fmt.cordobas(saldo), style: const TextStyle(fontSize: 13)),
      ],
    ),
  );
}
