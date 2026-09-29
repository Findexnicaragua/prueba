@TestOn('vm')
library;

/// # Las cifras del Resumen NO cambiaron al optimizar
///
/// ## Por qué existe
///
/// El 2026-09-03 se cambiaron **140 expresiones SQL** en las consultas del
/// dashboard para que los índices se puedan usar:
///
///   · `date(p.fecha_pago)` → `p.fecha_cobro` — la columna nueva de la 0273,
///     que guarda el mismo día pero como fecha y no como instante;
///   · `date(cu.fecha_vencimiento)` → `cu.fecha_vencimiento` — esa columna
///     guarda `YYYY-MM-DD` sin hora en las **63.207 filas de producción**
///     (medido), así que la función no cambiaba nada y sólo impedía el índice.
///
/// Resultado medido a escala de Mairena: **9.546 ms → 2.234 ms** y las
/// recorridas completas de tabla de **23 a 1**.
///
/// **Pero son consultas de DINERO.** Que sean más rápidas no vale nada si
/// devuelven otro número. Este archivo es la condición de entrega: reconstruye
/// la versión VIEJA de cada consulta —volviendo a envolver las columnas— y
/// exige que las dos den **exactamente lo mismo**, columna por columna, sobre
/// una base con los 51.598 cuotas y 27.717 pagos de Mairena.
///
/// Si una sola cifra difiere en un centavo, esto falla.
///
/// Requiere `powersync_x64.dll` en la raíz del repo.

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_query.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;

const kTenant = 't-cifras';
const kCuotas = 51598;
const kPagos = 27717;
const kContratos = 4686;
const kClientes = 4888;

/// Deshace la optimización sobre el SQL: vuelve a envolver las columnas en
/// `date()`, que es exactamente como estaban las consultas antes del cambio.
///
/// Se hace por texto y no guardando una copia de las consultas viejas a
/// propósito: una copia se desactualiza y termina comparando la versión nueva
/// contra otra versión nueva — un test que se auto-aprueba.
String comoEstabaAntes(String sql) => sql
    // `replaceAllMapped` y no `replaceAll`: en Dart el reemplazo de
    // `replaceAll` es un LITERAL, no interpola `$1`. Con `replaceAll` esto
    // generaba `date($1.fecha_pago)` y todas las consultas reventaban — o sea
    // que el test fallaba sin haber comparado una sola cifra.
    .replaceAllMapped(RegExp(r'(\w+)\.fecha_cobro'),
        (m) => 'date(${m[1]}.fecha_pago)')
    .replaceAllMapped(RegExp(r'(?<![.\w])fecha_cobro'),
        (m) => 'date(fecha_pago)')
    // `fecha_vencimiento` sólo cuando NO es ya argumento de una función de
    // fecha: `date(x.fecha_vencimiento, '+…')` se deja como está.
    .replaceAllMapped(
        RegExp(r'(?<!date\()(\w+)\.fecha_vencimiento(?!\s*,)'),
        (m) => 'date(${m[1]}.fecha_vencimiento)');

void main() {
  String? core;
  for (final n in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    if (File(n).existsSync()) core = File(n).absolute.path;
  }
  if (core == null) {
    test('mismas_cifras (saltado: falta powersync-sqlite-core)', () {}, skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(core!));
  }

  late PowerSyncDatabase db;
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cifras_');
    db = PowerSyncDatabase(schema: schema, path: p.join(tmp.path, 'c.db'));
    await db.initialize();
    await _sembrar(db);
  });

  tearDownAll(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const ini = '2026-08-15';
  const fin = '2026-09-14';
  const hoy = '2026-09-03';
  const g = 10;

  final consultas = <String, ConsultaSql>{
    'resumenCobros': resumenCobros(inicio: ini, fin: fin, diasGracia: g),
    'desgloseRecuperado':
        desgloseRecuperado(inicio: ini, fin: fin, diasGracia: g),
    'serieCobrosDiaria': serieCobrosDiaria(inicio: ini, fin: fin),
    'serieMoraDiaria': serieMoraDiaria(inicio: ini, fin: fin, diasGracia: g),
    'resumenMora': resumenMora(inicio: ini, fin: fin, diasGracia: g, hoy: hoy),
    'serieRecaudoMora':
        serieRecaudoMora(inicio: ini, fin: fin, diasGracia: g, hoy: hoy),
    'serieMoraPorCiclo':
        serieMoraPorCiclo(inicio: ini, fin: fin, diasGracia: g, hoy: hoy),
    'desgloseMora': desgloseMora(inicio: ini, fin: fin, diasGracia: g, hoy: hoy),
    'moraHistorica': moraHistorica(ciclos: const [
      ('2026-06-15', '2026-07-14'),
      ('2026-07-15', '2026-08-14'),
      ('2026-08-15', '2026-09-14'),
    ], diasGracia: g, hoy: hoy),
  };

  group('la optimización no movió ni una cifra', () {
    consultas.forEach((nombre, c) {
      test('🔴 $nombre da lo mismo que antes', () async {
        final viejo = comoEstabaAntes(c.sql);

        // Si el texto no cambió, la comparación no está probando NADA: sería
        // la consulta nueva contra sí misma (regla 15b).
        expect(viejo, isNot(c.sql),
            reason: '$nombre: `comoEstabaAntes` no revirtió nada, así que este '
                'test se estaría comparando consigo mismo');

        final a = await db.getAll(viejo, c.parametros);
        final b = await db.getAll(c.sql, c.parametros);

        expect(b.length, a.length, reason: '$nombre: distinta cantidad de filas');
        for (var i = 0; i < a.length; i++) {
          for (final col in a[i].keys) {
            expect(b[i][col].toString(), a[i][col].toString(),
                reason: '$nombre · fila $i · columna "$col": '
                    'antes=${a[i][col]} ahora=${b[i][col]}');
          }
        }
        // Y que haya medido algo: una consulta que no devuelve filas no prueba
        // que las cifras coincidan (regla 16).
        expect(a, isNotEmpty, reason: '$nombre no devolvió ninguna fila');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  });
}

/// Una base del tamaño de Mairena, con `fecha_cobro` sembrada igual que en
/// producción (el server la deriva, el cliente la escribe — ver 0273).
///
/// Los pagos llevan **hora distinta de medianoche**, que es el caso donde la
/// optimización mal hecha perdería plata: en producción hay 7.833 filas así.
Future<void> _sembrar(PowerSyncDatabase db) async {
  await db.writeTransaction((tx) async {
    await tx.execute(
        "INSERT INTO planes (id, tenant_id, nombre, tipo, precio_mensual, "
        "activo) VALUES ('pl', ?, 'Combo', 'combo', 700, 1)", [kTenant]);
    for (var i = 0; i < kClientes; i++) {
      await tx.execute(
          'INSERT INTO clientes (id, tenant_id, codigo, nombre, activo) '
          'VALUES (?, ?, ?, ?, 1)', ['cl$i', kTenant, '$i', 'Cliente $i']);
    }
    for (var i = 0; i < kContratos; i++) {
      await tx.execute(
          'INSERT INTO contratos (id, tenant_id, cliente_id, codigo, plan_id, '
          "estado, dia_pago, fecha_inicio) "
          "VALUES (?, ?, ?, ?, 'pl', 'activo', 15, '2026-01-15')",
          ['ct$i', kTenant, 'cl${i % kClientes}', '$i']);
    }
    for (var i = 0; i < kCuotas; i++) {
      final m = 12 - (i % 11);
      final a = m > 9 ? 2025 : 2026;
      final mm = m.toString().padLeft(2, '0');
      final d = (i % 28 + 1).toString().padLeft(2, '0');
      await tx.execute(
          'INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, '
          'periodo, fecha_vencimiento, monto, monto_pagado, cargos_neto, '
          'estado) VALUES (?, ?, ?, ?, ?, ?, 700, ?, ?, ?)',
          ['cu$i', kTenant, 'ct${i % kContratos}', 'cl${i % kClientes}',
           '$a-$mm-01', '$a-$mm-$d', i % 3 == 0 ? 700 : 0,
           i % 7 == 0 ? 50 : 0, i % 3 == 0 ? 'pagada' : 'pendiente']);
    }
    for (var i = 0; i < kPagos; i++) {
      final m = 12 - (i % 11);
      final a = m > 9 ? 2025 : 2026;
      final mm = m.toString().padLeft(2, '0');
      final d = (i % 28 + 1).toString().padLeft(2, '0');
      // La HORA importa: es lo que separa una optimización correcta de una que
      // pierde los cobros del último día del ciclo.
      final h = (i % 24).toString().padLeft(2, '0');
      await tx.execute(
          'INSERT INTO pagos (id, tenant_id, cuota_id, cobrador_id, '
          'monto_cordobas, fecha_pago, fecha_cobro, anulado, en_revision) '
          'VALUES (?, ?, ?, ?, 700, ?, ?, 0, 0)',
          ['pa$i', kTenant, 'cu${(i * 3) % kCuotas}', 'cob',
           '$a-$mm-$d $h:30:00', '$a-$mm-$d']);
    }
    // ── COBROS EN MORA, sembrados a proposito ────────────────────────────
    // `serieMoraDiaria` y `serieRecaudoMora` solo devuelven filas cuando hay
    // cuotas cobradas DESPUES de su vencimiento + los dias de gracia. Sin
    // esto devolvian [] y la comparacion vieja-contra-nueva no probaba nada:
    // dos vacios siempre son iguales (regla 16 del checklist).
    //
    // La ventana del test filtra por el VENCIMIENTO de la cuota (15-ago a
    // 14-sep), no por la fecha del pago. Asi que vencen el 20 de agosto y se
    // cobran en septiembre: 16 dias o mas despues, por encima de los 10 de
    // gracia, con la cuota dentro de la ventana.
    for (var i = 0; i < 500; i++) {
      // dias 01..12 de septiembre: todos > 20-ago + 10 de gracia (30-ago).
      final d = (i % 12 + 1).toString().padLeft(2, '0');
      await tx.execute(
          'INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, '
          'periodo, fecha_vencimiento, monto, monto_pagado, cargos_neto, '
          "estado) VALUES (?, ?, ?, ?, '2026-08-01', '2026-08-20', 700, 700, "
          "0, 'pagada')",
          ['mora-cu$i', kTenant, 'ct${i % kContratos}', 'cl${i % kClientes}']);
      await tx.execute(
          'INSERT INTO pagos (id, tenant_id, cuota_id, cobrador_id, '
          'monto_cordobas, fecha_pago, fecha_cobro, anulado, en_revision) '
          "VALUES (?, ?, ?, 'cob', 700, ?, ?, 0, 0)",
          ['mora-pa$i', kTenant, 'mora-cu$i',
           '2026-09-$d 14:30:00', '2026-09-$d']);
    }
  });
}
