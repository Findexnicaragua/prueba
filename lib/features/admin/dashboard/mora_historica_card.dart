import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import '../../../powersync/db.dart' as ps;
import 'info_grafica.dart';
import 'info_grafica_textos.dart';

/// Mora de los ÚLTIMOS 6 CICLOS, uno al lado del otro.
///
/// Pedido del dueño del tenant: la tarjeta "Mora del ciclo" contesta *cuánta
/// mora hay este mes*, pero no *si venimos mejorando o empeorando*. Un número
/// suelto no dice nada; seis en fila sí.
///
/// Cada barra es un ciclo (15 de un mes → 14 del siguiente, la misma ventana
/// que usa todo el Resumen — ver `periodo_dashboard.dart`) y se parte en dos:
/// lo que ya se recuperó y lo que sigue impago.
///
/// El universo es IDÉNTICO al de la tarjeta "Mora del ciclo" — cuotas del ciclo
/// que pasaron los días de gracia, excluyendo contratos suspendidos — así que
/// la barra del ciclo actual coincide con lo que muestra esa tarjeta. Si algún
/// día dejaran de coincidir, una de las dos está mal (invariante #10).
class MoraHistoricaCard extends ConsumerStatefulWidget {
  const MoraHistoricaCard({super.key, this.ocultarRecaudado = false});

  /// `admin_cobranza`: los montos PENDIENTES los ve (es su trabajo), pero no lo
  /// ya recobrado. Con esto la barra se muestra entera, sin partir.
  final bool ocultarRecaudado;

  @override
  ConsumerState<MoraHistoricaCard> createState() => _MoraHistoricaCardState();
}

/// Un ciclo de la serie.
class _CicloMora {
  const _CicloMora({
    required this.anio,
    required this.mes,
    required this.impago,
    required this.recuperado,
  });

  final int anio;
  final int mes;

  /// Saldo de las cuotas en mora de ese ciclo que sigue sin cobrarse.
  final double impago;

  /// Lo que se cobró de esas cuotas DESPUÉS de vencido el plazo de gracia.
  final double recuperado;

  double get total => impago + recuperado;

  /// "ago" — el mes del período, no el del vencimiento.
  String get etiqueta => mesCortoPeriodo(mes);
}

const _kCiclos = 6;

class _MoraHistoricaCardState extends ConsumerState<MoraHistoricaCard> {
  late Stream<List<Map<String, dynamic>>> _stream;
  int _diasGracia = -1;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  /// Los 6 ciclos, del más viejo al más nuevo. El último es el EN CURSO.
  List<({int anio, int mes})> get _ciclos {
    final p = periodoDe(Fmt.hoyNicaragua());
    return [
      for (var k = _kCiclos - 1; k >= 0; k--)
        (() {
          final d = DateTime(p.year, p.month - k, 1);
          return (anio: d.year, mes: d.month);
        })(),
    ];
  }

  void _rebuild() {
    final g = _diasGracia;
    final ciclos = _ciclos;

    // Los bordes van como PARÁMETROS y no inline: el corte de "hoy" sí se
    // resuelve en SQL (`date('now','-6 hours')`, regla #1b) para que no quede
    // congelado en el arranque de la app.
    final valores = List.generate(_kCiclos, (i) => '(?,?,?)').join(',');

    // Universo de mora, calcado del de `tendencia_cobros_card` para que la
    // barra del ciclo actual dé IGUAL que la tarjeta "Mora del ciclo".
    const saldo = 'max(cu.monto + COALESCE(cu.cargos_neto, 0) '
        '- COALESCE(cu.monto_pagado, 0), 0)';
    const noSusp = 'COALESCE((SELECT ct.estado FROM contratos ct '
        "WHERE ct.id = cu.contrato_id), 'activo') != 'suspendido'";
    const noSusp2 = 'COALESCE((SELECT ct2.estado FROM contratos ct2 '
        "WHERE ct2.id = cu2.contrato_id), 'activo') != 'suspendido'";

    _stream = ps.db.watch('''
      WITH ciclos(idx, ini, fin) AS (VALUES $valores)
      SELECT
        c.idx AS idx,
        COALESCE((
          SELECT SUM($saldo) FROM cuotas cu
           WHERE cu.estado IN ('pendiente','parcial')
             AND date(cu.fecha_vencimiento) >= c.ini
             AND date(cu.fecha_vencimiento) <  c.fin
             AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                 < date('now','-6 hours')
             AND $noSusp
        ), 0) AS impago,
        COALESCE((
          SELECT SUM(p2.monto_cordobas) FROM pagos p2
            JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE COALESCE(p2.anulado, 0) = 0
             AND COALESCE(p2.en_revision, 0) = 0
             AND cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= c.ini
             AND date(cu2.fecha_vencimiento) <  c.fin
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days')
                 < date(p2.fecha_pago)
             AND $noSusp2
        ), 0) AS recuperado
        FROM ciclos c
       ORDER BY c.idx
    ''', parameters: [
      // 3 por ciclo (idx, ini, fin) — van primero porque el CTE aparece
      // primero en el texto del SQL, y `?` es posicional.
      for (var i = 0; i < ciclos.length; i++) ...[
        i,
        isoDia(inicioPeriodo(ciclos[i].anio, ciclos[i].mes)),
        isoDia(finPeriodo(ciclos[i].anio, ciclos[i].mes)),
      ],
      g, // gracia — impago
      g, // gracia — recuperado
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final gracia = ref.watch(appSettingsProvider.select((s) => s.diasGracia));
    if (gracia != _diasGracia) {
      _diasGracia = gracia;
      _rebuild();
    }
    final scheme = Theme.of(context).colorScheme;
    final ciclos = _ciclos;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.stacked_bar_chart, color: scheme.error),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Mora — últimos 6 ciclos',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                const InfoGraficaBoton(kInfoMoraHistorica),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Si la mora viene bajando o subiendo, ciclo a ciclo',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _stream,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const SizedBox(
                    height: 190,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final porIdx = <int, Map<String, dynamic>>{
                  for (final r in snap.data!) (r['idx'] as num).toInt(): r,
                };
                final serie = [
                  for (var i = 0; i < ciclos.length; i++)
                    _CicloMora(
                      anio: ciclos[i].anio,
                      mes: ciclos[i].mes,
                      impago:
                          (porIdx[i]?['impago'] as num?)?.toDouble() ?? 0,
                      recuperado:
                          (porIdx[i]?['recuperado'] as num?)?.toDouble() ?? 0,
                    ),
                ];
                return _Barras(
                  serie: serie,
                  ocultarRecaudado: widget.ocultarRecaudado,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Las barras. Sin librería de gráficos a propósito: son 6 columnas y el
/// proyecto no tiene dependencia de charts — un `Column` con alturas
/// proporcionales es más liviano y no agrega superficie que mantener.
class _Barras extends StatelessWidget {
  const _Barras({required this.serie, required this.ocultarRecaudado});

  final List<_CicloMora> serie;
  final bool ocultarRecaudado;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxTotal =
        serie.fold<double>(0, (a, c) => c.total > a ? c.total : a);
    // Todo en cero: no dibujamos barras de 0 px, decimos que no hay mora.
    if (maxTotal < 0.01) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text('Sin mora en los últimos 6 ciclos.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }

    const alturaMax = 140.0;
    return Column(
      children: [
        SizedBox(
          height: alturaMax + 26,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < serie.length; i++)
                Expanded(
                  child: _Barra(
                    ciclo: serie[i],
                    alturaMax: alturaMax,
                    maxTotal: maxTotal,
                    ocultarRecaudado: ocultarRecaudado,
                    esActual: i == serie.length - 1,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (!ocultarRecaudado)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _Punto(color: Color(0xFF1D9E75), label: 'Recuperado'),
              const SizedBox(width: 14),
              _Punto(color: scheme.error, label: 'Por recuperar'),
            ],
          ),
      ],
    );
  }
}

class _Barra extends StatelessWidget {
  const _Barra({
    required this.ciclo,
    required this.alturaMax,
    required this.maxTotal,
    required this.ocultarRecaudado,
    required this.esActual,
  });

  final _CicloMora ciclo;
  final double alturaMax;
  final double maxTotal;
  final bool ocultarRecaudado;
  final bool esActual;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hTotal = (ciclo.total / maxTotal) * alturaMax;
    final hRec = ciclo.total < 0.01
        ? 0.0
        : (ciclo.recuperado / ciclo.total) * hTotal;

    final detalle = ocultarRecaudado
        ? '${ciclo.etiqueta}: ${Fmt.cordobas(ciclo.total)} de mora'
        : '${ciclo.etiqueta}: ${Fmt.cordobas(ciclo.total)} de mora · '
            'recuperado ${Fmt.cordobas(ciclo.recuperado)} · '
            'por recuperar ${Fmt.cordobas(ciclo.impago)}';

    return Tooltip(
      message: detalle + (esActual ? ' (ciclo en curso)' : ''),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SizedBox(
              height: alturaMax,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    height: (hTotal - hRec).clamp(0, alturaMax),
                    decoration: BoxDecoration(
                      color: scheme.error
                          .withValues(alpha: esActual ? 0.55 : 0.85),
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4)),
                    ),
                  ),
                  if (!ocultarRecaudado)
                    Container(
                      height: hRec.clamp(0, alturaMax),
                      color: const Color(0xFF1D9E75)
                          .withValues(alpha: esActual ? 0.55 : 0.85),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              ciclo.etiqueta,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontWeight: esActual ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Punto extends StatelessWidget {
  const _Punto({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
