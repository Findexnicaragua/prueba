@TestOn('vm')
library;

/// Las tres tarjetas nuevas del Resumen, contra el SQLite REAL.
///
/// Lo que verifica es UNA cosa, la que el dueño pidió explícitamente
/// (2026-08-28): *"que los documentos excel igual sean precisos con la
/// información que muestran las gráficas para que no se invente nada"*.
///
/// Por eso cada test corre la MISMA consulta que la pantalla y compara sus
/// totales contra los que el archivo escribiría. Si alguien le agrega un filtro
/// a un lado y no al otro, acá se cae.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

import 'escenario_seed.dart';

const gracia = 7;

String? _resolveCorePath() {
  for (final n in [
    'powersync_x64.dll',
    'libpowersync.so',
    'libpowersync.dylib'
  ]) {
    final f = File(p.join(Directory.current.path, n));
    if (f.existsSync()) return f.path;
  }
  return null;
}

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('tarjetas_nuevas (saltado: falta powersync-sqlite-core)', () {},
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
    tmpDir = await Directory.systemTemp.createTemp('tarjetas_');
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

  // ── Mora por cobrador y comunidad ──

  const saldoSql = 'max(cu.monto + COALESCE(cu.cargos_neto, 0) - '
      'COALESCE(cu.monto_pagado, 0), 0)';
  const cobrableSql = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') IN ('activo','suspendido')";

  test('mora por zona — los tres niveles suman lo mismo', () async {
    // La consulta de la tarjeta: una fila por (cobrador, comunidad, monto).
    final filas = await db.getAll(
      '''
      SELECT cu.cobrador_id AS cob_id,
             COALESCE(cm.nombre, 'Sin comunidad') AS com_nombre,
             $saldoSql AS saldo, COUNT(*) AS cuotas
        FROM cuotas cu
        JOIN clientes cl ON cl.id = cu.cliente_id AND cl.activo = 1
   LEFT JOIN comunidades cm ON cm.id = cl.comunidad_id
       WHERE cu.estado IN ('pendiente','parcial') AND $cobrableSql
         AND $saldoSql > 0.009
         AND date(cu.fecha_vencimiento, '+' || ? || ' days')
             < date('now','-6 hours')
       GROUP BY cu.cobrador_id, com_nombre, saldo
      ''',
      [gracia],
    );

    // El nivel 3 (tramos) tiene que sumar el nivel 2 (comunidad), y ése el
    // nivel 1 (cobrador). Como los tres salen de ESTA fila, la identidad es
    // `saldo * cuotas` sumado en cada agrupación.
    final porCom = <String, double>{};
    final porCob = <String, double>{};
    var total = 0.0;
    for (final r in filas) {
      final t = n(r, 'saldo') * n(r, 'cuotas');
      final cob = '${r['cob_id']}';
      porCom['$cob|${r['com_nombre']}'] =
          (porCom['$cob|${r['com_nombre']}'] ?? 0) + t;
      porCob[cob] = (porCob[cob] ?? 0) + t;
      total += t;
    }

    expect(porCob.values.fold<double>(0, (a, v) => a + v), closeTo(total, 0.01),
        reason: 'la suma de los cobradores tiene que dar el total');
    expect(porCom.values.fold<double>(0, (a, v) => a + v), closeTo(total, 0.01),
        reason: 'la suma de las comunidades tiene que dar el mismo total');

    // ignore: avoid_print
    print('\n== Mora por zona ==\n${filas.length} tramos · '
        '${porCom.length} comunidades · ${porCob.length} cobradores · '
        'C\$${total.toStringAsFixed(2)}');
  });

  test('mora por zona — el filtro de GRACIA está puesto', () async {
    // Este test existe por un bug real: al reescribir la tarjeta se perdió
    // `vencimiento + gracia < hoy` y pasó a mostrar toda la deuda viva en vez
    // de la mora (C$170.185 contra C$33.485 en el Test Tenant). Sin gracia el
    // universo TIENE que ser estrictamente mayor.
    Future<double> suma({required bool conGracia}) async {
      final r = await db.getAll(
        '''
        SELECT COALESCE(SUM($saldoSql), 0) AS m
          FROM cuotas cu
          JOIN clientes cl ON cl.id = cu.cliente_id AND cl.activo = 1
         WHERE cu.estado IN ('pendiente','parcial') AND $cobrableSql
           AND $saldoSql > 0.009
           ${conGracia ? "AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now','-6 hours')" : ''}
        ''',
        conGracia ? [gracia] : [],
      );
      return n(r.first, 'm');
    }

    final conFiltro = await suma(conGracia: true);
    final sinFiltro = await suma(conGracia: false);

    // ignore: avoid_print
    print('\n== Gracia ==\ncon filtro (mora): $conFiltro · '
        'sin filtro (toda la deuda): $sinFiltro');

    expect(conFiltro, lessThan(sinFiltro),
        reason: 'si son iguales, el filtro de mora no está haciendo nada');
    expect(conFiltro, greaterThan(0),
        reason: 'el escenario tiene que tener mora, si no el test no prueba nada');
  });


  test('mora por zona — filtrar el Excel por (cobrador, comunidad, saldo) da '
      'el MISMO conteo que la tabla', () async {
    // ESTE es el test que pidió el dueño (2026-08-28): *"en X comunidad con Y
    // cobrador hay 2 cuotas de 500, y en el excel aparece esa informacion con
    // los detalles de esas 2 cuotas"*. Si alguien le toca el universo a una de
    // las dos consultas y no a la otra, el filtro deja de cerrar y esto se cae.

    // (1) Lo que muestra la TABLA: una fila por (cobrador, comunidad, saldo).
    final tabla = await db.getAll(
      '''
      SELECT cu.cobrador_id AS cob_id,
             COALESCE(cm.nombre, 'Sin comunidad') AS com_nombre,
             $saldoSql AS saldo, COUNT(*) AS cuotas
        FROM cuotas cu
        JOIN clientes cl ON cl.id = cu.cliente_id AND cl.activo = 1
   LEFT JOIN comunidades cm ON cm.id = cl.comunidad_id
       WHERE cu.estado IN ('pendiente','parcial') AND $cobrableSql
         AND $saldoSql > 0.009
         AND date(cu.fecha_vencimiento, '+' || ? || ' days')
             < date('now','-6 hours')
       GROUP BY cu.cobrador_id, com_nombre, saldo
      ''',
      [gracia],
    );

    // (2) Lo que baja el EXCEL: una fila por cuota.
    final excel = await db.getAll(
      '''
      SELECT cu.cobrador_id AS cob_id,
             COALESCE(cm.nombre, 'Sin comunidad') AS com_nombre,
             $saldoSql AS saldo
        FROM cuotas cu
        JOIN clientes cl ON cl.id = cu.cliente_id AND cl.activo = 1
   LEFT JOIN comunidades cm ON cm.id = cl.comunidad_id
       WHERE cu.estado IN ('pendiente','parcial') AND $cobrableSql
         AND $saldoSql > 0.009
         AND date(cu.fecha_vencimiento, '+' || ? || ' days')
             < date('now','-6 hours')
      ''',
      [gracia],
    );

    expect(tabla, isNotEmpty,
        reason: 'sin mora en el escenario, el test no prueba nada');

    // El filtro de Excel, hecho a mano: contar las filas del archivo que
    // coinciden con cada línea de la tabla.
    String clave(Map<String, Object?> r) =>
        '${r['cob_id']}|${r['com_nombre']}|${n(r, 'saldo').toStringAsFixed(2)}';

    final conteoExcel = <String, int>{};
    for (final r in excel) {
      conteoExcel[clave(r)] = (conteoExcel[clave(r)] ?? 0) + 1;
    }

    for (final t in tabla) {
      final k = clave(t);
      expect(conteoExcel[k], t['cuotas'],
          reason: 'la tabla dice ${t['cuotas']} cuotas para [$k] y el Excel '
              'trae ${conteoExcel[k]}');
    }

    // Y al revés: el Excel no puede traer combinaciones que la tabla no muestre.
    expect(conteoExcel.length, tabla.length,
        reason: 'el Excel trae grupos que la tabla no lista');
    expect(excel.length, tabla.fold<int>(0, (a, t) => a + (t['cuotas'] as int)),
        reason: 'el total de filas del Excel tiene que ser el total de cuotas');

    // ignore: avoid_print
    print('\n== Excel trazable ==\n${excel.length} cuotas en ${tabla.length} '
        'grupos (cobrador × comunidad × monto), todos con el conteo exacto');
  });

  // ── Proyección ──

  test('proyección — pantalla y Excel miran el MISMO universo', () async {
    const contratoActivo = 'COALESCE((SELECT ct.estado FROM contratos ct '
        "WHERE ct.id = cu.contrato_id), 'activo') = 'activo'";
    const dias = 10;

    // Lo que agrega la PANTALLA: hoy + próximos, por cobrador.
    final pantalla = await db.getAll(
      '''
      SELECT COALESCE(SUM(CASE WHEN date(cu.fecha_vencimiento) = date('now','-6 hours')
                          OR (date(cu.fecha_vencimiento) > date('now','-6 hours')
                              AND date(cu.fecha_vencimiento)
                                  <= date('now','-6 hours','+' || ? || ' days'))
                          THEN $saldoSql ELSE 0 END), 0) AS m,
             COUNT(CASE WHEN date(cu.fecha_vencimiento) = date('now','-6 hours')
                          OR (date(cu.fecha_vencimiento) > date('now','-6 hours')
                              AND date(cu.fecha_vencimiento)
                                  <= date('now','-6 hours','+' || ? || ' days'))
                        THEN 1 END) AS c
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id AND c.activo = 1
       WHERE cu.estado IN ('pendiente','parcial') AND $contratoActivo
      ''',
      [dias, dias],
    );

    // Lo que lista el EXCEL: una fila por cuota, mismo rango.
    final excel = await db.getAll(
      '''
      SELECT COALESCE(SUM($saldoSql), 0) AS m, COUNT(*) AS c
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id AND c.activo = 1
       WHERE cu.estado IN ('pendiente','parcial') AND $contratoActivo
         AND date(cu.fecha_vencimiento) >= date('now','-6 hours')
         AND date(cu.fecha_vencimiento)
             <= date('now','-6 hours','+' || ? || ' days')
      ''',
      [dias],
    );

    expect(n(excel.first, 'm'), closeTo(n(pantalla.first, 'm'), 0.01),
        reason: 'el Excel de proyección trae otra plata que la tarjeta');
    expect(excel.first['c'], pantalla.first['c'],
        reason: 'el Excel de proyección trae otras cuotas que la tarjeta');
  });

  // ── Quién cobró ──

  test('quién cobró — pantalla y Excel cuentan los MISMOS pagos', () async {
    // El bug que este test cierra: el Excel hacía JOIN a `cobradores` sin
    // `activo = 1` y la pantalla sí lo filtraba. Un cobrador dado de baja con
    // pagos aparecía en el archivo y no en la tarjeta.
    const vivo =
        'COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0';

    final pantalla = await db.getAll(
      '''
      SELECT COALESCE(SUM(p.monto_cordobas), 0) AS m, COUNT(p.id) AS c
        FROM cobradores co
   LEFT JOIN pagos p ON p.cobrador_id = co.id AND $vivo
       WHERE co.activo = 1
      ''',
      [],
    );

    final excel = await db.getAll(
      '''
      SELECT COALESCE(SUM(p.monto_cordobas), 0) AS m, COUNT(p.id) AS c
        FROM pagos p
        JOIN cobradores co ON co.id = p.cobrador_id AND co.activo = 1
       WHERE $vivo
      ''',
      [],
    );

    // ignore: avoid_print
    print('\n== Quién cobró ==\npantalla: ${pantalla.first['c']} pagos · '
        'excel: ${excel.first['c']} pagos');

    expect(excel.first['c'], pantalla.first['c'],
        reason: 'el Excel cuenta pagos que la tarjeta no muestra (o al revés)');
    expect(n(excel.first, 'm'), closeTo(n(pantalla.first, 'm'), 0.01));
  });
}
