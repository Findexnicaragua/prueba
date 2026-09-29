import 'package:excel/excel.dart';

import '../../../../data/utils/formatters.dart';
import '../descarga_archivo.dart';

/// Construye un archivo Excel (.xlsx) de UNA hoja con encabezado + filas y lo
/// ofrece para descargar/guardar vía [guardarArchivo] (diálogo "Guardar como"
/// en Windows, selector de ubicación en Android).
///
/// Pensado para los reportes del admin: reutiliza las mismas queries que ya
/// alimentaban el export CSV, pero produce un .xlsx con formato (encabezado
/// destacado, columnas anchas según el contenido, montos como números con
/// separador de miles, así las sumas funcionan en Excel/Sheets).
///
/// Con [empresaNombre]/[titulo]/[periodo] agrega un header corporativo arriba
/// de la tabla (nombre de la empresa, título del reporte y período/fecha de
/// generación) — la librería `excel` no soporta imágenes embebidas, así que
/// el branding acá es tipográfico; el logo del tenant va en los reportes PDF.
///
/// [filas] es una lista de filas; cada celda puede ser `num` (→ celda numérica
/// con formato) o `String` (→ texto) o `null` (→ celda vacía). Los `int` se
/// muestran como enteros (conteos) y los `double` con 2 decimales (montos).
/// Devuelve la ruta donde se guardó, o `null` si el usuario canceló.
Future<String?> descargarExcel({
  required String fileName,
  required String hojaNombre,
  required List<String> headers,
  required List<List<Object?>> filas,
  String? empresaNombre,
  String? titulo,
  String? periodo,
  List<SeccionExcel>? secciones,
  List<HojaExcel> hojasExtra = const [],
  List<Object?>? total,
}) async {
  final bytes = construirExcelBytes(
    hojaNombre: hojaNombre,
    headers: headers,
    filas: filas,
    empresaNombre: empresaNombre,
    titulo: titulo,
    periodo: periodo,
    secciones: secciones,
    hojasExtra: hojasExtra,
    total: total,
  );
  return guardarArchivo(fileName: fileName, bytes: bytes, extension: 'xlsx');
}

/// Arma los bytes del .xlsx (separado de la descarga para poder testearlo
/// sin diálogo de guardado).
/// Un bloque de filas con su propio encabezado y subtotal dentro de una hoja.
/// Lo usa el export del dashboard para separar los 6 ciclos: sin corte, 29
/// filas seguidas no dejan ver donde termina un mes y empieza el otro.
class SeccionExcel {
  const SeccionExcel({required this.titulo, required this.filas, this.subtotal});

  final String titulo;
  final List<List<Object?>> filas;

  /// Fila de cierre del bloque. Null = sin subtotal.
  final List<Object?>? subtotal;
}

/// Una hoja adicional del libro. El export del dashboard la usa para las
/// cuotas ANULADAS: no entran en ningun numero de la tarjeta, pero esconderlas
/// del archivo deja sin explicar por que la ventana tiene mas cuotas que las
/// que la pantalla cuenta.
class HojaExcel {
  const HojaExcel(
      {required this.nombre, required this.headers, required this.filas});

  final String nombre;
  final List<String> headers;
  final List<List<Object?>> filas;
}

List<int> construirExcelBytes({
  required String hojaNombre,
  required List<String> headers,
  required List<List<Object?>> filas,
  String? empresaNombre,
  String? titulo,
  String? periodo,
  /// Si viene, reemplaza a [filas]: cada seccion se pinta con su encabezado,
  /// sus filas y su subtotal, separadas por una fila en blanco.
  List<SeccionExcel>? secciones,
  List<HojaExcel> hojasExtra = const [],
  /// Fila de cierre de toda la tabla (el gran total).
  List<Object?>? total,
}) {
  final excel = Excel.createExcel();
  // createExcel arranca con una hoja default ('Sheet1'); la renombramos a algo
  // descriptivo en vez de crear otra y tener que borrar la default.
  final defaultName = excel.getDefaultSheet();
  if (defaultName != null && defaultName != hojaNombre) {
    excel.rename(defaultName, hojaNombre);
  }
  final sheet = excel[hojaNombre];

  // Estilos reutilizables.
  final headerStyle = CellStyle(
    bold: true,
    fontColorHex: ExcelColor.white,
    backgroundColorHex: ExcelColor.blueGrey800,
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );
  // Enteros (conteos): separador de miles, sin decimales, a la derecha.
  final intStyle = CellStyle(
    horizontalAlign: HorizontalAlign.Right,
    numberFormat: NumFormat.custom(formatCode: '#,##0'),
  );
  // Montos (double): separador de miles + 2 decimales, a la derecha.
  final moneyStyle = CellStyle(
    horizontalAlign: HorizontalAlign.Right,
    numberFormat: NumFormat.custom(formatCode: '#,##0.00'),
  );

  // Header corporativo (mismo orden que el header de los PDF): empresa,
  // título, período + fecha de generación, fila en blanco. SIN merge a
  // propósito: una celda suelta desborda naturalmente sobre las vacías de
  // la derecha (texto completo visible); mergeada, Excel RECORTA lo que no
  // entra en el ancho de la tabla.
  var filaActual = 0;
  if (empresaNombre != null && empresaNombre.isNotEmpty) {
    void filaBranding(String texto, CellStyle estilo) {
      final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: filaActual));
      cell.value = TextCellValue(texto);
      cell.cellStyle = estilo;
      filaActual++;
    }

    filaBranding(
        empresaNombre,
        CellStyle(
            bold: true, fontSize: 14, fontColorHex: ExcelColor.blueGrey800));
    if (titulo != null && titulo.isNotEmpty) {
      filaBranding(titulo, CellStyle(bold: true, fontSize: 12));
    }
    final generado = 'Generado: ${Fmt.fechaCorta(DateTime.now())}';
    filaBranding(
        (periodo == null || periodo.isEmpty)
            ? generado
            : 'Período: $periodo — $generado',
        CellStyle(fontSize: 10, fontColorHex: ExcelColor.grey700));
    filaActual++; // fila en blanco antes de la tabla
  }

  // Fila de encabezado de la tabla. Celdas explícitas (no appendRow) para
  // que los índices no dependan de las filas/merges del branding.
  final filaHeaders = filaActual;
  for (var c = 0; c < headers.length; c++) {
    final cell = sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: filaHeaders));
    cell.value = TextCellValue(headers[c]);
    cell.cellStyle = headerStyle;
  }

  final seccionStyle = CellStyle(
      bold: true,
      fontColorHex: ExcelColor.blueGrey800,
      backgroundColorHex: ExcelColor.blueGrey100);
  final totalStyle = CellStyle(bold: true, backgroundColorHex: ExcelColor.green50);
  final totalNumStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.green50,
      horizontalAlign: HorizontalAlign.Right,
      numberFormat: NumFormat.custom(formatCode: '#,##0.00'));

  /// Pinta una fila en `rowIndex`, con formato numerico segun el tipo de cada
  /// celda. `estilo`/`estiloNum` pisan el default (se usa en subtotales).
  void pintarFila(Sheet hoja, int rowIndex, List<Object?> fila,
      {CellStyle? estilo, CellStyle? estiloNum}) {
    for (var c = 0; c < fila.length; c++) {
      final v = fila[c];
      final celda = _celda(v);
      if (celda == null) continue;
      final cell = hoja
          .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIndex));
      cell.value = celda;
      if (v is int) {
        cell.cellStyle = estiloNum ?? intStyle;
      } else if (v is num) {
        cell.cellStyle = estiloNum ?? moneyStyle;
      } else if (estilo != null) {
        cell.cellStyle = estilo;
      }
    }
  }

  var fila = filaHeaders + 1;
  if (secciones == null) {
    for (final f in filas) {
      pintarFila(sheet, fila, f);
      fila++;
    }
  } else {
    for (final sec in secciones) {
      final cab = sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: fila));
      cab.value = TextCellValue(sec.titulo);
      cab.cellStyle = seccionStyle;
      // El fondo se extiende a lo ancho para que el corte se vea de un vistazo.
      for (var c = 1; c < headers.length; c++) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: fila))
            .cellStyle = seccionStyle;
      }
      fila++;
      for (final f in sec.filas) {
        pintarFila(sheet, fila, f);
        fila++;
      }
      if (sec.subtotal != null) {
        pintarFila(sheet, fila, sec.subtotal!,
            estilo: CellStyle(bold: true),
            estiloNum: CellStyle(
                bold: true,
                horizontalAlign: HorizontalAlign.Right,
                numberFormat: NumFormat.custom(formatCode: '#,##0.00')));
        fila++;
      }
      fila++; // separacion entre ciclos
    }
  }
  if (total != null) {
    pintarFila(sheet, fila, total,
        estilo: totalStyle, estiloNum: totalNumStyle);
  }

  for (final extra in hojasExtra) {
    final hoja = excel[extra.nombre];
    for (var c = 0; c < extra.headers.length; c++) {
      final cell =
          hoja.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0));
      cell.value = TextCellValue(extra.headers[c]);
      cell.cellStyle = headerStyle;
    }
    for (var r = 0; r < extra.filas.length; r++) {
      pintarFila(hoja, r + 1, extra.filas[r]);
    }
    for (var c = 0; c < extra.headers.length; c++) {
      var maxLen = extra.headers[c].length;
      for (final f in extra.filas) {
        if (c < f.length) {
          final s = f[c]?.toString() ?? '';
          if (s.length > maxLen) maxLen = s.length;
        }
      }
      hoja.setColumnWidth(c, (maxLen + 3).clamp(12, 50).toDouble());
    }
  }

  // Ancho de columnas según el contenido más largo (encabezado o celda),
  // acotado a un rango razonable para que no quede ni cortado ni gigante.
  // Las filas de branding no cuentan: están mergeadas a lo ancho.
  final todasLasFilas = <List<Object?>>[
    ...filas,
    for (final s in secciones ?? const <SeccionExcel>[]) ...s.filas,
    if (total != null) total,
  ];
  for (var c = 0; c < headers.length; c++) {
    var maxLen = headers[c].length;
    for (final f in todasLasFilas) {
      if (c < f.length) {
        final s = f[c]?.toString() ?? '';
        if (s.length > maxLen) maxLen = s.length;
      }
    }
    sheet.setColumnWidth(c, (maxLen + 3).clamp(12, 50).toDouble());
  }

  final saved = excel.save();
  if (saved == null) {
    throw Exception('No se pudo generar el archivo Excel');
  }
  return saved;
}

/// Meses en español (índice = mes, 1-based).
const _mesesEs = [
  '', 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'
];

/// Mes que se muestra por cada cobro — el MES DE SERVICIO anclado al día de
/// pago FIJO (regla 2026-08-01, ARQUITECTURA §3.5): día ≤14 → período−1,
/// día ≥15 → período. Idéntico a lo que muestra la app, que llama al mismo
/// `Fmt.mesServicio`. [diaPago] es `ct.dia_pago` (el día REAL del contrato),
/// NO el día del vencimiento: ese trae el corrimiento domingo→lunes que en
/// v0.31.1 colapsaba dos meses (PN0190 → "Junio, Junio"). Con el día fijo el
/// mes es constante y único por cuota. Sin día (cuota manual) no corre.
String _mesDeServicio(Object? diaPago, String? periodo) {
  final p = _fecha(periodo);
  if (p == null) return '';
  final dia = diaPago is int ? diaPago : int.tryParse('${diaPago ?? ''}');
  final m = dia == null ? p : Fmt.mesServicio(dia, p);
  return _mesesEs[m.month];
}

DateTime? _fecha(String? v) {
  if (v == null || v.isEmpty) return null;
  return DateTime.tryParse(v.length == 7 ? '$v-01' : v);
}

/// "2026-06-03" o "2026-06-03T14:32:00" → "03/06/2026". `fecha_pago` es hora
/// local Nicaragua (wall-clock): se formatea DIRECTO, sin shift de TZ (coincide
/// con el recibo y con el bucket `date(fecha_pago)` — regla del proyecto).
String _fechaCortaDe(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year}';
}

/// Reporte de cobranza con el layout de la **plantilla estándar** (la que
/// compartieron Mairena/Telenet, default de todos los tenants): banner del
/// tenant + rango de fechas + 4 totales (C$/US$) + tabla de pagos del período.
///
/// Layout (8 columnas A–H, igual que la plantilla):
///   fila 0  empresa · fila 1 "Reporte de cobranza"
///   fila 3  Fecha inicial | … | SUBTOTAL CÓRDOBAS …… valor
///   fila 4  Fecha final   | … | CAMBIO COMPRA DE DIVISAS … valor
///   fila 5                      TOTAL CÓRDOBAS …… valor
///   fila 6                      TOTAL DÓLARES  …… valor
///   fila 7  encabezados de tabla · fila 8+ datos
///
/// Split de monedas (confirmado): pago en C$ → columna "Córdoba"; pago en US$ →
/// "Dólar" (monto_original) + "Compra de Divisas" (C$-equiv = monto_cordobas +
/// vuelto, invariante #3). Totales: SUBTOTAL = Σ córdobas; CAMBIO = Σ divisas;
/// TOTAL CÓRDOBAS = subtotal + cambio; TOTAL DÓLARES = Σ dólares.
///
/// [rows]: pagos no anulados del rango con `cliente_codigo`, `cliente_nombre`,
/// `cobrador_nombre`, `cuota_periodo`, `dia_pago`, `fecha_pago`,
/// `numero_recibo`, `moneda`,
/// `monto_original`, `monto_cordobas`, `vuelto_cordobas`.
/// (El paquete `excel` no embebe imágenes → el banner es tipográfico; el logo
/// del tenant solo va en los reportes PDF.)
List<int> construirReporteCobranzaBytes({
  required String empresaNombre,
  required String fechaInicial,
  required String fechaFinal,
  required List<Map<String, dynamic>> rows,
}) {
  final excel = Excel.createExcel();
  const hoja = 'Cobranza';
  final defaultName = excel.getDefaultSheet();
  if (defaultName != null && defaultName != hoja) excel.rename(defaultName, hoja);
  final sheet = excel[hoja];

  final tituloStyle =
      CellStyle(bold: true, fontSize: 14, fontColorHex: ExcelColor.blueGrey800);
  final subStyle = CellStyle(bold: true, fontSize: 12);
  final labelStyle =
      CellStyle(bold: true, fontColorHex: ExcelColor.blueGrey800);
  final money = CellStyle(
      horizontalAlign: HorizontalAlign.Right,
      numberFormat: NumFormat.custom(formatCode: '#,##0.00'));
  final headerStyle = CellStyle(
      bold: true,
      fontColorHex: ExcelColor.white,
      backgroundColorHex: ExcelColor.blueGrey800,
      horizontalAlign: HorizontalAlign.Center);

  void put(int col, int row, CellValue v, [CellStyle? st]) {
    final cell = sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    cell.value = v;
    if (st != null) cell.cellStyle = st;
  }

  // Banner + rango.
  put(0, 0, TextCellValue(empresaNombre), tituloStyle);
  put(0, 1, TextCellValue('Reporte de cobranza'), subStyle);
  put(0, 3, TextCellValue('Fecha inicial:'), labelStyle);
  put(1, 3, TextCellValue(fechaInicial));
  put(0, 4, TextCellValue('Fecha final:'), labelStyle);
  put(1, 4, TextCellValue(fechaFinal));

  // Tabla.
  const headers = [
    'ID', 'Nombre del Cliente', 'Cobrador', 'Mes', 'Fecha de cobro', 'Recibo #',
    'Dólar', 'Córdoba', 'Compra de Divisas'
  ];
  const headerRow = 7;
  for (var c = 0; c < headers.length; c++) {
    put(c, headerRow, TextCellValue(headers[c]), headerStyle);
  }

  num subtotalCordobas = 0, totalDivisas = 0, totalDolar = 0;
  var r = headerRow + 1;
  for (final row in rows) {
    final esUsd = (row['moneda']?.toString() ?? 'NIO') == 'USD';
    final mo = (row['monto_original'] as num?) ?? 0;
    final mc = (row['monto_cordobas'] as num?) ?? 0;
    final vu = (row['vuelto_cordobas'] as num?) ?? 0;

    put(0, r, TextCellValue(row['cliente_codigo']?.toString() ?? ''));
    put(1, r, TextCellValue(row['cliente_nombre']?.toString() ?? ''));
    put(2, r, TextCellValue(row['cobrador_nombre']?.toString() ?? ''));
    put(
        3,
        r,
        TextCellValue(
            _mesDeServicio(row['dia_pago'], row['cuota_periodo'] as String?)));
    // Fecha en que se registró el pago (wall-clock local Nicaragua, la misma
    // del recibo → formatear directo, sin shift de TZ). Cada fila es UN pago.
    put(4, r, TextCellValue(_fechaCortaDe(row['fecha_pago'] as String?)));
    put(5, r, TextCellValue(row['numero_recibo']?.toString() ?? ''));
    if (esUsd) {
      put(6, r, DoubleCellValue(mo.toDouble()), money);
      put(8, r, DoubleCellValue((mc + vu).toDouble()), money);
      totalDolar += mo;
      totalDivisas += (mc + vu);
    } else {
      put(7, r, DoubleCellValue(mc.toDouble()), money);
      subtotalCordobas += mc;
    }
    r++;
  }

  // Totales (arriba a la derecha, como la plantilla).
  // Valores alineados a la ÚLTIMA columna (ahora 8 por la columna nueva
  // "Fecha de cobro"; antes era 7 = "Compra de Divisas").
  put(3, 3, TextCellValue('SUBTOTAL CÓRDOBAS'), labelStyle);
  put(8, 3, DoubleCellValue(subtotalCordobas.toDouble()), money);
  put(3, 4, TextCellValue('CAMBIO COMPRA DE DIVISAS'), labelStyle);
  put(8, 4, DoubleCellValue(totalDivisas.toDouble()), money);
  put(3, 5, TextCellValue('TOTAL CÓRDOBAS'), labelStyle);
  put(8, 5, DoubleCellValue((subtotalCordobas + totalDivisas).toDouble()), money);
  put(3, 6, TextCellValue('TOTAL DÓLARES'), labelStyle);
  put(8, 6, DoubleCellValue(totalDolar.toDouble()), money);

  // ID, Nombre, Cobrador, Mes, Fecha de cobro, Recibo #, Dólar, Córdoba, Compra.
  const widths = [12, 30, 20, 12, 14, 14, 12, 14, 18];
  for (var c = 0; c < widths.length; c++) {
    sheet.setColumnWidth(c, widths[c].toDouble());
  }

  final saved = excel.save();
  if (saved == null) throw Exception('No se pudo generar el Excel');
  return saved;
}

/// Mapea un valor crudo de una fila a la celda tipada de Excel. Los números
/// quedan como números (sumables en Excel); el resto, como texto.
CellValue? _celda(Object? v) {
  if (v == null) return null;
  if (v is int) return IntCellValue(v);
  if (v is double) return DoubleCellValue(v);
  if (v is num) return DoubleCellValue(v.toDouble());
  return TextCellValue(v.toString());
}
