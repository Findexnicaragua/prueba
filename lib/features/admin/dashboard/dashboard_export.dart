/// Export a Excel del detalle que hay DETRÁS de las tarjetas del Resumen.
///
/// Por qué existe: las tarjetas muestran totales, y cuando un total no cierra
/// con lo que el dueño espera no hay forma de abrirlo. Con el archivo, se baja
/// el detalle, se suma la columna y se compara. Si no da igual que la pantalla
/// es un bug — y no hay que adivinar cuál de los dos está bien.
///
/// La regla que lo hace útil: **el archivo trae EXACTAMENTE las cuotas que la
/// tarjeta cuenta**, sobre el período que el usuario tenga elegido. Usa las
/// mismas consultas (`dashboard_query.dart`) que alimentan la tarjeta, y hay un
/// test que suma el detalle y lo compara contra el resumen.
library;

import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import '../../../powersync/db.dart' as ps;
import '../reportes/excel/reporte_excel.dart';
import 'dashboard_query.dart';

/// Las columnas de plata de un detalle: (título en el Excel, clave que devuelve
/// la consulta). Los encabezados, las filas y los subtotales se derivan TODOS
/// de esta lista, así que no se pueden desalinear entre sí — con 12 columnas,
/// mantener tres listas paralelas a mano es un error esperando.
typedef _Monto = (String, String);

const List<_Monto> _montosCobertura = [
  // Los MISMOS nombres que la tarjeta, con lo que miden entre parentesis. El
  // Excel decia Facturado / Entro / Falta y la pantalla Cobros / Recuperado /
  // Por recuperar: quien baja el archivo para cuadrar tiene que traducir de
  // memoria cual es cual.
  ('Cobros (facturado)', 'facturado'),
  ('Recuperado (entró)', 'pagado'),
  ('Por recuperar (falta)', 'falta'),
  // Las CUATRO columnas del cruce por mora (Sin mora·entró, Sin mora·falta,
  // En mora·entró, En mora·falta) se retiraron el 2026-08-27: el archivo pasa a
  // estar partido en BLOQUES por como se cobro, y el bloque dice lo mismo que
  // decian esas columnas, sin obligar a leer siete montos por fila.
  //
  // Lo unico que un bloque no puede representar es una cuota cobrada EN PARTE
  // dentro de la gracia y EN PARTE despues. Medido antes de sacarlas: CERO
  // casos en los tres tenants. Si algun dia aparece, esa cuota cae en
  // "cobradas tarde" (que es la lectura conservadora) y su detalle fino queda
  // solo en el historial de pagos del cliente.
  //
  // `cobrado_a_tiempo`, `cobrado_en_mora`, `impago_en_mora` y `en_fecha` SIGUEN
  // saliendo de la consulta: `_baldeDe` los usa para decidir en que bloque cae
  // cada fila. Lo que se fue es mostrarlos como columna.
];

/// Las de la hoja "Excluidas": las anuladas NO llevan el corte por mora. No
/// cuentan en ninguna tarjeta, y ponérselas invitaba a sumarlas con el resto.
const List<_Monto> _montosAnuladas = [
  ('Facturado', 'facturado'),
  ('Pagado', 'pagado'),
  ('Falta', 'falta'),
];

/// Las de mora. Las tres últimas son las de la tarjeta —y su subtotal da igual
/// que ella—; `Facturado` y `Pagado a tiempo` van adelante como contexto, para
/// que se vea de dónde sale la diferencia. Sin ellas, la fila de quien abonó
/// dentro de la gracia queda sin explicación.

List<String> _headers(List<_Monto> montos, {bool conDias = false}) => [
      'Cliente',
      'Nombre',
      'Contrato',
      'Tipo',
      // El identificador del COBRO. Pedido del dueño (2026-09-01) junto con la
      // fecha: quería poder señalar una fila y saber exactamente qué cobro es.
      //
      // Va bajo `conDias` —o sea sólo en el Detalle de Cobertura— porque la
      // otra hoja que usa este armador es "Excluidas", de cuotas ANULADAS: ahí
      // casi nunca hay cobro y serían dos columnas vacías.
      if (conDias) 'Recibo',
      'Vence',
      for (final m in montos) m.$1,
      'Estado',
      // Se llamaba "Último pago" y el dueño preguntó qué significaba. Siempre
      // fue esto: ninguna de las 32.609 cuotas cobradas tiene más de un pago.
      'Fecha de cobro',
      // El ciclo en el que CAYÓ ese cobro, con nombre y rango:
      // "Septiembre 2026 (15 ago – 14 sep)". Es la columna que contesta la
      // pregunta que trajo el dueño — dos cuotas de agosto cobradas el 16 de
      // agosto, o sea dentro del ciclo siguiente, y no había forma de verlo.
      //
      // Convive con "Cuándo entró", que dice lo mismo en RELATIVO (antes / en
      // / después del ciclo). El relativo dice que fue después; éste dice
      // después de QUÉ y cuándo.
      if (conDias) 'Ciclo del cobro',
      if (conDias) 'Días',
      if (conDias) 'Cuándo entró',
      if (conDias) 'Fila de la tarjeta',
    ];

/// En qué ciclo cayó una fecha de cobro, con nombre y rango.
///
/// Sale de `periodoDe`, la MISMA función que usa el selector de la tarjeta,
/// así que el texto de la columna es idéntico al del rótulo azul de la
/// pantalla. Si divergieran, el archivo diría un ciclo y la app otro.
String _cicloDelCobro(String? fechaCobro) {
  if (fechaCobro == null || fechaCobro.isEmpty) return '';
  final d = DateTime.tryParse(fechaCobro);
  if (d == null) return '';
  final p = periodoDe(d);
  return '${_nombreCiclo(p.year, p.month)} '
      '(${periodoLabel(p.year, p.month)})';
}

/// Cuantos dias pasaron entre que la cuota VENCIO y que se pago, dicho en
/// palabras. Nace del caso que trajo el dueno: una cuota que vencia el 18 y se
/// pago el 11 aparecia en el ciclo y no habia forma de saber, mirando el
/// archivo, que se habia pagado adelantada — habia que restar dos fechas de
/// cabeza, fila por fila.
///
/// Positivo = pago ANTES de vencer. Negativo = despues. Se distingue "en
/// gracia" de "tarde" con los mismos dias que usa la tarjeta, asi que las dos
/// superficies clasifican igual.
String _diasLabel(Map<String, dynamic> r, int diasGracia) {
  final vence = r['vence'] as String?;
  final pago = r['fecha_cobro'] as String?;
  if (vence == null || pago == null) return '—';
  final v = DateTime.tryParse(vence);
  final p = DateTime.tryParse(pago);
  if (v == null || p == null) return '—';
  final d = v.difference(p).inDays;
  if (d > 0) return '+$d adelantado';
  if (d == 0) return 'el día que vencía';
  final atraso = -d;
  return atraso <= diasGracia ? '−$atraso en gracia' : '−$atraso tarde';
}

/// Convierte una fila de la consulta en una fila del Excel. Los montos van como
/// `double` para que Excel los sume; el resto como texto.
List<Object?> _fila(Map<String, dynamic> r, List<_Monto> montos,
        {int? diasGracia, _Cuando? cuando}) =>
    [
      r['cliente_codigo'] ?? '',
      r['cliente_nombre'] ?? '',
      // Los cobros puntuales no cuelgan de ningún contrato — por eso no
      // aparecen en su pantalla. El guion lo hace explícito.
      r['contrato'] ?? '—',
      r['tipo'] ?? '',
      if (diasGracia != null) r['recibo'] ?? '',
      r['vence'] ?? '',
      for (final m in montos) ((r[m.$2] as num?) ?? 0).toDouble(),
      r['estado'] ?? '',
      r['fecha_cobro'] ?? '',
      if (diasGracia != null) _cicloDelCobro(r['fecha_cobro'] as String?),
      if (diasGracia != null) _diasLabel(r, diasGracia),
      if (diasGracia != null) _cuandoLabel(cuando ?? _Cuando.sinPago),
      // La fila de la TARJETA a la que pertenece esta cuota. Es la columna que
      // hace que el archivo cuadre con la pantalla: filtrando por ella salen
      // 29 y 28 exactos. Agrupar por "cuando entro" —como estuvo un dia— daba
      // 27 y no habia forma de llegar al 29, porque son preguntas distintas.
      if (diasGracia != null)
        (((r['falta'] as num?) ?? 0) > 0.009 ? 'Por recuperar' : 'Recuperado'),
    ];

List<Object?> _cierre(
  String etiqueta,
  List<Map<String, dynamic>> filas,
  List<_Monto> montos, {
  bool conDias = false,
}) =>
    [
      '$etiqueta · ${filas.length} cuotas',
      // Nombre · Contrato · Tipo · [Recibo] · Vence — hasta la primera columna
      // de plata. El `Recibo` sólo existe en el Detalle (`conDias`), así que su
      // hueco tambien es condicional: sin eso, la hoja "Excluidas" quedaba con
      // una celda de mas.
      '',
      '',
      '',
      if (conDias) '',
      '',
      for (final m in montos)
        filas.fold<double>(
            0, (a, r) => a + ((r[m.$2] as num?) ?? 0).toDouble()),
      // Estado · Fecha de cobro.
      '',
      '',
      // La fila de subtotal tiene que tener TANTAS celdas como el encabezado:
      // si el header gana una columna y esta no, Excel corre el subtotal y
      // deja de alinear. Lo verifica `LibroExcel.desparejas()` — que encontro
      // ESTE mismo error el 2026-09-01, cuando se agregaron `Recibo` y
      // `Ciclo del cobro` y el TOTAL quedo con 13 celdas para 15 columnas.
      //
      // Ciclo del cobro · Días · Cuándo entró · Fila de la tarjeta.
      if (conDias) '',
      if (conDias) '',
      if (conDias) '',
      if (conDias) '',
    ];

/// Los cuatro bloques del archivo de Cobertura. Espejan EXACTO la tabla de la
/// tarjeta y la forma de su curva (2026-08-27):
///
///   antes   -> la plata entro ANTES de que abriera el ciclo (pago adelantado
///              desde un ciclo anterior). Es la altura en la que arranca la curva.
///   dentro  -> entro durante el ciclo. Es lo que la curva sube.
///   despues -> entro DESPUES de que cerro (pago muy atrasado, desde un ciclo
///              siguiente). Es el salto del ultimo punto.
///   sinPago -> nunca recibio un peso.
///
/// El subtotal de "Recuperado (entró)" de cada uno de los tres primeros da,
/// respectivamente, las tres sub-filas de la tarjeta. Ese es el enganche que
/// pidio el dueno entre tabla, grafica y archivo.
///
/// Se clasifica por `ultimo_pago` y es exacto: medido antes de hacerlo, CERO
/// cuotas de los tres tenants tienen pagos en mas de uno de estos momentos.
enum _Cuando { antes, dentro, despues, sinPago }

_Cuando _cuandoEntro(Map<String, dynamic> r, String inicio, String fin) {
  final pago = r['fecha_cobro'] as String?;
  if (pago == null || pago.isEmpty) return _Cuando.sinPago;
  if (pago.compareTo(inicio) < 0) return _Cuando.antes;
  if (pago.compareTo(fin) >= 0) return _Cuando.despues;
  return _Cuando.dentro;
}

String _cuandoLabel(_Cuando c) => switch (c) {
      _Cuando.antes => 'antes del ciclo',
      _Cuando.dentro => 'en el ciclo',
      _Cuando.despues => 'después del ciclo',
      _Cuando.sinPago => '—',
    };

/// "Agosto 2026". `Fmt.mes` es `MMMM y`: YA trae el año, así que agregarle
/// `$anio` al lado lo duplicaba ("Agosto 2026 2026", y el archivo salía
/// `cobertura-agosto 2026-2026.xlsx`).
String _nombreCiclo(int anio, int mes) {
  final m = Fmt.mes(DateTime(anio, mes));
  return '${m[0].toUpperCase()}${m.substring(1)}';
}

/// Lo mismo, apto para nombre de archivo: sin espacios ni mayúsculas.
String _slugCiclo(int anio, int mes) =>
    _nombreCiclo(anio, mes).toLowerCase().replaceAll(' ', '-');

/// El libro ya armado, ANTES de guardarlo.
///
/// Existe separado de la descarga por una sola razón: el diálogo de guardado es
/// del sistema operativo y no corre en un test. Con el libro aparte, el test
/// construye los bytes de verdad y los vuelve a leer, así que verifica lo que
/// el dueño va a abrir en Excel — nombre del archivo incluido — y no una
/// aproximación. (Los dos bugs que reportó, la extensión que faltaba y la
/// columna Contrato vacía, vivían justo acá.)
class LibroExcel {
  const LibroExcel({
    required this.fileName,
    required this.hojaNombre,
    required this.headers,
    required this.filas,
    this.secciones,
    this.hojasExtra = const [],
    this.total,
    this.titulo,
    this.periodo,
    this.empresaNombre,
  });

  final String fileName;
  final String hojaNombre;
  final List<String> headers;
  final List<List<Object?>> filas;
  final List<SeccionExcel>? secciones;
  final List<HojaExcel> hojasExtra;
  final List<Object?>? total;
  final String? titulo;
  final String? periodo;
  final String? empresaNombre;

  /// Cuántas celdas de más o de menos tiene alguna fila respecto de los
  /// encabezados. Vacío = el libro está parejo.
  ///
  /// ## Por qué esto existe
  ///
  /// Los archivos con secciones arman su fila de cierre A MANO, poniendo un
  /// `''` por cada columna hasta llegar a la que lleva el número:
  ///
  /// ```dart
  /// ['Subtotal $nom', '', '', '', '', '', '', c.cuotas, c.monto]
  /// ```
  ///
  /// Agregar una columna y olvidar el `''` **no rompe nada**: el archivo se
  /// genera, se abre en Excel, y el subtotal aparece una casilla corrida —
  /// debajo de "Días de atraso" en vez de "Saldo". Nadie se entera hasta que
  /// alguien suma a mano y no le da.
  ///
  /// No lo caza `flutter analyze` (las filas son `List<Object?>` y aceptan
  /// cualquier largo) ni ningún test de datos. El 2026-09-01 se agregaron dos
  /// columnas a tres archivos a la vez y el riesgo dejó de ser teórico.
  List<String> desparejas() {
    final malas = <String>[];
    void ver(String donde, List<Object?> fila) {
      if (fila.length != headers.length) {
        malas.add('$donde: ${fila.length} celdas para '
            '${headers.length} columnas');
      }
    }

    for (var i = 0; i < filas.length; i++) {
      ver('fila $i', filas[i]);
    }
    for (final sec in secciones ?? const <SeccionExcel>[]) {
      for (var i = 0; i < sec.filas.length; i++) {
        ver('"${sec.titulo}" fila $i', sec.filas[i]);
      }
      if (sec.subtotal != null) ver('subtotal de "${sec.titulo}"', sec.subtotal!);
    }
    if (total != null) ver('TOTAL', total!);
    return malas;
  }

  List<int> bytes() {
    // En debug salta al construir el libro, con el nombre de la fila y los dos
    // números. En release el assert no está y el archivo sale igual: un
    // subtotal corrido es feo, no es motivo para dejar sin su Excel a alguien
    // que lo necesita.
    assert(() {
      final malas = desparejas();
      if (malas.isEmpty) return true;
      throw StateError('El libro "$fileName" tiene filas desparejas:\n  '
          '${malas.join('\n  ')}\n'
          'Suele ser una columna nueva sin su "" en la fila de cierre.');
    }());
    return _bytes();
  }

  List<int> _bytes() => construirExcelBytes(
        hojaNombre: hojaNombre,
        headers: headers,
        filas: filas,
        secciones: secciones,
        hojasExtra: hojasExtra,
        total: total,
        titulo: titulo,
        periodo: periodo,
        empresaNombre: empresaNombre,
      );

  /// Abre el diálogo de guardado. Devuelve la ruta, o null si se canceló.
  Future<String?> descargar() => descargarExcel(
        fileName: fileName,
        hojaNombre: hojaNombre,
        headers: headers,
        filas: filas,
        secciones: secciones,
        hojasExtra: hojasExtra,
        total: total,
        titulo: titulo,
        periodo: periodo,
        empresaNombre: empresaNombre,
      );
}

/// Baja el detalle de "Cobertura del ciclo" del período mostrado.
/// Devuelve la ruta, o null si el usuario canceló el diálogo de guardado.
Future<String?> exportarCobertura({
  required int anio,
  required int mes,
  required int diasGracia,
  required String hoy,
  String? empresaNombre,
}) async =>
    (await libroCobertura(
      anio: anio,
      mes: mes,
      diasGracia: diasGracia,
      hoy: hoy,
      empresaNombre: empresaNombre,
    ))
        .descargar();

/// Arma el libro de "Cobertura del ciclo" sin guardarlo (ver [LibroExcel]).
///
/// [hoy] tiene que ser EL MISMO que muestra la tarjeta: el corte por mora
/// depende de él y si difieren el archivo no reproduce la pantalla.
Future<LibroExcel> libroCobertura({
  required int anio,
  required int mes,
  required int diasGracia,
  required String hoy,
  String? empresaNombre,
}) async {
  final inicio = isoDia(inicioPeriodo(anio, mes));
  final fin = isoDia(finPeriodo(anio, mes));

  final q = detalleCobertura(
      inicio: inicio, fin: fin, diasGracia: diasGracia, hoy: hoy);
  final filas = await ps.db.getAll(q.sql, q.parametros);
  final qa = anuladasDelPeriodo(inicio: inicio, fin: fin);
  final anuladas = await ps.db.getAll(qa.sql, qa.parametros);

  // Mismo criterio que la columna "Usuarios" de la tarjeta: PERSONAS
  // distintas, `COUNT(DISTINCT cliente_id)`.
  //
  // Contaba SERVICIOS (contrato, más el cobro puntual suelto) porque hasta el
  // 2026-09-02 eso contaba la tarjeta. Cuando la tarjeta volvió a personas
  // —para que el dueño pueda ver de un vistazo quién tiene dos contratos— este
  // conteo quedó atrás: el Excel habría dicho 4.414 y la pantalla 4.409, que
  // es exactamente la contradicción que el comentario anterior advertía, dada
  // vuelta. Cambiar lo que la tarjeta CUENTA obliga a barrer lo que la muestra.
  //
  // Sin filtrar por tipo: un cobro puntual también pertenece a alguien, y esa
  // persona ya cuenta si además tiene mensualidad. Es lo mismo que hace el
  // agregado, que no distingue tipo.
  final usuarios = filas.map((r) => r['cliente_id']).toSet().length;
  // UNA SOLA LISTA PLANA (2026-08-28). Los bloques se retiraron porque eran
  // la causa de que el archivo no cuadrara con la tarjeta: agrupaban por
  // CUANDO entro la plata, y "Recuperado" es otra pregunta. El bloque
  // "cobrado en el ciclo" decia 27 y el dueno buscaba el 29, que no existia
  // en ninguna agrupacion posible — dos de esas 27 siguen debiendo y falta la
  // que se saldo con credito.
  //
  // Los dos cortes viven ahora como COLUMNAS: `Cuando entro` da 1/26/2 (los
  // del desplegable de la tarjeta) y `Fila de la tarjeta` da 29/28 (sus filas
  // madre). Filtrando cualquiera de las dos, el conteo cuadra con la pantalla.
  return LibroExcel(
    // CON extension: `guardarArchivo` inserta la fecha antes del punto, y sin
    // punto el archivo sale sin extension y Windows no lo abre con Excel.
    fileName: 'cobertura-${_slugCiclo(anio, mes)}.xlsx',
    hojaNombre: 'Detalle',
    headers: _headers(_montosCobertura, conDias: true),
    filas: [
      for (final r in filas)
        _fila(r, _montosCobertura,
            diasGracia: diasGracia, cuando: _cuandoEntro(r, inicio, fin))
    ],
    // secciones: NULL (no una lista vacia). El escritor usa
    // `if (secciones == null)` para decidir si pinta la lista plana; con []
    // entra igual en la rama de bloques y no escribe ninguna fila.
    total: _cierre('TOTAL DEL CICLO · $usuarios usuarios', filas,
        _montosCobertura,
        conDias: true),
    empresaNombre: empresaNombre,
    titulo: 'Cobertura del ciclo — detalle por cuota',
    periodo: '${_nombreCiclo(anio, mes)} · '
        'ciclo ${periodoLabel(anio, mes)}',
    hojasExtra: anuladas.isEmpty
        ? const []
        : [
            HojaExcel(
              nombre: 'Excluidas',
              headers: [..._headers(_montosAnuladas), 'Motivo de anulación'],
              filas: [
                for (final r in anuladas)
                  [..._fila(r, _montosAnuladas), r['motivo'] ?? ''],
              ],
            ),
          ],
  );
}

/// Baja el detalle de la tarjeta de Mora, SEGMENTADO POR CICLO.
///
/// La tarjeta abarca [ciclos] ciclos, así que el archivo trae todos. Sin el
/// corte por ciclo serían decenas de filas seguidas donde no se ve dónde
/// termina un mes y empieza el otro: cada bloque lleva su encabezado y su
/// subtotal, y al final va el gran total del semestre.

// ══════════════════════════════════════════════════════════════════════════
// MORA — todo lo de abajo es EXCLUSIVO de la tarjeta de Mora del ciclo.
//
// Los helpers están duplicados a propósito (`_headersMora`, `_filaMora`,
// `_cierreMora`) en vez de reusar los de Cobertura. El dueño pidió que las dos
// tarjetas sean independientes: *"cada grafica va a tener su propia
// codificacion y customizacion… con eso quiero asegurarme que un cambio que se
// haga en una grafica no modifique otras sin querer"* (2026-08-28). Agregar una
// columna acá no puede correr las columnas del archivo de Cobertura.
// ══════════════════════════════════════════════════════════════════════════

/// Las columnas de plata del archivo de mora. Son las de MORA, no las de
/// cobertura: un abono hecho DENTRO de la gracia entra en las de cobertura y no
/// en éstas, así que mezclarlas hacía que el Excel dijera 22.150 donde la
/// tarjeta decía 21.950 (fix 2026-08-12).
const List<_Monto> _montosMora = [
  ('Facturado', 'facturado'),
  ('Pagado a tiempo', 'pagado_a_tiempo'),
  ('En mora', 'en_mora'),
  ('Recuperado tarde', 'recuperado_tarde'),
  ('Sigue impago', 'sigue_impago'),
];

List<String> _headersMora() => [
      'Ciclo',
      'Cliente',
      'Nombre',
      'Contrato',
      'Tipo',
      'Vence',
      for (final m in _montosMora) m.$1,
      'Estado',
      // Mismo rename que en Cobertura: es el mismo dato y no puede llamarse
      // distinto en dos hojas del mismo Resumen.
      'Fecha de cobro',
      'Fila de la tarjeta',
      'Detalle',
    ];

List<Object?> _filaMora(
        Map<String, dynamic> r, String ciclo, String finCiclo) =>
    [
      ciclo,
      r['cliente_codigo'] ?? '',
      r['cliente_nombre'] ?? '',
      // Los cobros puntuales no cuelgan de ningún contrato — por eso no
      // aparecen en su pantalla. El guion lo hace explícito.
      r['contrato'] ?? '—',
      r['tipo'] ?? '',
      r['vence'] ?? '',
      for (final m in _montosMora) ((r[m.$2] as num?) ?? 0).toDouble(),
      r['estado'] ?? '',
      r['fecha_cobro'] ?? '',
      _filaTarjetaMora(r),
      _detalleMora(r, finCiclo),
    ];

/// El total del archivo. Tiene que tener TANTAS celdas como el encabezado: si
/// el header gana una columna y ésta no, Excel corre el total y deja de
/// alinear con su columna.
List<Object?> _cierreMora(String etiqueta, List<Map<String, dynamic>> filas) =>
    [
      '$etiqueta · ${filas.length} cuotas',
      '', '', '', '', '', // cliente, nombre, contrato, tipo, vence
      for (final m in _montosMora)
        filas.fold<double>(
            0, (a, r) => a + ((r[m.$2] as num?) ?? 0).toDouble()),
      '', '', // estado, último pago
      '', '', // fila de la tarjeta, detalle
    ];

Future<String?> exportarMora({
  required int anio,
  required int mes,
  required int ciclos,
  required int diasGracia,
  required String hoy,
  String? empresaNombre,
}) async =>
    (await libroMora(
      anio: anio,
      mes: mes,
      ciclos: ciclos,
      diasGracia: diasGracia,
      hoy: hoy,
      empresaNombre: empresaNombre,
    ))
        .descargar();

/// Arma el libro de mora sin guardarlo (ver [LibroExcel]).
///
/// [hoy] tiene que venir de la tarjeta, no calcularse acá: es lo que garantiza
/// que el archivo traiga las MISMAS cuotas que la pantalla está mostrando.
Future<LibroExcel> libroMora({
  required int anio,
  required int mes,
  required int ciclos,
  required int diasGracia,
  required String hoy,
  String? empresaNombre,
}) async {
  final secciones = <SeccionExcel>[];
  final todas = <Map<String, dynamic>>[];

  // AGRUPADO POR CICLO, cada bloque con su subtotal (pedido del dueno,
  // 2026-08-28: "en el excel me gustaria que esten agrupados por ciclo y cada
  // ciclo me muestre sus respectivos totales").
  //
  // Estuvo plano un rato, por la leccion de Cobertura —donde los bloques
  // obligaban a sumar subtotales a mano y los conteos no cerraban—, pero eso se
  // resolvio de otra forma: las columnas `Fila de la tarjeta` y `Detalle`
  // siguen ahi, y con ellas cada fila dice a que numero de la pantalla
  // pertenece. Asi se tienen las dos cosas: el total por ciclo a la vista y la
  // trazabilidad fila por fila.
  //
  // La columna `Ciclo` se conserva aunque el bloque ya lo diga en su titulo:
  // permite copiar filas a otra hoja sin perder de que ciclo eran.
  //
  // Del mas viejo al mas nuevo, igual que las barras.
  for (var k = ciclos - 1; k >= 0; k--) {
    final d = DateTime(anio, mes - k, 1);
    final ini = isoDia(inicioPeriodo(d.year, d.month));
    final fin = isoDia(finPeriodo(d.year, d.month));
    final q =
        detalleMora(inicio: ini, fin: fin, diasGracia: diasGracia, hoy: hoy);
    final delCiclo = await ps.db.getAll(q.sql, q.parametros);
    todas.addAll(delCiclo);
    final etiqueta = periodoLabel(d.year, d.month);
    secciones.add(SeccionExcel(
      titulo: '${_nombreCiclo(d.year, d.month)}  ·  ciclo $etiqueta',
      filas: [for (final r in delCiclo) _filaMora(r, etiqueta, fin)],
      // Sin filas no hay nada que sumar: un subtotal en cero solo hace ruido.
      subtotal: delCiclo.isEmpty
          ? null
          : _cierreMora('Subtotal $etiqueta', delCiclo),
    ));
  }

  return LibroExcel(
    fileName: 'mora-$ciclos-ciclos-hasta-${_slugCiclo(anio, mes)}.xlsx',
    hojaNombre: 'Mora por ciclo',
    headers: _headersMora(),
    filas: const [],
    secciones: secciones,
    total: _cierreMora('TOTAL $ciclos ciclos', todas),
    empresaNombre: empresaNombre,
    titulo: 'Mora — últimos $ciclos ciclos, detalle por cuota',
    periodo: 'hasta ${_nombreCiclo(anio, mes)}',
  );
}

/// A qué fila de la tarjeta pertenece esta cuota.
///
/// Es la columna que hace que el archivo cuadre con la pantalla: filtrando por
/// ella salen los mismos conteos. Una cuota parcial cobrada tarde está en las
/// DOS filas de la tarjeta (tiene plata recuperada Y sigue debiendo), y acá lo
/// dice en vez de elegir una — si eligiera, el filtro daría de menos.
String _filaTarjetaMora(Map<String, dynamic> r) {
  final rec = ((r['recuperado_tarde'] as num?) ?? 0) > 0.009;
  final imp = ((r['sigue_impago'] as num?) ?? 0) > 0.009;
  if (rec && imp) return 'Recuperado y por recuperar';
  if (rec) return 'Recuperado';
  return 'Por recuperar';
}

/// El desglose de segundo nivel de la tarjeta, para la misma cuota.
///
/// Tiene que clasificar con el MISMO criterio que `desgloseMora`, o filtrar el
/// archivo por "con abono parcial" daría un número y la tabla otro:
///   Recuperado    -> por CUÁNDO entró el pago (dentro del ciclo / posterior)
///   Por recuperar -> por si tiene algún abono (`monto_pagado > 0`)
///
/// [finCiclo] es el fin EXCLUSIVO del ciclo: un pago anterior a esa fecha entró
/// dentro del mismo ciclo, uno posterior en un ciclo siguiente.
String _detalleMora(Map<String, dynamic> r, String finCiclo) {
  final aTiempo = ((r['pagado_a_tiempo'] as num?) ?? 0);
  final tarde = ((r['recuperado_tarde'] as num?) ?? 0);
  final impago = ((r['sigue_impago'] as num?) ?? 0) > 0.009;

  String ladoRecuperado() {
    final pago = r['fecha_cobro'] as String?;
    if (pago == null) return '—';
    return pago.compareTo(finCiclo) < 0
        ? 'cobradas dentro del ciclo'
        : 'cobradas en un ciclo posterior';
  }

  // `monto_pagado > 0` es el criterio de la tabla, y son las DOS patas: un
  // abono hecho tarde también es un abono. Mirando solo `pagado_a_tiempo`, una
  // cuota abonada tarde salía como "sin ningún pago" en el archivo y como "con
  // abono parcial" en la pantalla.
  String ladoImpago() =>
      (aTiempo + tarde) > 0.009 ? 'con abono parcial' : 'sin ningún pago';

  // Una cuota parcial cobrada tarde está en las DOS filas de la tarjeta, así
  // que su Detalle nombra las dos. Hoy no existe en ninguno de los tres
  // tenants; si aparece, se ve en vez de desaparecer de un filtro.
  if (tarde > 0.009 && impago) return '${ladoRecuperado()} + ${ladoImpago()}';
  if (tarde > 0.009) return ladoRecuperado();
  return ladoImpago();
}
