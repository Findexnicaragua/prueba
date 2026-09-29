/// Tarjeta "Recaudo y mora" — el formato de 4 líneas que pidió el dueño
/// (2026-08-24, sobre capturas de referencia de otra app):
///
///   · Recaudado real   (sólida azul)      · Meta de recaudo  (punteada verde)
///   · Mora real        (sólida naranja)   · Límite de mora   (punteada rosa)
///
/// sobre los últimos [kCiclosRecaudo] ciclos (período 15→14, el del negocio),
/// con dos vistas — Mensual (valores del ciclo) y Acumulado (suma corrida) —,
/// cuatro KPIs y la tabla de indicadores con % del total.
///
/// SEMÁNTICA (validada contra producción antes de diseñar): por ciclo,
/// `facturado = recaudado + por recaudar + mora`, donde "por recaudar" es el
/// saldo AÚN EN PLAZO O GRACIA y "mora" el saldo que ya cruzó la gracia. Son
/// conjuntos disjuntos: la tabla suma 100% sin contar plata dos veces. En
/// Acumulado, la mora de cada ciclo es la que sigue viva HOY de las cuotas de
/// ESE ciclo — ciclos distintos son cuotas distintas, así que acumular no
/// duplica.
///
/// LAS DOS LÍNEAS PUNTEADAS NO EXISTEN COMO DATO: son derivadas con
/// porcentajes fijos ([kMetaRecaudoPct], [kLimiteMoraPct]) mientras el dueño
/// decide quién los configura (¿él? ¿cada ISP? ¿% o monto?). Al volverlos
/// setting, tocar SOLO esas dos constantes.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'escala_resumen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import 'dashboard_query.dart';
import 'resumen_watch.dart';

const int kCiclosRecaudo = 6;

/// Meta de recaudo = este % de lo facturado del ciclo. 1.0 = "cobrar todo lo
/// que vence", que es la única meta que hoy no requiere inventar un número.
const double kMetaRecaudoPct = 1.0;

/// Límite de mora = este % de lo facturado del ciclo. El 10% es un SUPUESTO
/// del mockup aprobado, no una decisión de producto.
const double kLimiteMoraPct = 0.10;

const _cRec = Color(0xFF4E8EF7);
const _cMeta = Color(0xFF66BB6A);
const _cMora = Color(0xFFEF9F27);
const _cLimite = Color(0xFFF06292);
const _cAlerta = Color(0xFFE24B4A);

/// Un ciclo de la serie, ya con la partición completa.
class CicloRecaudo {
  const CicloRecaudo({
    required this.anio,
    required this.mes,
    required this.fact,
    required this.rec,
    required this.mora,
    required this.porrec,
  });

  final int anio;
  final int mes;
  final double fact;
  final double rec;
  final double mora;
  final double porrec;

  String get etiqueta => mesCortoPeriodo(mes);
}

/// Mapea las filas de [serieRecaudoMora] a los [n] ciclos que terminan en
/// [anio]/[mes], RELLENANDO con ceros los ciclos sin cuotas: la query solo
/// devuelve los que tienen filas, y un hueco correría todas las etiquetas del
/// eje un lugar.
List<CicloRecaudo> ciclosDesdeFilas(
  List<Map<String, dynamic>> filas, {
  required int anio,
  required int mes,
  int n = kCiclosRecaudo,
}) {
  final porClave = {
    for (final f in filas) (f['ciclo'] as String? ?? ''): f,
  };
  final out = <CicloRecaudo>[];
  for (var i = n - 1; i >= 0; i--) {
    final d = DateTime(anio, mes - i, 1);
    final clave =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
    final f = porClave[clave];
    double num0(Object? v) => (v as num?)?.toDouble() ?? 0;
    out.add(CicloRecaudo(
      anio: d.year,
      mes: d.month,
      fact: num0(f?['fact']),
      rec: num0(f?['rec']),
      mora: num0(f?['mora']),
      porrec: num0(f?['porrec']),
    ));
  }
  return out;
}

/// Suma corrida de la serie, para la vista Acumulado.
List<CicloRecaudo> acumular(List<CicloRecaudo> serie) {
  var fact = 0.0, rec = 0.0, mora = 0.0, porrec = 0.0;
  return [
    for (final c in serie)
      CicloRecaudo(
        anio: c.anio,
        mes: c.mes,
        fact: fact += c.fact,
        rec: rec += c.rec,
        mora: mora += c.mora,
        porrec: porrec += c.porrec,
      ),
  ];
}

/// Como los KPIs y la tabla son 100% montos, el rol que no ve montos
/// recolectados (admin_cobranza) no monta esta tarjeta — el llamador gatea.
class RecaudoMoraCard extends ConsumerStatefulWidget {
  const RecaudoMoraCard({super.key});

  @override
  ConsumerState<RecaudoMoraCard> createState() => _RecaudoMoraCardState();
}

class _RecaudoMoraCardState extends ConsumerState<RecaudoMoraCard> {
  late int _anio, _mes; // último ciclo de la ventana visible
  bool _acumulado = false;
  int? _diasGracia;
  String _hoy = isoDia(Fmt.hoyNicaragua());
  int _refreshEpoch = 0;
  Stream<List<Map<String, dynamic>>> _stream = const Stream.empty();

  @override
  void initState() {
    super.initState();
    final p = periodoDe(Fmt.hoyNicaragua());
    _anio = p.year;
    _mes = p.month;
    // El stream se arma en build, cuando ya se conocen los días de gracia
    // (mismo patrón que TendenciaMoraCard).
  }

  DateTime get _inicioDate =>
      inicioPeriodo(_anio, _mes - (kCiclosRecaudo - 1));
  DateTime get _finDate => finPeriodo(_anio, _mes);

  bool get _puedeAvanzar => !Fmt.hoyNicaragua().isBefore(_finDate);

  void _cambiarMes(int delta) {
    final d = DateTime(_anio, _mes + delta, 1);
    if (delta > 0 && !_puedeAvanzar) return;
    setState(() {
      _anio = d.year;
      _mes = d.month;
      _rebuildStream();
    });
  }

  void _rebuildStream() {
    final q = serieRecaudoMora(
      inicio: isoDia(_inicioDate),
      fin: isoDia(_finDate),
      diasGracia: _diasGracia!,
      hoy: _hoy,
    );
    _stream = watchResumen(q.sql, parameters: q.parametros);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cargaron = ref.watch(settingsMapProvider).hasValue;
    final diasGracia =
        ref.watch(appSettingsProvider.select((s) => s.diasGracia));
    final refreshEpoch = ref.watch(dashboardRefreshEpochProvider);
    // Aviso de medianoche Nicaragua; el corte sale del reloj (ver la nota
    // larga en TendenciaMoraCard).
    ref.watch(diaNicaraguaProvider);
    final hoy = isoDia(Fmt.hoyNicaragua());
    if (cargaron &&
        (diasGracia != _diasGracia ||
            hoy != _hoy ||
            refreshEpoch != _refreshEpoch)) {
      _diasGracia = diasGracia;
      _hoy = hoy;
      _refreshEpoch = refreshEpoch;
      _rebuildStream();
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: _diasGracia == null
            ? const SizedBox(
                height: 120, child: Center(child: CircularProgressIndicator()))
            : StreamBuilder<List<Map<String, dynamic>>>(
                stream: _stream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Error al cargar datos',
                          style: TextStyle(color: scheme.error)),
                    );
                  }
                  if (!snap.hasData) {
                    return const SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator()));
                  }
                  final mensual = ciclosDesdeFilas(snap.data!,
                      anio: _anio, mes: _mes);
                  final serie = _acumulado ? acumular(mensual) : mensual;
                  return _cuerpo(context, scheme, serie);
                },
              ),
      ),
    );
  }

  Widget _cuerpo(
      BuildContext context, ColorScheme scheme, List<CicloRecaudo> serie) {
    final ultimo = serie.last;
    final sufijo = _acumulado ? '' : ' (${ultimo.etiqueta})';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Recaudo y mora',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    _acumulado
                        ? 'Acumulado de los últimos $kCiclosRecaudo ciclos'
                        : 'Últimos $kCiclosRecaudo ciclos · el KPI es del '
                            'ciclo ${ultimo.etiqueta} (${periodoLabel(ultimo.anio, ultimo.mes)})',
                    style: TextStyle(
                        fontSize: TxtResumen.apoyo, color: scheme.onSurfaceVariant),
                  ),
                ]),
          ),
          IconButton(
            tooltip: 'Ciclo anterior',
            onPressed: () => _cambiarMes(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: 'Ciclo siguiente',
            onPressed: _puedeAvanzar ? () => _cambiarMes(1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ]),
        const SizedBox(height: 6),
        const Wrap(spacing: 14, runSpacing: 5, children: [
          _LeyendaItem(color: _cRec, texto: 'Recaudado real'),
          _LeyendaItem(color: _cMeta, texto: 'Meta de recaudo'),
          _LeyendaItem(color: _cMora, texto: 'Mora real'),
          _LeyendaItem(color: _cLimite, texto: 'Límite de mora'),
        ]),
        const SizedBox(height: 10),
        AspectRatio(
          aspectRatio: 2.1,
          child: CustomPaint(
            painter: _CuatroLineasPainter(
              serie: serie,
              gridColor: scheme.outlineVariant,
              labelColor: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          _Kpi(
              titulo: 'Total cobros$sufijo',
              valor: Fmt.cordobas(ultimo.fact)),
          _sep(scheme),
          _Kpi(
              titulo: 'Recaudados$sufijo',
              valor: Fmt.cordobas(ultimo.rec),
              color: _cRec),
          _sep(scheme),
          _Kpi(
              titulo: 'Por recaudar$sufijo',
              valor: Fmt.cordobas(ultimo.porrec)),
          _sep(scheme),
          _Kpi(
              titulo: 'Mora$sufijo',
              valor: Fmt.cordobas(ultimo.mora),
              color: _cMora),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Text('Vista',
              style: TextStyle(
                  fontSize: TxtResumen.cifra,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant)),
          const Spacer(),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Mensual')),
              ButtonSegment(value: true, label: Text('Acumulado')),
            ],
            selected: {_acumulado},
            onSelectionChanged: (v) =>
                setState(() => _acumulado = v.first),
            showSelectedIcon: false,
            style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle:
                    WidgetStatePropertyAll(TextStyle(fontSize: TxtResumen.cifra))),
          ),
        ]),
        const SizedBox(height: 10),
        _TablaKpis(ciclo: ultimo, acumulado: _acumulado),
        const SizedBox(height: 6),
        Text(
          'Total cobros = lo facturado del ciclo · Por recaudar = saldo aún en '
          'plazo o gracia · Mora = saldo que cruzó la gracia. Los tres suman '
          'el total, sin pisarse. Meta y límite: '
          '${(kMetaRecaudoPct * 100).round()}% y '
          '${(kLimiteMoraPct * 100).round()}% de lo facturado (provisorios).',
          style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _sep(ColorScheme scheme) =>
      Container(width: 1, height: 34, color: scheme.outlineVariant);
}

class _LeyendaItem extends StatelessWidget {
  const _LeyendaItem({required this.color, required this.texto});
  final Color color;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 5),
      Text(texto, style: const TextStyle(fontSize: TxtResumen.apoyo)),
    ]);
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.titulo, required this.valor, this.color});
  final String titulo;
  final String valor;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(children: [
        Text(titulo.toUpperCase(),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: TxtResumen.minimo,
                letterSpacing: 0.3,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: 3),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(valor,
              style: TextStyle(
                  fontSize: TxtResumen.grande,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ),
      ]),
    );
  }
}

class _TablaKpis extends StatelessWidget {
  const _TablaKpis({required this.ciclo, required this.acumulado});
  final CicloRecaudo ciclo;
  final bool acumulado;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = ciclo.fact;
    String pct(double v) =>
        total <= 0 ? '—' : '${(v / total * 100).toStringAsFixed(1)}%';

    Widget fila(String nombre, double monto, String porcentaje,
        {Color? color, bool fuerte = false}) {
      final estilo = TextStyle(
          fontSize: TxtResumen.cifra,
          fontWeight: fuerte ? FontWeight.w700 : FontWeight.w400);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(flex: 3, child: Text(nombre, style: estilo)),
          Expanded(
              flex: 3,
              child: Text(Fmt.cordobas(monto),
                  textAlign: TextAlign.right,
                  style: estilo.copyWith(
                      fontFeatures: const [ui.FontFeature.tabularFigures()]))),
          Expanded(
              flex: 2,
              child: Text(porcentaje,
                  textAlign: TextAlign.right,
                  style: estilo.copyWith(
                      fontWeight: FontWeight.w700, color: color))),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
          acumulado
              ? 'Indicadores del acumulado'
              : 'Indicadores del ciclo ${ciclo.etiqueta}',
          style: const TextStyle(fontSize: TxtResumen.cifra, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Divider(height: 10, color: scheme.outlineVariant),
      fila('Total de cobros', ciclo.fact, total <= 0 ? '—' : '100,0%',
          fuerte: true),
      Divider(height: 1, color: scheme.outlineVariant),
      fila('Recaudados', ciclo.rec, pct(ciclo.rec), color: _cRec),
      Divider(height: 1, color: scheme.outlineVariant),
      fila('Por recaudar', ciclo.porrec, pct(ciclo.porrec)),
      Divider(height: 1, color: scheme.outlineVariant),
      fila('Mora', ciclo.mora, pct(ciclo.mora), color: _cMora),
    ]);
  }
}

class _CuatroLineasPainter extends CustomPainter {
  _CuatroLineasPainter({
    required this.serie,
    required this.gridColor,
    required this.labelColor,
  });

  final List<CicloRecaudo> serie;
  final Color gridColor;
  final Color labelColor;

  static const _padL = 44.0, _padR = 8.0, _padT = 8.0, _padB = 22.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (serie.isEmpty) return;
    final plotW = size.width - _padL - _padR;
    final plotH = size.height - _padT - _padB;
    if (plotW <= 0 || plotH <= 0) return;

    var maxV = 0.0;
    for (final c in serie) {
      maxV = math.max(
          maxV,
          math.max(math.max(c.rec, c.fact * kMetaRecaudoPct),
              math.max(c.mora, c.fact * kLimiteMoraPct)));
    }
    if (maxV <= 0) maxV = 1;
    maxV *= 1.06; // aire arriba

    double x(int i) => serie.length == 1
        ? _padL + plotW / 2
        : _padL + plotW * i / (serie.length - 1);
    double y(double v) => _padT + plotH * (1 - v / maxV);

    // Grid + labels del eje Y (4 divisiones).
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var g = 0; g <= 4; g++) {
      final gy = _padT + plotH * g / 4;
      canvas.drawLine(Offset(_padL, gy), Offset(size.width - _padR, gy), grid);
      _texto(canvas, _compacto(maxV * (4 - g) / 4),
          Offset(_padL - 6, gy - 5), labelColor,
          alinearDerecha: true);
    }

    void linea(double Function(CicloRecaudo) sel, Color color,
        {bool punteada = false}) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = punteada ? 2 : 2.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var i = 0; i < serie.length; i++) {
        final p = Offset(x(i), y(sel(serie[i])));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(punteada ? _dash(path) : path, paint);
      final dot = Paint()..color = color;
      for (var i = 0; i < serie.length; i++) {
        canvas.drawCircle(
            Offset(x(i), y(sel(serie[i]))), punteada ? 3.2 : 3.6, dot);
      }
    }

    // Orden de pintado: punteadas al fondo, sólidas encima.
    linea((c) => c.fact * kMetaRecaudoPct, _cMeta, punteada: true);
    linea((c) => c.fact * kLimiteMoraPct, _cLimite, punteada: true);
    linea((c) => c.rec, _cRec);
    linea((c) => c.mora, _cMora);

    // Aviso en el PRIMER ciclo cuya mora rebasa el límite.
    for (var i = 0; i < serie.length; i++) {
      final c = serie[i];
      if (c.mora > c.fact * kLimiteMoraPct && c.fact > 0) {
        final p = Offset(x(i), y(c.mora));
        canvas.drawCircle(
            p,
            7.5,
            Paint()
              ..color = _cAlerta
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
        break;
      }
    }

    // Etiquetas del eje X.
    for (var i = 0; i < serie.length; i++) {
      _texto(canvas, serie[i].etiqueta,
          Offset(x(i) - 10, size.height - _padB + 6), labelColor);
    }
  }

  Path _dash(Path origen, {double dash = 6, double gap = 5}) {
    final out = Path();
    for (final metric in origen.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        out.addPath(
            metric.extractPath(d, math.min(d + dash, metric.length)),
            Offset.zero);
        d += dash + gap;
      }
    }
    return out;
  }

  void _texto(Canvas canvas, String s, Offset donde, Color color,
      {bool alinearDerecha = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontSize: TxtResumen.minimo, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas,
        alinearDerecha ? donde.translate(-tp.width, 0) : donde);
  }

  static String _compacto(double v) {
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(0)}K';
    return v.toStringAsFixed(0);
  }

  @override
  bool shouldRepaint(_CuatroLineasPainter old) =>
      old.serie != serie ||
      old.gridColor != gridColor ||
      old.labelColor != labelColor;
}
