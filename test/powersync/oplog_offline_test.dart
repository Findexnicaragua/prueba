@TestOn('vm')
library;

/// Verificación del BLOQUEANTE crítico del rework de change log (Hueco offline):
/// un cobrador que NO descarga `op_log` (no está en su bucket de sync) igual debe
/// poder ESCRIBIRLA offline en su SQLite local SIN que falle, y PowerSync debe
/// ENCOLARLA para subir al reconectar (el upload queue es independiente de los
/// buckets de descarga). VERIFICADO 2026-06-19: pasa → el log de intención
/// escrito por el cliente es seguro offline y no puede tumbar el cobro.
///
/// Requiere el binario `powersync-sqlite-core` (mismo harness que pagos_repo_test).

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
    test('oplog offline (saltado: falta powersync-sqlite-core)', () {
      markTestSkipped('No se encontró el binario powersync-sqlite-core.');
    }, skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('oplog_offline_');
  });
  tearDown(() async {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  test('el cliente escribe op_log offline y queda ENCOLADO para subir, aunque '
      'no esté en ningún bucket de descarga', () async {
    // Schema con op_log como tabla sincronizada — tal como la tendría el
    // cobrador: la declara (puede escribirla) pero NO la descarga (sync rules).
    const schema = Schema([
      Table('op_log', [
        Column.text('tenant_id'),
        Column.text('op_id'),
        Column.text('tipo_op'),
        Column.text('entidad'),
        Column.text('entidad_id'),
        Column.text('actor_id'),
        Column.text('diff'),
        Column.text('ocurrido_en'),
      ]),
    ]);
    final db = PowerSyncDatabase(
      schema: schema,
      path: p.join(tmpDir.path, 'cobrador.db'),
    );
    await db.initialize();

    // OFFLINE: nunca se llama db.connect(). Escribir como lo haría pagos_repo
    // dentro de su writeTransaction al registrar un cobro.
    final id = uuid.v4();
    await db.execute(
      'INSERT INTO op_log (id, tenant_id, op_id, tipo_op, entidad, '
      'entidad_id, actor_id, diff, ocurrido_en) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id, 't1', uuid.v4(), 'cobro', 'cuotas', uuid.v4(), 'co-1',
        '{"campos":[{"campo":"Estado","antes":"Pendiente","despues":"Pagada"}]}',
        DateTime.now().toUtc().toIso8601String(),
      ],
    );

    // (1) La escritura local FUNCIONA → no rompería el cobro.
    final rows = await db.getAll('SELECT * FROM op_log WHERE id = ?', [id]);
    expect(rows, hasLength(1), reason: 'el INSERT local debe quedar escrito');
    expect(rows.first['tipo_op'], 'cobro');

    // (2) PowerSync la ENCOLÓ para subir (ps_crud) — independiente de los
    // buckets de descarga → al reconectar sube al server aunque el cobrador
    // no la baje.
    final batch = await db.getCrudBatch();
    expect(batch, isNotNull,
        reason: 'el INSERT debe estar en la cola de upload de PowerSync');
    final enColaDeOpLog = batch!.crud.any(
      (e) => e.table == 'op_log' && e.id == id && e.op == UpdateType.put,
    );
    expect(enColaDeOpLog, isTrue,
        reason: 'el op_log insertado debe estar encolado como PUT para subir');

    await db.close();
  });
}

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
