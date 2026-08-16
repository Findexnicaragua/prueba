import 'package:flutter/material.dart';

import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;

/// Detalle de una cuota en SOLO LECTURA (rol `lectura`, 0198).
///
/// Existe porque tocar una cuota abre `/cobro/:id`, que es un formulario de
/// cobro: para un rol que no cobra esa ruta está bloqueada y el tap rebotaba al
/// panel, dejándolo sin poder ni mirar la cuota. Acá ve lo mismo que el
/// formulario muestra arriba —montos, estado, vencimiento— más los pagos ya
/// aplicados, sin un solo control que escriba.
///
/// El saldo usa la fórmula canónica (invariante #10):
/// `monto + cargos_neto − monto_pagado`.
Future<void> mostrarCuotaSoloLectura(
    BuildContext context, String cuotaId) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollCtrl) =>
          _CuotaDetalleLectura(cuotaId: cuotaId, scrollCtrl: scrollCtrl),
    ),
  );
}

class _CuotaDetalleLectura extends StatefulWidget {
  const _CuotaDetalleLectura({required this.cuotaId, required this.scrollCtrl});

  final String cuotaId;
  final ScrollController scrollCtrl;

  @override
  State<_CuotaDetalleLectura> createState() => _CuotaDetalleLecturaState();
}

class _CuotaDetalleLecturaState extends State<_CuotaDetalleLectura> {
  // El builder del DraggableScrollableSheet corre en CADA frame de arrastre:
  // con el Future creado en build, la query se relanzaba a 60fps y el spinner
  // parpadeaba. Se resuelve una vez.
  late final _futuro = _cargar();

  Future<({Map<String, dynamic>? cuota, List<Map<String, dynamic>> pagos})>
      _cargar() async {
    final cuotas = await ps.db.getAll(
      'SELECT * FROM cuotas WHERE id = ?',
      [widget.cuotaId],
    );
    final pagos = await ps.db.getAll(
      '''
      SELECT p.monto_cordobas, p.vuelto_cordobas, p.monto_original, p.moneda,
             p.metodo, p.fecha_pago, p.anulado, co.nombre AS cobrador
        FROM pagos p
   LEFT JOIN cobradores co ON co.id = p.cobrador_id
       WHERE p.cuota_id = ?
       ORDER BY p.fecha_pago DESC
      ''',
      [widget.cuotaId],
    );
    return (cuota: cuotas.isEmpty ? null : cuotas.first, pagos: pagos);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<
        ({Map<String, dynamic>? cuota, List<Map<String, dynamic>> pagos})>(
      future: _futuro,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const SizedBox(
              height: 200, child: Center(child: CircularProgressIndicator()));
        }
        final c = snap.data!.cuota;
        if (c == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('La cuota ya no existe'),
          );
        }
        final monto = (c['monto'] as num?) ?? 0;
        final cargos = (c['cargos_neto'] as num?) ?? 0;
        final pagado = (c['monto_pagado'] as num?) ?? 0;
        final saldo = (monto + cargos - pagado).clamp(0, double.infinity);
        final pagos = snap.data!.pagos;

        return ListView(
          controller: widget.scrollCtrl,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Row(
              children: [
                Icon(Icons.receipt_long, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Detalle de la cuota',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility,
                          size: 13, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text('Solo lectura',
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _fila(context, 'Estado', (c['estado'] as String?) ?? '—'),
            _fila(context, 'Vence',
                Fmt.fechaCorta(DateTime.parse(c['fecha_vencimiento'] as String))),
            const Divider(height: 24),
            _fila(context, 'Monto', Fmt.cordobas(monto)),
            if (cargos != 0)
              _fila(context, 'Cargos y descuentos', Fmt.cordobas(cargos)),
            _fila(context, 'Pagado', Fmt.cordobas(pagado)),
            _fila(context, 'Saldo', Fmt.cordobas(saldo), destacado: true),
            const Divider(height: 24),
            Text('Pagos aplicados',
                style: TextStyle(fontSize: 12, color: scheme.outline)),
            const SizedBox(height: 8),
            if (pagos.isEmpty)
              Text('Sin pagos registrados',
                  style: TextStyle(color: scheme.outline))
            else
              ...pagos.map((p) {
                final anulado = (p['anulado'] as int? ?? 0) == 1;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              Fmt.fechaCorta(
                                  DateTime.parse(p['fecha_pago'] as String)),
                              style: TextStyle(
                                fontSize: 13,
                                decoration:
                                    anulado ? TextDecoration.lineThrough : null,
                              ),
                            ),
                            Text(
                              '${(p['cobrador'] as String?) ?? 'Sin cobrador'}'
                              ' · ${(p['metodo'] as String?) ?? '—'}',
                              style: TextStyle(
                                  fontSize: 11, color: scheme.outline),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        Fmt.cordobas((p['monto_cordobas'] as num?) ?? 0),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: anulado ? scheme.outline : null,
                          decoration:
                              anulado ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (anulado) ...[
                        const SizedBox(width: 6),
                        Text('anulado',
                            style:
                                TextStyle(fontSize: 11, color: scheme.error)),
                      ],
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  Widget _fila(BuildContext context, String label, String valor,
      {bool destacado = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 13, color: scheme.outline)),
          ),
          Text(valor,
              style: TextStyle(
                fontSize: destacado ? 15 : 13,
                fontWeight: destacado ? FontWeight.w600 : FontWeight.w500,
              )),
        ],
      ),
    );
  }
}
