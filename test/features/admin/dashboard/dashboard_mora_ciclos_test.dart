@TestOn('vm')
library;

/// Las consultas de la tarjeta "Mora del ciclo" contra el SQLite REAL.
///
/// Verifica la IDENTIDAD que sostiene la tarjeta entera: en cada ciclo,
/// `recuperado + por recuperar = total en mora`, y cada desglose suma
/// exactamente la fila de la que cuelga. Si eso se rompe, el hover de una
/// barra y la fila de la tabla dirían cosas distintas — que es justo lo que el
/// dueño pidió que no pudiera pasar (2026-08-28).
///
/// Los esperados NO están escritos a mano: son relaciones entre las cifras que
/// devuelve la consulta. Un escenario nuevo no los invalida.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_query.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

import 'escenario_seed.dart';

/// La ventana de 6 ciclos que termina en el ciclo en curso del escenario.
const inicio6 = '2026-02-15';
const fin6 = '2026-08-15';
const gracia = 7;
const hoyFijo = '2026-08-12';

String? _resolveCorePath() {
  for (final n in ['powersync_x64.dll', 'libpowersync.so', 'libpowersync.dylib']) {
    final f = File(p.join(Directory.current.path, n));
    if (f.existsSync()) return f.path;
  }
  return null;
}

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('mora_ciclos (saltado: falta powersync-sqlite-core)', () {}, skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();
  late PowerSyncDatabase db;
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('mora_ciclos_');
    db = PowerSyncDatabase(
        schema: schema, path: p.join(tmpDir.path, '${uuid.v4()}.db'));
    await db.initialize();
    await sembrarEscenario(db);
  });

  tearDown(() async {
    await db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  double n(Map<String, Object?> r, String k) => ((r[k] as num?) ?? 0).toDouble();

  test('serieMoraPorCiclo — cada ciclo cierra: rec + pend = mora', () async {
    final q = serieMoraPorCiclo(
        inicio: inicio6, fin: fin6, diasGracia: gracia, hoy: hoyFijo);
    final filas = await db.getAll(q.sql, q.parametros);

    expect(filas, isNotEmpty, reason: 'el escenario tiene mora en la ventana');

    // ignore: avoid_print
    print('\n== Mora por ciclo (6 ciclos hasta 14 ago 2026) ==');
    for (final r in filas) {
      final mora = n(r, 'mora_m');
      final rec = n(r, 'rec_m');
      final pend = n(r, 'pend_m');
      // ignore: avoid_print
      print('${r['ciclo']}  mora ${r['mora_c']}/$mora  '
          'rec ${r['rec_c']}/$rec  pend ${r['pend_c']}/$pend');

      // LA identidad de la tarjeta. Sin ella la barra apilada no cierra: el
      // verde y el rojo tienen que sumar exactamente la altura total.
      expect(rec + pend, closeTo(mora, 0.01),
          reason: 'ciclo ${r['ciclo']}: $rec + $pend != $mora');

      // Una cuota parcial cobrada tarde cae en las DOS filas de conteo (tiene
      // plata recuperada Y sigue debiendo), así que los conteos suman >= el
      // total, nunca menos.
      expect(n(r, 'rec_c') + n(r, 'pend_c'),
          greaterThanOrEqualTo(n(r, 'mora_c')),
          reason: 'ciclo ${r['ciclo']}: los conteos no pueden faltar');

      expect(mora, greaterThan(0),
          reason: 'un ciclo sin mora no debería devolver fila');
    }
  });

  test('serieMoraPorCiclo — un ciclo suelto da lo mismo que resumenMora',
      () async {
    // El puente entre las dos consultas: la barra de un ciclo y la tabla de
    // ese ciclo salen de consultas distintas, así que tienen que coincidir o
    // el hover mostraría un número y la tabla otro.
    const iniAgo = '2026-07-15';
    const finAgo = '2026-08-15';

    final serie = serieMoraPorCiclo(
        inicio: iniAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo);
    final fila = (await db.getAll(serie.sql, serie.parametros)).single;

    final res = resumenMora(
        inicio: iniAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo);
    final r = (await db.getAll(res.sql, res.parametros)).first;

    expect(n(fila, 'mora_m'), closeTo(n(r, 'meta_m'), 0.01));
    expect(n(fila, 'rec_m'), closeTo(n(r, 'rec_m'), 0.01));
    expect(n(fila, 'pend_m'), closeTo(n(r, 'porrec_m'), 0.01));
    expect(fila['mora_c'], r['meta_c']);
    expect(fila['rec_c'], r['rec_c']);
    expect(fila['pend_c'], r['porrec_c']);
  });

  test('desgloseMora — cada desglose suma su fila', () async {
    const iniAgo = '2026-07-15';
    const finAgo = '2026-08-15';

    final q = desgloseMora(
        inicio: iniAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo);
    final filas = await db.getAll(q.sql, q.parametros);

    // ignore: avoid_print
    print('\n== Desglose del ciclo 15 jul – 14 ago ==');
    for (final r in filas) {
      // ignore: avoid_print
      print('${r['fila']}/${r['clave']}  ${r['cuotas']} cuotas  ${n(r, 'monto')}');
    }

    double sumaDe(String fila) => filas
        .where((r) => r['fila'] == fila)
        .fold<double>(0, (a, r) => a + n(r, 'monto'));

    final res = resumenMora(
        inicio: iniAgo, fin: finAgo, diasGracia: gracia, hoy: hoyFijo);
    final r = (await db.getAll(res.sql, res.parametros)).first;

    expect(sumaDe('rec'), closeTo(n(r, 'rec_m'), 0.01),
        reason: 'el desglose de Recuperado tiene que sumar la fila madre');
    expect(sumaDe('pend'), closeTo(n(r, 'porrec_m'), 0.01),
        reason: 'el desglose de Por recuperar tiene que sumar la fila madre');

    // Las claves son las cuatro previstas y nada más: una quinta rompería el
    // switch de rótulos del widget en silencio.
    for (final f in filas) {
      expect(['dentro', 'despues', 'parcial', 'nada'], contains(f['clave']));
    }
  });
}
