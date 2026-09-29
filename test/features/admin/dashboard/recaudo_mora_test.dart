@TestOn('vm')
library;

/// La tarjeta "Recaudo y mora" (4 líneas), contra el SQLite REAL de PowerSync.
///
/// Corre `serieRecaudoMora` — la misma consulta de producción — sobre el
/// escenario de 15 clientes en 6 ciclos, y verifica lo que la tabla de la
/// tarjeta PROMETE: que `facturado = recaudado + por recaudar + mora` en cada
/// ciclo y en el acumulado, sin plata contada dos veces. La referencia visual
/// de la que salió el formato afirmaba esa identidad con "Por Recaudar" y
/// "Mora" como conjuntos disjuntos; este test es lo que la vuelve un hecho y
/// no una esperanza.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_query.dart';
import 'package:isp_billing/features/admin/dashboard/recaudo_mora_card.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

import 'escenario_seed.dart';

/// Ventana de 6 ciclos que termina en el ciclo de agosto 2026 (15 jul–14 ago),
/// la misma que arma la tarjeta con `inicioPeriodo(2026, 8 - 5)`.
const inicioVentana = '2026-02-15';
const finVentana = '2026-08-15';
const gracia = 7;

/// Corte FIJO, como en dashboard_numeros_test: con `date('now')` los
/// esperados cambiarían solos cada madrugada.
const hoyFijo = '2026-08-12';

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('recaudo_mora (saltado: falta powersync-sqlite-core)', () {},
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
    tmpDir = await Directory.systemTemp.createTemp('recaudo_mora_');
    db = PowerSyncDatabase(
        schema: schema, path: p.join(tmpDir.path, '${uuid.v4()}.db'));
    await db.initialize();
    await sembrarEscenario(db);
  });

  tearDown(() async {
    await db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<List<Map<String, dynamic>>> filasSerie() async {
    final q = serieRecaudoMora(
        inicio: inicioVentana,
        fin: finVentana,
        diasGracia: gracia,
        hoy: hoyFijo);
    return db.getAll(q.sql, q.parametros);
  }

  test('la identidad de la tabla: fact = rec + porrec + mora, POR CICLO',
      () async {
    final filas = await filasSerie();
    expect(filas, isNotEmpty);
    for (final f in filas) {
      final fact = (f['fact'] as num).toDouble();
      final suma = (f['rec'] as num).toDouble() +
          (f['porrec'] as num).toDouble() +
          (f['mora'] as num).toDouble();
      expect(suma, closeTo(fact, 0.01),
          reason: 'ciclo ${f['ciclo']}: la partición tiene que sumar el '
              'total — si no, la columna "% del Total" miente');
    }
  });

  test('los ciclos coinciden con periodoDe: día >= 15 cuenta al mes siguiente',
      () async {
    final filas = await filasSerie();
    final claves = filas.map((f) => f['ciclo'] as String).toList();
    // La ventana 2026-02-15 → 2026-08-15 solo puede producir los períodos
    // mar..ago: una clave fuera de ese rango sería una cuota mal asignada.
    const esperadas = [
      '2026-03', '2026-04', '2026-05', '2026-06', '2026-07', '2026-08',
    ];
    for (final c in claves) {
      expect(esperadas, contains(c));
    }
    expect(claves, orderedEquals([...claves]..sort()),
        reason: 'la query promete ORDER BY ciclo');
  });

  test('cross-check contra la tarjeta de Cobros: mismo universo, misma plata',
      () async {
    // El ciclo de agosto según la serie...
    final filas = await filasSerie();
    final ago = filas.singleWhere((f) => f['ciclo'] == '2026-08');
    // ...tiene que facturar y recaudar EXACTAMENTE lo que reporta
    // `resumenCobros` sobre esa misma ventana: dos tarjetas del mismo
    // dashboard no pueden decir números distintos del mismo ciclo.
    final q = resumenCobros(
        inicio: '2026-07-15', fin: finVentana, diasGracia: gracia);
    final r = (await db.getAll(q.sql, q.parametros)).first;
    expect((ago['fact'] as num).toDouble(),
        closeTo((r['meta_m'] as num).toDouble(), 0.01));
    expect((ago['rec'] as num).toDouble(),
        closeTo((r['rec_m'] as num).toDouble(), 0.01));
    expect(
        (ago['porrec'] as num).toDouble() + (ago['mora'] as num).toDouble(),
        closeTo((r['porrec_m'] as num).toDouble(), 0.01),
        reason: 'por recaudar + mora de la serie = el "por recuperar" total '
            'de la tarjeta de Cobros (que no separa por gracia)');
  });

  test('ciclosDesdeFilas rellena los huecos y no corre las etiquetas',
      () async {
    // Solo dos filas con hueco en el medio: abril sin cuotas.
    final serie = ciclosDesdeFilas([
      {'ciclo': '2026-03', 'fact': 100, 'rec': 40, 'mora': 10, 'porrec': 50},
      {'ciclo': '2026-05', 'fact': 200, 'rec': 200, 'mora': 0, 'porrec': 0},
    ], anio: 2026, mes: 5, n: 3);
    expect(serie.map((c) => c.mes), [3, 4, 5]);
    expect(serie[1].fact, 0, reason: 'abril no tiene filas: cero, no ausente');
    expect(serie[0].fact, 100);
    expect(serie[2].rec, 200);
  });

  test('acumular: monótona, y el último punto es la suma de todos', () async {
    final filas = await filasSerie();
    final mensual = ciclosDesdeFilas(filas, anio: 2026, mes: 8);
    final acum = acumular(mensual);
    for (var i = 1; i < acum.length; i++) {
      expect(acum[i].fact, greaterThanOrEqualTo(acum[i - 1].fact));
      expect(acum[i].rec, greaterThanOrEqualTo(acum[i - 1].rec));
    }
    double suma(double Function(CicloRecaudo) f) =>
        mensual.fold(0.0, (a, c) => a + f(c));
    expect(acum.last.fact, closeTo(suma((c) => c.fact), 0.01));
    expect(acum.last.rec, closeTo(suma((c) => c.rec), 0.01));
    expect(acum.last.mora, closeTo(suma((c) => c.mora), 0.01));
    // Y la identidad también vale acumulada.
    expect(acum.last.rec + acum.last.porrec + acum.last.mora,
        closeTo(acum.last.fact, 0.01));
  });
}

String? _resolveCorePath() {
  final raiz = Directory.current.path;
  for (final nombre in [
    'powersync_x64.dll',
    'libpowersync_x64.so',
    'libpowersync_aarch64.dylib',
    'libpowersync_x64.dylib',
  ]) {
    final f = File(p.join(raiz, nombre));
    if (f.existsSync()) return f.path;
  }
  return null;
}
