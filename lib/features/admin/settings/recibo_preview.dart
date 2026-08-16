import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/logo_empresa_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../recibo/recibo_ticket.dart';

/// Vista previa EN VIVO del recibo en la tab Recibos de settings (#8a).
///
/// Renderiza el MISMO widget `ReciboTicket` que ve el cobrador, con datos de
/// EJEMPLO, y se actualiza al instante cuando el admin cambia cualquier ajuste
/// del recibo (título, logo, monto en letras, pie, WhatsApp, ancho, etc.).
/// Así el "diseñador" es visual: el admin ve lo que configura sin imprimir.
class ReciboPreview extends ConsumerWidget {
  const ReciboPreview({super.key});

  /// Ancho en píxeles para simular la tira térmica (80mm≈300, 58mm≈215).
  /// Cualquier ancho que no sea 80 (incl. el legacy 57) se trata como angosto.
  static double _previewWidthPx(int formatoMm) => formatoMm != 80 ? 215 : 300;

  /// Fila de ejemplo con TODOS los campos que lee `ReciboTicket`. Cobro en
  /// efectivo de una cuota mensual con un ajuste y una reconexión (para que
  /// los sub-toggles de descuentos se vean en vivo), sin vuelto. La
  /// matemática cierra: 500 − descuento + reconexión = cobrados, saldo 0.
  Map<String, dynamic> _sampleRow(AppSettings settings) {
    final ahora = DateTime.now();
    final periodo = DateTime(ahora.year, ahora.month, 1);
    const cuotaMonto = 500.0;
    final descuento = settings.ajustesHabilitados ? 50.0 : 0.0;
    final reconexion = settings.reconexionHabilitada ? 100.0 : 0.0;
    final cargosNeto = reconexion - descuento;
    final montoCordobas = cuotaMonto + cargosNeto;

    return {
      'numero_completo': 'A-000123',
      'reimpresiones': 0,
      'impreso_en': null,
      'monto_cordobas': montoCordobas,
      'vuelto_cordobas': 0.0,
      'moneda': 'NIO',
      'monto_original': montoCordobas,
      'tasa_conversion': 1.0,
      'metodo': 'efectivo',
      'referencia': null,
      'fecha_pago': ahora.toIso8601String(),
      'periodo': periodo.toIso8601String(),
      'cuota_id': 'cuota-ejemplo',
      'cuota_monto': cuotaMonto,
      'monto_pagado_cuota': montoCordobas,
      'cargos_neto': cargosNeto,
      'dia_pago': 15,
      // El recibo deriva el mes de servicio del vencimiento histórico (fix #1);
      // sin este campo el preview rompía (DateTime.parse de null).
      'fecha_vencimiento':
          DateTime(periodo.year, periodo.month, 15).toIso8601String(),
      'cliente_nombre': 'Cliente de Ejemplo',
      'cliente_codigo': 'C-0001',
      'cliente_cedula': '001-010190-0001A',
      'plan_nombre': 'Plan Hogar 10 Mbps',
      'cuota_descripcion': null,
      'cobrador_nombre': 'Cobrador de Ejemplo',
    };
  }

  /// Cargos de ejemplo para el desglose del bloque `cuota` (un ajuste y una
  /// reconexión). El ticket los oculta si el sub-toggle está apagado, o si la
  /// opción correspondiente está deshabilitada en los settings de la empresa.
  List<Map<String, dynamic>> _sampleCargos(AppSettings settings) => [
        if (settings.ajustesHabilitados)
          const {
            'cuota_id': 'cuota-ejemplo',
            'tipo': 'descuento_monto',
            'monto': 50.0,
            'porcentaje': null,
            'descripcion': 'Sin servicio 3 días',
            'origen': 'ajuste',
          },
        if (settings.reconexionHabilitada)
          const {
            'cuota_id': 'cuota-ejemplo',
            'tipo': 'reconexion',
            'monto': 100.0,
            'porcentaje': null,
            'descripcion': 'Cargo por reconexión',
            'origen': 'cobro',
          },
      ];

  /// Mora de ejemplo (2 meses previos) para que el bloque `Detalle de mora`
  /// muestre datos cuando está habilitado en el layout. Cada fila lleva lo que
  /// lee el ticket: periodo, fecha_vencimiento y saldo.
  List<Map<String, dynamic>> _sampleMora() {
    final ahora = DateTime.now();
    return [
      for (var i = 2; i >= 1; i--)
        {
          'periodo': DateTime(ahora.year, ahora.month - i, 1).toIso8601String(),
          'fecha_vencimiento':
              DateTime(ahora.year, ahora.month - i, 15).toIso8601String(),
          'saldo': 500.0,
        },
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    // Logo reactivo: una sola fuente de verdad, la visibilidad del bloque
    // `logo` del layout. Si está visible y hay logo configurado, se muestra
    // el real; si no, null (igual que en el recibo real).
    final logoVisible =
        settings.reciboLayout.any((b) => b.id == 'logo' && b.visible);
    final logoBytes =
        logoVisible ? ref.watch(logoEmpresaBytesProvider).valueOrNull : null;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.visibility, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Vista previa',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${settings.formatoReciboMm}mm',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Datos de ejemplo — se actualiza al instante con tus cambios.',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 12),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: _previewWidthPx(settings.formatoReciboMm),
                ),
                // `ReciboTicket` se construye al ancho real del papel (dots);
                // se escala con FittedBox para entrar en la tira de preview.
                // Es el MISMO widget que ve el cobrador y que se imprime.
                child: FittedBox(
                  // contain: escala para LLENAR el ancho de la preview (no solo
                  // achicar), sino se ve diminuto en pantalla ancha.
                  fit: BoxFit.contain,
                  alignment: Alignment.topCenter,
                  child: ReciboTicket(
                    row: _sampleRow(settings),
                    settings: settings,
                    logoBytes: logoBytes,
                    cargosRows: _sampleCargos(settings),
                    moraRows: _sampleMora(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
