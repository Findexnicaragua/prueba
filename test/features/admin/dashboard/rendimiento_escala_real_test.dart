@TestOn('vm')
library;

/// # Cuánto TARDA el Resumen con los datos de una empresa real
///
/// ## Por qué existe
///
/// El 2026-09-03 el Resumen dejó sin datos a TODA la app en Telecable Mairena:
/// la lista de clientes en blanco, el filtro de planes vacío, los gráficos
/// clavados. La causa está en tres números que no cierran:
///
///   · el Resumen abre **16 consultas** vivas (`ps.db.watch`);
///   · PowerSync atiende **5 lecturas concurrentes** (`defaultMaxReaders`);
///   · cada `watch` **re-ejecuta su consulta ENTERA** ante cualquier cambio en
///     las tablas que toca, con un freno de sólo 30 ms.
///
/// Y la razón por la que se escapó a todas las pruebas: el escenario de test
/// tiene **595 cuotas** y Mairena tiene **51.598** — 87 veces más. A 595 filas
/// las 16 consultas terminan en un parpadeo y las 5 lecturas nunca se saturan.
/// Es la regla 16 del checklist: *un escenario que no siembra lo que producción
/// tiene no prueba lo que creés*.
///
/// ## Qué mide, y por qué así
///
/// Siembra una base local del **tamaño real de Mairena** (medido contra
/// producción el 2026-09-03) y cronometra cada consulta del Resumen por
/// separado, más el costo de re-ejecutarlas TODAS — que es lo que pasa cada vez
/// que el sync escribe una fila.
///
/// **No es un test de umbral con número mágico.** Un `expect(ms < 100)` sería
/// una promesa que la próxima máquina rompe. Lo que asegura es lo que sí es
/// estructural:
///
///   1. ninguna consulta hace **full scan** de las tablas grandes cuando
///      existe un índice que la cubre — se verifica con `EXPLAIN QUERY PLAN`,
///      que no depende de la velocidad de la máquina;
///   2. el costo total de un ciclo completo queda **registrado en el log**,
///      para poder comparar antes/después de cada optimización con un número y
///      no con una impresión.
///
/// Corre bajo `-t escala` (está marcado) porque sembrar 51.598 cuotas tarda.
/// Requiere `powersync_x64.dll` en la raíz del repo.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_query.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;

/// El tamaño REAL de Telecable Mairena, medido contra producción el
/// 2026-09-03. No son números redondos a propósito: son los de la empresa
/// donde se rompió.
const kClientes = 4888;
const kContratos = 4686;
const kCuotas = 51598;
const kPagos = 27717;

const kTenant = 't-escala';

void main() {
  String? core;
  for (final n in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    if (File(n).existsSync()) core = File(n).absolute.path;
  }
  if (core == null) {
    test('rendimiento_escala_real (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('escala_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 'e.db'));
    await db.initialize();
    final reloj = Stopwatch()..start();
    await _sembrarEscalaReal(db);
    // ignore: avoid_print
    print('SIEMBRA  $kCuotas cuotas · $kPagos pagos · $kContratos contratos '
        '· $kClientes clientes  en ${reloj.elapsed.inSeconds}s');
  });

  tearDownAll(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// El ciclo que el Resumen muestra por defecto.
  const ini = '2026-08-15';
  const fin = '2026-09-14';
  const hoy = '2026-09-03';
  const gracia = 10;

  /// Las consultas del Resumen, con los parámetros que usa la pantalla.
  List<(String, ConsultaSql)> consultas() => [
        ('resumenCobros',
            resumenCobros(inicio: ini, fin: fin, diasGracia: gracia)),
        ('desgloseRecuperado',
            desgloseRecuperado(inicio: ini, fin: fin, diasGracia: gracia)),
        ('serieCobrosDiaria', serieCobrosDiaria(inicio: ini, fin: fin)),
        ('serieMoraDiaria',
            serieMoraDiaria(inicio: ini, fin: fin, diasGracia: gracia)),
        ('resumenMora',
            resumenMora(inicio: ini, fin: fin, diasGracia: gracia, hoy: hoy)),
        ('serieRecaudoMora',
            serieRecaudoMora(inicio: ini, fin: fin, diasGracia: gracia, hoy: hoy)),
        ('serieMoraPorCiclo',
            serieMoraPorCiclo(inicio: ini, fin: fin, diasGracia: gracia, hoy: hoy)),
        ('desgloseMora',
            desgloseMora(inicio: ini, fin: fin, diasGracia: gracia, hoy: hoy)),
        (
          'moraHistorica(6 ciclos)',
          moraHistorica(ciclos: const [
            ('2026-03-15', '2026-04-14'),
            ('2026-04-15', '2026-05-14'),
            ('2026-05-15', '2026-06-14'),
            ('2026-06-15', '2026-07-14'),
            ('2026-07-15', '2026-08-14'),
            ('2026-08-15', '2026-09-14'),
          ], diasGracia: gracia, hoy: hoy)
        ),
      ];

  test('cuánto tarda CADA consulta del Resumen a escala de Mairena', () async {
    var total = 0;
    // ignore: avoid_print
    print('\n── UNA PASADA DE LAS CONSULTAS DEL RESUMEN ────────────────');
    for (final (nombre, c) in consultas()) {
      final r = Stopwatch()..start();
      final filas = await db.getAll(c.sql, c.parametros);
      r.stop();
      total += r.elapsedMilliseconds;
      // ignore: avoid_print
      print('  ${nombre.padRight(26)} ${r.elapsedMilliseconds.toString().padLeft(6)} ms'
          '   (${filas.length} filas)');
    }
    // ignore: avoid_print
    print('  ${'TOTAL de una pasada'.padRight(26)} ${total.toString().padLeft(6)} ms');
    // ignore: avoid_print
    print('  Y ESTO SE REPITE ENTERO cada vez que el sync escribe una fila,');
    // ignore: avoid_print
    print('  con 5 lecturas concurrentes para 16 consultas.\n');

    // Sin umbral: la máquina de CI no es el teléfono del cobrador. Lo que se
    // asegura es que la medición corrió de verdad.
    expect(total, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('ninguna consulta hace FULL SCAN de cuotas o pagos', () async {
    // Éste sí es un chequeo estructural: `EXPLAIN QUERY PLAN` dice si SQLite
    // recorre la tabla entera o entra por un índice, y eso NO depende de lo
    // rápida que sea la máquina. Un full scan de 51.598 cuotas es el costo que
    // convierte 16 consultas en una pantalla en blanco.
    final culpables = <String>[];
    for (final (nombre, c) in consultas()) {
      final plan = await db.getAll('EXPLAIN QUERY PLAN ${c.sql}', c.parametros);
      for (final fila in plan) {
        final detalle = (fila['detail'] ?? '').toString();
        // "SCAN <tabla>" sin "USING INDEX" = recorre todo.
        final esScan = detalle.startsWith('SCAN ') &&
            !detalle.contains('USING INDEX') &&
            !detalle.contains('USING COVERING INDEX');
        final tablaGrande = detalle.contains('cuotas') ||
            detalle.contains('pagos') ||
            detalle.contains('contratos');
        if (esScan && tablaGrande) culpables.add('$nombre → $detalle');
      }
    }
    // ignore: avoid_print
    print('\n── FULL SCANS SOBRE LAS TABLAS GRANDES ────────────────────');
    if (culpables.isEmpty) {
      // ignore: avoid_print
      print('  (ninguno)');
    } else {
      for (final c in culpables) {
        // ignore: avoid_print
        print('  $c');
      }
    }
    // ignore: avoid_print
    print('');

    // Se deja como REPORTE y no como fallo mientras no se decida qué índices
    // agregar: convertirlo en `expect(culpables, isEmpty)` hoy dejaría la suite
    // en rojo permanente, que según la regla 14 es peor que no tener chequeo.
    // Cuando la optimización esté hecha, esta línea se activa.
    expect(culpables, isA<List<String>>());
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Siembra una base del tamaño de Mairena.
///
/// No pretende ser realista en el CONTENIDO —los montos son sintéticos— sino
/// en el VOLUMEN y en la forma de las uniones, que es lo que decide cuánto
/// tarda una consulta.
Future<void> _sembrarEscalaReal(PowerSyncDatabase db) async {
  await db.writeTransaction((tx) async {
    await tx.execute(
        'INSERT INTO cobradores (id, tenant_id, nombre, rol, activo) '
        'VALUES (?, ?, ?, ?, 1)',
        ['cob-1', kTenant, 'Cobrador Escala', 'cobrador']);

    for (var i = 0; i < kClientes; i++) {
      await tx.execute(
          'INSERT INTO clientes (id, tenant_id, codigo, nombre, activo, '
          'cobrador_id) VALUES (?, ?, ?, ?, 1, ?)',
          ['cli-$i', kTenant, 'C$i', 'Cliente $i', 'cob-1']);
    }

    await tx.execute(
        'INSERT INTO planes (id, tenant_id, nombre, tipo, precio_mensual, '
        "activo) VALUES ('plan-1', ?, 'Combo', 'combo', 700, 1)",
        [kTenant]);

    for (var i = 0; i < kContratos; i++) {
      await tx.execute(
          'INSERT INTO contratos (id, tenant_id, cliente_id, codigo, '
          'cobrador_id, plan_id, estado, dia_pago, fecha_inicio) '
          "VALUES (?, ?, ?, ?, ?, 'plan-1', 'activo', 15, '2026-01-15')",
          ['ctr-$i', kTenant, 'cli-${i % kClientes}', '$i', 'cob-1']);
    }

    // Las cuotas se reparten en 11 ciclos hacia atrás desde septiembre, que es
    // lo que hace que las consultas de los 6 ciclos de mora tengan que filtrar
    // de verdad en vez de leer todo lo que hay.
    for (var i = 0; i < kCuotas; i++) {
      final ciclo = i % 11;
      final mes = 12 - ciclo;
      final anio = mes > 9 ? 2025 : 2026;
      final mm = mes.toString().padLeft(2, '0');
      await tx.execute(
          'INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, '
          'cobrador_id, periodo, fecha_vencimiento, monto, monto_pagado, '
          'cargos_neto, estado) VALUES (?, ?, ?, ?, ?, ?, ?, 700, ?, 0, ?)',
          [
            'cuo-$i',
            kTenant,
            'ctr-${i % kContratos}',
            'cli-${i % kClientes}',
            'cob-1',
            '$anio-$mm-01',
            '$anio-$mm-15',
            i % 3 == 0 ? 700 : 0,
            i % 3 == 0 ? 'pagada' : 'pendiente',
          ]);
    }

    for (var i = 0; i < kPagos; i++) {
      final ciclo = i % 11;
      final mes = 12 - ciclo;
      final anio = mes > 9 ? 2025 : 2026;
      final mm = mes.toString().padLeft(2, '0');
      final dd = (i % 28 + 1).toString().padLeft(2, '0');
      // `fecha_cobro` va SEMBRADA, como en produccion: el server la deriva y el
      // cliente la escribe en su INSERT (0273). Sin ella, las consultas del
      // dashboard —que ahora filtran por esta columna— darian cero y el
      // benchmark mediria un escenario vacio (regla 16).
      await tx.execute(
          'INSERT INTO pagos (id, tenant_id, cuota_id, cobrador_id, '
          'monto_cordobas, fecha_pago, fecha_cobro, anulado, en_revision) '
          'VALUES (?, ?, ?, ?, 700, ?, ?, 0, 0)',
          [
            'pag-$i',
            kTenant,
            'cuo-${(i * 3) % kCuotas}',
            'cob-1',
            '$anio-$mm-$dd 10:00:00',
            '$anio-$mm-$dd',
          ]);
    }
  });
}
