@TestOn('vm')
library;

/// La tarjeta "Estado actual", que el 2026-09-01 se comió a "Distribución de
/// cuotas".
///
/// Las dos medían lo mismo: `Cuotas por cobrar` de una era exactamente
/// `al día + en gracia + vencidas` de la otra, y "En mora" salía repetido en
/// ambas con el mismo número. La fusión sólo se puede sostener si esa igualdad
/// es cierta **por construcción y no por casualidad del escenario** — si un día
/// deja de serlo, la tarjeta muestra un titular que no es la suma de sus
/// partes, que es la forma más rápida de perder la confianza del que la mira.
///
/// Por eso este archivo corre `estadoActual()`, la consulta REAL del provider,
/// y no una copia parecida escrita acá: dos SQL que responden lo mismo se
/// separan en cuanto alguien toca uno.
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

import 'escenario_seed.dart';

void main() {
  String? core;
  for (final n in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    if (File(n).existsSync()) core = File(n).absolute.path;
  }
  if (core == null) {
    test('estado_actual (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;
  const gracia = 10;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('estado_actual_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
    await db.initialize();
    await sembrarEscenario(db);
  });

  tearDownAll(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> fila() async {
    final q = estadoActual(diasGracia: gracia);
    return (await db.getAll(q.sql, q.parametros)).first;
  }

  int c(Map<String, Object?> r, String k) => (r[k] as num).toInt();
  double m(Map<String, Object?> r, String k) => (r[k] as num).toDouble();

  test('las tres partes REPARTEN el titular, en cuotas y en córdobas',
      () async {
    final r = await fila();

    // ignore: avoid_print
    print('\n== Estado actual ==\n'
        'Por cobrar  ${c(r, 'cuotas_pend')}  C\$${m(r, 'saldo')}\n'
        '  al día    ${c(r, 'al_dia')}  C\$${m(r, 'saldo_al_dia')}\n'
        '  en gracia ${c(r, 'en_gracia')}  C\$${m(r, 'saldo_en_gracia')}\n'
        '  en mora   ${c(r, 'vencidas')}  C\$${m(r, 'saldo_vencido')}');

    expect(c(r, 'al_dia') + c(r, 'en_gracia') + c(r, 'vencidas'),
        c(r, 'cuotas_pend'),
        reason: 'las tres partes tienen que dar el titular EN CUOTAS');
    expect(
        m(r, 'saldo_al_dia') + m(r, 'saldo_en_gracia') + m(r, 'saldo_vencido'),
        closeTo(m(r, 'saldo'), 0.01),
        reason: 'y también EN CÓRDOBAS: la barra de la tarjeta reparte plata, '
            'no conteos');
  });

  // Sin esto el test de arriba pasaría con TODO en cero — que es justo el
  // escenario donde no prueba nada (checklist de audit #14: un chequeo que no
  // puede fallar es peor que no tenerlo).
  test('el escenario tiene cuotas en las tres situaciones', () async {
    final r = await fila();
    expect(c(r, 'cuotas_pend'), greaterThan(0),
        reason: 'sin deuda viva la partición es 0 = 0 + 0 + 0');
    expect(c(r, 'vencidas'), greaterThan(0),
        reason: 'sin cuotas en mora, la parte roja nunca se ejercita');
    expect(m(r, 'saldo'), greaterThan(0));
  });

  test('los atravesados NO son una cuarta parte: van adentro', () async {
    final r = await fila();

    // Suspendidos y parciales se cuentan APARTE porque la tarjeta los muestra
    // sangrados, pero cada uno ya está en al día, gracia o mora según su fecha.
    // Si alguno superara el titular, sería un bucket disfrazado.
    expect(c(r, 'cuotas_susp'), lessThanOrEqualTo(c(r, 'cuotas_pend')),
        reason: 'lo suspendido es un subconjunto de lo por cobrar');
    expect(m(r, 'saldo_susp'), lessThanOrEqualTo(m(r, 'saldo') + 0.01));
    expect(c(r, 'parciales'), lessThanOrEqualTo(c(r, 'cuotas_pend')),
        reason: 'una parcial es, por definición, una cuota viva');
  });

  test('ninguna cuota se pierde entre "por cobrar" y "pagadas"', () async {
    // La tarjeta muestra dos universos: lo vivo (arriba) y lo pagado (al pie).
    // Entre los dos tienen que estar TODAS las cuotas no anuladas. Si un día
    // aparece un estado nuevo, o alguno deja de contarse, acá se ve — y en la
    // tarjeta se vería como un número que no cuadra con nada.
    //
    // El conteo de control sale de una consulta distinta y más tonta a
    // propósito: si usara la misma expresión, probaría que sé copiar un WHERE.
    final r = await fila();
    final todas = await db.getAll(
        "SELECT COUNT(*) AS q FROM cuotas WHERE estado != 'anulada'");

    expect(c(r, 'cuotas_pend') + c(r, 'pagadas'),
        (todas.first['q'] as num).toInt(),
        reason: 'vivo + pagado = todas las cuotas que no están anuladas');
  });

  // Lo que este archivo NO prueba, y por qué: que "en mora" acá dé lo mismo
  // que en la tarjeta de Mora. El ALCANCE difiere a propósito —aquélla mira UN
  // ciclo y ésta suma todos— así que los números no tienen por qué coincidir.
  // Lo único comparable sería el corte de gracia, y para eso habría que
  // reescribir el WHERE acá: un test que compara una consulta contra una copia
  // de sí misma prueba que el autor sabe copiar, nada más. El cruce real entre
  // las dos definiciones de mora ya vive en `mora_cobertura_test.dart`, donde
  // las dos consultas SÍ miran la misma ventana.
}
