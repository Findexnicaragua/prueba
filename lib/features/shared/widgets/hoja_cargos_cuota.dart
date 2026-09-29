import 'package:flutter/material.dart';

import '../../../data/repositories/cuotas_repo.dart' show kOrigenesNoQuitables;
import '../../../data/utils/formatters.dart';
import '../../recibo/recibo_cargos.dart'
    show cargoEtiquetaRecibo, cargoLineaDetalle;

/// # La hoja "Descuentos y cargos de la cuota" — UNA sola para toda la app
///
/// ## Por qué existe
///
/// Había DOS hojas con el mismo título, la misma data y textos distintos: la
/// del cobro (`cobro_screen`) y la del detalle del contrato
/// (`contrato_detail_cuotas`). Al ser widgets separados **divergieron**: la
/// del contrato repetía la descripción del cargo y no decía los días; la del
/// cobro decía los días y no decía quién lo había aplicado. Y cuando el
/// 2026-09-02 se arregló una, la otra quedó igual.
///
/// Rubén lo señaló con precisión: *"se suponía que tenías que saber en qué
/// interfaces de la app está vinculado este apartado de cargos extras y
/// mostrarme o cambiarlas acorde a lo que se pide, y aquí fallamos"*.
///
/// Unificarlas no es prolijidad: es lo único que impide que vuelvan a decir
/// cosas distintas sobre la misma fila.
///
/// ## Lo que cambia entre los dos usos
///
/// Sólo el pie. En el cobro la hoja es **de referencia** —ahí no se crea ni se
/// quita nada— y en el contrato trae los botones de gestionar. Las LÍNEAS son
/// idénticas en los dos lados, que es el punto.
class HojaCargosCuota extends StatelessWidget {
  const HojaCargosCuota({
    super.key,
    required this.cargos,
    this.cargosAuto = const [],
    this.onQuitar,
    this.pie,
  });

  /// Los cargos ya persistidos. Filas de `cargos_extra` tal como las devuelve
  /// `cuotasRepo.cargosDeCuota` (con `origen`, `detalle` y
  /// `aplicado_por_nombre`).
  final List<Map<String, dynamic>> cargos;

  /// Los que una operación en curso va a insertar al confirmar (reconexión /
  /// pronto pago del cobro). Se muestran porque cambian lo que hay que cobrar,
  /// con la aclaración de que todavía no existen.
  final List<CargoPendiente> cargosAuto;

  /// Quitar un cargo. `null` = hoja de sólo lectura (el cobro).
  final void Function(Map<String, dynamic> cargo)? onQuitar;

  /// Los botones de gestionar, cuando el llamador los tiene.
  final Widget? pie;

  /// De dónde salió un cargo, en palabras.
  ///
  /// El subtítulo de la hoja NO puede afirmar quién los aplica: decía "los
  /// aplica el admin desde el contrato" y eso es falso para un cargo de cambio
  /// de plan o un crédito, que los crea una operación. Lo dice cada línea.
  static String? deQuienVino(Map<String, dynamic> c) {
    final origen = c['origen'] as String? ?? '';
    final quien = (c['aplicado_por_nombre'] as String?)?.trim();
    final porQuien =
        quien == null || quien.isEmpty ? 'Aplicado por el admin' : 'Aplicado por $quien';
    return switch (origen) {
      'cambio_plan' => 'Lo generó el cambio de plan',
      'puente' => 'Lo generó el cambio de fecha de pago',
      'credito' => 'Crédito a favor del cliente',
      'liquidacion' => 'Lo generó el cierre del contrato',
      'promo' => 'Promoción',
      'ajuste' => porQuien,
      // `cobro` y las filas viejas sin `origen` (la columna se agregó después):
      // no se puede afirmar quién las puso, así que no se afirma nada.
      _ => null,
    };
  }

  /// Si el cargo se puede quitar. Lee la lista CANÓNICA del repo — el mismo
  /// criterio que enforça `quitarCargo`, no una copia.
  static bool quitable(Map<String, dynamic> c) =>
      c['pago_id'] == null &&
      !kOrigenesNoQuitables.contains(c['origen'] as String? ?? '');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget linea({
      required String etiqueta,
      required double monto,
      required bool esDescuento,
      String? detalle,
      String? origen,
      String? cuando,
      Widget? accion,
    }) {
      // El orden de los renglones de apoyo es deliberado: primero QUÉ es
      // (los días del prorrateo), después DE DÓNDE vino, y al final CUÁNDO.
      // Antes la descripción cruda iba primera y repetía la etiqueta.
      final apoyo = [
        if (detalle != null && detalle.isNotEmpty) detalle,
        if (origen != null && origen.isNotEmpty) origen,
        if (cuando != null && cuando.isNotEmpty) cuando,
      ];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(esDescuento ? Icons.discount : Icons.add_circle_outline,
                size: 20, color: scheme.primary),
            const SizedBox(width: 10),
            // ÚNICO Expanded y a la izquierda (regla #15): el monto cae
            // siempre en el mismo borde, mida lo que mida la etiqueta.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(etiqueta,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  for (final a in apoyo)
                    Text(a,
                        style:
                            TextStyle(fontSize: 12, color: scheme.outline)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text('${esDescuento ? '−' : '+'}${Fmt.cordobas(monto)}',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            if (accion != null) accion,
          ],
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Descuentos y cargos de la cuota',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Cada línea dice de dónde salió y cuánto suma o resta a la cuota.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
            const SizedBox(height: 8),
            if (cargos.isEmpty && cargosAuto.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('Sin descuentos ni cargos.',
                    style: TextStyle(color: scheme.outline)),
              ),
            for (final c in cargos)
              linea(
                etiqueta: cargoEtiquetaRecibo(c, conMotivo: true),
                monto: ((c['monto'] as num?) ?? 0).toDouble(),
                esDescuento:
                    (c['tipo'] as String? ?? '').startsWith('descuento'),
                detalle: cargoLineaDetalle(c),
                origen: deQuienVino(c),
                cuando: _cuando(c),
                accion: onQuitar == null || !quitable(c)
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Quitar',
                        onPressed: () => onQuitar!(c),
                      ),
              ),
            for (final a in cargosAuto)
              linea(
                etiqueta: a.descripcion,
                monto: a.monto,
                esDescuento: a.esDescuento,
                origen: 'Se aplica al confirmar este cobro',
              ),
            if (pie != null) ...[
              const SizedBox(height: 8),
              pie!,
            ],
          ],
        ),
      ),
    );
  }

  /// `2026-09-02T19:35:00Z` → `02/09/2026 19:35`, en hora de Nicaragua.
  static String? _cuando(Map<String, dynamic> c) {
    final iso =
        (c['ocurrido_en'] as String?) ?? (c['aplicado_en'] as String?);
    if (iso == null) return null;
    final d = DateTime.tryParse(iso);
    if (d == null) return null;
    // UTC-6 sin DST, igual que el resto de la app (regla #1b).
    final l = d.toUtc().subtract(const Duration(hours: 6));
    return '${l.day.toString().padLeft(2, '0')}/'
        '${l.month.toString().padLeft(2, '0')}/${l.year} '
        '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }
}

/// Un cargo que TODAVÍA NO existe en la base: lo va a insertar la operación en
/// curso al confirmarse. Lo usa el cobro para su preview de reconexión /
/// pronto pago.
class CargoPendiente {
  const CargoPendiente({
    required this.descripcion,
    required this.monto,
    required this.esDescuento,
  });
  final String descripcion;
  final double monto;
  final bool esDescuento;
}
