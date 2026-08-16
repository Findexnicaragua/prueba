import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import '../repositories/settings_repo.dart';
import '../utils/periodo_dashboard.dart';
import 'db_epoch_provider.dart';

/// Providers de los KPIs del dashboard admin (R10).
///
/// Antes los KPIs vivían en `StreamBuilder` directos dentro del dashboard
/// screen, lo cual disparaba una re-subscripción al stream en cada rebuild
/// del padre (porque `ps.db.watch(...)` retorna una nueva instancia de
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
  });
  final int clientes;
  // cuotasPend/saldo/vencidas/saldoVencido EXCLUYEN contratos suspendidos
  // (salieron de cobros/mapa → no están "por cobrar"). La deuda suspendida se
  // reporta aparte para mantener visible que sigue contando en contabilidad.
  final int cuotasPend;
  final num saldo;
  final int vencidas;
  final num saldoVencido;
  final int cuotasSuspendidas;
  final num saldoSuspendido;

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
          other.saldoSuspendido == saldoSuspendido;

  @override
  int get hashCode => Object.hash(clientes, cuotasPend, saldo, vencidas,
      saldoVencido, cuotasSuspendidas, saldoSuspendido);
}

class TopCobrador {
  const TopCobrador({
    required this.id,
    required this.nombre,
    required this.total,
    required this.qty,
  });
  final String id;
  final String nombre;
  final num total;
  final int qty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopCobrador &&
          other.id == id &&
          other.nombre == nombre &&
          other.total == total &&
          other.qty == qty;

  @override
  int get hashCode => Object.hash(id, nombre, total, qty);
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

final cobrosRangoCustomProvider =
    StreamProvider.family<CobrosRangoCustom, (String, String)>((ref, rango) {
  ref.watch(dbEpochProvider);
  final (desde, hasta) = rango;
  return ps.db.watch(
    '''
    SELECT
      COALESCE(SUM(monto_cordobas), 0) AS total,
      COUNT(*) AS qty
      FROM pagos
     WHERE COALESCE(anulado, 0) = 0 AND COALESCE(en_revision, 0) = 0
       AND date(fecha_pago) >= ?
       AND date(fecha_pago) <= ?
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

final desgloseCajaProvider =
    StreamProvider.family<DesgloseCaja, int>((ref, diasGracia) {
  ref.watch(dbEpochProvider);
  // Los bordes del ciclo se calculan en el SQL (no en Dart) para que no queden
  // congelados en el arranque de la app — mismo motivo que en cobrosKpisProvider.
  return ps.db.watch(
    '''
    WITH w AS (SELECT ($_sqlInicioPeriodoNi) AS ini)
    SELECT
      COALESCE(SUM(p.monto_cordobas), 0) AS total,
      COALESCE(SUM(CASE WHEN date(cu.fecha_vencimiento) >= (SELECT ini FROM w)
                         AND date(cu.fecha_vencimiento) <  date((SELECT ini FROM w), '+1 month')
                        THEN p.monto_cordobas ELSE 0 END), 0) AS del_ciclo,
      COALESCE(SUM(CASE WHEN date(cu.fecha_vencimiento) <  (SELECT ini FROM w)
                        THEN p.monto_cordobas ELSE 0 END), 0) AS atrasos,
      COALESCE(SUM(CASE WHEN date(cu.fecha_vencimiento) >= date((SELECT ini FROM w), '+1 month')
                        THEN p.monto_cordobas ELSE 0 END), 0) AS adelantos,
      COALESCE(SUM(CASE WHEN cu.id IS NULL
                        THEN p.monto_cordobas ELSE 0 END), 0) AS sin_cuota,
      COALESCE(SUM(CASE WHEN date(cu.fecha_vencimiento) < (SELECT ini FROM w)
                         AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                             < date(p.fecha_pago)
                        THEN p.monto_cordobas ELSE 0 END), 0) AS mora_vieja
      FROM pagos p
 LEFT JOIN cuotas cu ON cu.id = p.cuota_id
     WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
       AND date(p.fecha_pago) >= (SELECT ini FROM w)
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
      moraVieja: r['mora_vieja'] as num,
    );
  });
});

final cobrosKpisProvider = StreamProvider<CobrosKpis>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  // Los cortes van INLINE en el SQL (no como parámetros de Dart) para que se
  // re-evalúen en cada emisión: si no, quedan congelados en el arranque.
  return ps.db.watch(
    '''
    SELECT
      COALESCE(SUM(CASE WHEN date(fecha_pago) =  $_sqlHoyNi           THEN monto_cordobas ELSE 0 END), 0) AS hoy,
      COALESCE(SUM(CASE WHEN date(fecha_pago) >= $_sqlInicioSemanaNi  THEN monto_cordobas ELSE 0 END), 0) AS semana,
      COALESCE(SUM(CASE WHEN date(fecha_pago) >= ($_sqlInicioPeriodoNi) THEN monto_cordobas ELSE 0 END), 0) AS periodo,
      COUNT(CASE WHEN date(fecha_pago) =  $_sqlHoyNi           THEN 1 END) AS qty_hoy,
      COUNT(CASE WHEN date(fecha_pago) >= $_sqlInicioSemanaNi  THEN 1 END) AS qty_semana,
      COUNT(CASE WHEN date(fecha_pago) >= ($_sqlInicioPeriodoNi) THEN 1 END) AS qty_periodo
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

final operativoKpisProvider = StreamProvider<OperativoKpis>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  // El titular "por cobrar"/"vencido" excluye contratos suspendidos (NO están
  // en rutas). Se carva SOLO 'suspendido' (todo lo demás —activo, y cualquier
  // otro estado con deuda— sigue en el titular), así titular + suspendido =
  // total y no se esconde deuda. La porción suspendida se reporta aparte.
  const noSusp = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') != 'suspendido'";
  const esSusp = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') = 'suspendido'";
  return ps.db.watch(
    '''
    SELECT
      (SELECT COUNT(*) FROM clientes WHERE activo = 1) AS clientes,
      (SELECT COUNT(*) FROM cuotas cu
         WHERE cu.estado IN ('pendiente','parcial') AND $noSusp) AS cuotas_pend,
      (SELECT COALESCE(SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)), 0)
         FROM cuotas cu WHERE cu.estado IN ('pendiente','parcial') AND $noSusp) AS saldo,
      (SELECT COUNT(*) FROM cuotas cu
         WHERE cu.estado IN ('pendiente','parcial') AND $noSusp
           AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
      ) AS vencidas,
      (SELECT COALESCE(SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)), 0)
         FROM cuotas cu
         WHERE cu.estado IN ('pendiente','parcial') AND $noSusp
           AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
      ) AS saldo_vencido,
      (SELECT COUNT(*) FROM cuotas cu
         WHERE cu.estado IN ('pendiente','parcial') AND $esSusp) AS cuotas_susp,
      (SELECT COALESCE(SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)), 0)
         FROM cuotas cu WHERE cu.estado IN ('pendiente','parcial') AND $esSusp) AS saldo_susp
    ''',
    parameters: [diasGracia, diasGracia],
  ).map((rows) {
    final r = rows.first;
    return OperativoKpis(
      clientes: (r['clientes'] as num).toInt(),
      cuotasPend: (r['cuotas_pend'] as num).toInt(),
      saldo: r['saldo'] as num,
      vencidas: (r['vencidas'] as num).toInt(),
      saldoVencido: r['saldo_vencido'] as num,
      cuotasSuspendidas: (r['cuotas_susp'] as num).toInt(),
      saldoSuspendido: r['saldo_susp'] as num,
    );
  });
});

final topCobradoresProvider = StreamProvider<List<TopCobrador>>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  // Corte INLINE (no parámetro de Dart): vive en la misma pantalla que el KPI
  // del período, y si uno se descongela y el otro no, a partir de medianoche
  // muestran ventanas distintas. Los paréntesis del CASE son obligatorios acá
  // porque va adentro del ON de un LEFT JOIN.
  return ps.db.watch(
    '''
    SELECT co.id, co.nombre,
           COALESCE(SUM(p.monto_cordobas), 0) AS total,
           COUNT(p.id) AS qty
      FROM cobradores co
 LEFT JOIN pagos p ON p.cobrador_id = co.id
                  AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
                  AND date(p.fecha_pago) >= ($_sqlInicioPeriodoNi)
     -- SIN filtro de rol: en la práctica cobra sobre todo la OFICINA
     -- (admin / admin_cobranza). Filtrando por rol='cobrador' el ranking
     -- mostraba el 21% de la plata en un tenant y el 12% en otro, y no
     -- cerraba con el arqueo, que nunca filtró por rol (§3.5-4b: la
     -- reportería agrupa por `pagos.cobrador_id`, quien HAYA cobrado).
     WHERE co.activo = 1
     GROUP BY co.id, co.nombre
     ORDER BY total DESC
     LIMIT 5
    ''',
  ).map((rows) => rows
      .map((r) => TopCobrador(
            id: r['id'] as String,
            nombre: (r['nombre'] as String?) ?? '',
            total: r['total'] as num,
            qty: (r['qty'] as num).toInt(),
          ))
      .toList());
});

final topCobradoresHoyProvider = StreamProvider<List<TopCobrador>>((ref) {
  ref.watch(dbEpochProvider);
  return ps.db.watch(
    '''
    SELECT co.id, co.nombre,
           COALESCE(SUM(p.monto_cordobas), 0) AS total,
           COUNT(p.id) AS qty
      FROM cobradores co
 LEFT JOIN pagos p ON p.cobrador_id = co.id
                  AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
                  AND date(p.fecha_pago) = $_sqlHoyNi
     -- SIN filtro de rol: en la práctica cobra sobre todo la OFICINA
     -- (admin / admin_cobranza). Filtrando por rol='cobrador' el ranking
     -- mostraba el 21% de la plata en un tenant y el 12% en otro, y no
     -- cerraba con el arqueo, que nunca filtró por rol (§3.5-4b: la
     -- reportería agrupa por `pagos.cobrador_id`, quien HAYA cobrado).
     WHERE co.activo = 1
     GROUP BY co.id, co.nombre
     ORDER BY total DESC
     LIMIT 5
    ''',
  ).map((rows) => rows
      .map((r) => TopCobrador(
            id: r['id'] as String,
            nombre: (r['nombre'] as String?) ?? '',
            total: r['total'] as num,
            qty: (r['qty'] as num).toInt(),
          ))
      .toList());
});

final distribucionCuotasProvider = StreamProvider<DistribucionCuotas>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  return ps.db.watch(
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

// ── Proyección de cobros por cobrador (sección nueva — dashboard.proyeccion_visible).
// Lo que cada cobrador ASIGNADO (organizativo, cu.cobrador_id) debería cobrar:
// cuotas vivas que vencen HOY, y aparte las que vencen dentro de los próximos
// `dias_cuotas_visibles` días (el toggle "incluir próximas" de la UI las suma).
// Saldo canónico (#10). Excluye no-activos (susp/cancelado), igual que Cobros. cobrador_id
// NULL = "Sin cobrador" (admin-managed). Cobrador ASIGNADO, no real (invariante
// #11): es proyección de quién DEBE salir a cobrar, no histórico cobrado.
class ProyeccionCobrador {
  const ProyeccionCobrador({
    required this.cobradorId,
    required this.nombre,
    required this.montoHoy,
    required this.cuotasHoy,
    required this.montoProximas,
    required this.cuotasProximas,
  });
  final String? cobradorId;
  final String nombre;
  final num montoHoy;
  final int cuotasHoy;
  final num montoProximas;
  final int cuotasProximas;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProyeccionCobrador &&
          other.cobradorId == cobradorId &&
          other.nombre == nombre &&
          other.montoHoy == montoHoy &&
          other.cuotasHoy == cuotasHoy &&
          other.montoProximas == montoProximas &&
          other.cuotasProximas == cuotasProximas;

  @override
  int get hashCode => Object.hash(
      cobradorId, nombre, montoHoy, cuotasHoy, montoProximas, cuotasProximas);
}

final proyeccionCobrosProvider =
    StreamProvider<List<ProyeccionCobrador>>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final diasProx =
      ref.watch(appSettingsProvider.select((s) => s.diasCuotasVisibles));
  const saldo =
      'max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)';
  // = 'activo' EXCLUYE también cancelados, igual que la lista de Cobros y el mapa
  // (estas secciones son "ruta": lo que el cobrador sale a cobrar; la deuda
  // residual de un cancelado se cobra desde el detalle del contrato — #10).
  const soloActivos = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') = 'activo'";
  return ps.db.watch(
    '''
    SELECT cu.cobrador_id AS cob_id, co.nombre AS cob_nombre,
      COALESCE(SUM(CASE WHEN date(cu.fecha_vencimiento) = date('now','-6 hours')
                        THEN $saldo ELSE 0 END), 0) AS monto_hoy,
      COUNT(CASE WHEN date(cu.fecha_vencimiento) = date('now','-6 hours')
                 THEN 1 END) AS cuotas_hoy,
      COALESCE(SUM(CASE WHEN date(cu.fecha_vencimiento) > date('now','-6 hours')
                        AND date(cu.fecha_vencimiento) <= date('now','-6 hours','+' || ? || ' days')
                        THEN $saldo ELSE 0 END), 0) AS monto_prox,
      COUNT(CASE WHEN date(cu.fecha_vencimiento) > date('now','-6 hours')
                 AND date(cu.fecha_vencimiento) <= date('now','-6 hours','+' || ? || ' days')
                 THEN 1 END) AS cuotas_prox
      FROM cuotas cu
      JOIN clientes c ON c.id = cu.cliente_id AND c.activo = 1
 LEFT JOIN cobradores co ON co.id = cu.cobrador_id
     WHERE cu.estado IN ('pendiente','parcial') AND $soloActivos
     GROUP BY cu.cobrador_id, co.nombre
    ''',
    parameters: [diasProx, diasProx],
  ).map((rows) => rows
          .map((r) => ProyeccionCobrador(
                cobradorId: r['cob_id'] as String?,
                nombre: (r['cob_nombre'] as String?) ?? '',
                montoHoy: r['monto_hoy'] as num,
                cuotasHoy: (r['cuotas_hoy'] as num).toInt(),
                montoProximas: r['monto_prox'] as num,
                cuotasProximas: (r['cuotas_prox'] as num).toInt(),
              ))
          // Solo cobradores con algo para cobrar (hoy o próximas).
          .where((p) => p.cuotasHoy > 0 || p.cuotasProximas > 0)
          .toList()
        ..sort((a, b) => (b.montoHoy + b.montoProximas)
            .compareTo(a.montoHoy + a.montoProximas)));
});

// ── Recuperación por cobrador y comunidad (sección nueva — dashboard.recuperacion_visible).
// Mora A RECUPERAR (pendiente): cuotas vivas vencidas pasada la gracia, por
// cobrador ASIGNADO × comunidad del cliente. Saldo canónico. Excluye no-activos
// (susp/cancelado), igual que Cobros. cobrador/comunidad NULL → "Sin cobrador"/"Sin comunidad".
class RecuperacionFila {
  const RecuperacionFila({
    required this.cobradorId,
    required this.cobrador,
    required this.comunidadId,
    required this.comunidad,
    required this.porRecuperar,
    required this.cuotas,
  });
  final String? cobradorId;
  final String cobrador;
  final String? comunidadId;
  final String comunidad;
  final num porRecuperar;
  final int cuotas;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecuperacionFila &&
          other.cobradorId == cobradorId &&
          other.cobrador == cobrador &&
          other.comunidadId == comunidadId &&
          other.comunidad == comunidad &&
          other.porRecuperar == porRecuperar &&
          other.cuotas == cuotas;

  @override
  int get hashCode => Object.hash(
      cobradorId, cobrador, comunidadId, comunidad, porRecuperar, cuotas);
}

/// Mora a recuperar por cobrador × comunidad.
///
/// [soloPeriodo] `false` (el DEFAULT de la card) devuelve la mora ACUMULADA
/// completa, sin límite de fecha: es la deuda que el equipo sale a cobrar.
///
/// `true` acota a las cuotas cuyo vencimiento cae dentro del período en curso.
/// Sirve para "cuánta mora generó este ciclo", NO como vista operativa: cruza
/// vencer-en-el-período con haber-pasado-la-gracia, dos condiciones que casi no
/// se solapan mientras el período está abierto (da 0 los primeros ~15+gracia
/// días). Ver el comentario de `_RecuperacionCardState._soloPeriodo`.
///
/// autoDispose: son dos instancias family (una por valor del toggle) con un
/// `GROUP BY` pesado sobre todas las cuotas cada una; sin esto quedan vivas
/// hasta el fin de la sesión y se re-ejecutan ante cada cambio de pagos/cuotas.
final recuperacionPorComunidadProvider = StreamProvider.autoDispose
    .family<List<RecuperacionFila>, bool>((ref, soloPeriodo) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  const saldo =
      'max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)';
  // = 'activo' EXCLUYE también cancelados, igual que la lista de Cobros y el mapa
  // (estas secciones son "ruta": lo que el cobrador sale a cobrar; la deuda
  // residual de un cancelado se cobra desde el detalle del contrato — #10).
  const soloActivos = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') = 'activo'";
  final v = ventanaPeriodoActual();
  final filtroPeriodo = soloPeriodo
      ? 'AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?'
      : '';
  return ps.db.watch(
    '''
    SELECT cu.cobrador_id AS cob_id, co.nombre AS cob_nombre,
           cl.comunidad_id AS com_id, cm.nombre AS com_nombre,
           COALESCE(SUM($saldo), 0) AS por_recuperar,
           COUNT(*) AS cuotas
      FROM cuotas cu
      JOIN clientes cl ON cl.id = cu.cliente_id AND cl.activo = 1
 LEFT JOIN cobradores co ON co.id = cu.cobrador_id
 LEFT JOIN comunidades cm ON cm.id = cl.comunidad_id
     WHERE cu.estado IN ('pendiente','parcial') AND $soloActivos
       AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now','-6 hours')
       $filtroPeriodo
     GROUP BY cu.cobrador_id, co.nombre, cl.comunidad_id, cm.nombre
     ORDER BY por_recuperar DESC
    ''',
    parameters: [
      diasGracia,
      if (soloPeriodo) ...[isoDia(v.inicio), isoDia(v.fin)],
    ],
  ).map((rows) => rows
      .map((r) => RecuperacionFila(
            cobradorId: r['cob_id'] as String?,
            cobrador: (r['cob_nombre'] as String?) ?? '',
            comunidadId: r['com_id'] as String?,
            comunidad: (r['com_nombre'] as String?) ?? '',
            porRecuperar: r['por_recuperar'] as num,
            cuotas: (r['cuotas'] as num).toInt(),
          ))
      .toList());
});

/// Una línea del desglose por MONTO de una comunidad: cuántas cuotas tienen ese
/// saldo exacto. `monto × cuotas` = el subtotal de esa línea; la suma de todos
/// los subtotales tiene que dar el total de la comunidad (así el usuario cierra
/// los números). Los saldos con pago PARCIAL caen en su propio valor (no 513 ni
/// 1282 redondos) — es correcto, suma igual.
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
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  const saldo =
      'max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)';
  const soloActivos = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') = 'activo'";
  final v = ventanaPeriodoActual();
  final filtroPeriodo = key.soloPeriodo
      ? 'AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?'
      : '';
  // NULL no matchea con `= ?`: los "sin cobrador"/"sin comunidad" van con IS NULL.
  final filtroCob =
      key.cobradorId == null ? 'AND cu.cobrador_id IS NULL' : 'AND cu.cobrador_id = ?';
  final filtroCom = key.comunidadId == null
      ? 'AND cl.comunidad_id IS NULL'
      : 'AND cl.comunidad_id = ?';
  return ps.db.watch(
    '''
    SELECT $saldo AS monto, COUNT(*) AS cuotas
      FROM cuotas cu
      JOIN clientes cl ON cl.id = cu.cliente_id AND cl.activo = 1
     WHERE cu.estado IN ('pendiente','parcial') AND $soloActivos
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
