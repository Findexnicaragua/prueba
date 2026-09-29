@TestOn('vm')
library;

/// El filtro **Plan** — que filtre de verdad, y que agrupe bien.
///
/// ## Por qué hace falta, y por qué antes no se podía escribir
///
/// Hasta el 2026-09-03 el generador Dart del escenario insertaba contratos
/// **sin `plan_id`** y no sembraba la tabla `planes` en absoluto. Un test del
/// filtro sobre ese harness habría dado **verde midiendo la nada**: cero
/// opciones, cero filas filtradas, todo "correcto". Es la regla 16 del AGENTS
/// textual — un escenario que no siembra lo que producción tiene no prueba lo
/// que uno cree. Por eso el seed ahora trae cuatro planes con sus tres tipos.
///
/// ## Las dos cosas que se prueban
///
/// 1. **El SQL filtra.** Se corre el SQL REAL de la app (`cobrosFlatQuery`,
///    el mismo archivo que usa la pantalla) contra el SQLite de PowerSync con
///    el escenario sembrado. Sin plan elegido devuelve N filas; con un plan
///    elegido, menos — y todas de ese plan.
/// 2. **Las opciones se agrupan y se ordenan.** Es puro Dart y no necesita
///    base: TV → Internet → Combo, y dentro de cada grupo del más usado al
///    menos usado.
///
/// Requiere `powersync_x64.dll` en la raíz. Sin él, la parte de SQL se SALTA.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/cuotas/cobros_query.dart';
import 'package:isp_billing/features/shared/widgets/filtro_planes.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:sqlite3/open.dart' as sq;

import '../admin/dashboard/escenario_seed.dart';

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  // 1. Las opciones: agrupación y orden. Puro Dart, sin base.
  // ─────────────────────────────────────────────────────────────────────────
  group('opcionesDePlanes', () {
    // Filas como las devuelve `kPlanesFiltroSql`, a propósito DESORDENADAS y
    // con el combo primero: si el orden saliera de la consulta y no de acá,
    // este test no distinguiría nada.
    final filas = <Map<String, dynamic>>[
      {'id': 'c1', 'nombre': 'Combo 20M', 'tipo': 'combo',
        'precio_mensual': 900, 'contratos': 5, 'activos': 5},
      {'id': 'i1', 'nombre': 'Internet 20MB', 'tipo': 'internet',
        'precio_mensual': 600, 'contratos': 9, 'activos': 9},
      {'id': 't1', 'nombre': 'CATV', 'tipo': 'tv',
        'precio_mensual': 500, 'contratos': 2, 'activos': 2},
      {'id': 't2', 'nombre': 'CATV', 'tipo': 'tv',
        'precio_mensual': 700, 'contratos': 40, 'activos': 40},
    ];

    test('agrupa TV → Internet → Combo, en ese orden', () {
      final ops = opcionesDePlanes(filas, conSinPlan: false);
      // El orden de los GRUPOS lo da el orden de esta lista: el panel los
      // agrupa con un Map en orden de inserción, no con un sort propio.
      expect(ops.map((o) => o.grupo).toList(),
          ['TV', 'TV', 'Internet', 'Combo']);
    });

    test('dentro de un grupo, el más usado primero', () {
      final ops = opcionesDePlanes(filas, conSinPlan: false);
      final tv = ops.where((o) => o.grupo == 'TV').toList();
      // t2 tiene 40 contratos y t1 tiene 2 → t2 va arriba, aunque en la lista
      // de entrada venga después.
      expect(tv.map((o) => o.id).toList(), ['t2', 't1']);
    });

    test('el subtítulo distingue dos planes con el MISMO nombre', () {
      final ops = opcionesDePlanes(filas, conSinPlan: false);
      final tv = ops.where((o) => o.grupo == 'TV').toList();
      // Los dos se llaman "CATV": sin el subtítulo serían indistinguibles, que
      // es el caso real de Mairena (siete planes con ese nombre).
      expect(tv[0].label, tv[1].label);
      expect(tv[0].subtitulo, isNot(tv[1].subtitulo));
      expect(tv[0].subtitulo, contains('40 clientes'));
      expect(tv[1].subtitulo, contains('2 clientes'));
    });

    test('un plan sin contratos activos NO dice "0 clientes"', () {
      final ops = opcionesDePlanes([
        {'id': 'z', 'nombre': 'Viejo', 'tipo': 'tv',
          'precio_mensual': 300, 'contratos': 4, 'activos': 0},
      ], conSinPlan: false);
      // Existe como opción (sus contratos cancelados viven en "Fuera de ruta")
      // pero "0 clientes" se leería como un error.
      expect(ops.single.subtitulo, contains('sin clientes activos'));
    });

    test('"Sin plan" va primero y sin grupo', () {
      final ops = opcionesDePlanes(filas);
      expect(ops.first.id, kPlanSinPlan);
      expect(ops.first.grupo, isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. El SQL: que filtre de verdad, contra el escenario sembrado.
  // ─────────────────────────────────────────────────────────────────────────
  String? core;
  for (final n in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    if (File(n).existsSync()) core = File(n).absolute.path;
  }
  if (core == null) {
    test('SQL del filtro (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  group('el SQL real filtra por plan', () {
    late PowerSyncDatabase db;
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('filtro_plan_');
      db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
      await db.initialize();
      await sembrarEscenario(db);
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<List<Map<String, dynamic>>> correr({Set<String>? planIds}) async {
      final (sql, params) = cobrosFlatQuery(
        filtro: CobrosFiltro.verTodo,
        diasGracia: 5,
        diasVisibles: 5,
        planIds: planIds,
      );
      return db.getAll(sql, params);
    }

    test('el escenario TIENE planes — si no, todo lo de abajo mide la nada',
        () async {
      final planes = await db.getAll('SELECT id, tipo FROM planes');
      expect(planes, isNotEmpty,
          reason: 'el generador Dart no sembró `planes`: cualquier test del '
              'filtro daría verde probando el vacío (regla 16)');
      expect(planes.map((r) => r['tipo']).toSet(),
          containsAll(<String>['tv', 'internet', 'combo']),
          reason: 'hacen falta los tres tipos para probar la agrupación');
      final conPlan = await db.getAll(
          'SELECT COUNT(*) AS n FROM contratos WHERE plan_id IS NOT NULL');
      expect((conPlan.first['n'] as int), greaterThan(0));
    });

    test('sin filtro devuelve más filas que con un plan elegido', () async {
      final todas = await correr();
      expect(todas, isNotEmpty);

      final unPlan = await db.getAll(
          'SELECT plan_id FROM contratos WHERE plan_id IS NOT NULL LIMIT 1');
      final planId = unPlan.first['plan_id'] as String;

      final filtradas = await correr(planIds: {planId});
      expect(filtradas.length, lessThan(todas.length),
          reason: 'filtrar por un solo plan tiene que acotar');
      expect(filtradas, isNotEmpty,
          reason: 'ese plan tiene contratos: no puede dar vacío');
    });

    test('todas las filas devueltas son del plan elegido', () async {
      final unPlan = await db.getAll(
          'SELECT plan_id FROM contratos WHERE plan_id IS NOT NULL LIMIT 1');
      final planId = unPlan.first['plan_id'] as String;

      final filtradas = await correr(planIds: {planId});
      final idsContrato =
          filtradas.map((r) => r['contrato_id']).whereType<String>().toSet();
      expect(idsContrato, isNotEmpty);

      final marcas = List.filled(idsContrato.length, '?').join(', ');
      final ajenos = await db.getAll(
        'SELECT COUNT(*) AS n FROM contratos '
        'WHERE id IN ($marcas) AND plan_id <> ?',
        [...idsContrato, planId],
      );
      expect(ajenos.first['n'], 0,
          reason: 'se coló una fila de otro plan');
    });

    test('un set VACÍO no filtra (nunca deja la lista vacía por accidente)',
        () async {
      final todas = await correr();
      final vacio = await correr(planIds: <String>{});
      expect(vacio.length, todas.length);
    });
  });
}
