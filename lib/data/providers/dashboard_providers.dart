import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/admin/dashboard/dashboard_query.dart'
    show estadoActual, ultimoVencimientoConPago;
import '../../powersync/db.dart' as ps;
import '../repositories/settings_repo.dart';
import '../utils/formatters.dart';
import '../utils/periodo_dashboard.dart';
import 'db_epoch_provider.dart';
import '../../features/admin/dashboard/resumen_watch.dart';

/// Providers de los KPIs del dashboard admin (R10).
///
/// Antes los KPIs vivían en `StreamBuilder` directos dentro del dashboard
/// screen, lo cual disparaba una re-subscripción al stream en cada rebuild
/// del padre (porque `watchResumen(...)` retorna una nueva instancia de
/// Stream en cada llamada). Eso causaba flashes de loading e queries
/// duplicadas en SQLite.
///
/// Acá los pasamos a `StreamProvider`: Riverpod cachea el stream por
/// identidad del provider, así que no importa cuántas veces rebuildee el
/// dashboard — el stream se subscribe una sola vez y los watchers leen
/// del cache.
///
/// Los providers que dependen de settings usan `select((s) => s.X)` para
/// invalidarse sólo cuando el campo específico cambia (no en cualquier
/// update del mapa global de settings).
///
/// Fechas: se computan dentro del factory del provider y quedan
/// efectivamente fijas hasta que el provider se invalida o la app
/// reinicia. El cambio de día sin reload manual deja stats un día atrás
/// — edge case aceptado, fuera de scope de R10.

// Las consultas de las tarjetas del Resumen (Cobertura, Mora, Proyeccion,
// Recuperacion por cobrador y comunidad, Quien cobro) NO viven aca: cada tarjeta se
// lleva la suya a su propio archivo. Es la independencia que pidio el dueno el
// 2026-08-28 — "cada una es individual, asi cada cambio en cada una es
// independiente de los demas y no deberian afectarlos".
//
// Lo que queda en este archivo es lo COMPARTIDO de verdad: el epoch de DB, los
// KPIs de caja y los cortes de fecha que varias pantallas necesitan iguales.

class CobrosKpis {
  const CobrosKpis({
    required this.hoy,
    required this.semana,
    required this.periodo,
    required this.qtyHoy,
    required this.qtySemana,
    required this.qtyPeriodo,
  });
  final num hoy;
  final num semana;
  // Acumulado del PERÍODO en curso (corte del 15, no mes calendario) — el
  // mismo rango que grafica la card de tendencia.
  final num periodo;
  final int qtyHoy;
  final int qtySemana;
  final int qtyPeriodo;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CobrosKpis &&
          other.hoy == hoy &&
          other.semana == semana &&
          other.periodo == periodo &&
          other.qtyHoy == qtyHoy &&
          other.qtySemana == qtySemana &&
          other.qtyPeriodo == qtyPeriodo;

  @override
  int get hashCode =>
      Object.hash(hoy, semana, periodo, qtyHoy, qtySemana, qtyPeriodo);
}

class OperativoKpis {
  const OperativoKpis({
    required this.clientes,
    required this.cuotasPend,
    required this.saldo,
    required this.vencidas,
    required this.saldoVencido,
    required this.cuotasSuspendidas,
    required this.saldoSuspendido,
    required this.alDia,
    required this.saldoAlDia,
    required this.enGracia,
    required this.saldoEnGracia,
    required this.pagadas,
    required this.parciales,
  });
  final int clientes;
  // cuotasPend/saldo/vencidas/saldoVencido INCLUYEN contratos suspendidos: son
  // TODA la deuda viva. Suspender significa "se fue debiendo y le vamos a
  // seguir cobrando" (regla del 2026-08-24), así que su deuda es tan cobrable
  // como la de un contrato activo — más, si se mira la intención.
  // cuotasSuspendidas/saldoSuspendido NO son un bucket aparte: son el DESGLOSE
  // de cuánto de lo anterior no está en la ruta del día. Sumarlos al titular lo
  // duplica.
  final int cuotasPend;
  final num saldo;
  final int vencidas;
  final num saldoVencido;
  final int cuotasSuspendidas;
  final num saldoSuspendido;

  /// Las TRES partes de `cuotasPend`, disjuntas y exhaustivas: una cuota por
  /// cobrar está al día, en gracia o en mora, nunca en dos.
  /// `alDia + enGracia + vencidas = cuotasPend` y lo mismo con los saldos
  /// — verificado contra producción el 2026-09-01 (Mairena:
  /// 20.217 + 797 + 2.596 = 23.610 cuotas y C$21.620.388 al peso).
  ///
  /// `vencidas`/`saldoVencido` son la tercera parte: ya estaban, y a propósito
  /// no se renombraron — los consume el titular de mora desde antes.
  final int alDia;
  final num saldoAlDia;
  final int enGracia;
  final num saldoEnGracia;

  /// Contexto histórico, NO parte de la cartera viva: cuotas ya saldadas desde
  /// que el tenant existe. Va al pie de la tarjeta por eso mismo.
  final int pagadas;

  /// Cuotas con abono que no alcanzó. Es un ATRAVESADO, no un cuarto bucket:
  /// cada una ya está contada en al día, gracia o mora según su fecha.
  final int parciales;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OperativoKpis &&
          other.clientes == clientes &&
          other.cuotasPend == cuotasPend &&
          other.saldo == saldo &&
          other.vencidas == vencidas &&
          other.saldoVencido == saldoVencido &&
          other.cuotasSuspendidas == cuotasSuspendidas &&
          other.saldoSuspendido == saldoSuspendido &&
          other.alDia == alDia &&
          other.saldoAlDia == saldoAlDia &&
          other.enGracia == enGracia &&
          other.saldoEnGracia == saldoEnGracia &&
          other.pagadas == pagadas &&
          other.parciales == parciales;

  @override
  int get hashCode => Object.hash(clientes, cuotasPend, saldo, vencidas,
      saldoVencido, cuotasSuspendidas, saldoSuspendido, alDia, saldoAlDia,
      enGracia, saldoEnGracia, pagadas, parciales);
}

class DistribucionCuotas {
  const DistribucionCuotas({
    required this.alDia,
    required this.parcial,
    required this.enGracia,
    required this.vencida,
    required this.pagada,
  });
  final int alDia;
  final int parcial;
  final int enGracia;
  final int vencida;
  final int pagada;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DistribucionCuotas &&
          other.alDia == alDia &&
          other.parcial == parcial &&
          other.enGracia == enGracia &&
          other.vencida == vencida &&
          other.pagada == pagada;

  @override
  int get hashCode =>
      Object.hash(alDia, parcial, enGracia, vencida, pagada);
}

/// Cortes de fecha calculados DENTRO del SQL, en hora Nicaragua (UTC-6, sin
/// DST — regla 1b de AGENTS). Antes se calculaban en Dart una sola vez, en el
/// factory del `StreamProvider`, así que quedaban CONGELADOS en el momento en
/// que arrancó la app: con el dashboard abierto al cruzar la medianoche, "Hoy"
/// seguía sumando el día anterior, y al cruzar el 15 el KPI del período seguía
/// contra el ciclo viejo (bug confirmado en el audit 2026-08-08). Al vivir en
/// la query se re-evalúan en cada emisión del stream.
/// Emite el día de Nicaragua y vuelve a emitir CUANDO CAMBIA.
///
/// Los KPIs de caja resuelven "hoy" y "esta semana" dentro del SQL para que no
/// queden congelados en el arranque de la app. Pero ese SQL solo se re-evalúa
/// cuando cambia la BASE, y a las 00:00 nadie escribe nada: la tarjeta seguía
/// mostrando el total de AYER hasta que alguien registrara un cobro.
///
/// Verificado el 2026-08-12 a las 00:01 en el tenant de prueba: "Hoy" decía
/// C$745,00 —el cobro del 11— aunque el 12 no había entrado nada. Un número de
/// ayer presentado como el de hoy es peor que no mostrarlo.
final diaNicaraguaProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  var dia = Fmt.hoyNicaragua();
  yield dia;
  while (true) {
    await Future<void>.delayed(const Duration(minutes: 1));
    final ahora = Fmt.hoyNicaragua();
    if (ahora != dia) {
      dia = ahora;
      yield dia;
    }
  }
});

const _sqlHoyNi = "date('now','-6 hours')";

/// Domingo de la semana en curso (semana DOMINGO→SÁBADO, pedido de Rubén
/// 2026-08-01). `%w` da 0 para domingo, así que restar `%w` días cae en el
/// domingo actual — y si HOY es domingo, resta 0 y se queda en hoy.
const _sqlInicioSemanaNi =
    "date('now','-6 hours','-' || strftime('%w','now','-6 hours') || ' days')";

/// Día 15 que abre el ciclo en curso (ver `periodo_dashboard.dart`): del 15 en
/// adelante es el 15 de este mes; antes del 15, el 15 del mes pasado.
const _sqlInicioPeriodoNi =
    "CASE WHEN CAST(strftime('%d','now','-6 hours') AS INTEGER) >= 15 "
    "THEN date('now','-6 hours','start of month','+14 days') "
    "ELSE date('now','-6 hours','start of month','-1 month','+14 days') END";

class CobrosRangoCustom {
  const CobrosRangoCustom({required this.total, required this.qty});
  final num total;
  final int qty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CobrosRangoCustom && other.total == total && other.qty == qty;

  @override
  int get hashCode => Object.hash(total, qty);
}

final cobrosRangoCustomProvider = StreamProvider.autoDispose.family<CobrosRangoCustom, (String, String)>((ref, rango) {
  ref.watch(dbEpochProvider);
  final (desde, hasta) = rango;
  return watchResumen(
    '''
    SELECT
      COALESCE(SUM(monto_cordobas), 0) AS total,
      COUNT(*) AS qty
      FROM pagos
     WHERE COALESCE(anulado, 0) = 0 AND COALESCE(en_revision, 0) = 0
       AND fecha_cobro >= ?
       AND fecha_cobro <= ?
    ''',
    parameters: [desde, hasta],
  ).map((rows) {
    final r = rows.first;
    return CobrosRangoCustom(
      total: r['total'] as num,
      qty: (r['qty'] as num).toInt(),
    );
  });
});

/// Descomposición de la CAJA del período por el vencimiento de la cuota que
/// pagó cada peso. Responde la pregunta que disparó el reclamo del dueño de
/// Telecable Mairena (2026-08-08): *"¿por qué la caja del período no es lo
/// mismo que el Recuperado de la gráfica?"*.
///
/// Los cuatro baldes SUMAN EXACTAMENTE el KPI "Este período" — esa es la
/// propiedad que hace auditable la tarjeta: el dueño puede sacar la
/// calculadora y le tiene que cerrar. Por eso acá NO se excluyen contratos
/// suspendidos ni cuotas anuladas: caja es caja, entró toda.
class DesgloseCaja {
  const DesgloseCaja({
    required this.total,
    required this.delCiclo,
    required this.atrasos,
    required this.adelantos,
    required this.sinCuota,
    required this.moraVieja,
    this.pagadoAntes = 0,
  });

  /// Total de caja del período (= el KPI "Este período").
  final num total;

  /// Pagos a cuotas que vencen DENTRO del ciclo.
  final num delCiclo;

  /// Pagos a cuotas de ciclos ANTERIORES (deuda vieja que se puso al día).
  final num atrasos;

  /// Pagos a cuotas que todavía NO vencen (el cliente pagó adelantado).
  final num adelantos;

  /// Pagos sin cuota asociada (no debería haber; se muestra si aparece).
  final num sinCuota;

  /// Porción de [atrasos] sobre cuotas que ya habían pasado los días de
  /// gracia: es recuperación de mora VIEJA, que no aparece en ninguna otra
  /// tarjeta del Resumen.
  final num moraVieja;

  /// Plata de cuotas de ESTE ciclo que entró ANTES de que el ciclo empezara
  /// (el cliente pagó adelantado el mes pasado). NO forma parte de esta caja
  /// —entró en la ventana anterior— pero SÍ del "Recuperado" de la tarjeta de
  /// cobertura. Es la única pieza que separa a las dos tarjetas, y sin ella el
  /// dueño no puede llegar de un número al otro:
  ///   delCiclo + pagadoAntes = el Recuperado de Cobertura del ciclo.
  final num pagadoAntes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesgloseCaja &&
          other.total == total &&
          other.delCiclo == delCiclo &&
          other.atrasos == atrasos &&
          other.adelantos == adelantos &&
          other.sinCuota == sinCuota &&
          other.moraVieja == moraVieja;

  @override
  int get hashCode =>
      Object.hash(total, delCiclo, atrasos, adelantos, sinCuota, moraVieja);
}

/// Ventana de caja que el usuario elige con los botones rápidos de "Cobros del
/// período". Solo mueve DESDE CUÁNDO se cuentan los pagos; los baldes del
/// desglose (de este ciclo / atrasos / adelantos) siguen comparando contra el
/// CICLO, que es lo que les da sentido.
enum VentanaCaja { hoy, semana, periodo }

extension VentanaCajaSql on VentanaCaja {
  /// Expresión SQL del primer día contado, en hora de Nicaragua.
  String get desdeSql => switch (this) {
        VentanaCaja.hoy => _sqlHoyNi,
        VentanaCaja.semana => _sqlInicioSemanaNi,
        VentanaCaja.periodo => _sqlInicioPeriodoNi,
      };

  String get etiqueta => switch (this) {
        VentanaCaja.hoy => 'Hoy',
        VentanaCaja.semana => 'Esta semana',
        VentanaCaja.periodo => 'Este período',
      };
}

/// Parámetros del desglose: los días de gracia y la ventana elegida.
typedef DesgloseArgs = ({int diasGracia, VentanaCaja ventana});

final desgloseCajaProvider = StreamProvider.autoDispose.family<DesgloseCaja, DesgloseArgs>((ref, args) {
  ref.watch(dbEpochProvider);
  ref.watch(diaNicaraguaProvider); // "hoy"/"esta semana" cambian a medianoche
  final diasGracia = args.diasGracia;
  // Los bordes del ciclo se calculan en el SQL (no en Dart) para que no queden
  // congelados en el arranque de la app — mismo motivo que en cobrosKpisProvider.
  return watchResumen(
    '''
    WITH w AS (SELECT ($_sqlInicioPeriodoNi) AS ini,
                      (${args.ventana.desdeSql}) AS desde)
    SELECT
      COALESCE(SUM(p.monto_cordobas), 0) AS total,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento >= (SELECT ini FROM w)
                         AND cu.fecha_vencimiento <  date((SELECT ini FROM w), '+1 month')
                        THEN p.monto_cordobas ELSE 0 END), 0) AS del_ciclo,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento <  (SELECT ini FROM w)
                        THEN p.monto_cordobas ELSE 0 END), 0) AS atrasos,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento >= date((SELECT ini FROM w), '+1 month')
                        THEN p.monto_cordobas ELSE 0 END), 0) AS adelantos,
      COALESCE(SUM(CASE WHEN cu.id IS NULL
                        THEN p.monto_cordobas ELSE 0 END), 0) AS sin_cuota,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento < (SELECT ini FROM w)
                         AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                             < p.fecha_cobro
                        THEN p.monto_cordobas ELSE 0 END), 0) AS mora_vieja,
      -- Fuera del WHERE de abajo a propósito: son pagos ANTERIORES a la
      -- ventana. Cierra el puente con la tarjeta de cobertura.
      COALESCE((SELECT SUM(p2.monto_cordobas) FROM pagos p2
                  JOIN cuotas cu2 ON cu2.id = p2.cuota_id
                 WHERE COALESCE(p2.anulado, 0) = 0
                   AND COALESCE(p2.en_revision, 0) = 0
                   AND cu2.estado != 'anulada'
                   AND cu2.fecha_vencimiento >= (SELECT ini FROM w)
                   AND cu2.fecha_vencimiento <  date((SELECT ini FROM w), '+1 month')
                   AND p2.fecha_cobro < (SELECT ini FROM w)), 0) AS pagado_antes
      FROM pagos p
 LEFT JOIN cuotas cu ON cu.id = p.cuota_id
     WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
       -- La VENTANA filtra los pagos; el CICLO (`ini`) clasifica los baldes.
       -- Mezclarlos haría que al elegir "Hoy" todo cayera en "atrasos".
       AND p.fecha_cobro >= (SELECT desde FROM w)
    ''',
    parameters: [diasGracia],
  ).map((rows) {
    final r = rows.first;
    return DesgloseCaja(
      total: r['total'] as num,
      delCiclo: r['del_ciclo'] as num,
      atrasos: r['atrasos'] as num,
      adelantos: r['adelantos'] as num,
      sinCuota: r['sin_cuota'] as num,
      pagadoAntes: (r['pagado_antes'] as num?) ?? 0,
      moraVieja: r['mora_vieja'] as num,
    );
  });
});

final cobrosKpisProvider = StreamProvider.autoDispose<CobrosKpis>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  ref.watch(diaNicaraguaProvider); // y al cruzar la medianoche
  ref.watch(dashboardRefreshEpochProvider);
  // Los cortes van INLINE en el SQL (no como parámetros de Dart) para que se
  // re-evalúen en cada emisión: si no, quedan congelados en el arranque.
  return watchResumen(
    '''
    SELECT
      COALESCE(SUM(CASE WHEN fecha_cobro =  $_sqlHoyNi           THEN monto_cordobas ELSE 0 END), 0) AS hoy,
      COALESCE(SUM(CASE WHEN fecha_cobro >= $_sqlInicioSemanaNi  THEN monto_cordobas ELSE 0 END), 0) AS semana,
      COALESCE(SUM(CASE WHEN fecha_cobro >= ($_sqlInicioPeriodoNi) THEN monto_cordobas ELSE 0 END), 0) AS periodo,
      -- CUOTAS distintas, no filas de `pagos`: dos abonos a la misma cuota son
      -- UNA cuota cobrada. Contando pagos, el número coincide con las cuotas
      -- solo mientras nadie abone dos veces — y cuando se despega, nadie se
      -- entera. Es lo que pidió el dueño: "el total y la cantidad de cuotas".
      COUNT(DISTINCT CASE WHEN fecha_cobro =  $_sqlHoyNi           THEN cuota_id END) AS qty_hoy,
      COUNT(DISTINCT CASE WHEN fecha_cobro >= $_sqlInicioSemanaNi  THEN cuota_id END) AS qty_semana,
      COUNT(DISTINCT CASE WHEN fecha_cobro >= ($_sqlInicioPeriodoNi) THEN cuota_id END) AS qty_periodo
      FROM pagos
     WHERE COALESCE(anulado, 0) = 0 AND COALESCE(en_revision, 0) = 0
    ''',
  ).map((rows) {
    final r = rows.first;
    return CobrosKpis(
      hoy: r['hoy'] as num,
      semana: r['semana'] as num,
      periodo: r['periodo'] as num,
      qtyHoy: (r['qty_hoy'] as num).toInt(),
      qtySemana: (r['qty_semana'] as num).toInt(),
      qtyPeriodo: (r['qty_periodo'] as num).toInt(),
    );
  });
});

final operativoKpisProvider = StreamProvider.autoDispose<OperativoKpis>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  ref.watch(dashboardRefreshEpochProvider);
  // Y AL CRUZAR LA MEDIANOCHE. Faltaba: `date('now','-6 hours')` vive dentro
  // del SQL y `db.watch` solo re-ejecuta cuando cambia una tabla, asi que a las
  // 00:01 la tarjeta seguia clasificando con el dia de ayer hasta que alguien
  // cobrara algo. Con un solo bucket dependiente de la fecha casi no se veia;
  // con los tres que muestra la tarjeta fusionada, una cuota que vencio anoche
  // se quedaba en "Al dia" a la vista de todos.
  ref.watch(diaNicaraguaProvider);
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  // El titular "por cobrar"/"vencido" incluye TODA la deuda viva, suspendidos
  // adentro (decisión del dueño, 2026-08-26). Hasta entonces los carvaba con el
  // argumento de que "NO están en rutas" — cierto, pero heredado de cuando
  // suspender y cancelar hacían casi lo mismo. Desde la regla del 2026-08-24
  // suspender significa exactamente *"se fue debiendo y le vamos a seguir
  // cobrando"*: es la deuda MÁS intencionalmente cobrable que hay, y era la
  // única que no entraba al número que el dueño mira primero.
  //
  // `esSusp` sobrevive, pero cambió de sentido: ya no es plata APARTE del
  // titular, es el DESGLOSE de cuánta de esa plata no está en la ruta del día
  // (se cobra desde "Recuperación · fuera de ruta"). Sumarla al titular la
  // duplicaría; leerla como desglose, no.
  //
  // Lo cancelado no necesita filtro: desde `0259`/`0261` un contrato cancelado
  // no tiene deuda viva, y desde `0260` tampoco un cliente desactivado. Aportan
  // cero por construcción. NO agregar un filtro "por si acaso": si alguna vez
  // aparece deuda ahí es un bug, y queremos verla, no esconderla.
  // UNA sola pasada sobre `cuotas`, no seis subconsultas escalares. El cambio
  // no es de performance: es que la PARTICION quede a la vista. Las tres ramas
  // (`futura` / ni una ni otra / `paso_gracia`) se excluyen entre si y cubren
  // todo lo vivo, asi que `al_dia + en_gracia + vencidas = cuotas_pend` por
  // construccion, y lo mismo con los saldos. Escrito como subconsultas sueltas
  // eso habia que creerlo; aca se lee.
  //
  // De aca sale TODA la tarjeta "Estado actual", que desde el 2026-09-01 se
  // comio a "Distribucion de cuotas": la vieja partia el mismo numero y repetia
  // "En mora" en otra tarjeta, sin la plata. Verificado contra produccion antes
  // de fusionar (Mairena): 20.217 + 797 + 2.596 = 23.610 cuotas, y
  // 18.910.031 + 692.255 + 2.018.102 = 21.620.388 C$, al peso.
  //
  // El titular "por cobrar"/"vencido" incluye TODA la deuda viva, suspendidos
  // adentro (decision del dueno, 2026-08-26). Hasta entonces los carvaba con el
  // argumento de que "NO estan en rutas" — cierto, pero heredado de cuando
  // suspender y cancelar hacian casi lo mismo. Desde la regla del 2026-08-24
  // suspender significa exactamente *"se fue debiendo y le vamos a seguir
  // cobrando"*: es la deuda MAS intencionalmente cobrable que hay, y era la
  // unica que no entraba al numero que el dueno mira primero.
  //
  // `susp` sobrevive, pero cambio de sentido: ya no es plata APARTE del
  // titular, es el DESGLOSE de cuanta de esa plata no esta en la ruta del dia
  // (se cobra desde "Recuperacion · fuera de ruta"). Sumarla al titular la
  // duplicaria; leerla como desglose, no.
  //
  // Lo cancelado no necesita filtro: desde `0259`/`0261` un contrato cancelado
  // no tiene deuda viva, y desde `0260` tampoco un cliente desactivado. Aportan
  // cero por construccion. NO agregar un filtro "por si acaso": si alguna vez
  // aparece deuda ahi es un bug, y queremos verla, no esconderla.
  //
  // El `CASE` que envuelve la subconsulta de contratos NO es cosmetico: SQLite
  // corta el CASE, asi que el lookup solo corre para las cuotas vivas. Sin el,
  // la pasada unica saldria a buscar el contrato de las 62.708 filas para
  // usarlo en 23.610.
  final q = estadoActual(diasGracia: diasGracia);
  return watchResumen(
    q.sql,
    parameters: q.parametros,
  ).map((rows) {
    final r = rows.first;
    int i(String k) => (r[k] as num).toInt();
    return OperativoKpis(
      clientes: i('clientes'),
      cuotasPend: i('cuotas_pend'),
      saldo: r['saldo'] as num,
      vencidas: i('vencidas'),
      saldoVencido: r['saldo_vencido'] as num,
      cuotasSuspendidas: i('cuotas_susp'),
      saldoSuspendido: r['saldo_susp'] as num,
      alDia: i('al_dia'),
      saldoAlDia: r['saldo_al_dia'] as num,
      enGracia: i('en_gracia'),
      saldoEnGracia: r['saldo_en_gracia'] as num,
      pagadas: i('pagadas'),
      parciales: i('parciales'),
    );
  });
});

final distribucionCuotasProvider = StreamProvider.autoDispose<DistribucionCuotas>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  ref.watch(dashboardRefreshEpochProvider);
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  return watchResumen(
    '''
    SELECT
      COUNT(CASE WHEN estado = 'pagada' THEN 1 END) AS pagada,
      COUNT(CASE WHEN estado = 'parcial' THEN 1 END) AS parcial,
      COUNT(CASE WHEN estado IN ('pendiente','parcial')
                AND fecha_vencimiento >= date('now', '-6 hours') THEN 1 END) AS al_dia,
      COUNT(CASE WHEN estado IN ('pendiente','parcial')
                AND fecha_vencimiento < date('now', '-6 hours')
                AND date(fecha_vencimiento, '+' || ? || ' days') >= date('now', '-6 hours')
           THEN 1 END) AS en_gracia,
      COUNT(CASE WHEN estado IN ('pendiente','parcial')
                AND date(fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
           THEN 1 END) AS vencida
      FROM cuotas
     WHERE estado != 'anulada'
    ''',
    parameters: [diasGracia, diasGracia],
  ).map((rows) {
    final r = rows.first;
    return DistribucionCuotas(
      alDia: (r['al_dia'] as num).toInt(),
      parcial: (r['parcial'] as num).toInt(),
      enGracia: (r['en_gracia'] as num).toInt(),
      vencida: (r['vencida'] as num).toInt(),
      pagada: (r['pagada'] as num).toInt(),
    );
  });
});

class MontoDesglose {
  const MontoDesglose({required this.monto, required this.cuotas});
  final num monto;
  final int cuotas;
  num get subtotal => monto * cuotas;
}

/// Clave del desglose: identifica UNA fila (cobrador × comunidad) de la card de
/// recuperación, más el toggle de período. Cualquiera de los dos ids puede ser
/// NULL ("Sin cobrador" / "Sin comunidad").
class RecuperacionDetalleKey {
  const RecuperacionDetalleKey({
    required this.cobradorId,
    required this.comunidadId,
    required this.soloPeriodo,
  });
  final String? cobradorId;
  final String? comunidadId;
  final bool soloPeriodo;

  @override
  bool operator ==(Object other) =>
      other is RecuperacionDetalleKey &&
      other.cobradorId == cobradorId &&
      other.comunidadId == comunidadId &&
      other.soloPeriodo == soloPeriodo;

  @override
  int get hashCode => Object.hash(cobradorId, comunidadId, soloPeriodo);
}

/// Desglose por monto de UNA comunidad de la card de recuperación.
///
/// Repite EXACTAMENTE el WHERE de `recuperacionPorComunidadProvider` (mismo
/// saldo canónico, misma gracia, mismos estados/activos, mismo filtro de
/// período) pero acotado a un (cobrador, comunidad) y agrupado por saldo. Así
/// la suma del desglose cierra contra la línea de la comunidad — si difieren,
/// una de las dos está mal. autoDispose: se crea al desplegar una comunidad y
/// se descarta al colapsar (no queda un watch por cada comunidad abierta alguna
/// vez).
final recuperacionDesgloseProvider = StreamProvider.autoDispose
    .family<List<MontoDesglose>, RecuperacionDetalleKey>((ref, key) {
  ref.watch(dbEpochProvider);
  ref.watch(dashboardRefreshEpochProvider);
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  const saldo =
      'max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)';
  // Mismo universo que `recuperacionPorComunidadProvider`: es su drill-down, y
  // si divergen la suma del desglose no cierra contra la fila que lo abrió.
  const cobrable = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') IN ('activo','suspendido')";
  final v = ventanaPeriodoActual();
  final filtroPeriodo = key.soloPeriodo
      ? 'AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?'
      : '';
  // NULL no matchea con `= ?`: los "sin cobrador"/"sin comunidad" van con IS NULL.
  final filtroCob =
      key.cobradorId == null ? 'AND cu.cobrador_id IS NULL' : 'AND cu.cobrador_id = ?';
  final filtroCom = key.comunidadId == null
      ? 'AND cl.comunidad_id IS NULL'
      : 'AND cl.comunidad_id = ?';
  return watchResumen(
    '''
    SELECT $saldo AS monto, COUNT(*) AS cuotas
      FROM cuotas cu
      JOIN clientes cl ON cl.id = cu.cliente_id AND cl.activo = 1
     WHERE cu.estado IN ('pendiente','parcial') AND $cobrable
       AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now','-6 hours')
       $filtroPeriodo $filtroCob $filtroCom
     GROUP BY $saldo
     ORDER BY monto DESC
    ''',
    parameters: [
      diasGracia,
      if (key.soloPeriodo) ...[isoDia(v.inicio), isoDia(v.fin)],
      if (key.cobradorId != null) key.cobradorId,
      if (key.comunidadId != null) key.comunidadId,
    ],
  ).map((rows) => rows
      .map((r) => MontoDesglose(
            monto: r['monto'] as num,
            cuotas: (r['cuotas'] as num).toInt(),
          ))
      .toList());
});

/// Si el tenant tiene habilitado el pago parcial. El overlay 'Con pago parcial'
/// de la distribución se muestra solo si está habilitado O si ya existen
/// parciales (si ninguna aplica, sería siempre 0 → no se muestra).
final pagoParcialHabilitadoProvider = Provider<bool>((ref) =>
    ref.watch(appSettingsProvider.select((s) => s.pagoParcialPermitido)));

/// Época de refresco del dashboard. Se incrementa al pulsar el botón de
/// actualización manual o por el temporizador pasivo de 10 minutos.
final dashboardRefreshEpochProvider = StateProvider<int>((ref) => 0);

/// Marca de tiempo de la última actualización del Resumen.
final dashboardUltimaActualizacionProvider =
    StateProvider<DateTime>((ref) => DateTime.now());

class LimitesCiclos {
  const LimitesCiclos({this.vence, this.primero});
  final DateTime? vence;
  final DateTime? primero;
}

/// Límites hacia adelante y hacia atrás calculados una sola vez y cacheados.
/// Ambas tarjetas (Cobertura y Mora) leen este provider en vez de ejecutar
/// consultas duplicadas en disco.
final limitesCiclosProvider = FutureProvider<LimitesCiclos>((ref) async {
  ref.watch(dbEpochProvider);
  ref.watch(dashboardRefreshEpochProvider);
  final q = ultimoVencimientoConPago();
  final filas = await ps.db.getAll(q.sql, q.parametros);
  if (filas.isEmpty) return const LimitesCiclos();
  final v = filas.first['vence'] as String?;
  final p = filas.first['primero'] as String?;
  return LimitesCiclos(
    vence: v != null ? DateTime.tryParse(v) : null,
    primero: p != null ? DateTime.tryParse(p) : null,
  );
});

