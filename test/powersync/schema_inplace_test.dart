@TestOn('vm')
library;

/// Prueba de seguridad de la Propuesta #1 (desacoplar el bump del wipe).
///
/// Valida que PowerSync (la versión instalada) actualiza el schema del cliente
/// IN-PLACE al reabrir el MISMO archivo con un schema cambiado: agregar una
/// COLUMNA o un ÍNDICE NO borra los datos locales (no re-descarga). Si estos
/// tests pasan, quitar la versión del nombre del archivo (`sitecsa_<uid>.db`,
/// sin `_vN`) es SEGURO para cambios aditivos — es el go/no-go documentado del
/// cambio. El caso de la columna nueva cubre además el bug histórico
/// "Could not find the X column ... in the schema cache" (commit 8924bf3) que
/// motivó meter la versión al filename: si acá NO reaparece, ese bug ya está
/// resuelto por la versión actual de PowerSync.
///
/// Requiere el binario nativo `powersync-sqlite-core` (mismo harness que
/// `test/data/repositories/pagos_repo_test.dart`): si falta, se SALTA.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('schema in-place (saltado: falta powersync-sqlite-core)', () {
      markTestSkipped(
        'No se encontró el binario `powersync-sqlite-core`. Ver instrucciones '
        'en test/data/repositories/pagos_repo_test.dart.',
      );
    }, skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();
  late Directory tmpDir;
  late String dbPath;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('schema_inplace_');
    // MISMO archivo entre reaperturas: simula "sin bump de filename".
    dbPath = p.join(tmpDir.path, 'inplace.db');
  });

  tearDown(() async {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  test('agregar una COLUMNA sobre el mismo archivo: los datos persisten y la '
      'columna nueva es consultable (sin error de schema cache)', () async {
    // V1: tabla con una sola columna 'a'.
    const v1 = Schema([
      Table('inplace_t', [Column.text('a')]),
    ]);
    final db1 = PowerSyncDatabase(schema: v1, path: dbPath);
    await db1.initialize();
    final rowId = uuid.v4();
    await db1.execute('INSERT INTO inplace_t (id, a) VALUES (?, ?)',
        [rowId, 'hola']);
    await db1.close();

    // V2: MISMO archivo, schema con una columna NUEVA 'b'.
    const v2 = Schema([
      Table('inplace_t', [Column.text('a'), Column.text('b')]),
    ]);
    final db2 = PowerSyncDatabase(schema: v2, path: dbPath);
    await db2.initialize();

    // El dato de V1 sigue ahí (NO se borró) y la columna nueva es consultable.
    final rows =
        await db2.getAll('SELECT a, b FROM inplace_t WHERE id = ?', [rowId]);
    expect(rows, hasLength(1),
        reason: 'la fila escrita bajo V1 sobrevive a la reapertura con V2');
    expect(rows.first['a'], 'hola');
    expect(rows.first['b'], isNull,
        reason: 'columna nueva: NULL para la fila vieja, NO "no such column"');
    await db2.close();
  });

  test('agregar un ÍNDICE sobre el mismo archivo (caso v32→v33): los datos '
      'persisten y el índice queda disponible/usable', () async {
    // V1: tabla SIN índice sobre 'b'.
    const v1 = Schema([
      Table('idx_t', [Column.text('a'), Column.text('b')]),
    ]);
    final db1 = PowerSyncDatabase(schema: v1, path: dbPath);
    await db1.initialize();
    for (var i = 0; i < 100; i++) {
      await db1.execute('INSERT INTO idx_t (id, a, b) VALUES (?, ?, ?)',
          [uuid.v4(), 'a-$i', 'b-${i.toString().padLeft(3, '0')}']);
    }
    await db1.close();

    // V2: MISMO archivo + un índice nuevo sobre 'b'.
    const v2 = Schema([
      Table('idx_t', [Column.text('a'), Column.text('b')], indexes: [
        Index('by_b', [IndexedColumn('b')]),
      ]),
    ]);
    final db2 = PowerSyncDatabase(schema: v2, path: dbPath);
    await db2.initialize();

    // Los 100 datos siguen (no se re-descargó nada: es el mismo archivo).
    final count = await db2.getAll('SELECT COUNT(*) AS n FROM idx_t');
    expect((count.first['n'] as num).toInt(), 100,
        reason: 'agregar un índice NO borra los datos locales');
    // El índice se construyó local sobre los datos ya existentes y se usa.
    final plan = await db2.getAll(
        'EXPLAIN QUERY PLAN SELECT a FROM idx_t WHERE b = ?', ['b-050']);
    final planText = plan.map((r) => r.values.join(' ')).join(' | ');
    expect(planText.toUpperCase(), contains('INDEX'),
        reason: 'EQP debe usar el índice nuevo (reconstruido local): $planText');
    await db2.close();
  });
}

/// Mismo resolutor de binario que `pagos_repo_test.dart`: `$POWERSYNC_CORE_PATH`
/// o la raíz del repo; null = saltar.
String? _resolveCorePath() {
  final override = Platform.environment['POWERSYNC_CORE_PATH'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return override;
  }
  final root = Directory.current.path;
  final candidates = <String>[
    p.join(root, 'libpowersync.so'),
    p.join(root, 'libpowersync.dylib'),
    p.join(root, 'powersync_x64.dll'),
    p.join(root, 'powersync_aarch64.dll'),
    p.join(root, 'libpowersync_x64.so'),
    p.join(root, 'libpowersync_aarch64.so'),
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
