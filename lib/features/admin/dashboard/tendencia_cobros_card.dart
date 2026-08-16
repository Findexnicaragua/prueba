import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import '../../../powersync/db.dart' as ps;
import 'info_grafica.dart';
import 'info_grafica_textos.dart';

// ── Data ──

class _DatosDia {
  _DatosDia({required this.fecha, required this.monto, required this.qty});
  final String fecha;
  final num monto;
  final int qty;
}

/// Serie de la curva de tendencia con los pagos de FUERA de la ventana
/// SEPARADOS, no aplastados en un día (fix del audit 2026-08-01).
///
/// La consulta diaria filtra los pagos por `cuota.fecha_vencimiento ∈ ventana`
/// (eje cobertura) pero un pago puede tener `fecha_pago` fuera de la ventana:
/// un pre-pago (antes del ciclo) o un pago tardío (después, en meses cerrados).
/// Antes esos se `.clamp`-eaban al día 0 / último día, inflando el tooltip
/// "Del día" hasta 5× y mintiendo la fecha. Acá se separan:
///  - `baseline`: lo recuperado ANTES del ciclo → base del día 0 (no un pico).
///  - por-día: solo lo cobrado EN cada día real del período.
///  - `tail`: lo recuperado DESPUÉS del ciclo → tramo final rotulado.
/// `granTotal = baseline + in-window + tail` DEBE igualar el "Recuperado" de la
/// tabla (mismo universo, solo redistribuido en el tiempo).
class SerieTendencia {
  const SerieTendencia({
    required this.baseline,
    required this.tail,
    required this.montoPorDia,
    required this.qtyPorDia,
    required this.acumulados,
    required this.granTotal,
  });
  final double baseline;
  final double tail;
  final Map<int, double> montoPorDia;
  final Map<int, int> qtyPorDia;
  final List<double> acumulados; // baseline + acumulado in-window, largo = dc
  final double granTotal;
}

/// Fila cruda de la serie diaria (fecha ISO yyyy-MM-dd, monto, cantidad).
class FilaDiaria {
  const FilaDiaria(this.fecha, this.monto, this.qty);
  final String fecha;
  final num monto;
  final int qty;
}

/// Construye la serie de la curva separando pre-ciclo / en-ventana / post-ciclo.
/// [dc] = días con datos (período actual = días transcurridos; cerrado = todos).
SerieTendencia construirSerieTendencia(
    List<FilaDiaria> dias, DateTime inicio, DateTime fin, int dc) {
  final n = dc < 0 ? 0 : dc;
  var baseline = 0.0, tail = 0.0, inWin = 0.0;
  final monto = <int, double>{};
  final qty = <int, int>{};
  for (final d in dias) {
    final date = DateTime.parse(d.fecha);
    if (date.isBefore(inicio)) {
      baseline += d.monto.toDouble();
      continue;
    }
    if (!date.isBefore(fin)) {
      tail += d.monto.toDouble();
      continue;
    }
    final idx = date.difference(inicio).inDays;
    // idx queda en [0, díasDelPeriodo). En período cerrado dc = ese total, así
    // que idx < dc. En período actual, un pago fechado DESPUÉS de hoy (idx>=dc,
    // raro) se manda al tail para no clavarlo en el último día visible.
    if (idx < 0) {
      baseline += d.monto.toDouble();
    } else if (idx >= n) {
      tail += d.monto.toDouble();
    } else {
      inWin += d.monto.toDouble();
      monto[idx] = (monto[idx] ?? 0) + d.monto.toDouble();
      qty[idx] = (qty[idx] ?? 0) + d.qty;
    }
  }
  final acum = <double>[];
  var run = baseline;
  for (var i = 0; i < n; i++) {
    run += (monto[i] ?? 0);
    acum.add(run);
  }
  // El tail (recuperado DESPUÉS del ciclo, meses cerrados) se pliega al ÚLTIMO
  // punto para que la curva CIERRE en el "Recuperado" de la tabla — pedido del
  // dueño: al final del ciclo el acumulado tiene que concordar con el total.
  // "Del día" se mantiene REAL (no se infla); el tail se aclara en el tooltip
  // del último día ("Después del ciclo") y en la nota bajo la gráfica.
  if (acum.isNotEmpty && tail > 0) acum[acum.length - 1] += tail;
  return SerieTendencia(
    baseline: baseline,
    tail: tail,
    montoPorDia: monto,
    qtyPorDia: qty,
    acumulados: acum,
    granTotal: baseline + inWin + tail,
  );
}

class _Resumen {
  const _Resumen({
    required this.metaUsuarios,
    required this.metaCuotas,
    required this.metaMonto,
    required this.recUsuarios,
    required this.recCuotas,
    required this.recMonto,
    this.recMontoTarde,
    this.porRecUsuariosQ,
    this.porRecCuotasQ,
  });
  final int metaUsuarios;
  final int metaCuotas;
  final num metaMonto;
  final int recUsuarios;
  final int recCuotas;
  final num recMonto;

  /// Porción de [recMonto] cobrada DESPUÉS de los días de gracia. Es exactamente
  /// el "Recuperado" de la tarjeta de Mora: un SUBCONJUNTO de lo recuperado, no
  /// plata aparte. Sumarlos fue el origen del reclamo del dueño (2026-08-08).
  final num? recMontoTarde;

  /// El resto de [recMonto]: cobrado a tiempo o dentro de la gracia.
  num? get recMontoATiempo =>
      recMontoTarde == null ? null : recMonto - recMontoTarde!;

  /// Conteos CONSULTADOS de lo que falta cobrar. Antes salían de restar dos
  /// `COUNT(DISTINCT)` (meta − recuperado), que subcuenta a todo cliente que
  /// esté en los dos conjuntos: el que pagó una cuota del ciclo y debe otra se
  /// restaba entero. Medido 2026-08-08 en Mairena: mostraba 2.406 clientes
  /// cuando eran 2.422 (16 de menos). La resta sigue siendo correcta para el
  /// MONTO (verificado contra el saldo canónico, desvío C$0,00), no para los
  /// conteos.
  final int? porRecUsuariosQ;
  final int? porRecCuotasQ;

  int get porRecUsuarios =>
      porRecUsuariosQ ?? math.max(metaUsuarios - recUsuarios, 0);
  int get porRecCuotas =>
      porRecCuotasQ ?? math.max(metaCuotas - recCuotas, 0);
  num get porRecMonto => (metaMonto - recMonto).clamp(0, double.infinity);
  double get pctRec => metaMonto > 0 ? (recMonto / metaMonto).clamp(0, 1) : 0;
  double get pctPorRec =>
      metaMonto > 0 ? (porRecMonto / metaMonto).clamp(0, 1) : 0;
}

const _noSuspendido = 'COALESCE((SELECT ct.estado FROM contratos ct '
    "WHERE ct.id = cu.contrato_id), 'activo') != 'suspendido'";
const _noSuspendido2 = 'COALESCE((SELECT ct2.estado FROM contratos ct2 '
    "WHERE ct2.id = cu2.contrato_id), 'activo') != 'suspendido'";

// ── Cobros del mes ──

class TendenciaCobrosCard extends ConsumerStatefulWidget {
  const TendenciaCobrosCard({super.key, this.ocultarRecaudado = false});

  /// Esconde lo COBRADO y deja lo PENDIENTE. Lo usa el rol admin_cobranza,
  /// que por definicion no ve montos recolectados pero SI gestiona mora y
  /// recuperacion de cartera. Antes se le ocultaba la tarjeta ENTERA: entraba
  /// al Resumen y no veia nada, ni la mora — que es literalmente su trabajo.
  final bool ocultarRecaudado;
  @override
  ConsumerState<TendenciaCobrosCard> createState() =>
      _TendenciaCobrosCardState();
}

class _TendenciaCobrosCardState extends ConsumerState<TendenciaCobrosCard> {
  late int _anio, _mes;
  int _diasGracia = 10;
  late Stream<List<Map<String, dynamic>>> _summaryStream;
  late Stream<List<Map<String, dynamic>>> _dailyStream;
  late Stream<List<Map<String, dynamic>>> _moraDailyStream;

  @override
  void initState() {
    super.initState();
    final p = periodoDe(Fmt.hoyNicaragua());
    _anio = p.year;
    _mes = p.month;
    _rebuildStreams();
  }

  DateTime get _inicioDate => inicioPeriodo(_anio, _mes);
  DateTime get _finDate => finPeriodo(_anio, _mes);
  String get _inicio => _inicioDate.toIso8601String().substring(0, 10);
  String get _fin => _finDate.toIso8601String().substring(0, 10);

  bool get _esPeriodoActual {
    final h = Fmt.hoyNicaragua();
    return !h.isBefore(_inicioDate) && h.isBefore(_finDate);
  }

  bool get _puedeAvanzar {
    final h = Fmt.hoyNicaragua();
    return !h.isBefore(_finDate);
  }

  void _cambiarMes(int delta) {
    final d = DateTime(_anio, _mes + delta, 1);
    final h = Fmt.hoyNicaragua();
    final nextStart = inicioPeriodo(d.year, d.month);
    if (h.isBefore(nextStart)) return;
    setState(() {
      _anio = d.year;
      _mes = d.month;
      _rebuildStreams();
    });
  }

  void _rebuildStreams() {
    final i = _inicio;
    final f = _fin;
    final g = _diasGracia;

    _summaryStream = ps.db.watch('''
      SELECT
        COUNT(DISTINCT cu.cliente_id) AS meta_u,
        COUNT(*) AS meta_c,
        COALESCE(SUM(cu.monto + COALESCE(cu.cargos_neto, 0)), 0) AS meta_m,
        (SELECT COUNT(DISTINCT cu2.cliente_id) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0
             AND cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND $_noSuspendido2
        ) AS rec_u,
        (SELECT COUNT(DISTINCT p2.cuota_id) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0
             AND cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND $_noSuspendido2
        ) AS rec_c,
        (SELECT COALESCE(SUM(p2.monto_cordobas), 0) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0
             AND cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND $_noSuspendido2
        ) AS rec_m,
        -- Porción de rec_m cobrada DESPUÉS de la gracia. Es EXACTAMENTE el
        -- "Recuperado" de la tarjeta de Mora (mismo universo + el corte de
        -- gracia), o sea un SUBCONJUNTO de rec_m. Se muestra como sub-fila para
        -- que no se pueda volver a sumar aparte (reclamo del dueño 2026-08-08).
        (SELECT COALESCE(SUM(p2.monto_cordobas), 0) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0
             AND cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < date(p2.fecha_pago)
             AND $_noSuspendido2
        ) AS rec_m_tarde,
        -- Conteos de lo que FALTA cobrar, consultados (no por resta): el
        -- cliente que pagó una cuota del ciclo y debe otra tiene que contar
        -- en las dos filas.
        (SELECT COUNT(DISTINCT cu2.cliente_id) FROM cuotas cu2
           WHERE cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND $_noSuspendido2
             AND (cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0)) > 0.009
        ) AS porrec_u,
        (SELECT COUNT(*) FROM cuotas cu2
           WHERE cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND $_noSuspendido2
             AND (cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0)) > 0.009
        ) AS porrec_c
      FROM cuotas cu
      WHERE cu.estado != 'anulada'
        AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?
        AND $_noSuspendido
    ''', parameters: [
      i, f,
      i, f,
      i, f,
      i, f, g,   // rec_m_tarde
      i, f,      // porrec_u
      i, f,      // porrec_c
      i, f,
    ]);

    _dailyStream = ps.db.watch('''
      SELECT date(p.fecha_pago) AS dia,
             COALESCE(SUM(p.monto_cordobas), 0) AS monto,
             COUNT(*) AS qty
      FROM pagos p
      JOIN cuotas cu ON cu.id = p.cuota_id
      WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
        AND cu.estado != 'anulada'
        AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?
        AND $_noSuspendido
      GROUP BY date(p.fecha_pago)
      ORDER BY dia
    ''', parameters: [i, f]);

    // Segunda curva: de lo cobrado del ciclo, la parte que entró TARDE (pasada
    // la gracia). Es el MISMO universo que el de arriba con una condición más,
    // así que la curva de mora queda siempre por debajo de la de cobros — no
    // son dos cosas que se suman, es una adentro de la otra.
    //
    // Pedido del dueño: quería ver la mora sobre el gráfico de cobros para
    // saber cuánto de lo recuperado vino de gente que pagó a destiempo.
    _moraDailyStream = ps.db.watch('''
      SELECT date(p.fecha_pago) AS dia,
             COALESCE(SUM(p.monto_cordobas), 0) AS monto,
             COUNT(*) AS qty
      FROM pagos p
      JOIN cuotas cu ON cu.id = p.cuota_id
      WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
        AND cu.estado != 'anulada'
        AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?
        AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date(p.fecha_pago)
        AND $_noSuspendido
      GROUP BY date(p.fecha_pago)
      ORDER BY dia
    ''', parameters: [i, f, g]);
  }

  @override
  Widget build(BuildContext context) {
    final diasGracia =
        ref.watch(appSettingsProvider.select((s) => s.diasGracia));
    if (diasGracia != _diasGracia) {
      _diasGracia = diasGracia;
      _rebuildStreams();
    }

    return _TendenciaCardShell(
      titulo: 'Cobros del mes',
      subtitulo: 'De lo que vence en el ciclo, cuánto ya se cobró',
      icon: Icons.show_chart,
      anio: _anio,
      mes: _mes,
      inicioDate: _inicioDate,
      finDate: _finDate,
      puedeAvanzar: _puedeAvanzar,
      onCambiarMes: _cambiarMes,
      chartColor: const Color(0xFF1D9E75),
      // Vocabulario del dueño del tenant, repuesto a pedido (2026-08-10).
      // Habían pasado a 'Facturado/Cobrado/Falta cobrar' porque "Cobros" en la
      // fila del TOTAL se lee como plata en caja, cuando es lo FACTURADO del
      // ciclo — y eso fue exactamente lo que lo hizo sumar mal. Vuelve a sus
      // palabras porque son las que usa su equipo; lo que desambigua ahora es
      // el subtítulo de la tarjeta y la nota del pie, que dicen explícitamente
      // que el 100% es lo que vence en el ciclo, no lo que entró.
      metaLabel: 'Cobros',
      recLabel: 'Recuperado',
      porRecLabel: 'Por recuperar',
      subRecLabel: 'tarde (pasada la gracia)',
      ocultarRecaudado: widget.ocultarRecaudado,
      info: kInfoCobrosDelMes,
      summaryStream: _summaryStream,
      dailyStream: _dailyStream,
      moraDailyStream: _moraDailyStream,
      moraLineColor: const Color(0xFFE24B4A),
      moraLegendLabel: 'Recuperado tarde (mora)',
      esPeriodoActual: _esPeriodoActual,
    );
  }
}

// ── Mora ──

class TendenciaMoraCard extends ConsumerStatefulWidget {
  const TendenciaMoraCard({super.key, this.ocultarRecaudado = false});

  /// Esconde lo COBRADO y deja lo PENDIENTE. Lo usa el rol admin_cobranza,
  /// que por definicion no ve montos recolectados pero SI gestiona mora y
  /// recuperacion de cartera. Antes se le ocultaba la tarjeta ENTERA: entraba
  /// al Resumen y no veia nada, ni la mora — que es literalmente su trabajo.
  final bool ocultarRecaudado;
  @override
  ConsumerState<TendenciaMoraCard> createState() => _TendenciaMoraCardState();
}

class _TendenciaMoraCardState extends ConsumerState<TendenciaMoraCard> {
  late int _anio, _mes;
  int _diasGracia = 10;
  late Stream<List<Map<String, dynamic>>> _summaryStream;
  late Stream<List<Map<String, dynamic>>> _dailyStream;

  @override
  void initState() {
    super.initState();
    final p = periodoDe(Fmt.hoyNicaragua());
    _anio = p.year;
    _mes = p.month;
    _rebuildStreams();
  }

  DateTime get _inicioDate => inicioPeriodo(_anio, _mes);
  DateTime get _finDate => finPeriodo(_anio, _mes);
  String get _inicio => _inicioDate.toIso8601String().substring(0, 10);
  String get _fin => _finDate.toIso8601String().substring(0, 10);

  bool get _esPeriodoActual {
    final h = Fmt.hoyNicaragua();
    return !h.isBefore(_inicioDate) && h.isBefore(_finDate);
  }

  bool get _puedeAvanzar {
    final h = Fmt.hoyNicaragua();
    return !h.isBefore(_finDate);
  }

  void _cambiarMes(int delta) {
    final d = DateTime(_anio, _mes + delta, 1);
    final h = Fmt.hoyNicaragua();
    final nextStart = inicioPeriodo(d.year, d.month);
    if (h.isBefore(nextStart)) return;
    setState(() {
      _anio = d.year;
      _mes = d.month;
      _rebuildStreams();
    });
  }

  void _rebuildStreams() {
    final i = _inicio;
    final f = _fin;
    final g = _diasGracia;

    const saldo =
        'max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)';

    // META = universo BRUTO de mora del período: cuotas que cruzaron la gracia
    // estando vencidas — las que SIGUEN impagas Y las que se recuperaron TARDE.
    //
    // Antes META era solo lo impago (`estado IN pendiente/parcial`), que se
    // ACHICA a medida que se cobra, mientras REC (pagos tardíos) CRECE → REC
    // superaba a META y "Cumplimiento" daba hasta 1500% en meses cerrados, con
    // "Por recuperar" en 0 (audit 2026-08-01). Con el universo bruto,
    // REC ⊆ META siempre: Por recuperar = META − REC = lo que sigue impago.
    //
    // Una cuota está en el universo si cruzó la gracia Y estuvo vencida = sigue
    // pendiente/parcial (impaga) O recibió un pago DESPUÉS de la gracia
    // (recuperada tarde). Una cuota pagada a tiempo cuya gracia ya venció NO
    // entra (nunca estuvo en mora).
    const universoMora = '''
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < date('now','-6 hours')
             AND cu2.estado != 'anulada'
             AND $_noSuspendido2
             AND (cu2.estado IN ('pendiente','parcial')
                  OR EXISTS (SELECT 1 FROM pagos p3 WHERE p3.cuota_id = cu2.id AND COALESCE(p3.anulado, 0) = 0 AND COALESCE(p3.en_revision, 0) = 0
                               AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < date(p3.fecha_pago)))''';
    _summaryStream = ps.db.watch('''
      SELECT
        (SELECT COUNT(DISTINCT cu2.cliente_id) FROM cuotas cu2
           WHERE 1=1 $universoMora) AS meta_u,
        (SELECT COUNT(*) FROM cuotas cu2
           WHERE 1=1 $universoMora) AS meta_c,
        -- META monto bruto = saldo aún impago + pagos recuperados tarde.
        ( (SELECT COALESCE(SUM($saldo), 0) FROM cuotas cu
             WHERE cu.estado IN ('pendiente','parcial')
               AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?
               AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now','-6 hours')
               AND $_noSuspendido)
        + (SELECT COALESCE(SUM(p2.monto_cordobas), 0) FROM pagos p2
             JOIN cuotas cu2 ON cu2.id = p2.cuota_id
             WHERE COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0
               AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
               AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < date(p2.fecha_pago)
               AND $_noSuspendido2)
        ) AS meta_m,
        (SELECT COUNT(DISTINCT cu2.cliente_id) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0
             AND cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < date(p2.fecha_pago)
             AND $_noSuspendido2
        ) AS rec_u,
        (SELECT COUNT(DISTINCT p2.cuota_id) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0
             AND cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < date(p2.fecha_pago)
             AND $_noSuspendido2
        ) AS rec_c,
        (SELECT COALESCE(SUM(p2.monto_cordobas), 0) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0
             AND cu2.estado != 'anulada'
             AND date(cu2.fecha_vencimiento) >= ? AND date(cu2.fecha_vencimiento) < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < date(p2.fecha_pago)
             AND $_noSuspendido2
        ) AS rec_m,
        -- "Sigue impago": consultado dentro del universo de mora, no por resta
        -- (una cuota parcial cuenta en las dos filas).
        (SELECT COUNT(DISTINCT cu2.cliente_id) FROM cuotas cu2
           WHERE cu2.estado IN ('pendiente','parcial') $universoMora
             AND (cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0)) > 0.009
        ) AS porrec_u,
        (SELECT COUNT(*) FROM cuotas cu2
           WHERE cu2.estado IN ('pendiente','parcial') $universoMora
             AND (cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0)) > 0.009
        ) AS porrec_c
    ''', parameters: [
      i, f, g, g,   // meta_u (universo: i, f, gracia-vencida, gracia-EXISTS)
      i, f, g, g,   // meta_c (mismo universo)
      i, f, g,      // meta_m — saldo impago
      i, f, g,      // meta_m — pagos tardíos
      i, f, g,      // rec_u
      i, f, g,      // rec_c
      i, f, g,      // rec_m
      i, f, g, g,   // porrec_u (universo)
      i, f, g, g,   // porrec_c (universo)
    ]);

    _dailyStream = ps.db.watch('''
      SELECT date(p.fecha_pago) AS dia,
             COALESCE(SUM(p.monto_cordobas), 0) AS monto,
             COUNT(*) AS qty
      FROM pagos p
      JOIN cuotas cu ON cu.id = p.cuota_id
      WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
        AND cu.estado != 'anulada'
        AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?
        AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date(p.fecha_pago)
        AND $_noSuspendido
      GROUP BY date(p.fecha_pago)
      ORDER BY dia
    ''', parameters: [i, f, g]);
  }

  @override
  Widget build(BuildContext context) {
    final diasGracia =
        ref.watch(appSettingsProvider.select((s) => s.diasGracia));
    if (diasGracia != _diasGracia) {
      _diasGracia = diasGracia;
      _rebuildStreams();
    }

    return _TendenciaCardShell(
      titulo: 'Mora del ciclo',
      subtitulo: 'Cuotas de este ciclo que pasaron los '
          '$_diasGracia días de gracia',
      icon: Icons.warning_amber_rounded,
      iconColor: Theme.of(context).colorScheme.error,
      anio: _anio,
      mes: _mes,
      inicioDate: _inicioDate,
      finDate: _finDate,
      puedeAvanzar: _puedeAvanzar,
      onCambiarMes: _cambiarMes,
      chartColor: const Color(0xFF1D9E75),
      metaLineColor: const Color(0xFFE24B4A),
      // Idem: vocabulario del dueño (2026-08-10).
      metaLabel: 'Total mora',
      recLabel: 'Recuperado',
      porRecLabel: 'Por recuperar',
      ocultarRecaudado: widget.ocultarRecaudado,
      info: kInfoMora,
      summaryStream: _summaryStream,
      dailyStream: _dailyStream,
      esPeriodoActual: _esPeriodoActual,
    );
  }
}

// ── Shell compartido ──

class _TendenciaCardShell extends StatelessWidget {
  const _TendenciaCardShell({
    required this.titulo,
    required this.subtitulo,
    required this.icon,
    this.iconColor,
    required this.anio,
    required this.mes,
    required this.inicioDate,
    required this.finDate,
    required this.puedeAvanzar,
    required this.onCambiarMes,
    required this.chartColor,
    this.metaLineColor,
    required this.metaLabel,
    required this.recLabel,
    required this.porRecLabel,
    this.subRecLabel,
    this.ocultarRecaudado = false,
    required this.summaryStream,
    required this.dailyStream,
    this.moraDailyStream,
    this.moraLineColor,
    this.moraLegendLabel,
    required this.esPeriodoActual,
    required this.info,
  });

  final String titulo;
  final String subtitulo;
  final IconData icon;
  final Color? iconColor;

  /// Aviso FIJO bajo la tabla (no detrás del (i)). Lo usa Mora para decir que
  /// su "Recuperado tarde" ya está contado dentro de Cobros del mes.
  final int anio, mes;
  final DateTime inicioDate, finDate;
  final bool puedeAvanzar;
  final void Function(int delta) onCambiarMes;
  final Color chartColor;
  final Color? metaLineColor;

  /// Segunda curva OPCIONAL sobre el mismo gráfico: de lo cobrado del ciclo, la
  /// parte que entró tarde. Solo la pasa "Cobros del mes". Es un SUBCONJUNTO de
  /// la curva principal —mismo universo con una condición más— así que va
  /// siempre por debajo: no se suman, una está adentro de la otra.
  final Stream<List<Map<String, dynamic>>>? moraDailyStream;
  final Color? moraLineColor;
  final String? moraLegendLabel;
  final String metaLabel, recLabel, porRecLabel;

  /// Rótulo de la sub-fila indentada bajo "Cobrado" (la porción que entró
  /// TARDE). Hace visible que el "Recuperado tarde" de la tarjeta de Mora está
  /// DENTRO de este número y no se suma aparte.
  final String? subRecLabel;

  /// Ver [TendenciaCobrosCard.ocultarRecaudado].
  final bool ocultarRecaudado;
  final Stream<List<Map<String, dynamic>>> summaryStream;
  final Stream<List<Map<String, dynamic>>> dailyStream;
  final bool esPeriodoActual;
  final InfoGrafica info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mesLabel = Fmt.mes(DateTime(anio, mes));
    final mesCapitalizado = mesLabel[0].toUpperCase() + mesLabel.substring(1);
    final periodo = periodoLabel(anio, mes);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: iconColor ?? scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(titulo,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                InfoGraficaBoton(info),
              ],
            ),
            // El EJE de la tarjeta en la cara, no detrás del (i): la confusión
            // del dueño (2026-08-08) fue sumar una tarjeta que mide por
            // vencimiento de cuota con otra que mide por fecha de pago.
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text(subtitulo,
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => onCambiarMes(-1),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Mes anterior',
                ),
                Column(
                  children: [
                    SizedBox(
                      width: 140,
                      child: Text(mesCapitalizado,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontWeight: FontWeight.w500, fontSize: 15)),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      // "Ciclo" adelante: el nombre del mes solo no alcanza —
                      // "Agosto 2026" cubre servicio de julio en el 99,95% de
                      // las cuotas, así que la ventana tiene que estar SIEMPRE
                      // a la vista y nombrada (pedido de Rubén 2026-08-08).
                      child: Text('Ciclo $periodo',
                          style: TextStyle(
                              fontSize: 11, color: scheme.onPrimaryContainer)),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: puedeAvanzar ? () => onCambiarMes(1) : null,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Mes siguiente',
                ),
              ],
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: summaryStream,
              builder: (context, snapSummary) {
                return StreamBuilder<List<Map<String, dynamic>>>(
                  stream: dailyStream,
                  builder: (context, snapDaily) {
                    if ((snapSummary.connectionState ==
                                ConnectionState.waiting &&
                            !snapSummary.hasData) ||
                        (snapDaily.connectionState ==
                                ConnectionState.waiting &&
                            !snapDaily.hasData)) {
                      return const SizedBox(
                          height: 200,
                          child:
                              Center(child: CircularProgressIndicator()));
                    }
                    if (snapSummary.hasError || snapDaily.hasError) {
                      return Text('Error al cargar datos',
                          style:
                              TextStyle(color: scheme.error, fontSize: 12));
                    }

                    final sr = snapSummary.data?.firstOrNull;
                    if (sr == null) return const SizedBox.shrink();

                    final resumen = _Resumen(
                      metaUsuarios: (sr['meta_u'] as num).toInt(),
                      metaCuotas: (sr['meta_c'] as num).toInt(),
                      metaMonto: sr['meta_m'] as num,
                      recUsuarios: (sr['rec_u'] as num).toInt(),
                      recCuotas: (sr['rec_c'] as num).toInt(),
                      recMonto: sr['rec_m'] as num,
                      recMontoTarde: sr['rec_m_tarde'] as num?,
                      porRecUsuariosQ: (sr['porrec_u'] as num?)?.toInt(),
                      porRecCuotasQ: (sr['porrec_c'] as num?)?.toInt(),
                    );

                    final dailyRows = snapDaily.data ?? [];
                    final dias = dailyRows
                        .map((r) => _DatosDia(
                              fecha: r['dia'] as String,
                              monto: r['monto'] as num,
                              qty: (r['qty'] as num).toInt(),
                            ))
                        .toList();

                    // Lo cobrado ANTES de que arrancara el ciclo (pre-pagos).
                    // Antes solo se veía pasando el mouse por el primer píxel
                    // del gráfico; es la mitad de por qué la caja del período
                    // no coincide con el "Cobrado" de esta tabla.
                    final adelantado = dias
                        .where((d) => DateTime.parse(d.fecha).isBefore(inicioDate))
                        .fold<double>(0, (s, d) => s + d.monto.toDouble());

                    return Column(
                      children: [
                        _TablaSummary(
                          resumen: resumen,
                          metaLabel: metaLabel,
                          recLabel: recLabel,
                          porRecLabel: porRecLabel,
                          subRecLabel: subRecLabel,
                          ocultarRecaudado: ocultarRecaudado,
                        ),
                        // Esta nota arranca con "De lo cobrado, C$X…": es un
                        // monto COBRADO explícito, y encima uno que NO se
                        // deriva de facturado−falta. Antes era inalcanzable
                        // para admin_cobranza porque la tarjeta entera estaba
                        // oculta; al devolverle la tarjeta quedó a la vista,
                        // justo arriba del cartel que dice que no ve montos
                        // cobrados. Medido: C$171.821,92 en Mairena.
                        if (adelantado > 0.009 && !ocultarRecaudado)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'De lo cobrado, ${Fmt.cordobas(adelantado)} ya venía '
                              'pagado por adelantado antes del '
                              '${inicioDate.day} ${mesCortoPeriodo(inicioDate.month)}.',
                              style:
                                  TextStyle(fontSize: 11, color: scheme.outline),
                            ),
                          ),
                        if (ocultarRecaudado)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Tu rol no muestra montos cobrados. Acá ves lo '
                              'facturado y lo que falta recuperar.',
                              style:
                                  TextStyle(fontSize: 11, color: scheme.outline),
                            ),
                          ),
                        // La nota de pie se mudó al botón (i) — pedido del
                        // dueño, que quería la tarjeta más limpia. El texto
                        // vive en `InfoGrafica.nota` de cada gráfica.
                        if (!ocultarRecaudado) const SizedBox(height: 16),
                        if (!ocultarRecaudado)
                          // Tercer stream anidado solo si hay curva de mora:
                          // sin `moraDailyStream` el StreamBuilder no se crea y
                          // la tarjeta de Mora sigue funcionando igual que antes.
                          StreamBuilder<List<Map<String, dynamic>>>(
                            stream: moraDailyStream,
                            builder: (context, snapMora) {
                              final diasMora = moraDailyStream == null
                                  ? null
                                  : (snapMora.data ?? [])
                                      .map((r) => _DatosDia(
                                            fecha: r['dia'] as String,
                                            monto: r['monto'] as num,
                                            qty: (r['qty'] as num).toInt(),
                                          ))
                                      .toList();
                              return _GraficoTendencia(
                                dias: dias,
                                diasMora: diasMora,
                                meta: resumen.metaMonto.toDouble(),
                                inicioDate: inicioDate,
                                finDate: finDate,
                                esPeriodoActual: esPeriodoActual,
                                lineColor: chartColor,
                                metaLineColor: metaLineColor,
                                metaLegendLabel: '$metaLabel (100%)',
                                moraLineColor: moraLineColor,
                                moraLegendLabel: moraLegendLabel,
                              );
                            },
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tabla de resumen ──

class _TablaSummary extends StatelessWidget {
  const _TablaSummary({
    required this.resumen,
    required this.metaLabel,
    required this.recLabel,
    required this.porRecLabel,
    this.subRecLabel,
    this.ocultarRecaudado = false,
  });
  final _Resumen resumen;
  final String metaLabel, recLabel, porRecLabel;
  final String? subRecLabel;

  /// Ver [TendenciaCobrosCard.ocultarRecaudado].
  final bool ocultarRecaudado;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const headerStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w500);
    const cellStyle = TextStyle(fontSize: 12);
    final mutedStyle = TextStyle(fontSize: 11, color: scheme.outline);

    Widget pctPill(double pct, {bool invertido = false}) {
      final pctStr = '${(pct * 100).round()}%';
      Color color;
      if (invertido) {
        color = pct <= 0.3
            ? Colors.green.shade700
            : (pct <= 0.7 ? Colors.orange.shade700 : scheme.error);
      } else {
        color = pct >= 0.7
            ? Colors.green.shade700
            : (pct >= 0.3 ? Colors.orange.shade700 : scheme.error);
      }
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(pctStr,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w500, color: color)),
      );
    }

    Widget fila(String label, Color dotColor, int usuarios, int cuotas,
        num monto, double pct,
        {bool invertido = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            SizedBox(
                width: 92,
                child: Text(label,
                    style: cellStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis)),
            Expanded(
              child: Text(Fmt.entero(usuarios),
                  style: mutedStyle, textAlign: TextAlign.right),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(Fmt.entero(cuotas),
                  style: mutedStyle, textAlign: TextAlign.right),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(Fmt.cordobas(monto), style: cellStyle),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
                width: 44,
                child: Center(
                    child: pctPill(pct, invertido: invertido))),
          ],
        ),
      );
    }

    // Sub-fila indentada: mismo ancho de columnas, sin punto ni pastilla de %,
    // para que se lea como un desglose DENTRO de la fila de arriba y no como
    // una cuarta categoría sumable.
    Widget subFila(String label, num monto) {
      return Padding(
        padding: const EdgeInsets.only(left: 26, top: 1, bottom: 3),
        child: Row(
          children: [
            Icon(Icons.subdirectory_arrow_right,
                size: 12, color: scheme.outline),
            const SizedBox(width: 4),
            Expanded(
              child: Text(label,
                  style: mutedStyle, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(Fmt.cordobas(monto), style: mutedStyle),
            ),
            const SizedBox(width: 50),
          ],
        ),
      );
    }

    final r = resumen;
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 14),
              SizedBox(width: 92),
              Expanded(
                  child: Text('Usuarios',
                      style: headerStyle, textAlign: TextAlign.right)),
              SizedBox(width: 8),
              Expanded(
                  child: Text('Cuotas',
                      style: headerStyle, textAlign: TextAlign.right)),
              SizedBox(width: 8),
              Expanded(
                  flex: 2,
                  child: Text('Monto',
                      style: headerStyle, textAlign: TextAlign.right)),
              SizedBox(width: 6),
              SizedBox(
                  width: 44,
                  child: Center(
                      child: Text('%', style: headerStyle))),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant),
        fila(metaLabel, scheme.primary, r.metaUsuarios, r.metaCuotas,
            r.metaMonto, 1.0),
        if (!ocultarRecaudado)
          fila(recLabel, const Color(0xFF1D9E75), r.recUsuarios, r.recCuotas,
              r.recMonto, r.pctRec),
        if (!ocultarRecaudado && subRecLabel != null && r.recMontoTarde != null) ...[
          subFila('a tiempo o en gracia', r.recMontoATiempo!),
          subFila(subRecLabel!, r.recMontoTarde!),
        ],
        fila(porRecLabel, const Color(0xFFE24B4A), r.porRecUsuarios,
            r.porRecCuotas, r.porRecMonto, r.pctPorRec,
            invertido: true),
        // Desde que los conteos se consultan (y no se restan), un cliente que
        // pagó una cuota del ciclo y debe otra aparece en las DOS filas, así
        // que la columna Usuarios ya no suma vertical. Es correcto, pero hay
        // que decirlo: si no, es otra vez "los números no cuadran".
        // La aclaración de que la columna Usuarios no suma vertical también
        // se mudó al botón (i).
      ],
    );
  }
}

// ── Gráfico de tendencia interactivo ──

class _GraficoTendencia extends StatefulWidget {
  const _GraficoTendencia({
    required this.dias,
    required this.meta,
    required this.inicioDate,
    required this.finDate,
    required this.esPeriodoActual,
    required this.lineColor,
    required this.metaLegendLabel,
    this.metaLineColor,
    this.diasMora,
    this.moraLineColor,
    this.moraLegendLabel,
  });
  final String metaLegendLabel;
  final List<_DatosDia> dias;

  /// Serie de la curva secundaria (lo recuperado TARDE). null = no se dibuja.
  final List<_DatosDia>? diasMora;
  final Color? moraLineColor;
  final String? moraLegendLabel;
  final double meta;
  final DateTime inicioDate;
  final DateTime finDate;
  final bool esPeriodoActual;
  final Color lineColor;
  final Color? metaLineColor;

  @override
  State<_GraficoTendencia> createState() => _GraficoTendenciaState();
}

class _GraficoTendenciaState extends State<_GraficoTendencia> {
  int? _selectedIndex;

  int get _diasEnPeriodo =>
      widget.finDate.difference(widget.inicioDate).inDays;

  int get _diasConDatos {
    if (!widget.esPeriodoActual) return _diasEnPeriodo;
    final h = Fmt.hoyNicaragua();
    return h.difference(widget.inicioDate).inDays + 1;
  }

  SerieTendencia get _serie => construirSerieTendencia(
        [for (final d in widget.dias) FilaDiaria(d.fecha, d.monto, d.qty)],
        widget.inicioDate,
        widget.finDate,
        _diasConDatos,
      );

  static const _leftPad = 50.0;

  void _onTap(Offset local, double fullWidth) {
    if (fullWidth <= _leftPad || _diasConDatos <= 0) return;
    final chartW = fullWidth - _leftPad;
    final step = chartW / _diasEnPeriodo;
    final idx =
        ((local.dx - _leftPad) / step).floor().clamp(0, _diasConDatos - 1);
    if (idx == _selectedIndex) {
      setState(() => _selectedIndex = null);
    } else {
      setState(() => _selectedIndex = idx);
    }
  }

  void _onHover(Offset local, double fullWidth) {
    if (fullWidth <= _leftPad || _diasConDatos <= 0) return;
    final chartW = fullWidth - _leftPad;
    final step = chartW / _diasEnPeriodo;
    final idx =
        ((local.dx - _leftPad) / step).floor().clamp(0, _diasConDatos - 1);
    if (idx != _selectedIndex) setState(() => _selectedIndex = idx);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final serie = _serie;
    final acumulados = serie.acumulados;
    // Misma transformación que la principal, con la misma ventana y el mismo
    // conteo de días: así los dos puntos del día `i` son comparables.
    final dm = widget.diasMora;
    final acumuladosMora = dm == null
        ? null
        : construirSerieTendencia(
            [for (final d in dm) FilaDiaria(d.fecha, d.monto, d.qty)],
            widget.inicioDate,
            widget.finDate,
            _diasConDatos,
          ).acumulados;
    const chartHeight = 180.0;
    final metaColor = widget.metaLineColor ?? scheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tendencia acumulada (monto C\$)',
            style: TextStyle(fontSize: 12, color: scheme.outline)),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final chartWidth = constraints.maxWidth;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                MouseRegion(
                  onHover: (e) => _onHover(e.localPosition, chartWidth),
                  onExit: (_) => setState(() => _selectedIndex = null),
                  child: GestureDetector(
                    onTapDown: (d) => _onTap(d.localPosition, chartWidth),
                    onHorizontalDragUpdate: (d) =>
                        _onHover(d.localPosition, chartWidth),
                    onHorizontalDragEnd: (_) =>
                        setState(() => _selectedIndex = null),
                    child: CustomPaint(
                      size: Size(chartWidth, chartHeight),
                      painter: _TendenciaPainter(
                        acumulados: acumulados,
                        acumuladosMora: acumuladosMora,
                        moraLineColor: widget.moraLineColor,
                        baseline: serie.baseline,
                        tail: serie.tail,
                        granTotal: serie.granTotal,
                        meta: widget.meta,
                        diasEnPeriodo: _diasEnPeriodo,
                        diasConDatos: _diasConDatos,
                        esPeriodoActual: widget.esPeriodoActual,
                        inicioDate: widget.inicioDate,
                        lineColor: widget.lineColor,
                        metaLineColor: metaColor,
                        gridColor: scheme.outlineVariant.withValues(alpha: 0.3),
                        textColor: scheme.outline,
                        selectedIndex: _selectedIndex,
                      ),
                    ),
                  ),
                ),
                if (_selectedIndex != null &&
                    _selectedIndex! < acumulados.length)
                  Builder(builder: (_) {
                    final idx = _selectedIndex!;
                    // La fecha del tooltip ahora SÍ corresponde a la plata del
                    // día: los pagos fuera de ventana ya no caen acá (van a
                    // baseline/tail), así que `inicioDate + idx` es el día real.
                    final date =
                        widget.inicioDate.add(Duration(days: idx));
                    final acum = acumulados[idx];
                    final montoDia = serie.montoPorDia[idx] ?? 0;
                    final qtyDia = serie.qtyPorDia[idx] ?? 0;
                    final chartW = chartWidth - _leftPad;
                    final xPos =
                        _leftPad + (idx + 0.5) / _diasEnPeriodo * chartW;
                    final goLeft = xPos > chartWidth * 0.6;

                    return Positioned(
                      top: 0,
                      left: goLeft ? null : xPos + 8,
                      right: goLeft ? chartWidth - xPos + 8 : null,
                      child: IgnorePointer(
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 200),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${date.day} de ${Fmt.mes(DateTime(date.year, date.month))}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w500, fontSize: 13),
                              ),
                              const SizedBox(height: 4),
                              _tooltipRow('Acumulado', Fmt.cordobas(acum),
                                  widget.lineColor),
                              _tooltipRow(
                                  'Del día',
                                  montoDia > 0
                                      ? '${Fmt.cordobas(montoDia)} ($qtyDia)'
                                      : 'C\$ 0,00',
                                  scheme.primary),
                              // El acumulado del día 0 ya incluye el pre-ciclo;
                              // se aclara para que no parezca que se cobró todo
                              // ese día.
                              if (idx == 0 && serie.baseline > 0)
                                _tooltipRow(
                                    'Antes del ciclo',
                                    Fmt.cordobas(serie.baseline),
                                    scheme.outline),
                              // El ÚLTIMO día del período cerrado suma lo cobrado
                              // tarde: se aclara para que el salto no confunda.
                              if (idx == acumulados.length - 1 && serie.tail > 0)
                                _tooltipRow(
                                    'Después del ciclo',
                                    Fmt.cordobas(serie.tail),
                                    scheme.outline),
                              if (widget.meta > 0)
                                _tooltipRow(
                                    'Cumplimiento',
                                    '${(acum / widget.meta * 100).toStringAsFixed(1)}%',
                                    scheme.outline),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        // `Wrap` y no `Row`: con la tercera referencia (mora) no entran las
        // tres en una línea en pantallas angostas, y un Row las desbordaría.
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _legendItem(widget.lineColor, 'Recuperado acumulado'),
            // NO es una meta: es el 100% de la tarjeta (lo facturado del ciclo
            // o el total que cayó en mora). No existe ningún setting de meta.
            _legendItem(metaColor, widget.metaLegendLabel, dashed: true),
            if (widget.diasMora != null &&
                widget.moraLineColor != null &&
                widget.moraLegendLabel != null)
              _legendItem(widget.moraLineColor!, widget.moraLegendLabel!),
          ],
        ),
        if (widget.diasMora != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'La línea de mora va SIEMPRE por debajo: es la parte de lo '
              'recuperado que entró tarde, no plata aparte.',
              style: TextStyle(fontSize: 10.5, color: scheme.outline),
            ),
          ),
        // La nota "Base X recuperado antes del ciclo · Y después" se quitó
        // (2026-08-01, pedido de Rubén): la curva igual arranca elevada para
        // cerrar en el total y el tooltip del día 0/último lo aclara al pasar.
      ],
    );
  }

  Widget _tooltipRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, color: color)),
          const SizedBox(width: 6),
          Text(value,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label, {bool dashed = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dashed)
          CustomPaint(
            size: const Size(16, 8),
            painter: _DashedLinePainter(color: color),
          )
        else
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

// ── Painter ──

class _TendenciaPainter extends CustomPainter {
  _TendenciaPainter({
    required this.acumulados,
    this.acumuladosMora,
    this.moraLineColor,
    required this.baseline,
    required this.tail,
    required this.granTotal,
    required this.meta,
    required this.diasEnPeriodo,
    required this.diasConDatos,
    required this.esPeriodoActual,
    required this.inicioDate,
    required this.lineColor,
    required this.metaLineColor,
    required this.gridColor,
    required this.textColor,
    this.selectedIndex,
  });

  final List<double> acumulados;

  /// Curva secundaria: de lo acumulado, la parte que entró tarde. Va SIEMPRE
  /// por debajo de la principal (es un subconjunto del mismo universo), así que
  /// comparte escala y no necesita segundo eje.
  final List<double>? acumuladosMora;
  final Color? moraLineColor;
  final double baseline; // recuperado antes del ciclo (base del día 0)
  final double tail; // recuperado después del ciclo (meses cerrados)
  final double granTotal; // = "Recuperado" de la tabla
  final double meta;
  final int diasEnPeriodo;
  final int diasConDatos;
  final bool esPeriodoActual;
  final DateTime inicioDate;
  final Color lineColor;
  final Color metaLineColor;
  final Color gridColor;
  final Color textColor;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 50.0;
    const bottomPad = 24.0;
    const topPad = 12.0;
    final chartW = size.width - leftPad;
    final chartH = size.height - bottomPad - topPad;

    final maxVal = [
      meta,
      granTotal, // incluye el tail: el eje tiene que abarcar el total real
      if (acumulados.isNotEmpty) acumulados.last,
    ].reduce(math.max);
    final yMax = maxVal > 0 ? maxVal * 1.1 : 100.0;

    double xOf(int offset) =>
        leftPad + (offset + 0.5) / diasEnPeriodo * chartW;
    double yOf(double val) => topPad + chartH * (1 - val / yMax);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    const gridLines = 4;
    for (var i = 0; i <= gridLines; i++) {
      final y = topPad + chartH * i / gridLines;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
    }
    canvas.drawLine(
        const Offset(leftPad, topPad), Offset(leftPad, topPad + chartH), gridPaint);
    canvas.drawLine(Offset(leftPad, topPad + chartH),
        Offset(size.width, topPad + chartH), gridPaint);

    final yLabelPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= gridLines; i++) {
      final val = yMax * (gridLines - i) / gridLines;
      final label = _formatCompact(val);
      yLabelPainter.text = TextSpan(
          text: label, style: TextStyle(fontSize: 10, color: textColor));
      yLabelPainter.layout();
      yLabelPainter.paint(
          canvas,
          Offset(leftPad - yLabelPainter.width - 4,
              topPad + chartH * i / gridLines - 6));
    }

    final xLabelPainter = TextPainter(textDirection: TextDirection.ltr);
    int? lastLabelMonth;
    for (var i = 0; i < diasEnPeriodo; i++) {
      final date = inicioDate.add(Duration(days: i));
      final isFirst = i == 0;
      final isLast = i == diasEnPeriodo - 1;
      final isMonthBoundary = date.day == 1;
      final isFifth = date.day % 5 == 0 && !isFirst && !isLast;

      if (!isFirst && !isLast && !isMonthBoundary && !isFifth) continue;

      String label;
      if (isMonthBoundary || (isFirst && lastLabelMonth != date.month)) {
        label = '${date.day} ${mesCortoPeriodo(date.month)}';
        lastLabelMonth = date.month;
      } else {
        label = '${date.day}';
      }

      xLabelPainter.text = TextSpan(
          text: label, style: TextStyle(fontSize: 10, color: textColor));
      xLabelPainter.layout();
      xLabelPainter.paint(
          canvas,
          Offset(xOf(i) - xLabelPainter.width / 2, topPad + chartH + 6));
    }

    if (meta > 0) {
      final metaY = yOf(meta);
      final dashPaint = Paint()
        ..color = metaLineColor.withValues(alpha: 0.5)
        ..strokeWidth = 1.5;
      _drawDashedLine(canvas, Offset(leftPad, metaY),
          Offset(size.width, metaY), dashPaint, 6, 4);
    }

    // (La línea punteada "pre-ciclo" del baseline se quitó — 2026-08-01, pedido
    // de Rubén. La curva SIGUE arrancando desde `baseline` — ver `acumulados`,
    // que ya lo incluyen — para cerrar en el total; solo se sacó el marcador.)

    if (acumulados.isEmpty) return;

    final fillPath = Path();
    fillPath.moveTo(xOf(0), topPad + chartH);
    for (var i = 0; i < acumulados.length; i++) {
      fillPath.lineTo(xOf(i), yOf(acumulados[i]));
    }
    fillPath.lineTo(xOf(acumulados.length - 1), topPad + chartH);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.25),
          lineColor.withValues(alpha: 0.02),
        ],
      ).createShader(Rect.fromLTWH(leftPad, topPad, chartW, chartH));
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final linePath = Path();
    for (var i = 0; i < acumulados.length; i++) {
      final x = xOf(i);
      final y = yOf(acumulados[i]);
      if (i == 0) {
        linePath.moveTo(x, y);
      } else {
        linePath.lineTo(x, y);
      }
    }
    canvas.drawPath(linePath, linePaint);

    // Curva de mora, punteada para que se distinga de la principal sin
    // competir con ella: es un detalle DENTRO de lo cobrado, no otra magnitud.
    final accMora = acumuladosMora;
    if (accMora != null && accMora.isNotEmpty && moraLineColor != null) {
      final moraPaint = Paint()
        ..color = moraLineColor!
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final moraPath = Path();
      for (var i = 0; i < accMora.length && i < acumulados.length; i++) {
        final x = xOf(i);
        final y = yOf(accMora[i]);
        if (i == 0) {
          moraPath.moveTo(x, y);
        } else {
          moraPath.lineTo(x, y);
        }
      }
      canvas.drawPath(moraPath, moraPaint);
    }

    if (esPeriodoActual && acumulados.isNotEmpty) {
      final lastX = xOf(acumulados.length - 1);
      final lastY = yOf(acumulados.last);
      canvas.drawCircle(
          Offset(lastX, lastY), 5, Paint()..color = lineColor);
      canvas.drawCircle(
          Offset(lastX, lastY),
          5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }

    if (selectedIndex != null && selectedIndex! < acumulados.length) {
      final sx = xOf(selectedIndex!);
      final sy = yOf(acumulados[selectedIndex!]);
      final vPaint = Paint()
        ..color = textColor.withValues(alpha: 0.4)
        ..strokeWidth = 1;
      _drawDashedLine(canvas, Offset(sx, topPad), Offset(sx, topPad + chartH),
          vPaint, 3, 2);
      canvas.drawCircle(
          Offset(sx, sy), 5, Paint()..color = lineColor);
      canvas.drawCircle(
          Offset(sx, sy),
          5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset from, Offset to, Paint paint,
      double dash, double gap) {
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    final ux = dx / dist;
    final uy = dy / dist;
    var drawn = 0.0;
    var drawing = true;
    while (drawn < dist) {
      final seg = drawing ? dash : gap;
      final end = math.min(drawn + seg, dist);
      if (drawing) {
        canvas.drawLine(
          Offset(from.dx + ux * drawn, from.dy + uy * drawn),
          Offset(from.dx + ux * end, from.dy + uy * end),
          paint,
        );
      }
      drawn = end;
      drawing = !drawing;
    }
  }

  String _formatCompact(double val) {
    if (val >= 1000000) return '${(val / 1000000).toStringAsFixed(1)}M';
    if (val >= 1000) return '${(val / 1000).toStringAsFixed(0)}k';
    return val.toStringAsFixed(0);
  }

  @override
  bool shouldRepaint(covariant _TendenciaPainter old) =>
      old.acumulados != acumulados ||
      old.meta != meta ||
      old.baseline != baseline ||
      old.tail != tail ||
      old.granTotal != granTotal ||
      old.selectedIndex != selectedIndex ||
      old.diasEnPeriodo != diasEnPeriodo ||
      old.inicioDate != inicioDate;
}

class _DashedLinePainter extends CustomPainter {
  _DashedLinePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    const dash = 4.0;
    const gap = 3.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
          Offset(x, size.height / 2),
          Offset(math.min(x + dash, size.width), size.height / 2),
          paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter old) =>
      old.color != color;
}
