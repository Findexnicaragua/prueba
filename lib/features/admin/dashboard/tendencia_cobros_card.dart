import 'dart:math' as math;

import 'escala_resumen.dart';
import 'bloque_parte_y_todo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import 'dashboard_export.dart';
import 'dashboard_query.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';
import 'mora_ciclos_card.dart' show MoraTablaCiclo;
import 'resumen_watch.dart';

// ── Paleta del corte de mora ──
// ROJO por pedido del dueño (2026-09-01), y es el MISMO `0xFFE24B4A` que usan
// "Por recuperar" acá y la tarjeta de Mora del ciclo entera. Que las dos
// tarjetas pinten la mora del mismo color no es estética: es lo que deja
// reconocer de un vistazo que hablan de la misma plata.
//
// Se probó primero en ámbar —el de "con abono parcial"— y quedaba como un
// tercer estado entre lo bueno y lo malo. La mora no es un matiz.
//
// El verde es el de "Recuperado": la mitad que entró en fecha se lee como parte
// de lo bueno, que es lo que es. (Estuvo un rato sin uso, entre que las filas
// "se cobraron a tiempo" y "todavía en plazo" se fueron de la tabla y que el
// globo pasó a mostrar las dos mitades del día.)
const _rojoMora = Color(0xFFE24B4A);
const _verdeOk = Color(0xFF1D9E75);

// ── Data ──

/// Una fila del globo del gráfico. Es DATA y no un widget porque la grilla
/// necesita verlas todas juntas para darle a cada columna el ancho de su celda
/// más ancha — que es lo que las mantiene alineadas sin importar el contenido.
class _GloboFila {
  const _GloboFila(this.rotulo, this.cuotas, this.monto,
      {this.color, this.total = false, this.tenue = false,
      this.separado = false, this.sangria = false, this.punto = true});
  final String rotulo;

  /// null = la fila no tiene conteo (el acumulado).
  final int? cuotas;
  final num monto;
  final Color? color;

  /// Fila de suma: negrita y línea arriba.
  final bool total;
  final bool tenue;

  /// Abre bloque: línea arriba, sin negrita.
  final bool separado;

  /// Corre el rótulo a la derecha. Dice "esto está ADENTRO de la fila de
  /// arriba", que es la diferencia entre leer un desglose y leer un sumando.
  final bool sangria;

  /// El puntito de color. Se apaga en las filas del bloque acumulado: ahí el
  /// color ya distingue, y un punto más compite con los de la curva —que sí
  /// marcan una serie del gráfico.
  final bool punto;
}

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
    required this.baselineQty,
    required this.tail,
    required this.tailQty,
    required this.montoPorDia,
    required this.qtyPorDia,
    required this.acumulados,
    required this.qtyAcumuladas,
    required this.granTotal,
  });
  final double baseline;
  /// Cuantas CUOTAS componen [baseline]. Se tiraba: el tooltip del primer dia
  /// podia decir "Antes del ciclo C$1.025" sin decir de cuantas cuotas salia.
  final int baselineQty;
  final double tail;
  /// Idem [baselineQty], para lo cobrado despues de que el ciclo cerro.
  final int tailQty;
  final Map<int, double> montoPorDia;
  final Map<int, int> qtyPorDia;
  final List<double> acumulados; // baseline + acumulado in-window, largo = dc

  /// El mismo acumulado que [acumulados], pero en CUOTAS. Se arma con la
  /// MISMA aritmética —arranca en [baselineQty] y el [tailQty] se pliega al
  /// último punto— para que las dos cifras del globo hablen del mismo
  /// conjunto: si una sumara el tail y la otra no, el renglón diría "7 cuotas
  /// · C\$4.990" con un 7 que no corresponde a esos 4.990.
  final List<int> qtyAcumuladas;
  final double granTotal;
}

/// Una linea del desglose de "Recuperado": que paso en un momento dado.
///
/// [saldadas] son las cuotas que quedaron sin saldo Y cuyo momento es este;
/// los cuatro momentos suman la fila madre. [monto] es TODA la plata que entro
/// en ese momento —incluida la de cuotas que siguen debiendo—, y los cuatro
/// suman el monto de la fila madre.
///
/// [parciales] recibieron algo y AUN DEBEN: su conteo NO suma aca (se cuentan
/// en "Por recuperar") pero su [parcialesMonto] SI esta dentro de [monto],
/// porque esa plata entro. [credito] son cuotas saldadas sin un peso de por
/// medio; su momento sale de la fecha en que se aplico el credito.
class LineaDesglose {
  const LineaDesglose({
    required this.momento,
    required this.saldadas,
    required this.monto,
    required this.parciales,
    required this.parcialesMonto,
    required this.credito,
    required this.mora,
    required this.moraMonto,
  });
  final String momento; // 'antes' | 'dentro' | 'despues' | 'sin'
  final int saldadas;
  final num monto;
  final int parciales;
  final num parcialesMonto;
  final int credito;

  /// De las [saldadas] de este momento, las que pagaron pasada la gracia.
  ///
  /// El momento dice CUÁNDO entró la plata; esto dice si llegó dentro del
  /// plazo. Los dos cortes son distintos y por eso conviven: una cuota puede
  /// pagarse "después del ciclo" y NO estar en mora — pasó el 14 pero dentro de
  /// los días de gracia de SU vencimiento. Eso, que antes no se podía ver,
  /// ahora se lee en el renglón.
  final int mora;

  /// El FACTURADO de esas cuotas, no lo cobrado tarde. Es el mismo número que
  /// mostraba la fila única antes de mudarse adentro de los momentos, así que
  /// la suma de los tres momentos da exactamente lo de antes.
  final num moraMonto;

  static List<LineaDesglose> deFilas(List<Map<String, dynamic>>? filas) {
    if (filas == null) return const [];
    num n(Map<String, dynamic> r, String k) => (r[k] as num?) ?? 0;
    // Orden fijo: es el recorrido temporal, no el que devuelva el GROUP BY.
    const orden = ['antes', 'dentro', 'despues', 'sin'];
    final porMomento = {for (final r in filas) '${r['momento']}': r};
    return [
      for (final m in orden)
        if (porMomento[m] != null &&
            (n(porMomento[m]!, 'saldadas') > 0 ||
                n(porMomento[m]!, 'monto') > 0.009))
          LineaDesglose(
            momento: m,
            saldadas: n(porMomento[m]!, 'saldadas').toInt(),
            monto: n(porMomento[m]!, 'monto'),
            parciales: n(porMomento[m]!, 'parciales').toInt(),
            parcialesMonto: n(porMomento[m]!, 'parciales_monto'),
            credito: n(porMomento[m]!, 'credito').toInt(),
            mora: n(porMomento[m]!, 'mora').toInt(),
            moraMonto: n(porMomento[m]!, 'mora_monto'),
          ),
    ];
  }

  /// Si esta linea tiene tercer nivel. Sin esto la flecha aparecería en las
  /// tres lineas y dos de ellas no abrirían nada.
  bool get tieneDetalle => parciales > 0 || credito > 0 || mora > 0;

  /// El rotulo del momento. Corto a proposito: entra en una linea.
  String get rotulo => switch (momento) {
        'antes' => 'antes del ciclo',
        'despues' => 'después del ciclo',
        'sin' => 'sin fecha de pago',
        _ => 'en el ciclo',
      };
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
  // Cuantas CUOTAS hay fuera de la ventana. Se tiraban: el tooltip podia decir
  // "Antes del ciclo C$1.025" pero no cuantas cuotas eran, y el dueno lo pidio.
  var baselineQty = 0, tailQty = 0;
  final monto = <int, double>{};
  final qty = <int, int>{};
  for (final d in dias) {
    final date = DateTime.parse(d.fecha);
    if (date.isBefore(inicio)) {
      baseline += d.monto.toDouble();
      baselineQty += d.qty;
      continue;
    }
    if (!date.isBefore(fin)) {
      tail += d.monto.toDouble();
      // Esta rama atrapa los pagos POSTERIORES al cierre en un ciclo cerrado y
      // se habia quedado sin el conteo: el tooltip decia "Despues del ciclo
      // 0 cuotas" con su monto al lado. La rama `idx >= n` de abajo tambien
      // suma tailQty pero solo corre en el periodo EN CURSO, asi que parchear
      // una sola dejaba el bug vivo justo donde se veia.
      tailQty += d.qty;
      continue;
    }
    final idx = date.difference(inicio).inDays;
    // idx queda en [0, díasDelPeriodo). En período cerrado dc = ese total, así
    // que idx < dc. En período actual, un pago fechado DESPUÉS de hoy (idx>=dc,
    // raro) se manda al tail para no clavarlo en el último día visible.
    if (idx < 0) {
      baseline += d.monto.toDouble();
      baselineQty += d.qty;
    } else if (idx >= n) {
      tail += d.monto.toDouble();
      tailQty += d.qty;
    } else {
      inWin += d.monto.toDouble();
      monto[idx] = (monto[idx] ?? 0) + d.monto.toDouble();
      qty[idx] = (qty[idx] ?? 0) + d.qty;
    }
  }
  final acum = <double>[];
  final acumQty = <int>[];
  var run = baseline;
  var runQty = baselineQty;
  for (var i = 0; i < n; i++) {
    run += (monto[i] ?? 0);
    runQty += (qty[i] ?? 0);
    acum.add(run);
    acumQty.add(runQty);
  }
  // El tail (recuperado DESPUÉS del ciclo, meses cerrados) se pliega al ÚLTIMO
  // punto para que la curva CIERRE en el "Recuperado" de la tabla — pedido del
  // dueño: al final del ciclo el acumulado tiene que concordar con el total.
  // "Del día" se mantiene REAL (no se infla); el tail se aclara en el tooltip
  // del último día ("Después del ciclo") y en la nota bajo la gráfica.
  if (acum.isNotEmpty && tail > 0) acum[acum.length - 1] += tail;
  // El conteo se pliega con la MISMA condición que el monto (`tail > 0`), no
  // con `tailQty > 0`: si se usaran condiciones distintas, un tail de monto
  // cero con cuotas —o al revés— dejaría las dos series contando universos
  // diferentes en el último punto.
  if (acumQty.isNotEmpty && tail > 0) {
    acumQty[acumQty.length - 1] += tailQty;
  }
  return SerieTendencia(
    baseline: baseline,
    baselineQty: baselineQty,
    tail: tail,
    tailQty: tailQty,
    montoPorDia: monto,
    qtyPorDia: qty,
    acumulados: acum,
    qtyAcumuladas: acumQty,
    granTotal: baseline + inWin + tail,
  );
}

/// Las tres filas que parten las cuotas del período: pagadas completas, a
/// medias, y sin pagar nada. Cada cuota está en una sola, así que las cuatro
/// columnas suman el total y el dueño puede auditarlas con calculadora.
///
/// Existe porque los conteos anteriores no partían: "Recuperado — Cuotas"
/// contaba las que recibieron ALGÚN pago y "Por recuperar" las que quedaban con
/// saldo, así que la cuota con abono parcial caía en las dos y 8 + 8 daba 16
/// sobre 15 (reclamo del dueño, 2026-08-11).
class ParticionCobro {
  const ParticionCobro({
    required this.completasCuotas,
    required this.completasFacturado,
    required this.completasEntro,
    required this.mediasCuotas,
    required this.mediasFacturado,
    required this.mediasEntro,
    required this.mediasFalta,
    required this.nadaCuotas,
    required this.nadaFacturado,
  });

  final int completasCuotas;
  final num completasFacturado;
  final num completasEntro;

  final int mediasCuotas;
  final num mediasFacturado;
  final num mediasEntro;
  final num mediasFalta;

  final int nadaCuotas;
  final num nadaFacturado;

  /// Lo que falta de las que no recibieron nada ES lo facturado.
  num get nadaFalta => nadaFacturado;

  /// Hay al menos una cuota a medias. La fila se muestra si esto es true O si
  /// el tenant tiene habilitado el pago parcial: con la feature apagada las
  /// parciales VIEJAS siguen existiendo hasta que se terminen de pagar, y
  /// esconderlas volvería a romper la suma.
  bool get hayMedias => mediasCuotas > 0;

  static ParticionCobro? deFila(Map<String, dynamic> r) {
    if (r['comp_c'] == null) return null; // la tarjeta de Mora no la trae
    num n(String k) => (r[k] as num?) ?? 0;
    return ParticionCobro(
      completasCuotas: n('comp_c').toInt(),
      completasFacturado: n('comp_f'),
      completasEntro: n('comp_e'),
      mediasCuotas: n('med_c').toInt(),
      mediasFacturado: n('med_f'),
      mediasEntro: n('med_e'),
      mediasFalta: n('med_s'),
      nadaCuotas: n('nada_c').toInt(),
      nadaFacturado: n('nada_f'),
    );
  }
}

/// Los otros dos cortes del mismo 100% del ciclo (ver `cortesDelCiclo`).
///
/// Por ORIGEN separa la cuota de servicio —cobro puntual y, cuando se habilite
/// el módulo, el cobro nacido de un ticket— de la mensualidad del contrato.
/// Por MORA reparte el facturado según CUÁNDO entró (o dejó de entrar).
///
/// Los tres cortes cierran en los mismos facturado/entró/falta porque reparten
/// las mismas cuotas; ninguno se suma con otro.
class CortesCiclo {
  const CortesCiclo({
    required this.contratoCuotas,
    required this.contratoFacturado,
    required this.contratoEntro,
    required this.contratoFalta,
    required this.servicioCuotas,
    required this.servicioFacturado,
    required this.servicioEntro,
    required this.servicioFalta,
    required this.aTiempoCuotas,
    required this.aTiempoFacturado,
    required this.cobradaEnMoraCuotas,
    required this.cobradaEnMoraFacturado,
    required this.sinSaldarCuotas,
    required this.sinSaldarFacturado,
    required this.sinSaldarEntro,
    required this.sinSaldarFalta,
    required this.enFechaCuotas,
    required this.enFechaFacturado,
    required this.enFechaEntro,
    required this.enFechaFalta,
    required this.recuperadoTarde,
    required this.sinSaldarMediasCuotas,
    required this.sinSaldarMediasFalta,
    required this.sinSaldarNadaCuotas,
    required this.sinSaldarNadaFalta,
  });

  /// [sinSaldarCuotas], partida entre las que ya recibieron un abono y las que
  /// no recibieron nada — las MISMAS dos filas en las que se parte "Por
  /// recuperar". Sirve para colgar la mora DENTRO de cada una en vez de al
  /// lado. Por construcción `medias + nada = sinSaldar`, en cuotas y en saldo.
  final int sinSaldarMediasCuotas;
  final num sinSaldarMediasFalta;
  final int sinSaldarNadaCuotas;
  final num sinSaldarNadaFalta;

  final int contratoCuotas;
  final num contratoFacturado, contratoEntro, contratoFalta;

  final int servicioCuotas;
  final num servicioFacturado, servicioEntro, servicioFalta;

  /// Las CUATRO del corte por mora. Reparten CUOTAS: cada una cae en un solo
  /// grupo por su estado final, así que los conteos suman las del ciclo y
  /// responden "de las 15, cuántas se cobraron estando en mora y cuántas
  /// siguen debiendo". Las columnas de plata cierran igual.
  ///
  /// Las dos primeras están saldadas (falta = 0); las dos últimas, no.
  final int aTiempoCuotas;
  final num aTiempoFacturado;
  final int cobradaEnMoraCuotas;
  final num cobradaEnMoraFacturado;
  final int sinSaldarCuotas;
  final num sinSaldarFacturado, sinSaldarEntro, sinSaldarFalta;
  final int enFechaCuotas;
  final num enFechaFacturado, enFechaEntro, enFechaFalta;

  /// Lo que la tarjeta de Mora llama "Recuperado": pagos posteriores a la
  /// gracia. Le da su techo a la curva roja del gráfico.
  final num recuperadoTarde;

  /// RECUPERADO: las cuotas que quedaron saldadas (a tiempo + en mora). Su
  /// facturado ES lo que entró — por eso no lleva "falta".
  int get recuperadoCuotas => aTiempoCuotas + cobradaEnMoraCuotas;
  num get recuperadoMonto => aTiempoFacturado + cobradaEnMoraFacturado;

  /// POR RECUPERAR: las que siguen con saldo. Puede haber entrado plata (un
  /// abono que no alcanzó), por eso tiene las tres columnas.
  int get porRecuperarCuotas => sinSaldarCuotas + enFechaCuotas;
  num get porRecuperarFacturado => sinSaldarFacturado + enFechaFacturado;
  num get porRecuperarEntro => sinSaldarEntro + enFechaEntro;
  num get porRecuperarFalta => sinSaldarFalta + enFechaFalta;

  /// Cuántas cuotas del ciclo pasaron por mora. No es un número nuevo: es la
  /// suma de las dos sub-filas "en mora" que ya están en la tabla.
  int get moraCuotas => cobradaEnMoraCuotas + sinSaldarCuotas;
  num get moraEntro => cobradaEnMoraFacturado + sinSaldarEntro;
  num get moraFalta => sinSaldarFalta;

  /// Lo facturado por esas cuotas. Es el TECHO de la curva roja: de todo esto
  /// se podía recuperar, y [recuperadoTarde] es lo que efectivamente entró
  /// después de la gracia.
  num get moraFacturado => cobradaEnMoraFacturado + sinSaldarFacturado;

  /// Lo que REALMENTE cayó en atraso: lo cobrado tarde más lo que sigue
  /// impago. NO es el facturado de esas cuotas — un abono hecho dentro de la
  /// gracia nunca estuvo en mora.
  num get moraFacturadoReal => recuperadoTarde + sinSaldarFalta;

  /// El bloque de servicios solo se dibuja si hay algo.
  bool get hayServicios => servicioCuotas > 0;

  static CortesCiclo? deFila(Map<String, dynamic>? r) {
    if (r == null || r['ctr_c'] == null) return null;
    num n(String k) => (r[k] as num?) ?? 0;
    return CortesCiclo(
      contratoCuotas: n('ctr_c').toInt(),
      contratoFacturado: n('ctr_f'),
      contratoEntro: n('ctr_e'),
      contratoFalta: n('ctr_s'),
      servicioCuotas: n('srv_c').toInt(),
      servicioFacturado: n('srv_f'),
      servicioEntro: n('srv_e'),
      servicioFalta: n('srv_s'),
      aTiempoCuotas: n('at_c').toInt(),
      aTiempoFacturado: n('at_f'),
      cobradaEnMoraCuotas: n('cm_c').toInt(),
      cobradaEnMoraFacturado: n('cm_f'),
      sinSaldarCuotas: n('sm_c').toInt(),
      sinSaldarFacturado: n('sm_f'),
      sinSaldarEntro: n('sm_e'),
      sinSaldarFalta: n('sm_s'),
      enFechaCuotas: n('ef_c').toInt(),
      enFechaFacturado: n('ef_f'),
      enFechaEntro: n('ef_e'),
      enFechaFalta: n('ef_s'),
      recuperadoTarde: n('m_cobrado'),
      sinSaldarMediasCuotas: n('sm_med_c').toInt(),
      sinSaldarMediasFalta: n('sm_med_s'),
      sinSaldarNadaCuotas: n('sm_nada_c').toInt(),
      sinSaldarNadaFalta: n('sm_nada_s'),
    );
  }
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
    this.porRecMontoQ,
    this.particion,
    this.cortes,
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

  /// Monto de lo que falta cobrar, CONSULTADO con el saldo canónico clampeado
  /// cuota por cuota — el mismo universo que sus conteos.
  ///
  /// Antes era `metaMonto - recMonto`, o sea la suma ALGEBRAICA de los saldos:
  /// una cuota sobre-cubierta aportaba saldo negativo y le comía deuda a los
  /// demás clientes. La fila mostraba "8 cuotas · C$4.200" cuando esas 8 cuotas
  /// sumaban C$5.400, y el dueño que abría el detalle y sumaba encontraba
  /// C$1.200 de diferencia. El fallback por resta se conserva para la tarjeta
  /// de Mora, cuya pata ya viene clampeada.
  final num? porRecMontoQ;

  /// Partición por estado de cobro: cada cuota del período cae en UN grupo.
  /// Null en la tarjeta de Mora, que no la usa.
  final ParticionCobro? particion;

  /// Los otros dos cortes del mismo 100%. Null en la tarjeta de Mora.
  final CortesCiclo? cortes;

  /// Copia con los cortes enchufados: llegan por un stream aparte y más tarde
  /// que el resumen, así que el `_Resumen` nace sin ellos.
  _Resumen conCortes(CortesCiclo? c) => _Resumen(
        metaUsuarios: metaUsuarios,
        metaCuotas: metaCuotas,
        metaMonto: metaMonto,
        recUsuarios: recUsuarios,
        recCuotas: recCuotas,
        recMonto: recMonto,
        recMontoTarde: recMontoTarde,
        porRecUsuariosQ: porRecUsuariosQ,
        porRecCuotasQ: porRecCuotasQ,
        porRecMontoQ: porRecMontoQ,
        particion: particion,
        cortes: c,
      );

  int get porRecUsuarios =>
      porRecUsuariosQ ?? math.max(metaUsuarios - recUsuarios, 0);
  int get porRecCuotas => porRecCuotasQ ?? math.max(metaCuotas - recCuotas, 0);
  num get porRecMonto =>
      porRecMontoQ ?? (metaMonto - recMonto).clamp(0, double.infinity);

  /// Lo cobrado que EXCEDE lo que se debía (cuotas sobre-cubiertas). Se muestra
  /// aparte en vez de esconderse: es plata que entró, pero no cancela deuda de
  /// nadie más. Con esto la columna cierra por verificación —
  /// `recMontoAplicado + porRecMonto = metaMonto`— y no por construcción.
  num get excedente => math.max(recMonto + porRecMonto - metaMonto, 0);

  /// La parte de [recMonto] que efectivamente cubrió deuda del período.
  num get recMontoAplicado => recMonto - excedente;

  double get pctRec =>
      metaMonto > 0 ? (recMontoAplicado / metaMonto).clamp(0, 1) : 0;
  double get pctPorRec =>
      metaMonto > 0 ? (porRecMonto / metaMonto).clamp(0, 1) : 0;
}

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

class _TendenciaCobrosCardState extends ConsumerState<TendenciaCobrosCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int _ultimoRefreshEpoch = 0;
  late int _anio, _mes;

  /// Días de gracia del tenant. Arranca en null a propósito: hasta que los
  /// settings no cargan, `appSettingsProvider` devuelve el default 10, y armar
  /// las consultas con ese valor pinta un primer frame con la mora de otro
  /// tenant. Telenet (gracia 5) abría en C$267.884 y saltaba a C$384.125 sin
  /// que nadie tocara nada.
  int? _diasGracia;
  Stream<List<Map<String, dynamic>>> _summaryStream = const Stream.empty();
  Stream<List<Map<String, dynamic>>> _dailyStream = const Stream.empty();
  Stream<List<Map<String, dynamic>>> _cortesStream = const Stream.empty();

  /// La serie diaria de lo cobrado EN MORA — la curva roja del gráfico.
  Stream<List<Map<String, dynamic>>> _moraStream = const Stream.empty();

  /// Lo que entró cada día pero es de OTRO ciclo. No alimenta ninguna curva:
  /// sólo el renglón del globo, para que un día con cobros de meses anteriores
  /// deje de decir "sin cobros este día".
  Stream<List<Map<String, dynamic>>> _otrosCiclosStream = const Stream.empty();
  Stream<List<Map<String, dynamic>>> _desgloseStream = const Stream.empty();

  /// El día de corte, igual que en la tarjeta de Mora: los cortes por mora
  /// dependen de él y tiene que ser el MISMO que ve el Excel.
  String _hoy = isoDia(Fmt.hoyNicaragua());

  @override
  void initState() {
    super.initState();
    final p = periodoDe(Fmt.hoyNicaragua());
    _anio = p.year;
    _mes = p.month;
  }

  DateTime get _inicioDate => inicioPeriodo(_anio, _mes);
  DateTime get _finDate => finPeriodo(_anio, _mes);
  String get _inicio => _inicioDate.toIso8601String().substring(0, 10);
  String get _fin => _finDate.toIso8601String().substring(0, 10);

  bool get _esPeriodoActual {
    final h = Fmt.hoyNicaragua();
    return !h.isBefore(_inicioDate) && h.isBefore(_finDate);
  }

  /// El vencimiento más nuevo que ya recibió un pago. Null hasta que llega la
  /// consulta; mientras tanto vale la regla vieja.
  DateTime? _ultimoVenceConPago;

  /// El ciclo mostrado ES futuro: todavía no empezó.
  bool get _esFuturo => Fmt.hoyNicaragua().isBefore(_inicioDate);

  bool get _puedeAvanzar {
    final h = Fmt.hoyNicaragua();
    // La regla de siempre: hasta el ciclo en curso.
    if (!h.isBefore(_finDate)) return true;
    // Y desde el 2026-09-02, un ciclo futuro TAMBIÉN se abre si ya tiene
    // cobros — el caso del cliente que paga por adelantado. Rubén lo encontró
    // probando: cobró el 02/09 una cuota que vence el 28/09 y no podía abrir
    // Octubre para verla.
    //
    // El criterio es "tiene PAGOS", no "tiene cuotas": las cuotas se generan
    // meses por adelantado y con ese criterio el selector recorrería ciclos
    // vacíos (18 ciclos con cuotas contra 8 con pagos, en el Test Tenant).
    final u = _ultimoVenceConPago;
    if (u == null) return false;
    // ¿El ciclo SIGUIENTE al mostrado contiene ese vencimiento o es anterior?
    final finSiguiente = finPeriodo(_anio, _mes + 1);
    return u.isBefore(finSiguiente);
  }

  void _cambiarMes(int delta) {
    final d = DateTime(_anio, _mes + delta, 1);
    final h = Fmt.hoyNicaragua();
    final nextStart = inicioPeriodo(d.year, d.month);
    // Hacia el FUTURO sólo se avanza si ese ciclo ya tiene cobros: es el mismo
    // criterio de `_puedeAvanzar`, repetido acá porque este método también lo
    // llama el gesto de swipe, que no pasa por el botón.
    if (h.isBefore(nextStart)) {
      final u = _ultimoVenceConPago;
      if (u == null || !u.isBefore(finPeriodo(d.year, d.month))) return;
    }
    setState(() {
      _anio = d.year;
      _mes = d.month;
      _rebuildStreams();
    });
  }

  void _rebuildStreams() {
    final q =
        resumenCobros(inicio: _inicio, fin: _fin, diasGracia: _diasGracia!);
    _summaryStream = watchResumen(q.sql, parameters: q.parametros);

    final serie = serieCobrosDiaria(inicio: _inicio, fin: _fin);
    _dailyStream = watchResumen(serie.sql, parameters: serie.parametros);

    // El desglose de mora de cada fila: cuantas de las pagadas estaban en mora
    // y cuantas de las pendientes lo estan. Va aparte de `resumenCobros`.
    final cortes = cortesDelCiclo(
        inicio: _inicio, fin: _fin, diasGracia: _diasGracia!, hoy: _hoy);
    _cortesStream = watchResumen(cortes.sql, parameters: cortes.parametros);
    // El desglose de "Recuperado" por CUANDO entro la plata. Va aparte porque
    // agrupa por momento y `resumenCobros` devuelve una sola fila.
    final desg = desgloseRecuperado(
        inicio: _inicio, fin: _fin, diasGracia: _diasGracia!);
    _desgloseStream = watchResumen(desg.sql, parameters: desg.parametros);

    // LA CURVA DE MORA, de vuelta (2026-09-01). Se habia ido el 2026-08-13
    // —"esta tarjeta mide CUMPLIMIENTO y nada mas"— y su consulta quedo
    // guardada con sus tests "para cuando se re-evalue la mora". Ese momento
    // llego: el dueño pidio ver la mora del ciclo aca, en rojo, junto a lo
    // recuperado.
    //
    // Es un SUBCONJUNTO de la serie verde (mismo universo, una condicion mas:
    // el pago entro pasada la gracia), asi que la roja queda siempre por
    // debajo. No son dos cosas que se suman.
    final sMora = serieMoraDiaria(
        inicio: _inicio, fin: _fin, diasGracia: _diasGracia!);
    _moraStream = watchResumen(sMora.sql, parameters: sMora.parametros);

    final sOtros = cobrosDeOtrosCiclosDiaria(
        inicio: _inicio, fin: _fin, diasGracia: _diasGracia!);
    _otrosCiclosStream =
        watchResumen(sOtros.sql, parameters: sOtros.parametros);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cargaron = ref.watch(settingsMapProvider).hasValue;
    final diasGracia =
        ref.watch(appSettingsProvider.select((s) => s.diasGracia));
    // A medianoche de Nicaragua entran cuotas nuevas a la mora y `db.watch`
    // no se entera solo. El provider AVISA; el corte sale del reloj, que
    // nunca está viejo (ver la nota en la tarjeta de Mora).
    ref.watch(diaNicaraguaProvider);
    final hoy = isoDia(Fmt.hoyNicaragua());

    // Límites de ciclo cacheados centralmente en Riverpod
    final limites = ref.watch(limitesCiclosProvider).valueOrNull;
    if (limites?.vence != null) {
      _ultimoVenceConPago = limites!.vence;
    }

    final refreshEpoch = ref.watch(dashboardRefreshEpochProvider);
    final huboRefresh = refreshEpoch != _ultimoRefreshEpoch;
    if (huboRefresh) {
      _ultimoRefreshEpoch = refreshEpoch;
    }

    if (cargaron && (diasGracia != _diasGracia || hoy != _hoy || huboRefresh)) {
      _diasGracia = diasGracia;
      _hoy = hoy;
      _rebuildStreams();
    }

    return _TendenciaCardShell(
      titulo: 'Cobertura del ciclo',
      // Para la tabla de mora que esta tarjeta hospeda. El MISMO corte que usa
      // el resto de la tarjeta: si cada parte resolviera su propio "hoy",
      // cruzar la medianoche haria que dos tablas de la misma pantalla
      // contaran cuotas distintas.
      diasGraciaMora: _diasGracia,
      hoyMora: _hoy,
      pagoParcialOn: ref.watch(pagoParcialHabilitadoProvider),
      // El Excel se arma con el MISMO corte y la MISMA gracia que la tarjeta:
      // si difirieran, el archivo no reproduciría lo que hay en pantalla.
      onExportar: _diasGracia == null
          ? null
          : () => exportarCobertura(
                anio: _anio,
                mes: _mes,
                diasGracia: _diasGracia!,
                hoy: _hoy,
              ),
      subtitulo: 'De lo que vence en el ciclo, cuánto ya se cobró',
      icon: Icons.show_chart,
      anio: _anio,
      mes: _mes,
      inicioDate: _inicioDate,
      finDate: _finDate,
      puedeAvanzar: _puedeAvanzar,
      esFuturo: _esFuturo,
      onCambiarMes: _cambiarMes,
      chartColor: const Color(0xFF1D9E75),
      // Vocabulario del dueño del tenant, repuesto a pedido (2026-08-10).
      // Habían pasado a 'Facturado/Cobrado/Falta cobrar' porque "Cobros" en la
      // fila del TOTAL se lee como plata en caja, cuando es lo FACTURADO del
      // ciclo — y eso fue exactamente lo que lo hizo sumar mal. Vuelve a sus
      // palabras porque son las que usa su equipo; lo que desambigua ahora es
      // el subtítulo de la tarjeta y la nota del pie, que dicen explícitamente
      // que el 100% es lo que vence en el ciclo, no lo que entró.
      ocultarRecaudado: widget.ocultarRecaudado,
      info: kInfoCobrosDelMes,
      summaryStream: _summaryStream,
      dailyStream: _dailyStream,
      // La curva de mora se fue a la tarjeta de Mora (2026-08-13): esta mide
      // CUMPLIMIENTO y nada mas. Su eje habla en % — la misma unidad que la
      // columna de la tabla, asi que la curva termina justo en el numero de la
      // fila Recuperado.
      cortesStream: _cortesStream,
      moraStream: _moraStream,
      otrosCiclosStream: _otrosCiclosStream,
      desgloseStream: _desgloseStream,
      ejePorcentaje: true,
      metaLegendLabel: 'Meta del ciclo (100%)', // el monto se agrega abajo
      esPeriodoActual: _esPeriodoActual,
    );
  }
}

// ── Mora ──

/// La tarjeta de Mora se MUDÓ a `mora_ciclos_card.dart` (2026-08-28).
/// Dejó de ser una curva diaria que agregaba los 6 meses en un solo número
/// —"64% global" no dice si la cartera viene mejorando— y pasó a ser barras
/// por ciclo + la tabla del ciclo elegido. `kCiclosMora` vive allá.

/// Botón de descarga del detalle. Estado de carga PROPIO, sin `showDialog`:
/// un diálogo de loading que no se cierra por una excepción deja la pantalla
/// negra sin salida (regla #7 del checklist de audit).
class _BotonExportar extends StatefulWidget {
  const _BotonExportar({required this.onExportar});
  final Future<String?> Function() onExportar;

  @override
  State<_BotonExportar> createState() => _BotonExportarState();
}

class _BotonExportarState extends State<_BotonExportar> {
  bool _bajando = false;

  Future<void> _bajar() async {
    if (_bajando) return;
    setState(() => _bajando = true);
    try {
      final ruta = await widget.onExportar();
      if (!mounted) return;
      if (ruta != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Guardado en $ruta')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo generar el Excel: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      // En el finally: si falla a mitad, el botón tiene que volver igual.
      if (mounted) setState(() => _bajando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bajando) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return IconButton(
      icon: const Icon(Icons.file_download_outlined, size: 20),
      tooltip: 'Descargar el detalle en Excel',
      onPressed: _bajar,
    );
  }
}

// ── Shell compartido ──

class _TendenciaCardShell extends StatelessWidget {
  const _TendenciaCardShell({
    required this.titulo,
    this.diasGraciaMora,
    this.hoyMora,
    required this.subtitulo,
    this.pagoParcialOn = true,
    this.onExportar,
    required this.icon,
    required this.anio,
    required this.mes,
    required this.inicioDate,
    required this.finDate,
    required this.puedeAvanzar,
    this.esFuturo = false,
    required this.onCambiarMes,
    required this.chartColor,
    this.ocultarRecaudado = false,
    required this.summaryStream,
    this.cortesStream,
    this.moraStream,
    this.otrosCiclosStream,
    this.desgloseStream,
    this.ejePorcentaje = false,
    this.metaLegendLabel,
    required this.dailyStream,
    required this.esPeriodoActual,
    required this.info,
  });

  final String titulo;

  /// Ver [_TablaSummary.pagoParcialOn].
  final bool pagoParcialOn;

  /// Baja a Excel el detalle del período MOSTRADO. Null = sin botón.
  final Future<String?> Function()? onExportar;
  final String subtitulo;
  final IconData icon;

  /// Aviso FIJO bajo la tabla (no detrás del (i)). Lo usa Mora para decir que
  /// su "Recuperado tarde" ya está contado dentro de Cobros del mes.
  final int anio, mes;
  final DateTime inicioDate, finDate;
  final bool puedeAvanzar;

  /// El ciclo mostrado todavía NO empezó. Sólo puede pasar desde que
  /// el selector deja abrir un ciclo futuro con cobros adelantados.
  final bool esFuturo;
  final void Function(int delta) onCambiarMes;
  final Color chartColor;

  /// Segunda curva OPCIONAL sobre el mismo gráfico: de lo cobrado del ciclo, la
  /// parte que entró tarde. Solo la pasa "Cobros del mes". Es un SUBCONJUNTO de
  /// la curva principal —mismo universo con una condición más— así que va
  /// siempre por debajo: no se suman, una está adentro de la otra.


  /// Ver [TendenciaCobrosCard.ocultarRecaudado].
  final bool ocultarRecaudado;
  final Stream<List<Map<String, dynamic>>> summaryStream;

  /// Solo Cobertura lo manda: el desglose de mora de cada fila.
  final Stream<List<Map<String, dynamic>>>? cortesStream;

  /// Lo cobrado en mora, día a día. Alimenta la curva roja.
  final Stream<List<Map<String, dynamic>>>? moraStream;

  /// Lo cobrado cada día que pertenece a OTRO ciclo. Sólo el globo.
  final Stream<List<Map<String, dynamic>>>? otrosCiclosStream;

  /// Solo la tarjeta de Cobertura lo pasa; la de Mora no desglosa por momento.
  final Stream<List<Map<String, dynamic>>>? desgloseStream;

  /// Eje del grafico en % del total (Cobertura) en vez de en cordobas (Mora).
  final bool ejePorcentaje;

  /// Rotulo de la punteada del 100%. Lo pasa siempre Cobertura, la unica
  /// tarjeta que usa este shell.
  final String? metaLegendLabel;

  final Stream<List<Map<String, dynamic>>> dailyStream;
  final bool esPeriodoActual;
  final InfoGrafica info;

  /// Dias de gracia y corte del dia, SOLO para la tabla de mora que esta
  /// tarjeta hospeda desde el 2026-09-02. Null = no se dibuja (los settings
  /// todavia no cargaron, o la tarjeta no la quiere).
  final int? diasGraciaMora;
  final String? hoyMora;

  /// Encabezado de cada tabla.
  ///
  /// **Es lo unico que separa una de la otra, y por eso no es decoracion**
  /// (decision de Ruben, 2026-09-02). Las dos tablas comparten los rotulos de
  /// fila `Recuperado` y `Por recuperar` — el vocabulario unico que el dueño
  /// pidio el 2026-08-27 — asi que puestas lado a lado esas palabras aparecen
  /// dos veces significando cosas distintas: en Cobertura es *de lo que vence
  /// este ciclo, cuanto se cobro*; en Mora es *de lo que cayo en mora, cuanto
  /// se rescato*. El encabezado es lo que lo desambigua.
  /// El `hint` es OBLIGATORIO y no decorativo: es lo que hace que los dos
  /// encabezados midan lo MISMO, y de eso depende que las dos tablas
  /// arranquen a la misma altura. Antes solo el de mora lo tenía —el
  /// renglón de los días de gracia— y la tabla de la derecha bajaba una
  /// línea entera.
  ///
  /// **`maxLines: 1` tampoco es cosmético.** Se descartó la alternativa de
  /// reservar altura vacía justamente por esto: una altura reservada se
  /// rompe en cuanto un texto envuelve a dos líneas en una pantalla
  /// angosta, y el desalineado vuelve a otro ancho. Con una línea fija en
  /// los dos, miden igual A CUALQUIER ANCHO, por construcción.
  Widget _rotuloTabla(ColorScheme scheme, String texto, String hint) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(texto.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: scheme.outline)),
          Text(hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 9.5, color: scheme.outlineVariant)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diasGracia = diasGraciaMora;
    final mesLabel = Fmt.mes(DateTime(anio, mes));
    final mesCapitalizado = mesLabel[0].toUpperCase() + mesLabel.substring(1);
    // La tarjeta puede declarar su propia ventana. La de Mora abarca 6 ciclos:
    // rotularla con el ÚLTIMO ("Ciclo 15 jul – 14 ago") debajo de un título que
    // dice "últimos 6 meses" se contradice, y hace leer la tabla como si fuera
    // de ese mes solo.
    final periodo = periodoLabel(anio, mes);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(titulo,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (onExportar != null) _BotonExportar(onExportar: onExportar!),
                InfoGraficaBoton(info),
              ],
            ),
            // El EJE de la tarjeta en la cara, no detrás del (i): la confusión
            // del dueño (2026-08-08) fue sumar una tarjeta que mide por
            // vencimiento de cuota con otra que mide por fecha de pago.
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text(subtitulo,
                  style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
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
                // `Flexible` y sin ancho FIJO. UNICO cambio a esta tarjeta
                // desde que Ruben la dio por cerrada (2026-08-28), y es un
                // OVERFLOW, no un rediseno: en un telefono el Row pedia 68px
                // mas de los que hay y Flutter pintaba la franja amarilla y
                // negra encima. Cazado por el test de 360px del 2026-08-29.
                // Nada de lo que la tarjeta MUESTRA cambia.
                Flexible(
                  child: Column(
                    children: [
                      Text(mesCapitalizado,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w500, fontSize: TxtResumen.grande)),
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
                        // "aún no empieza" cuando se está mirando un ciclo
                        // FUTURO (2026-09-02). Sin eso, su cobertura baja
                        // —4% en el Octubre del Test Tenant— se lee como un
                        // mes yendo pésimo, cuando lo que pasa es que todavía
                        // no arrancó y ese 4% son cobros ADELANTADOS.
                        child: Text(
                            esFuturo
                                ? 'Ciclo $periodo · aún no empieza'
                                : 'Ciclo $periodo',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: TxtResumen.apoyo,
                                color: scheme.onPrimaryContainer)),
                      ),
                    ],
                  ),
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
              stream: cortesStream,
              builder: (context, snapCortes) {
                final cortes = CortesCiclo.deFila(
                    (snapCortes.data?.isNotEmpty ?? false)
                        ? snapCortes.data!.first
                        : null);
                return StreamBuilder<List<Map<String, dynamic>>>(
                    stream: desgloseStream,
                    builder: (context, snapDesglose) {
                      final desglose =
                          LineaDesglose.deFilas(snapDesglose.data);
                      return StreamBuilder<List<Map<String, dynamic>>>(
              stream: summaryStream,
              builder: (context, snapSummary) {
                return StreamBuilder<List<Map<String, dynamic>>>(
                  stream: dailyStream,
                  builder: (context, snapDaily) {
                    if ((snapSummary.connectionState ==
                                ConnectionState.waiting &&
                            !snapSummary.hasData) ||
                        (snapDaily.connectionState == ConnectionState.waiting &&
                            !snapDaily.hasData)) {
                      return const SizedBox(
                          height: 200,
                          child: Center(child: CircularProgressIndicator()));
                    }
                    if (snapSummary.hasError || snapDaily.hasError) {
                      return Text('Error al cargar datos',
                          style: TextStyle(color: scheme.error, fontSize: TxtResumen.cifra));
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
                      porRecMontoQ: sr['porrec_m'] as num?,
                      particion: ParticionCobro.deFila(sr),
                    );

                    final dailyRows = snapDaily.data ?? [];
                    final dias = dailyRows
                        .map((r) => _DatosDia(
                              fecha: r['dia'] as String,
                              monto: r['monto'] as num,
                              qty: (r['qty'] as num).toInt(),
                            ))
                        .toList();

                    // (Aca se calculaban a mano `cobradoAntes/EnCiclo/
                    // Despues`. Los reemplazo `desgloseRecuperado`, que ademas
                    // trae los conteos y sabe de la cuota saldada con credito
                    // —que no tiene fecha de pago y este bucle no podia ubicar.)
                    return Column(
                      children: [
                        // Los cortes por origen y por mora viven en su propia
                        // consulta, así que llegan por su propio stream. Si
                        // TOPE DE ANCHO. Sin el, la tabla se estira a toda
                        // la ventana: en 1900px recibe 1812 y las tres
                        // columnas de numeros se reparten el sobrante 1:2:2,
                        // dejando el monto a ~1.700px del rotulo ("el cuadro
                        // esta muy alejado", 2026-08-28). 560 es lo que miden
                        // las columnas con su contenido comodo; en Android la
                        // tabla mide menos, asi que el tope NO se activa y el
                        // telefono queda igual. La curva SI usa todo el ancho:
                        // ella gana con el, la tabla no.
                        // LAS DOS TABLAS (2026-09-02). La de mora vivia en la
                        // tarjeta de los 6 ciclos con SU PROPIO selector, asi
                        // que habia dos controles de ciclo en el Resumen y
                        // podian quedar en meses distintos mirando lo mismo.
                        // Ahora las dos leen el ciclo de ESTA tarjeta.
                        //
                        // El calculo no cambio: las dos resuelven su rango con
                        // `inicioPeriodo`/`finPeriodo` sobre año y mes, asi que
                        // la de mora recibe exactamente las fechas que le daba
                        // su propio selector.
                        LayoutBuilder(
                          builder: (context, cons) {
                            // El MISMO umbral que usa `_GrillaMora` para su
                            // modo compacto. Si fueran distintos se veria una
                            // tabla compacta al lado de una ancha.
                            final lado = cons.maxWidth >= 600;
                            final cobertura = _TablaSummary(
                              pagoParcialOn: pagoParcialOn,
                              resumen: resumen.conCortes(cortes),
                              ocultarRecaudado: ocultarRecaudado,
                              desglose: desglose,
                              esFuturo: esFuturo,
                            );
                            final mora = diasGracia == null
                                ? const SizedBox.shrink()
                                : MoraTablaCiclo(
                                    anio: anio,
                                    mes: mes,
                                    diasGracia: diasGracia,
                                    hoy: hoyMora ?? isoDia(Fmt.hoyNicaragua()),
                                    ocultarRecaudado: ocultarRecaudado,
                                    // Sin tope propio: adentro de la fila lo
                                    // pone el `Expanded`, y suelta hereda el
                                    // de la columna.
                                    maxWidth: double.infinity,
                                  );
                            if (!lado) {
                              // Android: una abajo de la otra.
                              return Align(
                                alignment: Alignment.center,
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 720),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _rotuloTabla(scheme, 'Cobertura del ciclo',
                                          'de lo que vence en el ciclo'),
                                      const SizedBox(height: 4),
                                      cobertura,
                                      if (diasGracia != null) ...[
                                        const SizedBox(height: 18),
                                        _rotuloTabla(
                                            scheme,
                                            'Cobertura de mora',
                                            'vencidas + $diasGracia días de gracia'),
                                        const SizedBox(height: 4),
                                        mora,
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            }
                            // PC: lado a lado. El tope sube a 1040 (dos veces
                            // 520) porque ahora hay dos tablas donde habia una;
                            // con 720 las dos quedaban apretadas.
                            return Align(
                              alignment: Alignment.center,
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 1040),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          _rotuloTabla(
                                              scheme,
                                              'Cobertura del ciclo',
                                              'de lo que vence en el ciclo'),
                                          const SizedBox(height: 4),
                                          cobertura,
                                        ],
                                      ),
                                    ),
                                    if (diasGracia != null) ...[
                                      const SizedBox(width: 26),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            _rotuloTabla(
                                                scheme,
                                                'Cobertura de mora',
                                                'vencidas + $diasGracia días de gracia'),
                                            const SizedBox(height: 4),
                                            mora,
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        // La nota "de lo cobrado, C$X ya venía pagado por
                        // adelantado" se MUDÓ a la tarjeta de caja (pedido del
                        // dueño 2026-08-11: acá no le importa el dato). Allá sí
                        // sirve: es la pieza que cierra la cuenta entre las dos
                        // tarjetas, y sin ella no se puede llegar de un total
                        // al otro. Ver el puente en `_DesgloseCajaCard`.
                        if (ocultarRecaudado)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Tu rol no muestra montos cobrados. Acá ves lo '
                              'facturado y lo que falta recuperar.',
                              style: TextStyle(
                                  fontSize: TxtResumen.apoyo, color: scheme.outline),
                            ),
                          ),
                        // La nota de pie se mudó al botón (i) — pedido del
                        // dueño, que quería la tarjeta más limpia. El texto
                        // vive en `InfoGrafica.nota` de cada gráfica.
                        if (!ocultarRecaudado) const SizedBox(height: 16),
                        // La serie de mora va en SU PROPIO StreamBuilder,
                        // envolviendo sólo al gráfico: llega más tarde que las
                        // demás y anidarla más arriba haría parpadear la tabla
                        // entera cada vez que se actualiza.
                        if (!ocultarRecaudado)
                          StreamBuilder<List<Map<String, dynamic>>>(
                            stream: otrosCiclosStream,
                            builder: (context, snapOtros) {
                              // Un mapa día -> (cuotas, monto, cuotas de mora,
                              // monto de mora). Va como MAPA y no como serie:
                              // no se dibuja, sólo se consulta por el día que
                              // el globo esté mostrando.
                              //
                              // Las dos de mora son un SUBCONJUNTO de las dos
                              // primeras, no un segundo monto.
                              final otros = {
                                for (final f in snapOtros.data ??
                                    const <Map<String, dynamic>>[])
                                  '${f['dia']}': (
                                    ((f['qty'] as num?) ?? 0).toInt(),
                                    (f['monto'] as num?) ?? 0,
                                    ((f['mora_qty'] as num?) ?? 0).toInt(),
                                    (f['mora_monto'] as num?) ?? 0,
                                  ),
                              };
                              return StreamBuilder<List<Map<String, dynamic>>>(
                            stream: moraStream,
                            builder: (context, snapMora) {
                              final diasMora = [
                                for (final f
                                    in snapMora.data ?? const <Map<String, dynamic>>[])
                                  _DatosDia(
                                    fecha: '${f['dia']}',
                                    monto: (f['monto'] as num?) ?? 0,
                                    qty: ((f['qty'] as num?) ?? 0).toInt(),
                                  ),
                              ];
                              return _GraficoTendencia(
                                dias: dias,
                                meta: resumen.metaMonto.toDouble(),
                                inicioDate: inicioDate,
                                finDate: finDate,
                                esPeriodoActual: esPeriodoActual,
                                lineColor: chartColor,
                                // Cobertura lo pasa SIEMPRE (es la unica
                                // tarjeta que usa este shell desde que Mora se
                                // mudo).
                                metaLegendLabel: metaLegendLabel!,
                                ejePorcentaje: ejePorcentaje,
                                diasMora: diasMora,
                                // El TECHO de la mora del ciclo: lo que llegó a
                                // estar en mora, recuperado o no. Le da su
                                // referencia a la curva roja, igual que la meta
                                // se la da a la verde.
                                topeMora: cortes?.moraFacturadoReal.toDouble(),
                                otrosCiclos: otros,
                              );
                            },
                          );
                            },
                          ),
                      ],
                    );
                  },
                );
              },
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

class _TablaSummary extends StatefulWidget {
  const _TablaSummary({
    required this.resumen,
    this.ocultarRecaudado = false,
    this.desglose = const [],
    this.pagoParcialOn = true,
    this.esFuturo = false,
  });
  final _Resumen resumen;

  /// El ciclo mostrado todavía no empezó: lo recuperado es, por definición,
  /// cobro ADELANTADO. Se dice en la fila para que nadie lea ese monto como
  /// desempeño del mes — con 4% de cobertura y sin la aclaración, Octubre se
  /// leería como un desastre en vez de como un mes que no arrancó.
  final bool esFuturo;

  /// Setting `cobranza.pago_parcial` del tenant. Solo decide si la fila de
  /// "Pagadas a medias" se muestra cuando NO hay ninguna: con la feature
  /// prendida se deja a la vista aunque dé cero (es una de las tres opciones
  /// posibles del ciclo); apagada y sin parciales, sería ruido.
  final bool pagoParcialOn;

  /// Ver [TendenciaCobrosCard.ocultarRecaudado].
  final bool ocultarRecaudado;

  /// El desglose de "Recuperado" por momento. Vacio en la tarjeta de Mora.
  /// Sus `saldadas` suman el conteo de la fila madre y sus `monto` su monto.
  final List<LineaDesglose> desglose;

  @override
  State<_TablaSummary> createState() => _TablaSummaryState();
}

class _TablaSummaryState extends State<_TablaSummary> {
  /// Los dos desgloses arrancan CERRADOS: la tarjeta abre en tres filas que
  /// suman solas, y el detalle aparece solo si alguien lo pide.
  bool abierto = false;
  bool abiertoPorRec = false;

  /// Que lineas de momento tienen su tercer nivel abierto. La flecha aparece
  /// SOLO en las que tienen algo adentro (pedido del dueno 2026-08-28): en un
  /// ISP sin parciales ni creditos no se ve ninguna, y el desglose queda en
  /// tres lineas planas.
  final Set<String> momentosAbiertos = {};

  /// Los dos cortes de MORA (2026-08-31), uno por fila madre. Arrancan
  /// cerrados como los demás: la tarjeta abre en tres filas y el detalle
  /// aparece solo si alguien lo pide.
  // `moraRecAbierta` / `moraPendAbierta` se fueron el 2026-09-01: las filas de
  // mora dejaron de ser desplegables. Ahora viven ADENTRO de los momentos y de
  // las dos lineas de "Por recuperar", asi que el chevron que las abria es el
  // del momento, no uno propio.

  @override
  Widget build(BuildContext context) {
    // Alias locales para no reescribir el cuerpo entero al pasar a Stateful.
    final resumen = widget.resumen;
    final ocultarRecaudado = widget.ocultarRecaudado;
    final desglose = widget.desglose;
    final scheme = Theme.of(context).colorScheme;
    const headerStyle = TextStyle(fontSize: TxtResumen.apoyo, fontWeight: FontWeight.w500);
    const cellStyle = TextStyle(fontSize: TxtResumen.cifra);
    final mutedStyle = TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline);

    final r = resumen;

    // ── Tabla de PARTICIÓN (Cobertura del ciclo) ──
    // Cada cuota cae en un solo grupo, así que las cuatro columnas suman el
    // total y se pueden verificar con calculadora. La de Mora sigue con la
    // tabla de siempre (particion == null).
    // ── Tabla de COBERTURA: tres filas, el concepto original ──
    // Cobros = lo que vence en el ciclo · Recuperado = lo que entró ·
    // Por recuperar = lo que falta. Las TRES columnas de conteo suman porque
    // cada una usa una definición que no se pisa: un cliente debe algo o no
    // debe nada, una cuota está saldada o tiene saldo, y un córdoba entró o
    // falta.
    //
    // Se volvió acá después de probar cortes por estado de pago, por origen y
    // por mora: cada dimensión que se agregaba hacía menos legible el conjunto
    // ("la data no se me hace clara" — Rubén, 2026-08-13). La mora sale de esta
    // tarjeta y se queda en la suya, que ya existe; `cortesDelCiclo` y su test
    // siguen vivos para cuando se re-evalúe. El desglose fino (parciales,
    // cobros de servicio, mora por cuota) vive en el Excel.
    final part = r.particion;
    // Los cortes llegan por un stream aparte y MÁS TARDE que el resumen, así
    // que puede ser null en los primeros frames: las filas de mora se guardan
    // detrás de esa comprobación en vez de asumir que están.
    final cortes = r.cortes;
    // ¿Hay corte de mora que mostrar en cada fila madre? Se calcula UNA vez
    // porque lo consultan dos lugares: el chevron (para decidir si la fila se
    // puede abrir) y el bloque de filas (para decidir si se dibuja).
    // Ya no hace falta preguntar "hay mora?" para decidir si la fila madre se
    // puede abrir: la mora vive adentro de los momentos y de las dos lineas de
    // "Por recuperar", asi que si no hay nada de eso tampoco hay mora que
    // mostrar. El flag existia cuando la mora colgaba de la fila madre como
    // hermana, y sin el las lineas quedaban INALCANZABLES (bug del 2026-08-31).
    // 🔴 EL GUARD BAJO (2026-09-02). Antes acá había un `if (part != null)`
    // que envolvía la tabla ENTERA, con este comentario: *"pasa SOLO en el
    // primer frame, antes de que llegue el stream"*. Era falso: pasa TAMBIÉN
    // cuando el ciclo no tiene una sola cuota, y entonces la tabla desaparece
    // y la tarjeta se ve rota. Lo reportó Rubén mirando Julio 2024 (0 cuotas):
    // la de mora dibujaba guiones al lado y ésta no dibujaba nada.
    //
    // De las ~500 líneas que el guard protegía, sólo CINCO usan `part`, y son
    // las sub-filas del desglose de "Por recuperar" — que además ya tienen su
    // propio `> 0`. Las tres filas madre salen de `r` y no lo necesitan.
    {
      Widget celda(String txt,
              {int flex = 2, bool fuerte = false, bool mudo = false}) =>
          Expanded(
            flex: flex,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(txt,
                  style: mudo
                      ? mutedStyle
                      : (fuerte
                          ? cellStyle.copyWith(fontWeight: FontWeight.w600)
                          : cellStyle)),
            ),
          );

      /// [sub] = sub-fila de desglose. No lleva punto de color —el punto es el
      /// ancla de una fila madre— sino una GUIA: una barra vertical del color
      /// de su madre, que es lo que el dueno pidio dos veces para saber que
      /// numero pertenece a cual.
      ///
      /// El rotulo va en una caja de ancho FIJO, la misma para madre y
      /// sub-fila. Antes cada una lo armaba por su cuenta —la madre sumaba
      /// 8+6+108 = 122 y la sub 22+12+6+98 = 138— y las columnas de numeros de
      /// las sub-filas quedaban 16px corridas a la derecha. Con una sola caja
      /// de 122 no se pueden desalinear, y coincide con el encabezado
      /// (14 + 108) sin que haya que acordarse de moverlos juntos.
      ///
      /// Los rotulos van a UNA linea (`maxLines: 1` + ellipsis): partidos en
      /// dos dejaban el monto huerfano en el renglon de abajo.
      // 170 y no 122: los rotulos de segundo nivel ("con abono parcial") se
      // cortaban con ellipsis. Las sub-filas no usan la columna de %, asi que
      // el espacio sale de ahi sin apretar los numeros.
      const anchoRotulo = 170.0;
      Widget fila3(String label, Color dot, int cuotas, int? pct, num monto,
          {int? usuarios,
          bool fuerte = false,
          bool sub = false,
          bool soloTexto = false,
          bool sinConteo = false,
          bool nivel2 = false,
          bool conteoEntreParentesis = false,
          String? prefijoMonto,
          VoidCallback? onTap,
          bool? abiertoFlag}) {
        // El chevron va como WIDGET, no metido en el string del rotulo: los
        // tests localizan las filas con `find.text('Recuperado')` y un
        // '▾  Recuperado' deja de matchear. Se le descuentan sus 12px al ancho
        // del rotulo para no mover las columnas.
        // GRILLA (pedido del dueno 2026-08-28, "algo estilo excel rows and
        // columns"): fondo levemente gris en las sub-filas para que el bloque
        // desplegado se lea como una unidad, y linea arriba en las filas
        // madre. Las dos MUY tenues: son guia, no reja.
        // ABAJO DE `kAnchoTablaCompleta` LA FILA DEJA DE SER FILA (2026-09-03).
        //
        // A 360px la tarjeta tiene ~272px utiles; con `anchoRotulo` en 170
        // quedan 34 por columna, y "3.984.934,53 C\$" mide ~100 a
        // `TxtResumen.cifra`. El `FittedBox` lo escalaba al 34% — fuente
        // efectiva de 5px, que es lo que el dueno fotografio y llamo
        // ilegible. Agrandar la letra ahi no arregla nada: el problema es que
        // a ese ancho NO ENTRA una tabla de cuatro columnas.
        //
        // El 2026-09-01 se probo "el monto solo, en la segunda linea": el
        // dueno lo vio y lo rechazo (*"las tablas en android no me gustan"*).
        // Desde el 2026-09-03 es TARJETA — [TarjetaFilaResumen], compartida
        // con la tabla de mora. No se abrevia ni se esconde nada: se descarto
        // el formato compacto ("3,98 M") justamente porque el numero de la
        // pantalla dejaba de ser el que se compara con el Excel.
        // El `LayoutBuilder` va AFUERA del `Container`, no adentro: en modo
        // tarjeta no tiene que haber `Container` de fila. Estando adentro, la
        // tarjeta heredaba su raya superior y su fondo gris — una tarjeta con
        // un pedazo de tabla pegado arriba.
        final fila = LayoutBuilder(builder: (context, cc) {
            final angosto = cc.maxWidth < kAnchoTablaCompleta;
            // TELEFONO: la fila deja de ser fila. La dibuja el ladrillo
            // COMPARTIDO con la tabla de mora — que es lo que evita que las
            // dos vuelvan a divergir (ver [ParteResumen]). El TOTAL no pasa
            // por aca: lo dibuja `TotalResumen` en el build.
            if (angosto) {
              return ParteResumen(
                label: label,
                color: dot,
                cuotas: cuotas,
                pct: pct,
                monto: monto,
                usuarios: usuarios,
                nivel: nivel2 ? 2 : (sub ? 1 : 0),
                soloTexto: soloTexto,
                sinConteo: sinConteo,
                // El parentesis de la tabla decia "esta cuota se cuenta en
                // OTRA fila" y habia que saber interpretarlo. Con lugar para
                // escribir, se dice.
                nota: conteoEntreParentesis ? 'ya contadas arriba' : null,
                prefijoMonto: prefijoMonto,
                abierto: abiertoFlag,
                // El `onTap` lo pone el `InkWell` de afuera: ponerlo tambien
                // aca anidaria dos y el toque se contaria una sola vez, pero
                // con dos ondas superpuestas.
              );
            }
            // La celda del monto se arma aparte porque en angosto NO va en el
            // Row: baja a su propia linea.
            final celdaMonto = soloTexto
                // flex 2, igual que `celda`: con el default (1) esta fila
                // repartia 1:2:1 y sus columnas no caian donde las demas.
                ? const Expanded(flex: 2, child: SizedBox.shrink())
                : celda('${prefijoMonto ?? ''}${Fmt.cordobas(monto)}',
                    fuerte: fuerte, mudo: sub);

            final linea = Row(
            children: [
              // PLANO a proposito: nada de un Row anidado para el rotulo. Los
              // tests localizan una fila con `find.ancestor(... byType(Row))`
              // y toman el PRIMERO; un Row interno se lleva ese match y la
              // fila "encontrada" ya no contiene las celdas de numeros.
              //
              // Los dos caminos suman lo MISMO (122 = `anchoRotulo`), que es
              // lo que mantiene las columnas alineadas entre madre y sub-fila:
              //   madre: 8 + 6 + 108
              //   sub:   4 + 2 + 8 + 108
              // Los TRES caminos suman 14 antes del rotulo: asi las columnas
              // de numeros caen en el mismo x en los tres niveles.
              if (nivel2) ...[
                const SizedBox(width: 26),
                Container(
                    width: 2, height: 11, color: dot.withValues(alpha: 0.4)),
                const SizedBox(width: 6),
              ] else if (sub) ...[
                const SizedBox(width: 4),
                // La GUIA que pidio el dueno: una barra del color de su fila
                // madre, para saber a cual pertenece cada numero.
                Container(width: 2, height: 13, color: dot.withValues(alpha: 0.4)),
                const SizedBox(width: 8),
              ] else ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              // El hueco del chevron SE RESERVA SIEMPRE (2026-09-02), esté o
              // no la fila desplegable: si no, el rótulo arranca 12px más a la
              // izquierda en las filas que no se abren y la tabla se lee
              // torcida. Mismo criterio en la grilla de mora, que ahora vive
              // al lado de ésta.
              SizedBox(
                width: 12,
                child: abiertoFlag == null
                    ? null
                    : Icon(
                        abiertoFlag
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 12,
                        color: scheme.outline),
              ),
              // En PC el rotulo va en una caja de ancho FIJO: es lo que
              // mantiene las columnas de numeros alineadas entre la fila madre
              // y sus sub-filas. En telefono esa caja se come 170 de 272px, y
              // ahi el rotulo pasa a ser ELASTICO: se lleva lo que sobra
              // despues de las dos columnas que quedan.
              //
              // Los DOS caminos de arriba miden 14 (8+6 y 4+2+8), asi que el
              // rotulo tiene el mismo ancho y las columnas quedan alineadas.
              // El descuento tiene que ser EXACTAMENTE lo que ocupa el
              // marcador de cada nivel, o la fila mide distinto y las lineas
              // verticales dejan de caer en la misma columna:
              //   madre  8+6 = 14   ·  sub 4+2+8 = 14  ·  nivel2 26+2+6 = 34
              // Estaba restando 26 en nivel 2 y ocupando 34: 8px corridos.
              angosto
                  ? Expanded(
                      child: Text(label,
                          style: sub
                              ? mutedStyle
                              : (fuerte
                                  ? cellStyle.copyWith(
                                      fontWeight: FontWeight.w600)
                                  : cellStyle),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis))
                  : SizedBox(
                // El 12 del chevron se descuenta SIEMPRE: su hueco ahora
                // existe siempre (ver arriba).
                width: anchoRotulo - (nivel2 ? 34 : 14) - 12,
                child: Text(label,
                    style: sub
                        ? mutedStyle
                        : (fuerte
                            ? cellStyle.copyWith(fontWeight: FontWeight.w600)
                            : cellStyle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              // Linea vertical que separa el QUE del CUANTO.
              Container(
                  width: 1,
                  height: 15,
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(width: 7),
              // USUARIOS: personas distintas, contra las CUOTAS de al lado.
              // Cuando difieren es que alguien tiene mas de un contrato en el
              // ciclo — que es justo para lo que el dueno mira esta columna.
              // Vacia en las sub-filas: el desglose parte CUOTAS, y repartir
              // personas entre sus lineas contaria a la misma dos veces.
              (soloTexto || sinConteo || usuarios == null)
                  ? const Expanded(flex: 1, child: SizedBox.shrink())
                  : celda(Fmt.entero(usuarios), flex: 1, mudo: sub),
              const SizedBox(width: 7),
              Container(
                  width: 1,
                  height: 15,
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(width: 7),
              (soloTexto || sinConteo)
                  ? const Expanded(flex: 1, child: SizedBox.shrink())
                  // El parentesis dice "esta cuota se cuenta en OTRA fila": su
                  // conteo no suma aca aunque su plata si.
                  : celda(
                      conteoEntreParentesis
                          ? '(${Fmt.entero(cuotas)})'
                          : Fmt.entero(cuotas),
                      flex: 1,
                      mudo: sub),
              const SizedBox(width: 7),
              Container(
                  width: 1,
                  height: 15,
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(width: 7),
              // El % NO es un semaforo: es COMPOSICION — que parte del total es
              // esta fila. Vivia en una pastilla cuyo color se calculaba con un
              // `0` LITERAL, asi que las tres salian en `scheme.error`: el 100%
              // de Cobros pintado de alarma. Ahora es texto plano en el color
              // de la fila —el mismo del punto—: el color dice DE QUE FILA es,
              // no si esta bien o mal.
              Expanded(
                  // flex 1, igual que su encabezado: si no coinciden, el
                  // rotulo deja de caer sobre su columna.
                  flex: 1,
                  child: pct == null
                      ? const SizedBox.shrink()
                      : Text('$pct%',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: TxtResumen.apoyo,
                              fontWeight: FontWeight.w500,
                              color: dot))),
              const SizedBox(width: 7),
              Container(
                  width: 1,
                  height: 15,
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(width: 7),
              celdaMonto,
            ],
            );

            return Container(
              padding: EdgeInsets.symmetric(vertical: sub ? 3 : 7),
              decoration: BoxDecoration(
                color: sub
                    ? scheme.onSurface.withValues(alpha: 0.028)
                    : Colors.transparent,
                // Linea arriba en TODAS las filas, no solo en las madre: entre
                // sub-filas no habia ninguna y el bloque desplegado se leia
                // como un bloque de texto. Mas tenue en las sub-filas para que
                // la jerarquia siga siendo evidente.
                border: Border(
                    top: BorderSide(
                        color: scheme.outlineVariant
                            .withValues(alpha: fuerte ? 0.55 : 0.3))),
              ),
              child: linea,
            );
          });
        if (onTap == null) return fila;
        return InkWell(
            onTap: onTap, borderRadius: BorderRadius.circular(4), child: fila);
      }

      // `maxLines: 1` + altura FIJA de la fila (2026-09-02). Desde que las dos
      // tablas comparten fila, cada una mide la mitad de ancho y el encabezado
      // largo —"% de las 56 cuotas"— envuelve a DOS líneas en una y no en la
      // otra, según el largo del número. Eso hacía más alta una cabecera que la
      // otra y corría TODAS las filas de esa tabla: es el origen de los 18px
      // que el dueño vio. Con una línea y altura fija, las dos cabeceras miden
      // lo mismo pase lo que pase con el texto.
      Widget encabezado(String txt,
              {int flex = 2, TextAlign align = TextAlign.right}) =>
          Expanded(
            flex: flex,
            child: Text(txt,
                style: headerStyle,
                textAlign: align,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          );

      // El 100% son LAS CUOTAS del ciclo, y la columna lo dice. Es la unica
      // forma de que el % no se pueda leer mal: 7 de 15 es 47%, la cuenta que
      // el lector hace solo. Cuando el % era de PLATA (4.700/11.200 = 42%) al
      // lado de "7 cuotas", fallaba por 5 puntos y parecia error de cuenta.
      final recuperadas = r.metaCuotas - r.porRecCuotas;
      final pctRecuperado =
          r.metaCuotas > 0 ? (recuperadas / r.metaCuotas * 100).round() : 0;

      return LayoutBuilder(builder: (context, ct) {
      // Se mide con el MISMO criterio que `fila3`, o la cabecera podria quedar
      // dibujada sobre filas que ya son tarjetas.
      final tarjetas = ct.maxWidth < kAnchoTablaCompleta;
      return Column(
        children: [
          // En modo tarjeta NO hay cabecera: no hay columnas sobre las que
          // caer, y cada tarjeta rotula su propio dato.
          if (!tarjetas) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              height: kAltoCabeceraTabla,
              child: Row(
              children: [
                // El mismo ancho y los mismos separadores que `fila3`, o el
                // encabezado deja de caer sobre su columna.
                const SizedBox(width: 170),
                const SizedBox(width: 8),
                encabezado('Usuarios', flex: 1),
                const SizedBox(width: 15),
                encabezado('Cuotas', flex: 1),
                const SizedBox(width: 15),
                // Centrado, para caer sobre las celdas de % (que van centradas).
                //
                // Decia "% de las N cuotas" y con las dos tablas lado a lado no
                // entraba: se cortaba en "% de las 56 cu…" y de paso apretaba a
                // "Usuarios" hasta "Usuar…". Ahora dice solo "%" y su columna
                // baja a flex 1 —lo mas ancho que aloja es "100%"—, que es de
                // donde sale el lugar para las otras dos.
                // El denominador no se pierde: es la fila "Cobros" de esta
                // misma tabla, a dos renglones de distancia.
                encabezado('%', flex: 1, align: TextAlign.center),
                const SizedBox(width: 15),
                encabezado('Monto'),
              ],
            ),
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          ],
          // UN SOLO vocabulario en toda la app, el del dueño: Cobros (lo
          // facturado) / Recuperado (lo cobrado) / Por recuperar (lo que
          // falta). Esta tabla decia Pagadas / Pendientes / Total del ciclo
          // mientras la tarjeta de Mora, pegada abajo, ya decia Cobros /
          // Recuperado / Por recuperar: dos vocabularios para lo mismo en la
          // misma pantalla. Pedido del dueño 2026-08-27, con su mockup.
          if (tarjetas)
            // EL TITULAR DEL BLOQUE. La barra reparte lo que vence en el ciclo
            // entre lo recuperado y lo que falta, con los MISMOS porcentajes
            // que muestran las filas de abajo (invariante #10: el mismo numero
            // en todas las superficies).
            //
            // Con `ocultarRecaudado` el tramo verde no se dibuja y queda como
            // canaleta gris: ese rol no ve montos cobrados.
            TotalResumen(
              label: 'Cobros',
              color: scheme.primary,
              monto: r.metaMonto,
              usuarios: r.metaUsuarios,
              cuotas: r.metaCuotas,
              segmentos: [
                if (!ocultarRecaudado)
                  (fraccion: pctRecuperado / 100, color: const Color(0xFF1D9E75)),
                (fraccion: (r.metaCuotas > 0 ? 100 - pctRecuperado : 0) / 100,
                    color: const Color(0xFFE24B4A)),
              ],
            )
          else
            fila3('Cobros', scheme.primary, r.metaCuotas,
                r.metaCuotas > 0 ? 100 : 0, r.metaMonto,
                usuarios: r.metaUsuarios, fuerte: true),
          // `ocultarRecaudado` (rol admin_cobranza) tiene que tapar TAMBIEN
          // esta fila: `metaMonto - porRecMonto` ES lo cobrado. El gate estaba
          // puesto solo en la tabla generica de mas abajo —la que dibuja la
          // tarjeta de Mora—, asi que en Cobertura el rol leia la nota "Tu rol
          // no muestra montos cobrados" con el monto cobrado arriba.
          if (!ocultarRecaudado)
            fila3(
                widget.esFuturo ? 'Recuperado · por adelantado' : 'Recuperado',
                const Color(0xFF1D9E75), recuperadas,
                pctRecuperado, r.metaMonto - r.porRecMonto,
                usuarios: r.recUsuarios,
                fuerte: true,
                // El chevron aparece si hay ALGO adentro: los momentos o el
                // corte de mora. Mirar sólo `desglose` dejaba la mora
                // inalcanzable cuando no había momentos que mostrar —la fila
                // no se podía abrir y sus dos líneas no existían para el
                // usuario—. Lo cazó el test de UI al agregarlas.
                abiertoFlag: desglose.isEmpty ? null : abierto,
                onTap: desglose.isEmpty
                    ? null
                    : () => setState(() => abierto = !abierto)),
          // DESGLOSE DE "RECUPERADO", por CUANDO entro la plata. Se abre y se
          // cierra: cerrado, la tarjeta son tres filas que suman solas.
          //
          // Las lineas de momento son las que SUMAN: sus `saldadas` dan el
          // conteo de la fila madre y sus `monto` su monto. Lo indentado un
          // nivel mas dice "de esas": NO se agrega, explica de que esta hecha
          // la de arriba.
          //
          // En un ISP normal esto son tres lineas y nada mas: los pagos
          // parciales dependen del setting `cobranza.pago_parcial` (apagado en
          // los dos ISP reales) y el credito a favor es raro. Los renglones de
          // caso raro aparecen SOLO cuando existen.
          if (!ocultarRecaudado && abierto)
            for (final d in desglose) ...[
              fila3(d.rotulo, const Color(0xFF1D9E75), d.saldadas, null,
                  d.monto,
                  sub: true,
                  abiertoFlag: d.tieneDetalle
                      ? momentosAbiertos.contains(d.momento)
                      : null,
                  onTap: d.tieneDetalle
                      ? () => setState(() =>
                          momentosAbiertos.contains(d.momento)
                              ? momentosAbiertos.remove(d.momento)
                              : momentosAbiertos.add(d.momento))
                      : null),
              if (momentosAbiertos.contains(d.momento)) ...[
                // LA MORA DEL MOMENTO, PRIMERA (2026-09-01). Va arriba de las
                // otras dos porque es la que el dueno viene a buscar, y SOLO
                // donde la hay: que "antes del ciclo" y "despues del ciclo" no
                // la dibujen ES el dato — esas cuotas pagaron fuera de la
                // ventana pero DENTRO de la gracia de su propia cuota, asi que
                // nunca estuvieron en mora. Con la fila unica de antes eso no
                // se podia ver.
                if (d.mora > 0)
                  fila3('venían de mora', _rojoMora, d.mora, null, d.moraMonto,
                      sub: true, nivel2: true),
              // Su plata YA esta dentro del monto de arriba, por eso el
              // conteo va entre parentesis: esas cuotas se cuentan abajo, en
              // "Por recuperar".
                if (d.parciales > 0)
                  fila3('con abono parcial', const Color(0xFFEF9F27),
                      d.parciales, null, d.parcialesMonto,
                      sub: true, nivel2: true, conteoEntreParentesis: true),
                if (d.credito > 0)
                  fila3('saldada con crédito', const Color(0xFF185FA5),
                      d.credito, null, 0,
                      sub: true, nivel2: true),
              ],
            ],
          // LA MORA DE "RECUPERADO" SE MUDO ADENTRO DE LOS MOMENTOS
          // (2026-09-01, pedido del dueno: *"los momentos son la jerarquia
          // principal"*). Estuvo aca como HERMANA de los tres, con dos
          // argumentos que resultaron discutibles:
          //
          //   · "son dos cortes distintos de las mismas cuotas" — cierto, pero
          //     eso no obliga a ponerlos al lado: el de mora se puede repartir
          //     DENTRO del otro, y asi se ve algo que antes no se veia (que las
          //     2 de "despues del ciclo" NO estaban en mora, porque pagaron
          //     fuera de la ventana pero dentro de su gracia);
          //   · "anidarlo pediria un CUARTO nivel" — falso: `fila3` ya dibuja
          //     tres, y la mora entra como HERMANA de "con abono parcial", no
          //     debajo.
          //
          // Se perdio en la mudanza la fila "se cobraron a tiempo": era el
          // complemento de la mora sobre la fila madre y ahora se lee restando
          // (26 - 7 = 19 se cobraron a tiempo en el ciclo). Si vuelve a hacer
          // falta, es una fila `nivel2` mas por momento con
          // `d.saldadas - d.mora`.
          fila3('Por recuperar', const Color(0xFFE24B4A), r.porRecCuotas,
              r.metaCuotas > 0 ? 100 - pctRecuperado : 0, r.porRecMonto,
              usuarios: r.porRecUsuarios,
              fuerte: true,
              abiertoFlag: r.porRecCuotas > 0 ? abiertoPorRec : null,
              onTap: r.porRecCuotas == 0
                  ? null
                  : () => setState(() => abiertoPorRec = !abiertoPorRec)),
          // DESGLOSE DE "POR RECUPERAR". Este cierra solo: las dos lineas
          // suman el conteo Y el monto de su fila madre, sin excepciones.
          //
          // "con abono parcial" son LAS MISMAS cuotas que aparecen en el
          // desglose de arriba. Alla se muestra lo que YA ENTRO de ellas; aca
          // lo que TODAVIA FALTA, que es lo que significa la columna Monto en
          // esta fila. Poner el monto entrado aca —como estuvo un dia— lo hace
          // leer como deuda, que es exactamente lo contrario.
          if (abiertoPorRec) ...[
            // La mora va ADENTRO de cada linea, no al lado (2026-09-01).
            // `sinSaldarMedias* + sinSaldarNada* = sinSaldar*`, que es lo que
            // la fila unica "en mora" mostraba antes: el numero no se movio, se
            // mudo. El monto sigue siendo el SALDO —lo que todavia se debe—,
            // igual que su fila madre; poner el facturado la haria leer como si
            // fuera plata distinta.
            // `part` puede ser null: en el primer frame y en un ciclo vacío.
            if (part != null && part.mediasCuotas > 0) ...[
              fila3('con abono parcial', const Color(0xFFE24B4A),
                  part.mediasCuotas, null, part.mediasFalta,
                  sub: true),
              if (cortes != null && cortes.sinSaldarMediasCuotas > 0)
                fila3('en mora', _rojoMora, cortes.sinSaldarMediasCuotas, null,
                    cortes.sinSaldarMediasFalta,
                    sub: true, nivel2: true),
            ],
            if (part != null && part.nadaCuotas > 0) ...[
              fila3('sin ningún pago', const Color(0xFFE24B4A), part.nadaCuotas,
                  null, part.nadaFacturado,
                  sub: true),
              if (cortes != null && cortes.sinSaldarNadaCuotas > 0)
                fila3('en mora', _rojoMora, cortes.sinSaldarNadaCuotas, null,
                    cortes.sinSaldarNadaFalta,
                    sub: true, nivel2: true),
            ],
            // "todavía en plazo" se fue con la mudanza: era el complemento
            // de "en mora" sobre la fila madre y ahora se lee restando. Con la
            // mora repartida en las dos lineas, una fila mas de complemento por
            // linea eran cuatro renglones para decir dos restas.
          ],
          // EL PIE DE MORA SE RETIRO (2026-08-27, pedido del dueno: "es
          // bastante confuso, no hace match visual con la tabla ni con la
          // grafica"). Tenia razon y era estructural: sus dos numeros —36
          // cuotas y C$25.155— eran un TERCER corte del ciclo que no salia de
          // ninguna fila de la tabla ni de ningun punto de la curva. El 36 era
          // "las que pasaron por mora" (8 ya cobradas + 28 debiendo), o sea
          // mitad de una fila y mitad de otra.
          //
          // La mora del ciclo vive en la tarjeta de Mora, que es para eso.
        ],
      );
      });
    }

    // Aca vivia un `return SizedBox.shrink()` para el caso `part == null`, y
    // era la causa de que la tabla desapareciera en un ciclo sin cuotas. Ya no
    // hay caso sin tabla: las filas madre salen de `r`, que siempre esta.
    //
    // Y antes de eso vivia la tabla vieja de tres filas con columna
    // "Servicios", exclusiva de Mora. Se borro con ella: dejarla habria sido
    // una segunda tabla que nadie renderiza y que el proximo que lea el
    // archivo va a creer viva — justo el tipo de superficie muerta que ya
    // costo un diagnostico falso ("la tarjeta muestra los mismos numeros en
    // dos tablas").
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
    this.ejePorcentaje = false,
    this.diasMora = const [],
    this.topeMora,
    this.otrosCiclos = const {},
  });

  /// Por día ISO, cuántas cuotas de OTROS ciclos se cobraron y cuánto.
  ///
  /// No se dibuja: alimenta un renglón del globo. La curva sigue midiendo
  /// SÓLO lo que vence en el ciclo, que es lo que la tarjeta promete.
  /// Día → (cuotas, monto, cuotas de mora, monto de mora). Las dos últimas
  /// son un SUBCONJUNTO de las dos primeras.
  final Map<String, (int, num, int, num)> otrosCiclos;

  /// Lo cobrado EN MORA, día a día. Es un SUBCONJUNTO de [dias]: mismo
  /// universo con una condición más (el pago entró pasada la gracia), así que
  /// la curva roja queda siempre por debajo de la verde. **No se suman.**
  final List<_DatosDia> diasMora;

  /// Cuánto llegó a estar en mora en el ciclo, recuperado o no. Se dibuja
  /// punteado, como la meta: es el techo contra el que se lee la curva roja.
  /// Null mientras los cortes no hayan llegado — entonces no se dibuja.
  final double? topeMora;
  final String metaLegendLabel;

  /// El eje Y en % del total en vez de en córdobas.
  final bool ejePorcentaje;

  /// Segunda punteada: el 100% de la MORA del ciclo, para que la curva roja
  /// tenga contra qué leerse. Sin ella corría contra lo facturado del ciclo y
  /// parecía plana. Null en la tarjeta de Mora, que ya tiene la suya.
  final List<_DatosDia> dias;

  /// Serie de la curva secundaria (lo recuperado TARDE). null = no se dibuja.
  final double meta;
  final DateTime inicioDate;
  final DateTime finDate;
  final bool esPeriodoActual;
  final Color lineColor;

  @override
  State<_GraficoTendencia> createState() => _GraficoTendenciaState();
}

class _GraficoTendenciaState extends State<_GraficoTendencia> {
  int? _selectedIndex;

  int get _diasEnPeriodo => widget.finDate.difference(widget.inicioDate).inDays;

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

  /// La MISMA construccion que la verde, sobre el subconjunto que entro
  /// tarde: asi las dos curvas comparten baseline, cola y escala, y la roja
  /// no puede quedar por encima de la que la contiene.
  SerieTendencia get _serieMora => construirSerieTendencia(
        [for (final d in widget.diasMora) FilaDiaria(d.fecha, d.monto, d.qty)],
        widget.inicioDate,
        widget.finDate,
        _diasConDatos,
      );

  static const _leftPad = 50.0;

  void _onTap(Offset local, double fullWidth) {
    if (fullWidth <= _leftPad || _diasConDatos <= 0) return;
    final chartW = fullWidth - _leftPad;
    final step = chartW / _diasEnPeriodo;
    // Mismo criterio que `_onHover`: fuera del grafico no se selecciona nada.
    final idx = ((local.dx - _leftPad) / step).floor();
    if (local.dx < _leftPad || idx < 0 || idx >= _diasConDatos) {
      if (_selectedIndex != null) setState(() => _selectedIndex = null);
      return;
    }
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
    // DESCARTAR, no clampear. Con el clamp, arrastrar sobre la franja del eje
    // Y (a la izquierda del grafico) mostraba el dia 0, y pasar por un dia
    // futuro mostraba el ultimo con datos: el tooltip decia un dia que el dedo
    // no estaba tocando.
    final crudo = ((local.dx - _leftPad) / step).floor();
    if (local.dx < _leftPad || crudo < 0 || crudo >= _diasConDatos) {
      if (_selectedIndex != null) setState(() => _selectedIndex = null);
      return;
    }
    if (crudo != _selectedIndex) setState(() => _selectedIndex = crudo);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final serie = _serie;
    final acumulados = serie.acumulados;
    final serieMora = _serieMora;
    // Sin tope no hay nada rojo que dibujar: los cortes todavia no llegaron
    // (stream aparte) o el ciclo no tuvo un solo dia de atraso.
    final hayMora = (widget.topeMora ?? 0) > 0;
    const chartHeight = 180.0;
    final metaColor = scheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // La unidad se DERIVA del eje. Estaba hardcodeada en cordobas y
        // Cobertura pasa `ejePorcentaje: true`: el titulo decia "monto C\$"
        // sobre un eje rotulado 25% / 50% / 75% / 100%.
        // "Recuperado", igual que la fila de la tabla. La misma curva se
        // llamaba "Cobrado acumulado" arriba y "Recuperado acumulado" en la
        // leyenda. Y la unidad va dicha: este % es del MONTO, mientras el de la
        // tabla es de CUOTAS — sin decirlo, los dos se leen como el mismo.
        Text(
            widget.ejePorcentaje
                ? 'Recuperado acumulado (% del monto)'
                : 'Recuperado acumulado (C\$)',
            style: TextStyle(fontSize: TxtResumen.cifra, color: scheme.outline)),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final chartWidth = constraints.maxWidth;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // 🔴 El gráfico Y LA LEYENDA van juntos como PRIMER hijo, para
                // que el globo —que es el ÚLTIMO— se dibuje encima de los dos.
                //
                // Antes la leyenda era hermana POSTERIOR en la Column de
                // afuera, y en Flutter el hermano posterior se pinta arriba:
                // con el globo desbordando hacia abajo (mide ~196px contra los
                // 180 del gráfico), la leyenda le quedaba escrita encima y se
                // leía como si el globo fuera transparente. No era
                // transparencia: era orden de pintado (2026-09-03).
                //
                // Es el mismo problema que ya se arregló una vez en el eje
                // HORIZONTAL —el globo se salía por los costados y se clampeó—
                // y que quedó abierto en el vertical.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MouseRegion(
                      onHover: (e) => _onHover(e.localPosition, chartWidth),
                      onExit: (_) => setState(() => _selectedIndex = null),
                      child: GestureDetector(
                        onTapDown: (d) => _onTap(d.localPosition, chartWidth),
                        onHorizontalDragUpdate: (d) =>
                            _onHover(d.localPosition, chartWidth),
                        child: CustomPaint(
                          size: Size(chartWidth, chartHeight),
                          painter: _TendenciaPainter(
                            acumulados: acumulados,
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
                            ejePorcentaje: widget.ejePorcentaje,
                            gridColor: scheme.outlineVariant.withValues(alpha: 0.3),
                            textColor: scheme.outline,
                            selectedIndex: _selectedIndex,
                            diasConPago: {
                              for (final e in serie.montoPorDia.entries)
                                if (e.value > 0) e.key
                            },
                            moraAcumulados:
                                hayMora ? serieMora.acumulados : const [],
                            // Mismo criterio que la verde, pero sobre la serie
                            // de MORA: un punto por dia con recuperacion.
                            diasConPagoMora: hayMora
                                ? {
                                    for (final e in serieMora.montoPorDia.entries)
                                      if (e.value > 0) e.key
                                  }
                                : const <int>{},
                            topeMora: hayMora ? widget.topeMora : null,
                            moraColor: _rojoMora,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // `Wrap` y no `Row`: con la tercera referencia (mora) no entran las
                    // tres en una línea en pantallas angostas, y un Row las desbordaría.
                    Wrap(
                      spacing: 16,
                      runSpacing: 4,
                      children: [
                        _legendItem(widget.lineColor, 'Recuperado'),
                        // NO es una meta: es el 100% de la tarjeta (lo facturado del ciclo
                        // o el total que cayó en mora). No existe ningún setting de meta.
                        // Con el eje en %, la leyenda dice CONTRA QUE es ese 100%: sin el
                        // monto, un "100%" no se puede contrastar con nada.
                        _legendItem(
                            metaColor,
                            widget.ejePorcentaje && widget.meta > 0
                                ? '${widget.metaLegendLabel} · ${Fmt.cordobas(widget.meta)}'
                                : widget.metaLegendLabel,
                            dashed: true),
                        // Las dos rojas SOLO si el ciclo tuvo atraso. Un ciclo limpio no
                        // tiene por que cargar con la leyenda de una curva que no esta
                        // dibujada: diria que hay algo rojo y no lo hay.
                        if (hayMora) ...[
                          _legendItem(_rojoMora, 'Recuperado de mora'),
                          // El techo de la roja, con su monto por la misma razon que el de
                          // la verde: un punteado sin numero no se contrasta con nada.
                          _legendItem(
                              _rojoMora, 'Cayó en mora · ${Fmt.cordobas(widget.topeMora!)}',
                              dashed: true),
                        ],
                      ],
                    ),
                  ],
                ),
                if (_selectedIndex != null &&
                    _selectedIndex! < acumulados.length)
                  Builder(builder: (_) {
                    final idx = _selectedIndex!;
                    // La fecha del tooltip ahora SÍ corresponde a la plata del
                    // día: los pagos fuera de ventana ya no caen acá (van a
                    // baseline/tail), así que `inicioDate + idx` es el día real.
                    final date = widget.inicioDate.add(Duration(days: idx));
                    final acum = acumulados[idx];
                    final montoDia = serie.montoPorDia[idx] ?? 0;
                    final qtyDia = serie.qtyPorDia[idx] ?? 0;
                    // Sub-conjunto del anterior: de esas cuotas del día, las
                    // que llegaron pasada la gracia. NO se suman a las de
                    // arriba — están adentro.
                    final moraMontoDia =
                        hayMora ? (serieMora.montoPorDia[idx] ?? 0) : 0;
                    final moraQtyDia =
                        hayMora ? (serieMora.qtyPorDia[idx] ?? 0) : 0;
                    // EL ACUMULADO DE MORA (2026-09-02, pedido de Rubén: *"me
                    // gustaría también tener un acumulado pero de lo de
                    // recuperado de mora"*).
                    //
                    // NO cuesta una consulta: es la MISMA serie que dibuja la
                    // línea roja, leída en el mismo índice. Y es un
                    // SUBCONJUNTO de `acum`, no un monto aparte — verificado
                    // contra la base con el predicado de la tarjeta: en el
                    // Test Tenant, agosto 2026, C\$4.990 de C\$21.100 (7 de
                    // 30 pagos). Por eso el renglón va sangrado y dice "de
                    // eso": puesto al mismo nivel se leería como algo que se
                    // suma, y sumarlo contaría esa plata dos veces.
                    final moraAcum = hayMora && idx < serieMora.acumulados.length
                        ? serieMora.acumulados[idx]
                        : 0.0;
                    final moraQtyAcum =
                        hayMora && idx < serieMora.qtyAcumuladas.length
                            ? serieMora.qtyAcumuladas[idx]
                            : 0;
                    // Lo que entró ESE DÍA pero pertenece a otro ciclo. La
                    // clave es la fecha ISO y no el índice: el mapa viene de
                    // una consulta que agrupa por `date(fecha_pago)`.
                    final iso = '${date.year.toString().padLeft(4, '0')}-'
                        '${date.month.toString().padLeft(2, '0')}-'
                        '${date.day.toString().padLeft(2, '0')}';
                    final otroCiclo = widget.otrosCiclos[iso];
                    final chartW = chartWidth - _leftPad;
                    final xPos =
                        _leftPad + (idx + 0.5) / _diasEnPeriodo * chartW;
                    final goLeft = xPos > chartWidth * 0.6;

                    final filas = <_GloboFila>[
                      if (qtyDia > 0) ...[
                        // Un día sin mora NO se parte: una suma de un solo
                        // sumando es ruido, y son la mayoría de los días.
                        if (moraQtyDia > 0) ...[
                          _GloboFila('a tiempo', qtyDia - moraQtyDia,
                              montoDia - moraMontoDia,
                              color: _verdeOk),
                          _GloboFila('venían de mora', moraQtyDia,
                              moraMontoDia,
                              color: _rojoMora),
                          _GloboFila('cobradas', qtyDia, montoDia,
                              total: true),
                        ] else
                          _GloboFila('cobradas', qtyDia, montoDia,
                              total: true),
                      ],
                      // ── LO QUE SUMA AL ACUMULADO ──────────
                      //
                      // ORDEN (2026-09-02, pedido de Rubén): arriba del total
                      // va SÓLO lo que suma a él, y el total cierra abajo —
                      // *"el acumulado es la constante del ciclo, y como en los
                      // recibos el total sale al final"*.
                      if (idx == 0 && serie.baseline > 0)
                        _GloboFila('Antes del ciclo',
                            serie.baselineQty, serie.baseline,
                            separado: qtyDia > 0, tenue: true),
                      if (idx == acumulados.length - 1 &&
                          serie.tail > 0) ...[
                        _GloboFila('Después del ciclo',
                            serie.tailQty, serie.tail,
                            separado: qtyDia > 0, tenue: true),
                        if (serieMora.tail > 0.009)
                          _GloboFila('de eso, de mora',
                              serieMora.tailQty, serieMora.tail,
                              tenue: true,
                              sangria: true,
                              punto: false,
                              color: _rojoMora),
                      ],
                      // ── EL TOTAL, que CIERRA el ciclo ─────────
                      _GloboFila('Acumulado del ciclo', null, acum,
                          separado: true, tenue: true),
                      if (moraAcum > 0.009)
                        _GloboFila('de eso, de mora', moraQtyAcum,
                            moraAcum,
                            tenue: true,
                            sangria: true,
                            punto: false,
                            color: _rojoMora),
                      // ── LO QUE **NO** ES DE ESTE CICLO ────────
                      if (otroCiclo != null && otroCiclo.$1 > 0) ...[
                        _GloboFila('de otros ciclos', otroCiclo.$1,
                            otroCiclo.$2,
                            separado: true, tenue: true),
                        if (otroCiclo.$4 > 0.009)
                          _GloboFila('de eso, de mora', otroCiclo.$3,
                              otroCiclo.$4,
                              tenue: true,
                              sangria: true,
                              punto: false,
                              color: _rojoMora),
                      ],
                    ];

                    // EL GLOBO, ACOTADO AL GRAFICO Y A LA TARJETA (2026-09-04).
                    //
                    // Horizontalmente: 295px (antes 250px) permite que las
                    // cifras en córdobas (ej. "3.211.922,82 C$") y los rótulos
                    // ("Acumulado del ciclo") entren sin truncar el "C$".
                    //
                    // Verticalmente: en días con muchas filas (ej. día final con
                    // tail, mora y otros ciclos = 9 filas), el globo mide
                    // ~250px y desbordaba hacia abajo, siendo tapado por la
                    // tarjeta siguiente en la pantalla. Al calcular la altura
                    // estimada, si supera el área visible del gráfico (~200px)
                    // se desplaza hacia arriba (`top` negativo) para que su
                    // base quede siempre adentro de la tarjeta actual.
                    final altoEstimado = 52.0 +
                        (qtyDia == 0 ? 18.0 : 0.0) +
                        filas.length * 22.0;
                    const maxTopPermitido = 200.0;
                    final topOffset = altoEstimado > maxTopPermitido
                        ? (maxTopPermitido - altoEstimado)
                        : 0.0;

                    final anchoGlobo = math.min(295.0, chartWidth);
                    final left = (goLeft ? xPos - 8 - anchoGlobo : xPos + 8)
                        .clamp(0.0, math.max(0.0, chartWidth - anchoGlobo))
                        .toDouble();

                    return Positioned(
                      top: topOffset,
                      left: left,
                      width: anchoGlobo,
                      child: IgnorePointer(
                        child: Container(
                          constraints:
                              BoxConstraints(maxWidth: anchoGlobo),
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
                                '${Fmt.diaSemana(date)} ${date.day} de '
                                '${Fmt.mes(DateTime(date.year, date.month))}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: TxtResumen.grande),
                              ),
                              const SizedBox(height: 7),
                              _tablaGlobo(filas, sinCobros: qtyDia == 0),
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
        // Las notas al pie del grafico se quitaron (2026-08-13, pedido de
        // Ruben: "podemos remover los textos explicativos"). Lo que decian vive
        // en el (i): que la curva de mora es un SUBCONJUNTO de lo recuperado y
        // no plata aparte, y que la curva arranca elevada por el pre-ciclo.
        // La nota "Base X recuperado antes del ciclo · Y después" se quitó
        // (2026-08-01, pedido de Rubén): la curva igual arranca elevada para
        // cerrar en el total y el tooltip del día 0/último lo aclara al pasar.
      ],
    );
  }

  /// UNA fila del globo. Es data, no widget: la grilla la arma
  /// [_tablaGlobo], que necesita ver TODAS las filas juntas para poder darle
  /// a cada columna el ancho de su celda mas ancha.
  ///
  /// [cuotas] null = la fila no tiene conteo (el acumulado).

  /// Arma el globo entero como UNA grilla de tres columnas.
  ///
  /// El ancho de las columnas de cuotas y monto sale de su celda mas ancha
  /// (`IntrinsicColumnWidth`), asi que TODAS las filas coinciden por
  /// construccion. El rotulo se queda con lo que sobra (`FlexColumnWidth`) y
  /// se trunca si no entra: si algo se tiene que perder, que sea la palabra y
  /// no la cifra.
  ///
  /// [sinCobros] pone el aviso arriba de la grilla — ese dia no hay reparto
  /// que mostrar, solo el acumulado.
  Widget _tablaGlobo(List<_GloboFila> filas, {required bool sinCobros}) {
    final scheme = Theme.of(context).colorScheme;

    Widget celda(Widget hijo, {bool derecha = true}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5),
          child: Align(
            alignment: derecha ? Alignment.centerRight : Alignment.centerLeft,
            child: hijo,
          ),
        );

    TableRow fila(_GloboFila f) {
      final estilo = TextStyle(
        fontSize: f.tenue ? 11.5 : 12,
        fontWeight: f.total ? FontWeight.w600 : FontWeight.w400,
        color: f.tenue ? scheme.outline : scheme.onSurface,
      );
      return TableRow(
        decoration: f.total || f.separado
            ? BoxDecoration(
                border: Border(
                    top: BorderSide(
                        color: scheme.outlineVariant, width: 0.5)))
            : null,
        children: [
          celda(
            Padding(
              padding: EdgeInsets.only(
                  left: f.sangria ? 12 : 0,
                  top: f.total || f.separado ? 4 : 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (f.color != null && f.punto) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                          color: f.color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    // DOS líneas, no una (2026-09-03). El globo mide 250px y
                    // con "1.476.822,69 C$" en su columna, al rótulo le quedan
                    // ~110: "Acumulado del ciclo" salía cortado como
                    // "Acumulado del cic…" — o sea que el renglón más
                    // importante del globo era el único que no se podía leer.
                    //
                    // Partirlo NO deja el monto huérfano, a diferencia de la
                    // tabla de abajo (ver `fila3`): acá cada dato vive en su
                    // propia columna de la `Table` y el alineado vertical es
                    // `middle`, así que la cifra queda centrada contra las dos
                    // líneas. Y que el globo crezca de alto ya no molesta:
                    // desde este mismo cambio se dibuja ENCIMA de la leyenda.
                    //
                    // Se descartó ensanchar el globo: acercarlo a los bordes
                    // revive el desborde horizontal que ya se arregló una vez.
                    child: Text(f.rotulo,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: estilo.copyWith(color: f.color ?? estilo.color)),
                  ),
                ],
              ),
            ),
            derecha: false,
          ),
          celda(Padding(
            padding: EdgeInsets.only(
                left: 8, top: f.total || f.separado ? 4 : 0),
            child: Text(f.cuotas == null ? '' : '${f.cuotas}', style: estilo),
          )),
          celda(Padding(
            padding: EdgeInsets.only(
                left: 8, top: f.total || f.separado ? 4 : 0),
            child: Text(Fmt.cordobas(f.monto),
                style: estilo, maxLines: 1, softWrap: false),
          )),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sinCobros)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            // "de ESTE ciclo" y no "este día": pudo entrar plata de cuotas de
            // otros ciclos, y afirmar que no hubo cobros era falso. Lo reportó
            // el dueño mirando el 16 de agosto en el ciclo de septiembre, un
            // día en que habían entrado C$1.000 de dos cuotas de agosto.
            child: Text('Sin cobros de este ciclo',
                style: TextStyle(
                    fontSize: TxtResumen.cifra, color: scheme.outline)),
          ),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(),
            1: IntrinsicColumnWidth(),
            2: IntrinsicColumnWidth(),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [for (final f in filas) fila(f)],
        ),
      ],
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
        // `Flexible` + ellipsis: el rotulo de la punteada llega a medir
        // "Meta del ciclo (100%) · 34.445,00 C$", que en un telefono no entra
        // ni en una linea del `Wrap` y desbordaba 185px. Segundo y ultimo
        // cambio a esta tarjeta desde que se dio por cerrada: es un OVERFLOW,
        // no un rediseno (test de 360px, 2026-08-29).
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TxtResumen.cifra, color: color)),
        ),
      ],
    );
  }
}

// ── Painter ──

class _TendenciaPainter extends CustomPainter {
  _TendenciaPainter({
    required this.acumulados,
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
    this.ejePorcentaje = false,
    required this.gridColor,
    required this.textColor,
    this.selectedIndex,
    this.diasConPago = const <int>{},
    this.moraAcumulados = const [],
    this.diasConPagoMora = const <int>{},
    this.topeMora,
    this.moraColor = const Color(0xFFE24B4A),
  });

  final List<double> acumulados;

  /// Curva secundaria: de lo acumulado, la parte que entró tarde. Va SIEMPRE
  /// por debajo de la principal (es un subconjunto del mismo universo), así que
  /// comparte escala y no necesita segundo eje. Vacía = no se dibuja.
  final List<double> moraAcumulados;

  /// Dias en que se recupero mora, para marcarlos con un punto igual que
  /// [diasConPago] hace con la curva verde. Sin esto la roja subia sin decir
  /// CUANDO: se veia el resultado, no el evento.
  final Set<int> diasConPagoMora;

  /// El techo de esa curva: todo lo que cayó en atraso en el ciclo, se haya
  /// recuperado o no. Se pinta punteado, igual que la meta le da su techo a la
  /// verde. Null = no hubo mora (o los cortes no llegaron todavía).
  ///
  /// **La roja puede pasarse de su punteada, igual que la verde de la meta.**
  /// No es un bug: las CURVAS suman plata que entró (crudo) y las PUNTEADAS
  /// son facturado (clampeado a lo que la cuota necesitaba), así que un
  /// sobrepago hecho tarde levanta una y no la otra. Es el mismo caso que el
  /// `math.max` del eje ya contempla para la verde. Medido 2026-09-01 contra
  /// producción: 0 cuotas divergen en los 3 tenants, historia completa.
  final double? topeMora;
  final Color moraColor;

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

  /// Indices de dia en los que ENTRO plata. Se pintan como un punto sobre la
  /// curva: sin ellos, una linea que sube de a poco no deja ver DONDE hubo
  /// cobros, y el dueno tenia que barrer con el mouse para encontrarlos.
  ///
  /// Sale de `montoPorDia`, no de "donde la curva subio": el dia 0 arranca
  /// elevado cuando hubo pagos ANTES del ciclo (una cuota adelantada), y ahi no
  /// hubo cobro ese dia. Derivarlo de la subida marcaria un punto que no existe.
  final Set<int> diasConPago;
  final bool ejePorcentaje;
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

    const gridLines = 4;
    final maxVal = [
      meta,
      granTotal, // incluye el tail: el eje tiene que abarcar el total real
      if (acumulados.isNotEmpty) acumulados.last,
      // La mora es un SUBCONJUNTO, asi que en teoria nunca manda el eje. Va
      // igual por la misma razon que el `math.max` de abajo: preferimos que el
      // eje se estire antes que cortar una linea.
      if (topeMora != null) topeMora!,
      if (moraAcumulados.isNotEmpty) moraAcumulados.last,
    ].reduce(math.max);
    // Con eje en PORCENTAJE el tope es la META: 100% arriba y la curva usa
    // todo el alto. `_ejeMaximo` redondeaba hacia arriba a un numero "lindo"
    // y el eje llegaba a 149%, con media grafica vacia.
    //
    // El `math.max` no es decorativo: si un ciclo cobrara MAS de lo facturado
    // (sobrepago) la curva se saldria del cuadro. Preferimos que el eje se
    // estire antes que cortar la linea.
    final yMax = ejePorcentaje
        ? math.max(meta, maxVal)
        : _ejeMaximo(maxVal, gridLines);

    double xOf(int offset) => leftPad + (offset + 0.5) / diasEnPeriodo * chartW;
    double yOf(double val) => topPad + chartH * (1 - val / yMax);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 0; i <= gridLines; i++) {
      final y = topPad + chartH * i / gridLines;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
    }
    canvas.drawLine(const Offset(leftPad, topPad),
        Offset(leftPad, topPad + chartH), gridPaint);
    canvas.drawLine(Offset(leftPad, topPad + chartH),
        Offset(size.width, topPad + chartH), gridPaint);

    final yLabelPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= gridLines; i++) {
      final val = yMax * (gridLines - i) / gridLines;
      // El eje habla en % del ciclo cuando la tarjeta mide cumplimiento: es la
      // MISMA unidad que la columna de la tabla, así que la curva termina justo
      // en el número de la fila Recuperado. Con el eje en córdobas había que
      // traducir de memoria entre 5.800 y 52%.
      final label = (ejePorcentaje && meta > 0)
          ? '${(val / meta * 100).round()}%'
          : _formatCompact(val);
      yLabelPainter.text = TextSpan(
          text: label, style: TextStyle(fontSize: TxtResumen.minimo, color: textColor));
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
      // En una ventana larga (la tarjeta de Mora abarca 6 ciclos, ~184 días)
      // marcar cada 5 días daría casi 40 etiquetas encimadas: ahí solo van los
      // cambios de mes. En la de un ciclo se mantienen los quintos.
      final ventanaLarga = diasEnPeriodo > 45;
      final isFifth = !ventanaLarga && date.day % 5 == 0 && !isFirst && !isLast;

      if (!isFirst && !isLast && !isMonthBoundary && !isFifth) continue;

      String label;
      if (isMonthBoundary || (isFirst && lastLabelMonth != date.month)) {
        label = '${date.day} ${mesCortoPeriodo(date.month)}';
        lastLabelMonth = date.month;
      } else {
        label = '${date.day}';
      }

      xLabelPainter.text = TextSpan(
          text: label, style: TextStyle(fontSize: TxtResumen.minimo, color: textColor));
      xLabelPainter.layout();
      xLabelPainter.paint(canvas,
          Offset(xOf(i) - xLabelPainter.width / 2, topPad + chartH + 6));
    }

    if (meta > 0) {
      final metaY = yOf(meta);
      final dashPaint = Paint()
        ..color = metaLineColor.withValues(alpha: 0.5)
        ..strokeWidth = 1.5;
      _drawDashedLine(canvas, Offset(leftPad, metaY), Offset(size.width, metaY),
          dashPaint, 6, 4);
    }


    // (La línea punteada "pre-ciclo" del baseline se quitó — 2026-08-01, pedido
    // de Rubén. La curva SIGUE arrancando desde `baseline` — ver `acumulados`,
    // que ya lo incluyen — para cerrar en el total; solo se sacó el marcador.)

    // TENANT SIN NADA: sin meta, sin cobros y sin mora, `yMax` da 0 y `yOf`
    // divide por cero -> NaN -> `drawCircle` con un Offset invalido. En debug
    // eso es un assert que tumba el frame; en release el assert no esta y el
    // dibujo queda indefinido. Pasa en un tenant recien creado y en cualquier
    // device ANTES del primer sync, que es la primera pantalla que ve alguien
    // nuevo. La grilla y los rotulos ya se dibujaron arriba (no usan `yOf`), y
    // de aca para abajo no hay nada que plotear.
    //
    // Va DESPUES de la punteada de meta a proposito: esa esta guardada por
    // `meta > 0`, y si hay meta entonces `yMax >= meta > 0`.
    if (!(yMax > 0)) return;

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

    // Un punto por dia con cobro. Van despues de la linea y ANTES del punto de
    // "hoy" y del seleccionado, para que esos dos —que son mas grandes y con
    // borde blanco— queden encima y se distingan.
    for (final i in diasConPago) {
      if (i < 0 || i >= acumulados.length) continue;
      final px = xOf(i);
      final py = yOf(acumulados[i]);
      canvas.drawCircle(Offset(px, py), 3.5, Paint()..color = lineColor);
      canvas.drawCircle(
          Offset(px, py),
          3.5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }

    // LA MORA, de vuelta (2026-09-01). Se habia ido el 2026-08-13 porque la
    // tarjeta "mide CUMPLIMIENTO y nada mas"; el dueño la pidio de nuevo, en
    // rojo, para leer el ciclo y su atraso de un solo vistazo.
    //
    // Va DESPUES de la curva verde a proposito: es la de adentro (subconjunto),
    // asi que tiene que quedar encima o la verde la tapa donde se tocan.
    if (moraAcumulados.isNotEmpty) {
      final moraPath = Path();
      for (var i = 0; i < moraAcumulados.length; i++) {
        final x = xOf(i);
        final y = yOf(moraAcumulados[i]);
        if (i == 0) {
          moraPath.moveTo(x, y);
        } else {
          moraPath.lineTo(x, y);
        }
      }
      // Mas fina que la verde y SIN relleno: son dos curvas sobre la misma
      // escala y dos areas pintadas una encima de la otra se leen como una
      // suma. No se suman: la roja esta contenida en la verde.
      canvas.drawPath(
          moraPath,
          Paint()
            ..color = moraColor
            ..strokeWidth = 2.0
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round);

      // Un punto por dia en que se RECUPERO mora (pedido de Ruben,
      // 2026-09-02). Mismo tamano y mismo borde blanco que los de la verde,
      // para que se lean como la misma cosa en dos series; el color los
      // separa. Un poco mas chicos (3.0 contra 3.5) porque la roja es la
      // curva fina y de adentro: puntos del mismo tamano sobre una linea mas
      // delgada se ven mas pesados que los de la verde.
      for (final i in diasConPagoMora) {
        if (i < 0 || i >= moraAcumulados.length) continue;
        final px = xOf(i);
        final py = yOf(moraAcumulados[i]);
        canvas.drawCircle(Offset(px, py), 3.0, Paint()..color = moraColor);
        canvas.drawCircle(
            Offset(px, py),
            3.0,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
    }

    // El techo de la mora, punteado. Va al final para que ninguna curva lo
    // tape: es la referencia contra la que se lee la roja.
    if (topeMora != null && topeMora! > 0) {
      final moraY = yOf(topeMora!);
      _drawDashedLine(
          canvas,
          Offset(leftPad, moraY),
          Offset(size.width, moraY),
          Paint()
            ..color = moraColor.withValues(alpha: 0.55)
            ..strokeWidth = 1.5,
          6,
          4);
    }

    if (esPeriodoActual && acumulados.isNotEmpty) {
      final lastX = xOf(acumulados.length - 1);
      final lastY = yOf(acumulados.last);
      canvas.drawCircle(Offset(lastX, lastY), 5, Paint()..color = lineColor);
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
      canvas.drawCircle(Offset(sx, sy), 5, Paint()..color = lineColor);
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

  /// Techo del eje redondeado hacia arriba, para que las divisiones caigan en
  /// números redondos. Con el `maxVal * 1.1` anterior, un máximo de 2.100 daba
  /// ticks en 2.310 / 1.732 / 1.155 / 577 y el eje se leía "2k · 2k · 1k · 578":
  /// dos etiquetas idénticas y una con decimales sueltos.
  double _ejeMaximo(double maxVal, int divisiones) {
    if (maxVal <= 0) return 100;
    final crudo = maxVal * 1.05 / divisiones;
    final magnitud =
        math.pow(10, (math.log(crudo) / math.ln10).floor()).toDouble();
    const escalones = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0];
    final norm = crudo / magnitud;
    final paso =
        escalones.firstWhere((e) => e >= norm - 1e-9, orElse: () => 10.0) *
            magnitud;
    return paso * divisiones;
  }

  /// Etiqueta del eje. Por debajo de 10.000 va el número entero con separador
  /// de miles: a esa escala la abreviatura "k" pierde demasiada precisión y
  /// dos divisiones distintas terminan mostrando el mismo texto.
  String _formatCompact(double val) {
    if (val >= 1000000) return '${(val / 1000000).toStringAsFixed(1)}M';
    if (val >= 10000) return '${(val / 1000).round()}k';
    return Fmt.entero(val.round());
  }

  @override
  bool shouldRepaint(covariant _TendenciaPainter old) =>
      old.acumulados != acumulados ||
      old.meta != meta ||
      old.baseline != baseline ||
      old.tail != tail ||
      old.granTotal != granTotal ||
      old.selectedIndex != selectedIndex ||
      old.diasConPago.length != diasConPago.length ||
      old.diasConPagoMora.length != diasConPagoMora.length ||
      // Sin esto la curva roja no aparece: su stream llega DESPUES del primer
      // pintado y el canvas se queda con el frame viejo.
      old.moraAcumulados.length != moraAcumulados.length ||
      old.topeMora != topeMora ||
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
      canvas.drawLine(Offset(x, size.height / 2),
          Offset(math.min(x + dash, size.width), size.height / 2), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter old) => old.color != color;
}
