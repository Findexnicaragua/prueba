@TestOn('vm')
library;

/// La columna USUARIOS cierra contra el DESGLOSE DEL EXCEL.
///
/// **Es el requisito textual de Rubén (2026-09-02):** *"quiero que la data sea
/// real basada en cada ciclo y que todo haga match así como tiene que hacer
/// match cuando descargue el excel con el desglose completo"*.
///
/// **Por qué hace falta un test y no alcanza con haberlo mirado una vez.** Los
/// conteos de la pantalla salen de agregados y los del Excel de recorrer filas:
/// son dos caminos distintos al mismo número. Nada obliga a que sigan
/// coincidiendo cuando alguien toque un `WHERE` de un lado — y el modo de falla
/// es silencioso, porque las dos pantallas siguen mostrando números creíbles.
///
/// El test reconstruye el universo del Excel **fila por fila** y cuenta los
/// clientes distintos a mano, para después compararlo contra el agregado que
/// alimenta la tabla. Si divergen, alguien cambió un filtro de un solo lado.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_export.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_query.dart';
import 'package:isp_billing/powersync/db.dart' as ps;
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
    test('usuarios_cierran (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  // La MISMA ventana y gracia que el resto de los tests del Resumen.
  const inicio = '2026-07-15';
  const fin = '2026-08-15';
  const gracia = 10;
  const hoyFijo = '2026-08-31';

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('usuarios_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 't.db'));
    await db.initialize();
    await sembrarEscenario(db);
    ps.db = db;
    // `libroCobertura` titula el archivo con `Fmt.mes` (DateFormat en es), y
    // sin esto tira LocaleDataException antes de llegar al conteo.
    await initializeDateFormatting('es');
  });

  tearDownAll(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  int c(Map<String, Object?> r, String k) => (r[k] as num).toInt();

  Future<Map<String, Object?>> tabla() async {
    final q = resumenCobros(inicio: inicio, fin: fin, diasGracia: gracia);
    return (await db.getAll(q.sql, q.parametros)).first;
  }

  /// Las filas del Excel de Cobertura: el MISMO universo que recorre
  /// `detalleCobertura` — `estado != 'anulada'` dentro de la ventana.
  Future<List<Map<String, Object?>>> filasDelExcel() => db.getAll('''
        SELECT cu.cliente_id,
               COALESCE(cu.monto_pagado, 0) AS pagado,
               cu.monto + COALESCE(cu.cargos_neto, 0)
                 - COALESCE(cu.monto_pagado, 0) AS falta
          FROM cuotas cu
          JOIN clientes c ON c.id = cu.cliente_id
         WHERE cu.estado != 'anulada'
           AND date(cu.fecha_vencimiento) >= ?
           AND date(cu.fecha_vencimiento) < ?
      ''', [inicio, fin]);

  int clientesDistintos(Iterable<Map<String, Object?>> filas) =>
      filas.map((f) => f['cliente_id']).toSet().length;

  group('Cobertura: la columna Usuarios cierra con el Excel', () {
    test('el total: mismos clientes que filas tiene el Excel', () async {
      final t = await tabla();
      final excel = await filasDelExcel();
      expect(c(t, 'meta_u'), clientesDistintos(excel),
          reason: 'la tabla y el Excel tienen que recorrer el MISMO universo');
      // Y el conteo de cuotas también, que es el otro lado de la comparación
      // que el dueño hace de un vistazo.
      expect(c(t, 'meta_c'), excel.length);
    });

    test('Recuperado: los clientes que pagaron algo', () async {
      final t = await tabla();
      final excel = await filasDelExcel();
      final conPago =
          excel.where((f) => (f['pagado'] as num).toDouble() > 0.009);
      expect(c(t, 'rec_u'), clientesDistintos(conPago));
    });

    test('Por recuperar: los clientes que siguen debiendo', () async {
      final t = await tabla();
      final excel = await filasDelExcel();
      final conSaldo =
          excel.where((f) => (f['falta'] as num).toDouble() > 0.009);
      expect(c(t, 'porrec_u'), clientesDistintos(conSaldo));
    });

    test('USUARIOS nunca puede pasar a CUOTAS', () async {
      final t = await tabla();
      // Una persona puede tener varias cuotas, nunca al revés. Si esto se
      // rompe, el conteo dejó de ser de personas.
      expect(c(t, 'meta_u'), lessThanOrEqualTo(c(t, 'meta_c')));
      expect(c(t, 'rec_u'), lessThanOrEqualTo(c(t, 'rec_c')));
      expect(c(t, 'porrec_u'), lessThanOrEqualTo(c(t, 'porrec_c')));
    });

    test('y cuenta PERSONAS, no contratos', () async {
      final t = await tabla();
      // El escenario tiene al menos un cliente con dos contratos vivos en la
      // ventana. Contando contratos esto daría IGUAL a las cuotas y el dueño
      // no vería nada — que es exactamente el bug que este cambio corrige.
      final contratos = (await db.getAll('''
            SELECT COUNT(DISTINCT COALESCE(cu.contrato_id, cu.id)) AS n
              FROM cuotas cu
             WHERE cu.estado != 'anulada'
               AND date(cu.fecha_vencimiento) >= ?
               AND date(cu.fecha_vencimiento) < ?
          ''', [inicio, fin])).first;
      expect(c(t, 'meta_u'), lessThan(c(contratos, 'n')),
          reason: 'el escenario tiene clientes con más de un contrato: si '
              'Usuarios igualara a contratos, estaría contando servicios');
    });
  });

  group('el Excel ESCRIBE el mismo número que la pantalla', () {
    // Los dos tests de arriba comparan la tarjeta contra el universo del
    // Excel reconstruido A MANO. Este compara contra el número que el archivo
    // REALMENTE escribe en su fila de cierre — que es el que Rubén ve al
    // abrirlo, y el que se descolgó: el conteo del export seguía contando
    // SERVICIOS cuando la tarjeta ya contaba PERSONAS. Habría dicho 4.414
    // contra 4.409 en la pantalla, sin que nada fallara.
    test('el cierre del archivo dice los usuarios de la tarjeta', () async {
      final t = await tabla();
      // El ciclo 15/07→15/08 es el mismo que mira `tabla()`.
      final libro = await libroCobertura(
          anio: 2026, mes: 8, diasGracia: gracia, hoy: hoyFijo);
      final cierre = libro.total!.first.toString();
      expect(cierre, contains('${c(t, 'meta_u')} usuarios'),
          reason: 'el cierre del Excel dice "$cierre" y la tarjeta '
              '${c(t, 'meta_u')} usuarios');
    });

    test('y el archivo tiene una fila por cuota', () async {
      final t = await tabla();
      final libro = await libroCobertura(
          anio: 2026, mes: 8, diasGracia: gracia, hoy: hoyFijo);
      expect(libro.filas.length, c(t, 'meta_c'));
    });
  });

  group('Mora: la columna Usuarios sale del mismo universo', () {
    Future<Map<String, Object?>> filaMora() async {
      final q = serieMoraPorCiclo(
          inicio: inicio, fin: fin, diasGracia: gracia, hoy: hoyFijo);
      final filas = await db.getAll(q.sql, q.parametros);
      return filas.first;
    }

    test('cada fila tiene tantos usuarios como cuotas, o menos', () async {
      final m = await filaMora();
      expect(c(m, 'mora_u'), lessThanOrEqualTo(c(m, 'mora_c')));
      expect(c(m, 'rec_u'), lessThanOrEqualTo(c(m, 'rec_c')));
      expect(c(m, 'pend_u'), lessThanOrEqualTo(c(m, 'pend_c')));
    });

    test('y las partes no pueden superar al total', () async {
      final m = await filaMora();
      // `rec` y `pend` PARTEN la mora por cuota; en personas pueden solaparse
      // (alguien con dos cuotas, una recuperada y otra no), así que la suma
      // puede pasarse — pero ninguna parte suelta puede superar al total.
      expect(c(m, 'rec_u'), lessThanOrEqualTo(c(m, 'mora_u')));
      expect(c(m, 'pend_u'), lessThanOrEqualTo(c(m, 'mora_u')));
    });
  });
}
