@TestOn('vm')
library;

/// El archivo que se baja del Resumen, construido de verdad y leído de vuelta.
///
/// Por qué existe: los dos bugs que reportó el dueño —el archivo bajaba sin
/// extensión y la columna Contrato salía toda en guiones— no los cazaba nada.
/// Las consultas estaban bien y los tests de números pasaban; lo que fallaba
/// era el ARMADO del archivo, que hasta ahora ningún test tocaba. Acá se
/// generan los bytes reales del `.xlsx`, se vuelven a abrir y se leen las
/// celdas: si Excel va a mostrar un guion, el test lo ve primero.
///
/// Requiere `powersync_x64.dll` en la raíz del repo. Sin él, se SALTA.

import 'dart:ffi';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:isp_billing/data/utils/periodo_dashboard.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_export.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_query.dart';
import 'package:isp_billing/powersync/db.dart' as ps;
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

import 'escenario_seed.dart';

/// El ciclo en curso del escenario: 15 jul – 14 ago 2026.
const anio = 2026;
const mes = 8;
const gracia = 7;

/// El corte fijo: sin el, el detalle por mora del Excel cambiaria segun el dia
/// en que se corra el test.
const hoyCorte = '2026-08-13';

/// El día de corte, FIJO — ver la nota en `dashboard_numeros_test.dart`.
const hoyFijo = '2026-08-12';

void main() {
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('dashboard_export (saltado: falta powersync-sqlite-core)', () {},
        skip: true);
    return;
  }
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();
  late Directory tmpDir;

  // Los nombres de ciclo ('Agosto 2026') salen de `Fmt.mes`, que necesita el
  // locale cargado — igual que en la app.
  setUpAll(() => initializeDateFormatting('es_NI', null));

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('dash_export_');
    // El export lee de `ps.db`, el mismo global que usa la app.
    ps.db = PowerSyncDatabase(
        schema: schema, path: p.join(tmpDir.path, '${uuid.v4()}.db'));
    await ps.db.initialize();
    await sembrarEscenario(ps.db);
  });

  tearDown(() async {
    await ps.db.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  test('el nombre del archivo lleva .xlsx', () async {
    // Windows abre por extensión: sin el `.xlsx` el archivo baja como un
    // documento sin tipo y hay que renombrarlo a mano para verlo.
    final cobertura = await libroCobertura(
        anio: anio, mes: mes, diasGracia: gracia, hoy: hoyCorte);
    expect(cobertura.fileName, endsWith('.xlsx'));

    final mora = await libroMora(
        anio: anio, mes: mes, ciclos: 6, diasGracia: gracia, hoy: hoyFijo);
    expect(mora.fileName, endsWith('.xlsx'));

    // Y el punto tiene que ser UNO SOLO: `guardarArchivo` mete la fecha antes
    // del último punto, así que un nombre con puntos de más la mete en el
    // lugar equivocado y la extensión queda partida.
    expect('.'.allMatches(cobertura.fileName).length, 1);
    expect('.'.allMatches(mora.fileName).length, 1);
  });

  test('la columna Contrato trae el código, no un guion', () async {
    final libro = await libroCobertura(
        anio: anio, mes: mes, diasGracia: gracia, hoy: hoyCorte);
    final hoja = _abrir(libro.bytes(), 'Detalle');
    final col = hoja.headers.indexOf('Contrato');
    expect(col, greaterThanOrEqualTo(0),
        reason: 'la columna tiene que existir');

    final contratos = [for (final f in hoja.filas) f[col]];
    // ignore: avoid_print
    print('\n== Columna Contrato del ciclo ${periodoDelCiclo()} ==\n'
        '${contratos.join(' · ')}');

    // El bug era éste: TODAS en guion, porque la consulta leía `codigo` y en
    // el tenant de prueba ningún contrato lo tenía. Con el respaldo al id, el
    // guion pasa a significar una sola cosa.
    expect(contratos.where((c) => c != '—'), isNotEmpty,
        reason: 'si todas salen en guion la columna no sirve para nada');

    // El guion queda reservado a las cuotas que no cuelgan de ningún contrato
    // (los cobros puntuales): es lo que explica que una persona aparezca dos
    // veces en el mismo ciclo.
    final tipo = hoja.headers.indexOf('Tipo');
    for (var i = 0; i < hoja.filas.length; i++) {
      final esPuntual = hoja.filas[i][tipo] == 'cobro puntual';
      expect(contratos[i] == '—', esPuntual,
          reason: 'fila $i (${hoja.filas[i][tipo]}): el guion es SOLO para los '
              'cobros puntuales');
    }
  });

  test('la columna Cuándo entró suma el Recuperado de la tarjeta',
      () async {
    // El enganche que pidió el dueño (2026-08-27): el archivo se agrupa por
    // cuándo entró la plata —antes / en el ciclo / después— y esos tres tienen
    // que dar, sumados, la fila "Recuperado". Son ademas, uno a uno, las tres
    // partes de la curva: la altura en que arranca, lo que sube, y el salto del
    // ultimo punto. Si esto se cae, las tres superficies dejan de hablarse.
    final libro = await libroCobertura(
        anio: anio, mes: mes, diasGracia: gracia, hoy: hoyCorte);
    final hoja = _abrir(libro.bytes(), 'Detalle');

    final cCuando = hoja.headers.indexOf('Cuándo entró');
    final cEntro = hoja.headers.indexOf('Recuperado (entró)');
    expect(cCuando, isNot(-1), reason: 'la columna que agrupa tiene que existir');

    double sumarDe(Set<String> cuandos) => hoja.filas
        .where((f) => cuandos.contains('${f[cCuando]}'))
        .fold<double>(0, (a, f) => a + (double.tryParse('${f[cEntro]}') ?? 0));

    final q = resumenCobros(
        inicio: '2026-07-15', fin: '2026-08-15', diasGracia: gracia);
    final r = (await ps.db.getAll(q.sql, q.parametros)).first;

    expect(
        sumarDe({'antes del ciclo', 'en el ciclo', 'después del ciclo'}),
        closeTo((r['rec_m'] as num).toDouble(), 0.01),
        reason: 'los tres momentos suman el Recuperado de la tarjeta');

    // Y las que no recibieron nada no aportan un peso.
    expect(sumarDe({'—'}), closeTo(0, 0.01),
        reason: 'el bloque "sin ningún pago" no puede tener plata');
  });

  // LA PREGUNTA DEL DUENO (2026-09-01): *"los Excel reflejan y concuerdan con
  // la informacion de las graficas?"*.
  //
  // Para lo que ya existia habia tests. Para la MORA que se agrego ese mismo
  // dia —la fila "venian de mora" adentro de cada momento— no habia ninguno, y
  // el dato en el archivo no esta como columna propia: sale de cruzar
  // "Cuando entro" con "Dias". Si ese cruce no da lo mismo que la tarjeta, el
  // archivo dice otra cosa que la pantalla y no hay forma de saber cual creer.
  test('la mora del archivo da lo mismo que la fila de la tarjeta', () async {
    final libro = await libroCobertura(
        anio: anio, mes: mes, diasGracia: gracia, hoy: hoyCorte);
    final hoja = _abrir(libro.bytes(), 'Detalle');

    final cDias = hoja.headers.indexOf('Días');
    final cFila = hoja.headers.indexOf('Fila de la tarjeta');
    expect(cDias, isNot(-1), reason: 'la columna que clasifica el atraso');
    expect(cFila, isNot(-1));

    // "tarde" es la palabra con la que `_diasLabel` marca lo que entro pasada
    // la gracia — el MISMO corte que usa la tarjeta.
    final tardeYSaldadas = hoja.filas.where((f) =>
        '${f[cDias]}'.contains('tarde') &&
        '${f[cFila]}'.contains('Recuperado'));

    final q = cortesDelCiclo(
        inicio: '2026-07-15',
        fin: '2026-08-15',
        diasGracia: gracia,
        hoy: hoyCorte);
    final cortes = (await ps.db.getAll(q.sql, q.parametros)).first;

    // ignore: avoid_print
    print('\n== Mora: archivo vs tarjeta ==\n'
        'archivo: ${tardeYSaldadas.length} filas\n'
        'tarjeta: ${cortes['cm_c']} cuotas');

    expect(tardeYSaldadas.length, (cortes['cm_c'] as num).toInt(),
        reason: 'las filas del archivo marcadas "tarde" y saldadas tienen que '
            'ser las mismas que la tarjeta cuenta en "venian de mora"');
    expect(tardeYSaldadas.length, greaterThan(0),
        reason: 'sin una sola cuota en mora el test no compara nada');
  });

  // LAS COLUMNAS QUE PIDIO EL DUENO (2026-09-01) para poder seguir una cuota
  // cobrada fuera de su ciclo: el recibo, la fecha de cobro y EN QUE CICLO
  // cayo ese cobro.
  //
  // El caso que lo trajo: dos cuotas que vencen el 10 y el 14 de agosto y se
  // cobraron el 16 — o sea dentro del ciclo SIGUIENTE. En la tarjeta salen
  // como "despues del ciclo", que dice que fue despues pero no de que ni
  // cuando.
  test('el Detalle identifica el cobro: recibo, fecha y ciclo', () async {
    final libro = await libroCobertura(
        anio: anio, mes: mes, diasGracia: gracia, hoy: hoyCorte);
    final hoja = _abrir(libro.bytes(), 'Detalle');

    for (final c in const ['Recibo', 'Fecha de cobro', 'Ciclo del cobro']) {
      expect(hoja.headers, contains(c), reason: 'falta la columna "$c"');
    }
    // Y la vieja no puede seguir viva: el mismo dato con dos nombres es
    // exactamente lo que hizo preguntar al dueno que significaba.
    expect(hoja.headers, isNot(contains('Último pago')));

    final cRec = hoja.headers.indexOf('Recibo');
    final cFec = hoja.headers.indexOf('Fecha de cobro');
    final cCic = hoja.headers.indexOf('Ciclo del cobro');
    final cCua = hoja.headers.indexOf('Cuándo entró');

    // Las filas cobradas DESPUES del ciclo: su columna de ciclo tiene que
    // nombrar al ciclo siguiente, no al de la hoja.
    final despues = hoja.filas
        .where((f) => '${f[cCua]}' == 'después del ciclo')
        .toList();
    expect(despues, isNotEmpty,
        reason: 'el escenario tiene que traer alguna cobrada despues, si no '
            'este test no prueba lo que vino a probar');

    for (final f in despues) {
      // ignore: avoid_print
      print('  recibo=${f[cRec]}  cobro=${f[cFec]}  ciclo=${f[cCic]}');
      expect('${f[cCic]}', contains('Septiembre 2026'),
          reason: 'una cuota del ciclo de agosto cobrada despues cayo en el '
              'ciclo de septiembre, y la columna tiene que decirlo con nombre');
      expect('${f[cCic]}', contains('15 ago'),
          reason: 'y con el rango entre parentesis, como el rotulo de la '
              'tarjeta');
      expect('${f[cRec]}'.trim(), isNotEmpty,
          reason: 'toda cuota cobrada tiene recibo — medido en produccion: '
              '32.609 de 32.609');
    }
  });

  // El ciclo de la columna NO se puede calcular por las suyas: tiene que salir
  // de la misma funcion que el selector de la tarjeta, o el archivo diria un
  // ciclo y la pantalla otro para la misma fecha.
  test('el ciclo del cobro usa el mismo corte que la tarjeta', () async {
    final libro = await libroCobertura(
        anio: anio, mes: mes, diasGracia: gracia, hoy: hoyCorte);
    final hoja = _abrir(libro.bytes(), 'Detalle');
    final cFec = hoja.headers.indexOf('Fecha de cobro');
    final cCic = hoja.headers.indexOf('Ciclo del cobro');

    var comparadas = 0;
    for (final f in hoja.filas) {
      final fecha = DateTime.tryParse('${f[cFec]}');
      if (fecha == null) continue;
      final p = periodoDe(fecha);
      expect('${f[cCic]}', contains(periodoLabel(p.year, p.month)),
          reason: 'la fecha ${f[cFec]} cae en ${periodoLabel(p.year, p.month)} '
              'segun `periodoDe`, y la columna dice "${f[cCic]}"');
      comparadas++;
    }
    expect(comparadas, greaterThan(3),
        reason: 'muy pocas filas con fecha para que el test valga');
  });

  test('las filas del archivo reconcilian con las de la tarjeta', () async {
    // La red del cambio del 2026-08-27: el archivo se parte por COMO se cobro
    // —a tiempo / tarde / por recuperar— y esos tres tienen que ser el desglose
    // EXACTO de la tarjeta. Los dos primeros suman su fila "Recuperado"; el
    // tercero ES su fila "Por recuperar". Si un dia se toca `_baldeDe` y deja
    // de ser una particion, esto se cae.
    final libro = await libroCobertura(
        anio: anio, mes: mes, diasGracia: gracia, hoy: hoyCorte);
    final hoja = _abrir(libro.bytes(), 'Detalle');

    final q = resumenCobros(
        inicio: '2026-07-15', fin: '2026-08-15', diasGracia: gracia);
    final r = (await ps.db.getAll(q.sql, q.parametros)).first;

    // Cada cuota cae en UN bloque: la suma de los tres es el total de filas.
    final porRecuperar = (r['porrec_c'] as num).toInt();
    final recuperadas = (r['meta_c'] as num).toInt() - porRecuperar;
    expect(hoja.filas.length, recuperadas + porRecuperar,
        reason: 'los tres bloques son una PARTICION: ninguna cuota se repite '
            'ni se pierde');

    // Y la columna Días existe, que es lo que el archivo gano en este cambio.
    expect(hoja.headers, contains('Días'),
        reason: 'sin ella no hay forma de ver un pago adelantado');

    // Las cuatro columnas del cruce por mora se retiraron: el bloque las dice.
    for (final vieja in const [
      'Sin mora · entró',
      'Sin mora · falta',
      'En mora · entró',
      'En mora · falta',
    ]) {
      expect(hoja.headers, isNot(contains(vieja)),
          reason: 'el cruce por mora se fue a los bloques: $vieja');
    }
  });

  test('el total del archivo es el mismo número de la tarjeta', () async {
    // La razón de ser del export: bajar el detalle, sumar la columna y que dé
    // igual que la pantalla. Si difieren, uno de los dos miente.
    final libro = await libroCobertura(
        anio: anio, mes: mes, diasGracia: gracia, hoy: hoyCorte);
    final hoja = _abrir(libro.bytes(), 'Detalle');

    double sumar(String header) {
      final c = hoja.headers.indexOf(header);
      return hoja.filas
          .fold<double>(0, (a, f) => a + (double.tryParse('${f[c]}') ?? 0));
    }

    final q = resumenCobros(
        inicio: '2026-07-15', fin: '2026-08-15', diasGracia: gracia);
    final r = (await ps.db.getAll(q.sql, q.parametros)).first;

    // Los nombres de columna son los de la TARJETA desde 2026-08-27: el Excel
    // decia Facturado / Entro / Falta y la pantalla Cobros / Recuperado / Por
    // recuperar, y quien bajaba el archivo para cuadrar tenia que traducir.
    expect(sumar('Cobros (facturado)'),
        closeTo((r['meta_m'] as num).toDouble(), 0.01),
        reason: 'lo facturado del detalle = la fila Cobros');
    expect(sumar('Por recuperar (falta)'),
        closeTo((r['porrec_m'] as num).toDouble(), 0.01),
        reason: 'lo que falta del detalle = la fila Por recuperar');
    expect(hoja.filas.length, r['meta_c'],
        reason: 'una fila por cuota contada en la tarjeta');
  });

  test('la mora va AGRUPADA por ciclo, con subtotal y columnas de trazabilidad',
      () async {
    // El dueno la quiere agrupada: "en el excel me gustaria que esten
    // agrupados por ciclo y cada ciclo me muestre sus respectivos totales"
    // (2026-08-28). Los bloques conviven con las columnas `Fila de la tarjeta`
    // y `Detalle`, que son las que dejan reconstruir cualquier numero de la
    // pantalla fila por fila — sin ellas, los bloques obligaban a sumar
    // subtotales a mano, que fue el reclamo original.
    final libro = await libroMora(
        anio: anio, mes: mes, ciclos: 6, diasGracia: gracia, hoy: hoyFijo);
    final hoja = _abrir(libro.bytes(), 'Mora por ciclo');

    expect(hoja.headers.first, 'Ciclo');
    expect(hoja.headers, contains('Fila de la tarjeta'));
    expect(hoja.headers, contains('Detalle'));

    final primera = (List<Object?> f) => f.isEmpty ? '' : '${f.first ?? ''}';

    // `contains('ciclo')` a secas y no un separador exacto: el titulo lleva
    // doble espacio alrededor del punto medio y buscar '· ciclo ' con UN
    // espacio no matcheaba nada — el test pasaba a rojo por el filtro, no por
    // el archivo.
    final bloques = hoja.crudo
        .map(primera)
        .where((t) => t.toLowerCase().contains('ciclo '))
        .toList();
    // ignore: avoid_print
    print('\n== Bloques del archivo de mora ==\n${bloques.join('\n')}');
    expect(bloques.length, 6, reason: 'un bloque por cada ciclo de las barras');

    final subtotales =
        hoja.crudo.map(primera).where((t) => t.startsWith('Subtotal')).toList();
    expect(subtotales, isNotEmpty, reason: 'cada bloque cierra con su total');
    expect(subtotales.length, lessThanOrEqualTo(6),
        reason: 'nunca mas de uno por ciclo');

    final total = hoja.crudo.map(primera).where((t) => t.startsWith('TOTAL'));
    expect(total.length, 1, reason: 'un gran total al final, no uno por ciclo');

    // El subtotal tiene que tener TANTAS celdas como el encabezado: si le
    // faltan, Excel corre los montos y dejan de caer bajo su columna.
    for (final f in hoja.crudo) {
      if (primera(f).startsWith('Subtotal') || primera(f).startsWith('TOTAL')) {
        expect(f.length, hoja.headers.length,
            reason: 'la fila de cierre "${primera(f)}" no alinea con el header');
      }
    }
  });

  test('el detalle de mora suma EXACTO lo que dice la tarjeta', () async {
    // El reclamo que motivó todo esto: el Excel decía 22.150/18.265 donde la
    // gráfica decía 21.950/18.065. No era un error de cálculo — el Excel traía
    // las columnas de COBERTURA (lo facturado, lo cobrado) sobre una tabla de
    // MORA (lo que cayó en atraso). Un abono hecho DENTRO de la gracia entra en
    // las primeras y no en las segundas, así que jamás iban a coincidir.
    final libro = await libroMora(
        anio: anio, mes: mes, ciclos: 6, diasGracia: gracia, hoy: hoyFijo);
    final hoja = _abrir(libro.bytes(), 'Mora por ciclo');

    double sumar(String header) {
      final c = hoja.headers.indexOf(header);
      expect(c, greaterThanOrEqualTo(0), reason: 'falta la columna $header');
      return hoja.filas
          .fold<double>(0, (a, f) => a + (double.tryParse('${f[c]}') ?? 0));
    }

    // La tarjeta, sobre la MISMA ventana de 6 ciclos y el MISMO día de corte.
    final q = resumenMora(
        inicio: '2026-02-15',
        fin: '2026-08-15',
        diasGracia: gracia,
        hoy: hoyFijo);
    final r = (await ps.db.getAll(q.sql, q.parametros)).first;

    // ignore: avoid_print
    print('\n== Detalle de mora vs tarjeta ==\n'
        'Total mora     Excel ${sumar('En mora')}  ·  tarjeta ${r['meta_m']}\n'
        'Recuperado     Excel ${sumar('Recuperado tarde')}  ·  '
        'tarjeta ${r['rec_m']}\n'
        'Por recuperar  Excel ${sumar('Sigue impago')}  ·  '
        'tarjeta ${r['porrec_m']}');

    expect(sumar('En mora'), closeTo((r['meta_m'] as num).toDouble(), 0.01),
        reason: 'la columna En mora tiene que dar el Total mora de la tarjeta');
    expect(sumar('Recuperado tarde'),
        closeTo((r['rec_m'] as num).toDouble(), 0.01));
    expect(sumar('Sigue impago'),
        closeTo((r['porrec_m'] as num).toDouble(), 0.01));
    expect(hoja.filas.length, r['meta_c'], reason: 'una fila por cuota');

    // Y las tres cierran entre sí: es lo que hace que la tarjeta no se
    // contradiga a sí misma.
    expect(sumar('Recuperado tarde') + sumar('Sigue impago'),
        closeTo(sumar('En mora'), 0.01));

    // Las de contexto NO son parte de la mora, y tienen que diferir — si
    // dieran igual, este escenario no estaría ejercitando el caso que rompió.
    expect(sumar('Facturado'), greaterThan(sumar('En mora')),
        reason: 'alguien abonó dentro de la gracia; sin ese caso el test '
            'pasaría sin probar nada');
    expect(sumar('Facturado') - sumar('Pagado a tiempo'),
        closeTo(sumar('En mora'), 0.01));
  });
}

String periodoDelCiclo() => '15 jul – 14 ago 2026';

/// Una hoja del archivo ya generado, con su fila de encabezados ubicada.
class _Hoja {
  _Hoja(this.crudo, this.headers, this.filas);
  final List<List<Object?>> crudo;
  final List<String> headers;
  final List<List<Object?>> filas;
}

/// Abre los bytes como Excel de verdad y devuelve la hoja pedida.
///
/// Busca la fila de encabezados en vez de asumir en qué renglón cae: arriba
/// van el nombre de la empresa, el título y el período, y esa cantidad cambia.
_Hoja _abrir(List<int> bytes, String nombre) {
  final excel = Excel.decodeBytes(bytes);
  expect(excel.tables.keys, contains(nombre));
  final crudo = [
    for (final fila in excel.tables[nombre]!.rows)
      [for (final c in fila) c?.value?.toString()],
  ];
  final iHead = crudo.indexWhere((f) => f.contains('Contrato'));
  expect(iHead, greaterThanOrEqualTo(0), reason: 'no hay fila de encabezados');
  final headers = [for (final h in crudo[iHead]) h ?? ''];

  // Datos = lo de abajo, sin las filas en blanco, los encabezados de sección
  // ni las de cierre (subtotales y total).
  final filas = <List<Object?>>[];
  for (final f in crudo.skip(iHead + 1)) {
    final primera = f.isEmpty ? '' : f.first ?? '';
    if (primera.isEmpty) continue;
    if (primera.startsWith('Subtotal') || primera.startsWith('TOTAL')) continue;
    if (primera.contains('· ciclo ') || primera.contains('·  ciclo')) continue;
    // Titulo de seccion: una sola celda con texto y el resto vacio. Los de
    // Cobertura ('CUOTAS DE CONTRATO · 14 cuotas') no traen '· ciclo', asi
    // que sin esto se contaban como filas de datos.
    if (f.where((c) => c != null && '$c'.isNotEmpty).length <= 1) continue;
    if (f.contains('Contrato')) continue; // encabezado repetido por sección
    filas.add(f);
  }
  return _Hoja(crudo, headers, filas);
}

String? _resolveCorePath() {
  for (final n in ['powersync_x64.dll', 'libpowersync_x64.so']) {
    final f = File(p.join(Directory.current.path, n));
    if (f.existsSync()) return f.path;
  }
  return null;
}
