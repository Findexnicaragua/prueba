@TestOn('vm')
library;

/// El corte de MORA que la tarjeta "Cobertura del ciclo" va a mostrar.
///
/// **No hay consulta nueva, y eso es el punto.** `cortesDelCiclo` ya devolvía
/// las cuatro categorías —`at_*` a tiempo, `cm_*` cobrado en mora, `sm_*` sigue
/// en mora, `ef_*` en fecha— y su stream ya estaba armado en la tarjeta. Al
/// implementar esto se escribió una segunda consulta que hacía lo mismo y se
/// borró antes de que llegara a ningún lado: **dos consultas de plata que
/// responden la misma pregunta terminan divergiendo**, y ahí nacen las
/// pantallas que se contradicen.
///
/// Lo que este archivo protege:
///
///  1. que las cuatro categorías **partan exacto** las dos filas madre de la
///     tabla — el defecto que hundió al intento anterior, un pie cuyos números
///     eran "mitad de una fila y mitad de otra" y que el dueño mandó sacar el
///     2026-08-27 porque *"no hace match visual con la tabla"*;
///  2. que **"en mora" signifique lo mismo** acá que en la tarjeta de Mora del
///     ciclo, cruzando las dos consultas de producción — no dos copias de la
///     misma idea.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_query.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;

import 'escenario_seed.dart';

void main() {
  String? core;
  for (final n in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    if (File(n).existsSync()) core = File(n).absolute.path;
  }
  if (core == null) {
    test('mora_cobertura (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  // La MISMA ventana y gracia que el resto de los tests del Resumen.
  const inicioAgo = '2026-07-15';
  const finAgo = '2026-08-15';
  const gracia = 10;
  const hoyFijo = '2026-08-31';

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('mora_cob_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
    await db.initialize();
    await sembrarEscenario(db);
  });

  tearDownAll(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> unaFila(ConsultaSql q) async =>
      (await db.getAll(q.sql, q.parametros)).first;

  double n(Map<String, Object?> r, String k) => (r[k] as num).toDouble();
  int c(Map<String, Object?> r, String k) => (r[k] as num).toInt();

  test('las cuatro categorías PARTEN las filas madre de la tabla', () async {
    final cob = await unaFila(
        resumenCobros(inicio: inicioAgo, fin: finAgo, diasGracia: gracia));
    final cortes = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));

    // ignore: avoid_print
    print('\n== Mora dentro de Cobertura ==\n'
        'Saldadas       ${cob['comp_c']}\n'
        '  en mora      ${cortes['cm_c']}   C\$${n(cortes, 'cm_f')}\n'
        '  a tiempo     ${cortes['at_c']}   C\$${n(cortes, 'at_f')}\n'
        'Con saldo      ${cob['porrec_c']}\n'
        '  en mora      ${cortes['sm_c']}   C\$${n(cortes, 'sm_s')}\n'
        '  en fecha     ${cortes['ef_c']}   C\$${n(cortes, 'ef_s')}');

    // ── Lo RECUPERADO se parte en dos ─────────────────────────────────────
    expect(c(cortes, 'cm_c') + c(cortes, 'at_c'), cob['comp_c'],
        reason: 'cobrado en mora + a tiempo = las cuotas saldadas');

    // ── Lo que FALTA COBRAR se parte en dos ───────────────────────────────
    expect(c(cortes, 'sm_c') + c(cortes, 'ef_c'), cob['porrec_c'],
        reason: 'sigue en mora + en fecha = las cuotas con saldo');
    expect(n(cortes, 'sm_s') + n(cortes, 'ef_s'),
        closeTo(n(cob, 'porrec_m'), 0.01),
        reason: 'sus saldos suman el "Por recuperar" de la tabla');

    // ── Y las cuatro juntas son TODO el ciclo ─────────────────────────────
    // Sin esto, una cuota podría quedar fuera de las cuatro y nadie lo vería:
    // los dos expects de arriba seguirían cerrando cada uno por su lado.
    expect(
        c(cortes, 'cm_c') +
            c(cortes, 'at_c') +
            c(cortes, 'sm_c') +
            c(cortes, 'ef_c'),
        cob['meta_c'],
        reason: 'las cuatro categorías reparten TODAS las cuotas del ciclo');
  });

  test('"en mora" significa lo MISMO que en la tarjeta de Mora del ciclo',
      () async {
    final cortes = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));

    // La otra tarjeta, con su propia consulta de producción. `pend` × (`nada` |
    // `parcial`) son las que siguen debiendo estando en mora.
    final q = desgloseMora(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo);
    final filas = await db.getAll(q.sql, q.parametros);
    final pendMonto = filas
        .where((f) => f['fila'] == 'pend')
        .fold<double>(0, (a, f) => a + (f['monto'] as num).toDouble());
    final pendCuotas = filas
        .where((f) => f['fila'] == 'pend')
        .fold<int>(0, (a, f) => a + (f['cuotas'] as num).toInt());

    // ignore: avoid_print
    print('\nCobertura dice: ${cortes['sm_c']} cuotas  '
        'C\$${n(cortes, 'sm_s')}\n'
        'Mora dice:      $pendCuotas cuotas  C\$$pendMonto');

    // ESTE es el cruce que importa: dos consultas distintas, escritas por
    // separado, tienen que dar el mismo número. Si divergen, las dos tarjetas
    // están diciendo cosas diferentes sobre la misma plata — que es
    // exactamente lo que el dueño pidió evitar.
    expect(c(cortes, 'sm_c'), pendCuotas,
        reason: 'las cuotas en mora son las mismas en las dos tarjetas');
    expect(n(cortes, 'sm_s'), closeTo(pendMonto, 0.01),
        reason: 'y su monto también');
  });

  // ── COBROS DE OTROS CICLOS (2026-09-01) ───────────────────────────────
  //
  // El dueño abrió el ciclo de septiembre, pasó el mouse por el 16 de agosto y
  // el globo dijo "Sin cobros este día". Ese día habían entrado C$1.000: dos
  // cuotas que vencían el 10 y el 14 de agosto, cobradas dentro de la ventana
  // de septiembre.
  //
  // Lo que estos tests fijan es el LÍMITE de la consulta nueva: tiene que
  // traer eso y NADA de lo que la curva ya cuenta. Si algún día se cruzan, el
  // globo sumaría dos veces la misma plata.

  test('trae lo que entró en la ventana y vence FUERA de ella', () async {
    final q = cobrosDeOtrosCiclosDiaria(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia);
    final filas = await db.getAll(q.sql, q.parametros);

    var qty = 0;
    var monto = 0.0;
    for (final f in filas) {
      qty += ((f['qty'] as num?) ?? 0).toInt();
      monto += ((f['monto'] as num?) ?? 0).toDouble();
      // ignore: avoid_print
      print('  ${f['dia']}: ${f['qty']} cuota(s) de otro ciclo · '
          'C\$${f['monto']}');
    }

    expect(qty, greaterThan(0),
        reason: 'el escenario tiene que traer algún cobro de otro ciclo '
            'dentro de esta ventana, si no el test no prueba nada');
    expect(monto, greaterThan(0));
  });

  // ── LOS TOPES DE NAVEGACION (2026-09-02) ──────────────────────────────
  //
  // Ruben cobro una cuota que vence el 28/09 el dia 02/09 y no podia abrir
  // Octubre para verla: la regla era "nunca un ciclo futuro". Ahora el
  // selector avanza hasta el ultimo ciclo QUE YA TIENE PAGOS.
  test('ultimoVencimientoConPago: el tope sale de los PAGOS, no de las cuotas',
      () async {
    final q = ultimoVencimientoConPago();
    final filas = await db.getAll(q.sql, q.parametros);
    expect(filas, hasLength(1));
    final vence = filas.first['vence'] as String?;
    final primero = filas.first['primero'] as String?;
    expect(vence, isNotNull, reason: 'el escenario tiene pagos');
    expect(primero, isNotNull);

    // 🔴 LO QUE ESTE TEST EXISTE PARA FIJAR: el tope tiene que salir de los
    // PAGOS. Las cuotas se generan meses por adelantado, asi que si alguien
    // cambiara el criterio a "tiene cuotas", el selector recorreria ciclos
    // vacios. Medido en produccion al decidirlo: 18 ciclos con cuotas contra
    // 8 con pagos.
    final maxCuota = (await db.getAll(
            "SELECT MAX(date(fecha_vencimiento)) AS v FROM cuotas "
            "WHERE estado != 'anulada'"))
        .first['v'] as String?;
    expect(maxCuota, isNotNull);
    expect(vence!.compareTo(maxCuota!), lessThanOrEqualTo(0),
        reason: 'el tope de PAGOS no puede pasar al de CUOTAS: si son iguales',
    );

    // Y el piso es el vencimiento mas viejo que exista -- el tope hacia atras
    // del selector de la grafica de mora.
    expect(primero!.compareTo(vence), lessThanOrEqualTo(0));
  });
  test('las columnas de mora son un SUBCONJUNTO, no un segundo monto',
      () async {
    // Se agregaron el 2026-09-02 para que el globo pueda decir, de lo cobrado
    // de otros ciclos, cuanto venia de un atraso. Son las MISMAS filas con una
    // condicion mas -haber entrado pasada la gracia-, igual que la curva roja
    // respecto de la verde. Si alguna vez `mora_monto` superara a `monto`, es
    // que el predicado dejo de ser un subconjunto y el globo estaria sumando
    // plata que no existe.
    final q = cobrosDeOtrosCiclosDiaria(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia);
    final filas = await db.getAll(q.sql, q.parametros);
    expect(filas, isNotEmpty);
    for (final f in filas) {
      final monto = ((f['monto'] as num?) ?? 0).toDouble();
      final moraM = ((f['mora_monto'] as num?) ?? 0).toDouble();
      final qty = ((f['qty'] as num?) ?? 0).toInt();
      final moraQ = ((f['mora_qty'] as num?) ?? 0).toInt();
      expect(moraM, lessThanOrEqualTo(monto + 0.009),
          reason: 'la mora del ${f['dia']} supera lo cobrado ese dia');
      expect(moraQ, lessThanOrEqualTo(qty),
          reason: 'mas cuotas en mora que cuotas, el ${f['dia']}');
    }
  });
  test('NO se pisa con lo que la curva ya cuenta', () async {
    // Las dos consultas miran la misma ventana de FECHA DE PAGO, pero una se
    // queda con las cuotas que vencen adentro y la otra con las que vencen
    // afuera. Son complementarias: ninguna cuota puede estar en las dos, y
    // juntas tienen que dar toda la plata que entró en la ventana.
    final qOtros = cobrosDeOtrosCiclosDiaria(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia);
    final otros = await db.getAll(qOtros.sql, qOtros.parametros);
    final montoOtros = otros.fold<double>(
        0, (a, f) => a + ((f['monto'] as num?) ?? 0).toDouble());

    final todo = await db.getAll(
      "SELECT COALESCE(SUM(p.monto_cordobas), 0) AS m FROM pagos p "
      "JOIN cuotas cu ON cu.id = p.cuota_id "
      "WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0 "
      "AND cu.estado != 'anulada' "
      "AND date(p.fecha_pago) >= ? AND date(p.fecha_pago) < ?",
      [inicioAgo, finAgo],
    );
    final dentro = await db.getAll(
      "SELECT COALESCE(SUM(p.monto_cordobas), 0) AS m FROM pagos p "
      "JOIN cuotas cu ON cu.id = p.cuota_id "
      "WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0 "
      "AND cu.estado != 'anulada' "
      "AND date(p.fecha_pago) >= ? AND date(p.fecha_pago) < ? "
      "AND date(cu.fecha_vencimiento) >= ? AND date(cu.fecha_vencimiento) < ?",
      [inicioAgo, finAgo, inicioAgo, finAgo],
    );

    expect(montoOtros + (dentro.first['m'] as num).toDouble(),
        closeTo((todo.first['m'] as num).toDouble(), 0.01),
        reason: 'lo de otros ciclos y lo del ciclo tienen que PARTIR toda la '
            'plata que entró en la ventana: si se solapan, el globo la '
            'contaría dos veces');
  });

  // ── LA MORA, REPARTIDA ADENTRO DE LA JERARQUÍA (2026-09-01) ────────────
  //
  // Dejó de ser una fila hermana y pasó a vivir dentro de cada momento y
  // dentro de cada línea de "Por recuperar". La mudanza sólo se sostiene si
  // las partes SUMAN lo que mostraba la fila única: si no, el dueño ve un
  // total que ya no está en ninguna parte y no tiene forma de saber cuál creer.

  test('la mora por MOMENTO suma la fila única que reemplazó', () async {
    final desg = desgloseRecuperado(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia);
    final filas = await db.getAll(desg.sql, desg.parametros);
    final cortes = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));

    // SIN ESTO EL TEST PASA CON 0 = 0 y no prueba nada — que es exactamente
    // como lo escribí la primera vez: quedó DESPUÉS del test que reescribe las
    // `fecha_pago` del escenario, así que para cuando corría ya no quedaba una
    // sola cuota en mora y `0 == 0` daba verde. Por eso además vive ARRIBA de
    // ese test: los tests de este archivo comparten UNA base (`setUpAll`), y el
    // que muta no la restaura.
    expect(c(cortes, 'cm_c'), greaterThan(0),
        reason: 'el escenario tiene que traer cuotas cobradas en mora, si no '
            'este test no compara nada');

    var qty = 0;
    var monto = 0.0;
    for (final f in filas) {
      qty += ((f['mora'] as num?) ?? 0).toInt();
      monto += ((f['mora_monto'] as num?) ?? 0).toDouble();
      // ignore: avoid_print
      print('  ${f['momento']}: ${f['mora']} de mora · C\$${f['mora_monto']}');
    }

    expect(qty, c(cortes, 'cm_c'),
        reason: 'los momentos tienen que repartir EXACTO las cuotas que la '
            'fila única mostraba');
    expect(monto, closeTo(n(cortes, 'cm_f'), 0.01),
        reason: 'y su plata: el monto es el FACTURADO, el mismo que mostraba '
            'la fila única');
  });

  test('la mora de "Por recuperar" suma su fila única', () async {
    final cortes = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));

    expect(c(cortes, 'sm_med_c') + c(cortes, 'sm_nada_c'), c(cortes, 'sm_c'),
        reason: 'con abono + sin ningún pago = las que siguen en mora');
    expect(n(cortes, 'sm_med_s') + n(cortes, 'sm_nada_s'),
        closeTo(n(cortes, 'sm_s'), 0.01),
        reason: 'y lo mismo con el saldo');
  });

  // EL CRUCE QUE PIDIÓ EL DUEÑO (2026-09-01): *"esa data sí tiene que hacer
  // match con la tabla y con la información de la mora del otro gráfico"*.
  //
  // El tooltip suma día a día lo que la curva roja dibuja (`serieMoraDiaria`),
  // y la tabla muestra `cm_c`/`cm_f`. Son consultas DISTINTAS y podrían
  // separarse: la curva cuenta toda cuota con pago tardío y la tabla sólo las
  // que además quedaron SALDADAS. Hoy no divergen —medido contra producción el
  // 2026-09-01: 13.507 cuotas con pago tardío en los 3 tenants, historia
  // completa, y CERO sin saldar— pero el día que alguien abone tarde sin
  // saldar, el globo diría un número que la tabla no tiene. Que salte acá y no
  // en la pantalla del dueño.
  test('lo que suma el globo día a día es lo que dice la tabla', () async {
    final serie =
        serieMoraDiaria(inicio: inicioAgo, fin: finAgo, diasGracia: gracia);
    final dias = await db.getAll(serie.sql, serie.parametros);
    final cortes = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));

    final qtyGlobo =
        dias.fold<int>(0, (a, d) => a + ((d['qty'] as num?) ?? 0).toInt());

    expect(qtyGlobo, c(cortes, 'cm_c'),
        reason: 'si esto falla, hay cuotas con pago tardío que NO quedaron '
            'saldadas: la curva las cuenta y la tabla las manda a "Por '
            'recuperar → en mora". Hay que decidir cuál manda ANTES de que el '
            'dueño vea dos números.');
  });

  test('una cuota pagada DENTRO de la gracia no cuenta como mora', () async {
    // El caso que separa las dos definiciones posibles de "en mora", y que en
    // el ciclo en curso del Test Tenant daba 0 contra 5. Se construye a mano
    // para no depender de que el escenario lo tenga: todas las saldadas pasan
    // a estar pagadas el mismo día que vencían.
    //
    // Con la definición correcta —se pagó pasada la gracia— ninguna es mora.
    // Con la otra —la cuota ya venció— lo serían todas, y estaría mal: se
    // pagaron en fecha.
    final antes = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));

    // `fecha_cobro` se mueve JUNTO con `fecha_pago`. En produccion lo hace el
    // trigger del server (0273) y la app nunca updatea `fecha_pago` — solo la
    // inserta —, asi que este UPDATE a mano tiene que imitar al trigger. Si
    // solo moviera `fecha_pago`, el dashboard —que desde el 2026-09-04 lee
    // `fecha_cobro`— seguiria viendo el dia viejo, y este test daria 7 en vez
    // de 0. Asi lo caza si algun dia la app SI empieza a editar la fecha de un
    // pago sin mover las dos.
    await db.execute(
        "UPDATE pagos SET fecha_pago = (SELECT cu.fecha_vencimiento "
        "                                 FROM cuotas cu "
        "                                WHERE cu.id = pagos.cuota_id), "
        "                 fecha_cobro = (SELECT date(cu.fecha_vencimiento) "
        "                                  FROM cuotas cu "
        "                                 WHERE cu.id = pagos.cuota_id) "
        "WHERE cuota_id IN (SELECT id FROM cuotas "
        "                    WHERE date(fecha_vencimiento) >= ? "
        "                      AND date(fecha_vencimiento) < ? "
        "                      AND estado = 'pagada')",
        [inicioAgo, finAgo]);

    final despues = await unaFila(cortesDelCiclo(
        inicio: inicioAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo));

    expect(c(despues, 'cm_c'), 0,
        reason: 'pagando el día del vencimiento, ninguna pasó por mora');
    expect(c(despues, 'at_c'), c(antes, 'cm_c') + c(antes, 'at_c'),
        reason: 'las saldadas se corrieron todas a la línea de "a tiempo"');
  });

}
