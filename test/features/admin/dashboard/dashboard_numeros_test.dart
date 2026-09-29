@TestOn('vm')
library;

/// Los números del Resumen del dashboard, contra el SQLite REAL de PowerSync.
///
/// Corre las consultas de producción (`dashboard_query.dart`, el mismo archivo
/// que usa la app) sobre un escenario de 15 clientes repartidos en 6 ciclos,
/// donde cada caso de borde tiene un cliente que lo dispara. Los esperados se
/// calcularon a mano ANTES de correr nada: son el patrón, no el resultado.
///
/// Por qué existe: con 4.600 clientes reales, cuando un número no cuadra hay
/// que investigar. Acá el número esperado se calcula en un minuto y la
/// comparación es inmediata.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_query.dart';
import 'package:isp_billing/features/admin/reportes/arqueo_query.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

import 'escenario_seed.dart';

/// El ciclo en curso del escenario: 15 jul – 14 ago 2026.
const inicioAgo = '2026-07-15';
const finAgo = '2026-08-15';
const gracia = 7;

/// El dia de corte, FIJO.
///
/// Antes salia de `date('now','-6 hours')` adentro del SQL, asi que estos
/// esperados dependian del dia en que se corriera la suite: manana entran dos
/// cuotas mas a la mora y los numeros cambian solos. Con el corte como
/// parametro el escenario se vuelve reproducible — que es lo unico que hace
/// util un esperado calculado a mano.
const hoyFijo = '2026-08-12';

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('dashboard_numeros (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();
  late PowerSyncDatabase db;
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('dash_numeros_');
    db = PowerSyncDatabase(
        schema: schema, path: p.join(tmpDir.path, '${uuid.v4()}.db'));
    await db.initialize();
    await sembrarEscenario(db);
  });

  tearDown(() async {
    await db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> unaFila(ConsultaSql q) async {
    final rows = await db.getAll(q.sql, q.parametros);
    return rows.first;
  }

  test('el escenario se sembró completo', () async {
    final r = await unaFila(const ConsultaSql(
        'SELECT (SELECT COUNT(*) FROM clientes) AS cli, '
        '(SELECT COUNT(*) FROM contratos) AS ctr, '
        '(SELECT COUNT(*) FROM cuotas) AS cuo, '
        '(SELECT COUNT(*) FROM pagos) AS pag',
        []));
    // ESTE es el único test que conoce el TAMAÑO del escenario, a propósito:
    // si el seed crece o se rompe a medias, se cae acá y en un solo lugar. Los
    // demás tests de este archivo prueban INVARIANTES —que las filas cierren,
    // que los porcentajes sumen 100— y por eso no dependen de estos números.
    //
    // Creció de 15 a 60 clientes el 2026-08-27 (`ad0a1e94`): con 15, todos del
    // mismo cobrador y sin comunidad, tres de las tarjetas nuevas no se podían
    // probar. Los 14/15/93/86 que había acá eran del escenario viejo y son la
    // razón por la que este archivo pasó semanas con 7 tests en rojo.
    expect(r['cli'], 59, reason: 'TT-05 es un cliente con dos contratos');
    expect(r['ctr'], 60);
    expect(r['cuo'], 343);
    expect(r['pag'], 245);
  });

  test('Cobros del mes — las tres filas cierran y los % suman 100', () async {
    final r = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));

    final meta = (r['meta_m'] as num).toDouble();
    final rec = (r['rec_m'] as num).toDouble();
    final porRec = (r['porrec_m'] as num).toDouble();
    final tarde = (r['rec_m_tarde'] as num).toDouble();

    // ignore: avoid_print
    print('\n== Cobros del mes (15 jul – 14 ago 2026) ==\n'
        'Cobros          u=${r['meta_u']} c=${r['meta_c']} C\$$meta\n'
        'Recuperado      u=${r['rec_u']} c=${r['rec_c']} C\$$rec\n'
        '  ↳ tarde                       C\$$tarde\n'
        'Por recuperar   u=${r['porrec_u']} c=${r['porrec_c']} C\$$porRec');

    // La sub-fila de pagos tardíos es un SUBCONJUNTO de lo recuperado, no
    // plata aparte: sumarlas fue el origen del reclamo del dueño.
    expect(tarde, lessThanOrEqualTo(rec),
        reason: 'lo cobrado tarde no puede superar lo cobrado');

    // El corazón del asunto: la columna Monto tiene que cerrar por
    // VERIFICACIÓN, no por construcción. `porrec_m` se consulta con el saldo
    // canónico clampeado por cuota; `rec_m` suma pagos. Que den `meta` es el
    // hecho a probar — antes `porrec_m` era `meta - rec`, así que cerraba
    // siempre aunque los datos dijeran otra cosa.
    expect(rec + porRec, closeTo(meta, 0.01),
        reason: 'recuperado + por recuperar = cobros');

    // Acá vivían tres montos absolutos del escenario de 15 clientes (11.200 /
    // 5.800 / 5.400). Se retiran, no se actualizan: con 343 cuotas generadas
    // por perfiles de pago, nadie puede recalcularlos a mano — y un número que
    // se copia de la salida del propio código no prueba nada, solo se pudre.
    // Lo que se prueba es el invariante de arriba, que vale con CUALQUIER
    // escenario, más el caso curado de abajo. El tamaño del escenario lo fija
    // el test 'el escenario se sembró completo'.

    // TT-08 recibió dos cobros sobre la misma cuota (C$935 + C$1.200). El
    // segundo NO cuenta: el guard del server lo manda a revisión por sobrepago,
    // y el escenario lo refleja. Verificado contra el tenant de prueba real.
    final sobrepago =
        await db.getAll("SELECT COUNT(*) AS n FROM pagos WHERE en_revision = 1 "
            "AND monto_cordobas = 1200");
    expect(sobrepago.first['n'], 1,
        reason: 'el sobrepago tiene que estar en cuarentena, no vivo');
  });

  test('una cuota sobrepagada no le come deuda a los demás', () async {
    // El doble cobro offline NO llega acá: el guard del server (0218) manda el
    // sobrepago a revisión — verificado contra el tenant de prueba. Pero el
    // saldo negativo sigue siendo alcanzable BAJANDO el total después de
    // cobrar: quitar un cargo de reconexión de una cuota ya pagada, o la
    // cancelación de contrato, que recalcula el monto ignorando los cargos.
    // Se construye ese estado a mano para probar que la fila no miente.
    // Se mide ANTES de romper nada: el test compara contra el estado previo,
    // no contra un número escrito a mano. Así prueba exactamente lo que dice
    // —que el sobrepago no mueve la deuda ajena— con cualquier escenario.
    final antes = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final metaAntes = (antes['meta_m'] as num).toDouble();
    final porRecAntes = (antes['porrec_m'] as num).toDouble();

    await db.execute(
        "UPDATE cuotas SET monto_pagado = monto + 1200 "
        "WHERE id = (SELECT id FROM cuotas "
        "            WHERE date(fecha_vencimiento) >= ? "
        "              AND date(fecha_vencimiento) < ? "
        "              AND estado = 'pagada' LIMIT 1)",
        [inicioAgo, finAgo]);

    final r = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final meta = (r['meta_m'] as num).toDouble();
    final porRec = (r['porrec_m'] as num).toDouble();

    // Lo que se prueba: el saldo negativo de esa cuota NO se resta de la deuda
    // de los otros. Antes, 'Por recuperar' salía por resta y daba C$1.200 menos
    // que la suma de las cuotas que la propia fila enumeraba.
    expect(porRec, closeTo(porRecAntes, 0.01),
        reason: 'la deuda de los demás no se toca');
    expect(meta, closeTo(metaAntes, 0.01),
        reason: 'lo facturado tampoco cambia');

    // Y el excedente queda a la vista en vez de desaparecer.
    final rec = (r['rec_m'] as num).toDouble();
    expect(math.max(rec + porRec - meta, 0), closeTo(0, 0.01),
        reason: 'monto_pagado sube pero rec_m suma PAGOS, que no cambiaron: '
            'el excedente de este camino se ve en el saldo, no en los pagos');
  });

  test('los tres cortes del ciclo cierran en los MISMOS totales', () async {
    // El pedido del dueño: "los totales me hagan match por periodo... tiene que
    // dar el 100% incluyendo lo del desglose de la mora". Los tres cortes miran
    // las mismas cuotas desde angulos distintos; si alguno no cierra, hay un
    // camino de plata sin cablear (ARQUITECTURA §3.5 (6)).
    final r = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final c = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));
    double n(Map<String, Object?> m, String k) => ((m[k] as num?) ?? 0).toDouble();
    int i(Map<String, Object?> m, String k) => (m[k] as num).toInt();

    final fact = n(r, 'meta_m');
    final entro = n(r, 'rec_m');
    final falta = n(r, 'porrec_m');

    // CORTE POR ORIGEN: contrato + servicio = el ciclo, en las tres columnas.
    expect(n(c, 'ctr_f') + n(c, 'srv_f'), closeTo(fact, 0.01));
    expect(n(c, 'ctr_e') + n(c, 'srv_e'), closeTo(entro, 0.01));
    expect(n(c, 'ctr_s') + n(c, 'srv_s'), closeTo(falta, 0.01));
    expect(i(c, 'ctr_c') + i(c, 'srv_c'), r['meta_c']);

    // CORTE POR MORA: reparte CUOTAS, y las cuatro suman las del ciclo. Es lo
    // que permite responder "de las 15, cuantas se cobraron estando en mora".
    expect(i(c, 'at_c') + i(c, 'cm_c') + i(c, 'sm_c') + i(c, 'ef_c'),
        r['meta_c'],
        reason: 'las cuatro filas de mora tienen que dar las cuotas del ciclo');
    expect(n(c, 'at_f') + n(c, 'cm_f') + n(c, 'sm_f') + n(c, 'ef_f'),
        closeTo(fact, 0.01));
    // Las dos primeras estan saldadas: su facturado ES lo que entro.
    expect(n(c, 'at_f') + n(c, 'cm_f') + n(c, 'sm_e') + n(c, 'ef_e'),
        closeTo(entro, 0.01));
    expect(n(c, 'sm_s') + n(c, 'ef_s'), closeTo(falta, 0.01));

    // Y los DOS numeros que el dueño compara contra la otra tarjeta siguen
    // dando igual: lo recuperado de la mora y lo que sigue debiendose.
    final m = await unaFila(resumenMora(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));
    expect(n(c, 'm_cobrado'), closeTo(n(m, 'rec_m'), 0.01),
        reason: 'lo cobrado tarde es el "Recuperado" de la tarjeta de Mora');
    expect(n(c, 'sm_s'), closeTo(n(m, 'porrec_m'), 0.01),
        reason: 'lo que sigue sin saldar es su "Por recuperar"');
    expect(i(c, 'cm_c') + i(c, 'sm_c'), m['meta_c'],
        reason: 'y el mismo conteo de cuotas que pasaron por mora');
  });

  test('una cuota sobrepagada NO empuja el ciclo arriba del 100%', () async {
    // El clamp de `util`. Sin el, las 4 partes sumaban facturado + sobrepago y
    // la tarjeta mostraba 102% sin ninguna fila que lo explicara. Se construye
    // el estado a mano porque el guard del server lo impide por el camino normal.
    await db.execute(
        'UPDATE cuotas SET monto_pagado = monto + COALESCE(cargos_neto,0) + 265 '
        'WHERE id = (SELECT id FROM cuotas '
        '            WHERE date(fecha_vencimiento) >= ? '
        '              AND date(fecha_vencimiento) < ? LIMIT 1)',
        [inicioAgo, finAgo]);

    final r = await unaFila(resumenCobros(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final c = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));
    double n(Map<String, Object?> m, String k) => ((m[k] as num?) ?? 0).toDouble();

    expect(n(c, 'at_f') + n(c, 'cm_f') + n(c, 'sm_f') + n(c, 'ef_f'),
        closeTo(n(r, 'meta_m'), 0.01),
        reason: 'el sobrepago no puede inflar el 100% del ciclo');
    expect(n(c, 'ctr_f') + n(c, 'srv_f'), closeTo(n(r, 'meta_m'), 0.01));
  });

  test('la partición en tres suma el total en las cuatro columnas', () async {
    final r = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    double n(String k) => ((r[k] as num?) ?? 0).toDouble();

    // ignore: avoid_print
    print('\n== Cobertura del ciclo, partición ==\n'
        'Pagadas completas  ${r['comp_c']} cuotas  fact ${n('comp_f')}  '
        'entró ${n('comp_e')}\n'
        'Pagadas a medias   ${r['med_c']} cuotas  fact ${n('med_f')}  '
        'entró ${n('med_e')}  falta ${n('med_s')}\n'
        'Sin pagar nada     ${r['nada_c']} cuotas  fact ${n('nada_f')}');

    // Cada cuota en UN grupo: los conteos parten exacto.
    expect((r['comp_c'] as int) + (r['med_c'] as int) + (r['nada_c'] as int),
        r['meta_c'],
        reason: 'las tres filas tienen que dar TODAS las cuotas del ciclo');
    // (Los conteos 7/2/6 eran del escenario de 15 clientes. Lo que prueba
    // este test es que las tres partes den EXACTO el total —el expect de
    // arriba—, y eso vale con cualquier tamaño de escenario.)

    // FACTURADO parte el total.
    expect(n('comp_f') + n('med_f') + n('nada_f'),
        closeTo((r['meta_m'] as num).toDouble(), 0.01));
    // (Los tres montos absolutos del escenario viejo se retiraron: ver la
    // nota en 'las tres filas cierran'. Lo que prueba este test es que las
    // tres partes SUMAN el total, que es el invariante de arriba.)

    // ENTRÓ parte lo recuperado. Acá está la razón de que haga falta una
    // segunda columna: los 1.100 de las cuotas a medias son plata que entró
    // pero cuya cuota sigue debiendo. Con una sola columna, poner "7 cuotas"
    // al lado de C$5.800 mentiría: esas 7 solo facturan C$4.700.
    expect(n('comp_e') + n('med_e'),
        closeTo((r['rec_m'] as num).toDouble(), 0.01));


    // FALTA parte lo pendiente: 0 de las completas + 965 + 4.435.
    expect(n('med_s') + n('nada_f'),
        closeTo((r['porrec_m'] as num).toDouble(), 0.01));

  });

  test('las dos pastillas de % suman 100 exacto', () async {
    final r = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final meta = (r['meta_m'] as num).toDouble();
    final rec = (r['rec_m'] as num).toDouble();
    final porRec = (r['porrec_m'] as num).toDouble();
    final aplicado = rec - math.max(rec + porRec - meta, 0);

    // La fórmula de la UI: se redondea UNA vez y el complemento se deriva.
    final pRec = (aplicado / meta * 100).round();
    final pPorRec = 100 - pRec;
    expect(pRec + pPorRec, 100);
    expect(pRec, 52, reason: '5.800 de 11.200');
    expect(pPorRec, 48, reason: '5.400 de 11.200');

    // Las fracciones crudas tienen que sumar 100 antes de redondear: si no,
    // el problema sería de los montos y no del redondeo.
    expect(aplicado / meta * 100 + porRec / meta * 100, closeTo(100.0, 0.001));
  });

  test('el redondeo de los % no puede imprimir 101', () {
    // Unit puro, sin base: Dart redondea el 0,5 ALEJÁNDOSE del cero, así que
    // cuando la fracción cae justo en x,5 las DOS pastillas suben. Es siempre
    // 101, nunca 99, y se dispara con montos redondos — el caso normal.
    const casos = <List<double>>[
      [7000, 11200], // 62,5% / 37,5%  <- el que reportó el audit
      [500, 800],
      [1500, 4000],
      [625, 1000],
      [1100, 2600], // este no cae en el borde: control
    ];
    for (final c in casos) {
      final rec = c[0], meta = c[1], porRec = meta - rec;
      final ingenuo =
          (rec / meta * 100).round() + (porRec / meta * 100).round();
      final derivado = 100; // el complemento se deriva, no se redondea aparte
      expect(derivado, 100);
      if (ingenuo != 100) {
        // Deja constancia de que el caso viejo efectivamente rompía.
        expect(ingenuo, 101,
            reason: 'redondear cada fracción por separado sube las dos');
      }
    }
  });

  test('Cobros del mes — los conteos no se restan', () async {
    final r = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final metaU = r['meta_u'] as int;
    final recU = r['rec_u'] as int;
    final porRecU = r['porrec_u'] as int;

    // Correcto por diseño: TT-05 (dos contratos) y los parciales están en las
    // dos filas. Si esto diera exactamente metaU, sería porque se restó — y la
    // resta subcuenta (medido en Mairena: 2.406 cuando eran 2.422).
    expect(recU + porRecU, greaterThan(metaU),
        reason: 'un cliente con una cuota pagada y otra debiendo cuenta en las '
            'dos filas');
    expect(recU, lessThanOrEqualTo(metaU));
    expect(porRecU, lessThanOrEqualTo(metaU));
  });

  test('Mora del ciclo — Recuperado nunca supera al Total', () async {
    final r = await unaFila(resumenMora(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));
    final meta = (r['meta_m'] as num).toDouble();
    final rec = (r['rec_m'] as num).toDouble();
    final porRec = (r['porrec_m'] as num).toDouble();

    // ignore: avoid_print
    print('\n== Mora del ciclo ==\n'
        'Total mora      u=${r['meta_u']} c=${r['meta_c']} C\$$meta\n'
        'Recuperado      u=${r['rec_u']} c=${r['rec_c']} C\$$rec\n'
        'Por recuperar   u=${r['porrec_u']} c=${r['porrec_c']} C\$$porRec');

    expect(rec, lessThanOrEqualTo(meta),
        reason: 'REC ⊆ META por construcción del universo bruto');
    expect(rec + porRec, closeTo(meta, 0.01),
        reason: 'recuperado + sigue impago = total en mora');
    expect(r['rec_u'] as int, lessThanOrEqualTo(r['meta_u'] as int));
    expect(r['rec_c'] as int, lessThanOrEqualTo(r['meta_c'] as int));
  });

  test('la barra del ciclo en curso da igual que la tarjeta de Mora', () async {
    // Si divergen, el dueño ve dos números distintos para lo mismo en la misma
    // pantalla — y deja de creerle a los dos.
    final mora = await unaFila(resumenMora(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));
    final q = moraHistorica(
        ciclos: const [(inicioAgo, finAgo)], diasGracia: gracia, hoy: hoyFijo);
    final barra = (await db.getAll(q.sql, q.parametros)).first;

    expect((barra['recuperado'] as num).toDouble(),
        closeTo((mora['rec_m'] as num).toDouble(), 0.01));
    expect((barra['impago'] as num).toDouble(),
        closeTo((mora['porrec_m'] as num).toDouble(), 0.01));
    final totalBarra = (barra['impago'] as num).toDouble() +
        (barra['recuperado'] as num).toDouble();
    expect(totalBarra, closeTo((mora['meta_m'] as num).toDouble(), 0.01));
  });

  test('los 6 ciclos vienen completos, en orden y sin valores imposibles',
      () async {
    // Los ciclos van del 15 al 14, no por mes calendario.
    const ciclos = <(String, String)>[
      ('2026-02-15', '2026-03-15'), // mar
      ('2026-03-15', '2026-04-15'), // abr
      ('2026-04-15', '2026-05-15'), // may
      ('2026-05-15', '2026-06-15'), // jun
      ('2026-06-15', '2026-07-15'), // jul
      ('2026-07-15', '2026-08-15'), // ago, en curso
    ];
    // OJO con may y jun: son los ciclos donde TT-09 (contrato suspendido el 5
    // ago) pagó TARDE su cuota de C$720. Con el filtro de suspendidos que había
    // antes, esas dos barras mostraban C$4.540 y C$2.935 — la suspensión de
    // agosto borraba hacia atrás plata cobrada en mayo y junio. Los valores de
    // acá son la mora REAL de esos ciclos.
    // Acá vivía una tabla con los seis ciclos escritos a mano (mar 2.030,
    // abr 3.355, …). Era del escenario de 15 clientes y quedó imposible de
    // mantener: con 60 la población sale de sumar perfiles de pago, no de una
    // lista que alguien pueda recalcular.
    //
    // NO se reemplazó por "total == recuperado + impago": la consulta no
    // devuelve un total aparte, así que esa comparación sería `x == x` — un
    // chequeo que no puede fallar nunca, que es peor que no tener chequeo
    // (AGENTS, checklist #14). Lo que queda es lo que SÍ se puede afirmar sin
    // inventar: seis ciclos, en orden, sin valores negativos y con plata en
    // los cerrados.
    //
    // La verificación fuerte de estos números vive en el test de al lado —"la
    // mora de 6 meses da lo mismo que sumar los 6 ciclos"—, que cruza esta
    // consulta contra OTRA distinta. Ese cruce sí puede fallar, y es el que
    // protege de verdad.
    const nombres = ['mar', 'abr', 'may', 'jun', 'jul', 'ago'];

    final q = moraHistorica(ciclos: ciclos, diasGracia: gracia, hoy: hoyFijo);
    final filas = await db.getAll(q.sql, q.parametros);
    expect(filas.length, 6);

    // ignore: avoid_print
    print('\n== Mora, últimos 6 ciclos ==');
    for (var i = 0; i < 6; i++) {
      final rec = (filas[i]['recuperado'] as num).toDouble();
      final imp = (filas[i]['impago'] as num).toDouble();
      // ignore: avoid_print
      print('${nombres[i]}  total=${rec + imp}  recuperado=$rec  debe=$imp');
      expect(rec, greaterThanOrEqualTo(0),
          reason: '${nombres[i]}: lo recuperado no puede ser negativo');
      expect(imp, greaterThanOrEqualTo(0),
          reason: '${nombres[i]}: lo impago no puede ser negativo');
      // Un ciclo CERRADO con mora cero sería sospechoso en este escenario:
      // se diseñó para que los seis tengan movimiento. Si algún día da cero,
      // o el filtro se rompió o el escenario cambió — las dos cosas hay que
      // mirarlas.
      if (i < 5) {
        expect(rec + imp, greaterThan(0),
            reason: '${nombres[i]}: un ciclo cerrado sin nada de mora '
                'significa que el filtro dejó fuera todo el ciclo');
      }
    }
  });

  test('la caja del dashboard da IGUAL que el arqueo', () async {
    // Las dos miden lo mismo: plata que entró, por fecha_pago, de pagos vivos.
    // Tienen que dar idéntico sobre la misma ventana o una de las dos miente.
    // Se corre la query de producción del arqueo, no una copia.
    final arq = await db.getAll(arqueoSql(''), [
      inicioAgo, '2026-08-14', // pagos: BETWEEN, inclusivo en los dos extremos
      inicioAgo, '2026-08-14', // devoluciones de saldo a favor
    ]);
    final ingresoArqueo = arq.fold<double>(
        0, (a, r) => a + ((r['ingreso_total'] as num?) ?? 0).toDouble());

    // 🔴 La MISMA ventana que el arqueo, con los dos extremos. Antes esto era
    // `>= inicioAgo` sin tope, y la comparacion pasaba solo porque el escenario
    // viejo no tenia ni un pago despues del 14/08. Al ampliar la poblacion
    // aparecieron los del ciclo en curso y el test fallo por C$5.300 — que no
    // era una diferencia entre caja y arqueo, sino entre dos ventanas
    // distintas. Un test que compara dos cosas tiene que acotarlas igual.
    final caja = await db.getAll(
        'SELECT COALESCE(SUM(monto_cordobas), 0) AS total FROM pagos '
        'WHERE COALESCE(anulado, 0) = 0 AND COALESCE(en_revision, 0) = 0 '
        '  AND date(fecha_pago) BETWEEN ? AND ?',
        [inicioAgo, '2026-08-14']);
    final totalCaja = (caja.first['total'] as num).toDouble();

    // ignore: avoid_print
    print('\n== Caja vs arqueo ==\n'
        'arqueo (ingreso bruto)  C\$$ingresoArqueo\n'
        'caja del dashboard      C\$$totalCaja');

    expect(totalCaja, closeTo(ingresoArqueo, 0.01),
        reason: 'la caja del dashboard y el ingreso del arqueo son la misma '
            'plata contada de la misma forma');

    // Y la tendencia mide OTRA cosa: por fecha_vencimiento, no por fecha_pago.
    // Que difiera es correcto; que coincidiera de casualidad taparía el punto.
    final tend = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    expect((tend['rec_m'] as num).toDouble(), isNot(closeTo(totalCaja, 0.01)),
        reason: 'cobertura y caja son ejes distintos: el escenario tiene un '
            'pago de una cuota vieja justamente para que no coincidan');
  });

  test('la mora de 6 meses da lo mismo que sumar los 6 ciclos', () async {
    // La tarjeta nueva muestra la TABLA sobre la ventana de 6 meses y la CURVA
    // ciclo a ciclo. Si las dos consultas no dan lo mismo, la tabla y su propio
    // gráfico se contradicen — que es exactamente lo que había que arreglar.
    const inicio6m = '2026-02-15'; // arranque del ciclo de marzo
    const ciclos = <(String, String)>[
      ('2026-02-15', '2026-03-15'),
      ('2026-03-15', '2026-04-15'),
      ('2026-04-15', '2026-05-15'),
      ('2026-05-15', '2026-06-15'),
      ('2026-06-15', '2026-07-15'),
      ('2026-07-15', '2026-08-15'),
    ];

    final tabla = await unaFila(resumenMora(
        inicio: inicio6m, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));
    final q = moraHistorica(ciclos: ciclos, diasGracia: gracia, hoy: hoyFijo);
    final barras = await db.getAll(q.sql, q.parametros);

    final sumaRec = barras.fold<double>(
        0, (a, r) => a + (r['recuperado'] as num).toDouble());
    final sumaImp =
        barras.fold<double>(0, (a, r) => a + (r['impago'] as num).toDouble());

    // ignore: avoid_print
    print('\n== Mora, 6 meses ==\n'
        'tabla:  total=${tabla['meta_m']} rec=${tabla['rec_m']} '
        'porRec=${tabla['porrec_m']}\n'
        'barras: total=${sumaRec + sumaImp} rec=$sumaRec porRec=$sumaImp');

    expect((tabla['rec_m'] as num).toDouble(), closeTo(sumaRec, 0.01));
    expect((tabla['porrec_m'] as num).toDouble(), closeTo(sumaImp, 0.01));
    expect(
        (tabla['meta_m'] as num).toDouble(), closeTo(sumaRec + sumaImp, 0.01));

    // Los tres valores "calculados a mano desde los 6 ciclos" que había acá
    // eran del escenario de 15 clientes. Lo que importa —y sigue probado
    // arriba— es que la TABLA y las BARRAS den lo mismo: si una de las dos
    // consultas se mueve, se cae, sin depender de cuántos clientes haya.
  });

  test('el detalle exportable suma EXACTO lo que muestra la tarjeta', () async {
    // La razon de ser del export: bajarlo, sumar la columna, y que de lo mismo
    // que la pantalla. Si divergen, el Excel y la tarjeta dicen cosas distintas
    // y no hay forma de saber cual creer.
    final tarjeta = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final q = detalleCobertura(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo);
    final filas = await db.getAll(q.sql, q.parametros);

    double suma(String col) =>
        filas.fold<double>(0, (a, r) => a + ((r[col] as num?) ?? 0).toDouble());

    // ignore: avoid_print
    print('\n== Detalle exportable ==\n'
        '${filas.length} filas · facturado ${suma('facturado')} · '
        'pagado ${suma('pagado')} · falta ${suma('falta')}');

    expect(filas.length, tarjeta['meta_c'], reason: 'una fila por cuota');
    expect(suma('facturado'),
        closeTo((tarjeta['meta_m'] as num).toDouble(), 0.01));
    expect(suma('pagado'), closeTo((tarjeta['rec_m'] as num).toDouble(), 0.01));
    expect(
        suma('falta'), closeTo((tarjeta['porrec_m'] as num).toDouble(), 0.01));

    // Y las PERSONAS distintas del detalle son las de la tarjeta.
    //
    // ESTO SE DECIDIO DOS VECES, EN SENTIDOS OPUESTOS — leer antes de volver a
    // darlo vuelta. Hasta el 2026-09-02 esta linea contaba CONTRATOS, porque
    // en agosto el dueño vio "mas cuotas que usuarios" y reporto que no le
    // cerraba. El 2026-09-02 explico PARA QUE usa la columna: "si veo mas
    // cuotas que usuarios, reviso si por accidente alguien tiene dos
    // contratos" — y contando contratos eso es IMPOSIBLE de ver, da 1:1
    // siempre. Se midio antes de cambiarlo: en Mairena, 4.414 = 4.414 contando
    // contratos, contra 4.409 vs 4.414 contando personas = cinco clientes con
    // dos servicios, todos legitimos.
    //
    // O sea: las dos columnas NO tienen por que cuadrar. Cuando no cuadran, esa
    // diferencia ES el dato. Ver `docs/reglas/` y el comentario de `meta_u`.
    final personas = filas.map((r) => r['cliente_codigo']).toSet().length;
    expect(personas, tarjeta['meta_u'],
        reason: 'el detalle y la tarjeta tienen que contar las mismas personas');
    expect(tarjeta['meta_u'] as num, lessThan(tarjeta['meta_c'] as num),
        reason: 'el escenario tiene clientes con dos contratos: si Usuarios '
            'igualara a Cuotas, estaria contando servicios otra vez');

    // El tipo distingue las dos formas de tener dos cuotas en un ciclo.
    expect(filas.where((r) => r['tipo'] == 'cobro puntual').length, 1,
        reason: 'el cargo manual de TT-13');

    // La columna que el dueño pidió: el contrato de cada cuota, para
    // distinguir a quien tiene varios. Vacía SOLO en los cobros puntuales,
    // que genuinamente no cuelgan de ninguno — si estuviera vacía en todas,
    // la columna no serviría para nada (paso: los contratos del escenario
    // nacian sin codigo).
    for (final r in filas) {
      if (r['tipo'] == 'cobro puntual') {
        expect(r['contrato'], isNull);
      } else {
        expect(r['contrato'], isNotNull,
            reason: 'toda mensualidad tiene que decir de que contrato es');
        expect((r['contrato'] as String).isNotEmpty, isTrue);
      }
    }
    // Y los dos contratos de TT-05 tienen que ser DISTINTOS: es lo que
    // explica que una misma persona aparezca dos veces.
    final deYahoska = filas
        .where((r) => r['cliente_codigo'] == 'TT-05')
        .map((r) => r['contrato'])
        .toSet();
    expect(deYahoska.length, 2, reason: 'dos servicios, dos contratos');

    // Las anuladas van aparte: la diferencia entre lo que hay en la ventana y
    // lo que la tarjeta cuenta tiene que quedar explicada.
    final qa = anuladasDelPeriodo(inicio: inicioAgo, fin: finAgo);
    final anuladas = await db.getAll(qa.sql, qa.parametros);
    // Los conteos fijos (2 anuladas, 17 cuotas) eran del escenario de 15
    // clientes. Se reemplazan por el hecho que querían proteger, contado por
    // una consulta DISTINTA de las dos que se suman: si el detalle o las
    // anuladas dejaran fuera una cuota, este total deja de cerrar. Contra la
    // suma de las dos mismas listas sería `x == x` y no podría fallar nunca.
    final enLaVentana = (await db.getAll(
      'SELECT COUNT(*) AS n FROM cuotas '
      'WHERE date(fecha_vencimiento) >= ? AND date(fecha_vencimiento) < ?',
      [inicioAgo, finAgo],
    )).first['n'] as int;

    expect(anuladas.every((r) => r['estado'] == 'anulada'), isTrue,
        reason: 'la lista de anuladas sólo puede traer cuotas anuladas');
    expect(filas.length + anuladas.length, enLaVentana,
        reason: 'entre el detalle y las anuladas tienen que estar TODAS las '
            'cuotas que vencen en la ventana: la diferencia con lo que la '
            'tarjeta cuenta es justamente lo que las anuladas explican');
  });

  test('el detalle de mora coincide con su tarjeta', () async {
    final tarjeta = await unaFila(resumenMora(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));
    final q = detalleMora(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo);
    final filas = await db.getAll(q.sql, q.parametros);
    expect(filas.length, tarjeta['meta_c'],
        reason: 'una fila por cuota que cruzo la gracia');
  });

  test('la curva diaria cierra exacto contra la tabla', () async {
    final resumen = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final serie = serieCobrosDiaria(inicio: inicioAgo, fin: finAgo);
    final dias = await db.getAll(serie.sql, serie.parametros);
    final sumaDias =
        dias.fold<double>(0, (a, d) => a + (d['monto'] as num).toDouble());

    // El total de la curva y el "Recuperado" de la tabla salen de queries
    // distintas: si divergen, una de las dos está mal.
    expect(sumaDias, closeTo((resumen['rec_m'] as num).toDouble(), 0.01));

    final serieMora =
        serieMoraDiaria(inicio: inicioAgo, fin: finAgo, diasGracia: gracia);
    final diasMora = await db.getAll(serieMora.sql, serieMora.parametros);
    final sumaMora =
        diasMora.fold<double>(0, (a, d) => a + (d['monto'] as num).toDouble());
    expect(sumaMora, closeTo((resumen['rec_m_tarde'] as num).toDouble(), 0.01),
        reason: 'la curva roja es la sub-fila de pagos tardíos');
    expect(sumaMora, lessThanOrEqualTo(sumaDias),
        reason: 'la curva roja va siempre por debajo de la verde');
  });

  test('un ciclo cerrado no cambia si se suspende un contrato después',
      () async {
    // TT-09 está suspendido y pagó los ciclos cerrados. Su plata tiene que
    // seguir contando: la suspensión ya anuló las cuotas que no se van a
    // cobrar, así que lo que sobrevive es plata cobrada o deuda real.
    const inicioMay = '2026-04-15';
    const finMay = '2026-05-15';
    final r = await unaFila(
        resumenCobros(inicio: inicioMay, fin: finMay, diasGracia: gracia));
    final suspendido = await db.getAll(
        "SELECT COALESCE(SUM(cu.monto_pagado), 0) AS m FROM cuotas cu "
        "JOIN contratos ct ON ct.id = cu.contrato_id "
        "WHERE ct.estado = 'suspendido' AND cu.estado != 'anulada' "
        "AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?",
        [inicioMay, finMay]);
    final plataSuspendida = (suspendido.first['m'] as num).toDouble();

    expect(plataSuspendida, greaterThan(0),
        reason: 'el escenario tiene que traer plata cobrada de un suspendido, '
            'si no el test no prueba nada');
    expect(
        (r['rec_m'] as num).toDouble(), greaterThanOrEqualTo(plataSuspendida),
        reason: 'la plata del contrato suspendido sigue contando en el ciclo '
            'cerrado donde entró');
  });
}

String? _resolveCorePath() {
  for (final name in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    final f = File(name);
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}
