import 'package:excel/excel.dart';
import 'package:flutter/material.dart';

import '../../../../data/models/prestamos_models.dart';
import '../../../../data/utils/formatters.dart';
import 'descarga_archivo.dart';
import 'docx/reporte_docx.dart';

/// Formatos de exportación disponibles para los Estados Financieros.
enum FormatoExportFinanciero {
  excel,
  word,
}

/// Diálogo amigable para elegir el formato de exportación de los Estados Financieros.
Future<FormatoExportFinanciero?> mostrarDialogoExportEstadosFinancieros(
    BuildContext context) {
  return showDialog<FormatoExportFinanciero>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.account_balance, color: Color(0xFF1B3B6F)),
          SizedBox(width: 10),
          Text('Exportar Estados Financieros'),
        ],
      ),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Seleccione el formato deseado para generar el Balance General, '
            'Estado de Resultados, Flujo de Caja y Resumen de Cartera:',
            style: TextStyle(fontSize: 14, color: Color(0xFF555555)),
          ),
          SizedBox(height: 18),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancelar'),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.table_view, color: Color(0xFF1E7E34)),
          label: const Text('Excel (.xlsx)'),
          onPressed: () =>
              Navigator.pop(ctx, FormatoExportFinanciero.excel),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.description, color: Colors.white),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1B3B6F),
          ),
          label: const Text('Word (.docx)'),
          onPressed: () =>
              Navigator.pop(ctx, FormatoExportFinanciero.word),
        ),
      ],
    ),
  );
}

/// Genera y descarga los Estados Financieros completos en Excel o Word.
Future<void> exportarEstadosFinancieros(
  BuildContext context, {
  required ResumenCartera cartera,
  required EstadoCaja caja,
  required String empresaNombre,
  required FormatoExportFinanciero formato,
  DateTime? fechaCorte,
}) async {
  final now = fechaCorte ?? DateTime.now();
  final fechaStr =
      '${now.year}_${now.month.toString().padLeft(2, '0')}_${now.day.toString().padLeft(2, '0')}';

  if (formato == FormatoExportFinanciero.excel) {
    final bytes = construirEstadosFinancierosExcelBytes(
      cartera: cartera,
      caja: caja,
      empresaNombre: empresaNombre,
      fechaCorte: now,
    );
    await guardarExcelConAviso(
      context,
      fileName: 'estados_financieros_${empresaNombre.replaceAll(' ', '_')}_$fechaStr.xlsx',
      bytes: bytes,
      mensaje: 'Estados Financieros exportados a Excel con éxito',
    );
  } else {
    final bytes = construirEstadosFinancierosDocxBytes(
      cartera: cartera,
      caja: caja,
      empresaNombre: empresaNombre,
      fechaCorte: now,
    );
    await guardarDocxConAviso(
      context,
      fileName: 'estados_financieros_${empresaNombre.replaceAll(' ', '_')}_$fechaStr.docx',
      bytes: bytes,
      mensaje: 'Estados Financieros exportados a Word con éxito',
    );
  }
}

// -----------------------------------------------------------------------------
// EXCEL BUILDER
// -----------------------------------------------------------------------------

/// Construye los bytes del libro Excel (.xlsx) con el Estado Financiero formal.
List<int> construirEstadosFinancierosExcelBytes({
  required ResumenCartera cartera,
  required EstadoCaja caja,
  required String empresaNombre,
  DateTime? fechaCorte,
}) {
  final now = fechaCorte ?? DateTime.now();
  final fechaFormateada =
      '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';

  final excel = Excel.createExcel();
  const hoja = 'Estados Financieros';
  final defaultSheet = excel.getDefaultSheet();
  if (defaultSheet != null && defaultSheet != hoja) {
    excel.rename(defaultSheet, hoja);
  }
  final sheet = excel[hoja];

  // Estilos
  final titleStyle = CellStyle(
    bold: true,
    fontSize: 14,
    fontColorHex: ExcelColor.fromHexString('1B3B6F'),
  );
  final subtitleStyle = CellStyle(
    bold: true,
    fontSize: 11,
    fontColorHex: ExcelColor.fromHexString('555555'),
  );
  final sectionHeader = CellStyle(
    bold: true,
    fontSize: 11,
    fontColorHex: ExcelColor.white,
    backgroundColorHex: ExcelColor.fromHexString('1B3B6F'),
    horizontalAlign: HorizontalAlign.Left,
  );
  final subSectionHeader = CellStyle(
    bold: true,
    fontColorHex: ExcelColor.fromHexString('0F766E'),
  );
  final money = CellStyle(
    horizontalAlign: HorizontalAlign.Right,
    numberFormat: NumFormat.custom(formatCode: '#,##0.00'),
  );
  final moneyBold = CellStyle(
    bold: true,
    horizontalAlign: HorizontalAlign.Right,
    numberFormat: NumFormat.custom(formatCode: '#,##0.00'),
    backgroundColorHex: ExcelColor.fromHexString('E8F4F8'),
  );
  final totalLabel = CellStyle(
    bold: true,
    fontColorHex: ExcelColor.fromHexString('1B3B6F'),
    backgroundColorHex: ExcelColor.fromHexString('E8F4F8'),
  );

  void put(int col, int row, CellValue v, [CellStyle? st]) {
    final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    cell.value = v;
    if (st != null) cell.cellStyle = st;
  }

  // Encabezado
  put(0, 0, TextCellValue(empresaNombre.toUpperCase()), titleStyle);
  put(0, 1, TextCellValue('ESTADOS FINANCIEROS Y SITUACIÓN DE CARTERA'), subtitleStyle);
  put(0, 2, TextCellValue('Fecha de corte: $fechaFormateada   |   Moneda: C\$ (Córdobas)'), subtitleStyle);

  var r = 4;

  // 1. ESTADO DE SITUACIÓN FINANCIERA (BALANCE GENERAL)
  put(0, r, TextCellValue('1. ESTADO DE SITUACIÓN FINANCIERA (BALANCE GENERAL)'), sectionHeader);
  put(1, r, TextCellValue('MONTO (C\$)'), sectionHeader);
  r++;

  put(0, r, TextCellValue('ACTIVO DISPONIBLE Y LIQUIDEZ'), subSectionHeader);
  r++;
  put(0, r, TextCellValue('  Caja actual (Operativa)'));
  put(1, r, DoubleCellValue(caja.cajaActual), money);
  r++;
  put(0, r, TextCellValue('  Caja de préstamos (Disponible para colocar)'));
  put(1, r, DoubleCellValue(caja.cajaPrestamos), money);
  r++;
  put(0, r, TextCellValue('  Bancos (Fondos en cuentas bancarias)'));
  put(1, r, DoubleCellValue(caja.bancos), money);
  r++;
  final totalDisponible = caja.cajaActual + caja.cajaPrestamos + caja.bancos;
  put(0, r, TextCellValue('SUBTOTAL ACTIVO DISPONIBLE'), totalLabel);
  put(1, r, DoubleCellValue(totalDisponible), moneyBold);
  r += 2;

  put(0, r, TextCellValue('CARTERA DE PRÉSTAMOS (ACTIVOS EXIGIBLES)'), subSectionHeader);
  r++;
  put(0, r, TextCellValue('  Cartera Activa / Vigente (${cartera.activosCount} créditos)'));
  put(1, r, DoubleCellValue(cartera.activosMonto), money);
  r++;
  put(0, r, TextCellValue('  Cartera Por Vencer (${cartera.porVencerCount} créditos)'));
  put(1, r, DoubleCellValue(cartera.porVencerMonto), money);
  r++;
  put(0, r, TextCellValue('  Cartera en Mora Vigente (${cartera.moraVigenteCount} créditos)'));
  put(1, r, DoubleCellValue(cartera.moraVigenteMonto), money);
  r++;
  put(0, r, TextCellValue('  Cartera en Mora Vencida (${cartera.moraVencidaCount} créditos)'));
  put(1, r, DoubleCellValue(cartera.moraVencidaMonto), money);
  r++;
  final totalCartera = cartera.totalCarteraAdeudada;
  put(0, r, TextCellValue('SUBTOTAL CARTERA DE PRÉSTAMOS'), totalLabel);
  put(1, r, DoubleCellValue(totalCartera), moneyBold);
  r += 2;

  final totalActivos = totalDisponible + totalCartera;
  put(0, r, TextCellValue('TOTAL ACTIVOS (DISPONIBLE + CARTERA)'), totalLabel);
  put(1, r, DoubleCellValue(totalActivos), moneyBold);
  r += 2;

  put(0, r, TextCellValue('FONDOS Y PATRIMONIO'), subSectionHeader);
  r++;
  put(0, r, TextCellValue('  Capital Aportado'));
  put(1, r, DoubleCellValue(caja.capitalAportado), money);
  r++;
  put(0, r, TextCellValue('  Capital Recuperado'));
  put(1, r, DoubleCellValue(caja.capitalRecuperado), money);
  r++;
  put(0, r, TextCellValue('  Rendimientos e Intereses Acumulados'));
  put(1, r, DoubleCellValue(caja.interesesAcumulados), money);
  r++;
  final totalPatrimonio = caja.capitalAportado + caja.interesesAcumulados;
  put(0, r, TextCellValue('TOTAL FONDOS Y PATRIMONIO'), totalLabel);
  put(1, r, DoubleCellValue(totalPatrimonio), moneyBold);
  r += 3;

  // 2. ESTADO DE RESULTADOS (RENDIMIENTO OPERATIVO)
  put(0, r, TextCellValue('2. ESTADO DE RESULTADOS (RENDIMIENTO OPERATIVO)'), sectionHeader);
  put(1, r, TextCellValue('MONTO (C\$)'), sectionHeader);
  r++;
  put(0, r, TextCellValue('INGRESOS OPERATIVOS'), subSectionHeader);
  r++;
  put(0, r, TextCellValue('  Intereses cobrados por préstamos'));
  put(1, r, DoubleCellValue(caja.interesesCobrados), money);
  r++;
  put(0, r, TextCellValue('  Ingresos netos'));
  put(1, r, DoubleCellValue(caja.ingresosNetos), money);
  r++;
  final totalIngresos = caja.interesesCobrados + caja.ingresosNetos;
  put(0, r, TextCellValue('TOTAL INGRESOS OPERATIVOS'), totalLabel);
  put(1, r, DoubleCellValue(totalIngresos), moneyBold);
  r += 2;

  put(0, r, TextCellValue('EGRESOS OPERATIVOS'), subSectionHeader);
  r++;
  put(0, r, TextCellValue('  Gastos diarios'));
  put(1, r, DoubleCellValue(caja.gastosDiarios), money);
  r++;
  put(0, r, TextCellValue('  Egresos diversos'));
  put(1, r, DoubleCellValue(caja.egresos), money);
  r++;
  final totalEgresos = caja.gastosDiarios + caja.egresos;
  put(0, r, TextCellValue('TOTAL EGRESOS OPERATIVOS'), totalLabel);
  put(1, r, DoubleCellValue(totalEgresos), moneyBold);
  r += 2;

  final utilidadNeta = totalIngresos - totalEgresos;
  put(0, r, TextCellValue('UTILIDAD / RENDIMIENTO NETO DEL PERÍODO'), totalLabel);
  put(1, r, DoubleCellValue(utilidadNeta), moneyBold);
  r += 3;

  // 3. ESTADO DE FLUJO DE EFECTIVO Y CAJA
  put(0, r, TextCellValue('3. ESTADO DE FLUJO DE EFECTIVO Y LIQUIDEZ'), sectionHeader);
  put(1, r, TextCellValue('MONTO (C\$)'), sectionHeader);
  r++;
  put(0, r, TextCellValue('  Caja inicial'));
  put(1, r, DoubleCellValue(caja.cajaInicial), money);
  r++;
  put(0, r, TextCellValue('  (+) Capital Recuperado'));
  put(1, r, DoubleCellValue(caja.capitalRecuperado), money);
  r++;
  put(0, r, TextCellValue('  (+) Intereses Cobrados'));
  put(1, r, DoubleCellValue(caja.interesesCobrados), money);
  r++;
  put(0, r, TextCellValue('  (-) Gastos Diarios'));
  put(1, r, DoubleCellValue(caja.gastosDiarios), money);
  r++;
  put(0, r, TextCellValue('  (-) Egresos'));
  put(1, r, DoubleCellValue(caja.egresos), money);
  r++;
  put(0, r, TextCellValue('SALDO FINAL EN CAJA ACTUAL'), totalLabel);
  put(1, r, DoubleCellValue(caja.cajaActual), moneyBold);
  r += 3;

  // 4. RESUMEN DE CARTERA
  put(0, r, TextCellValue('4. RESUMEN DE CARTERA Y GESTIÓN DE RIESGO'), sectionHeader);
  put(1, r, TextCellValue('CANTIDAD / MONTO'), sectionHeader);
  r++;
  put(0, r, TextCellValue('  Clientes registrados en cartera'));
  put(1, r, IntCellValue(cartera.clientesCount));
  r++;
  put(0, r, TextCellValue('  Préstamos totales emitidos'));
  put(1, r, IntCellValue(cartera.prestamosCount));
  r++;
  put(0, r, TextCellValue('  Créditos cancelados / pagados'));
  put(1, r, TextCellValue('${cartera.pagadosCount} (C\$ ${cartera.pagadosMonto.toStringAsFixed(2)})'));
  r++;
  put(0, r, TextCellValue('  Total cartera en mora'));
  put(1, r, TextCellValue('${cartera.enMoraCount} créditos (C\$ ${cartera.enMoraMonto.toStringAsFixed(2)})'));
  r++;
  final pctMora = cartera.totalCarteraAdeudada > 0
      ? (cartera.enMoraMonto / cartera.totalCarteraAdeudada) * 100
      : 0.0;
  put(0, r, TextCellValue('  Índice de mora sobre cartera total'));
  put(1, r, TextCellValue('${pctMora.toStringAsFixed(2)}%'));

  // Anchos de columna
  sheet.setColumnWidth(0, 50);
  sheet.setColumnWidth(1, 28);

  final saved = excel.save();
  if (saved == null) {
    throw Exception('No se pudo generar el archivo Excel de Estados Financieros');
  }
  return saved;
}

// -----------------------------------------------------------------------------
// WORD (.DOCX) BUILDER
// -----------------------------------------------------------------------------

/// Construye los bytes del documento Word (.docx) formal con membrete y tablas.
List<int> construirEstadosFinancierosDocxBytes({
  required ResumenCartera cartera,
  required EstadoCaja caja,
  required String empresaNombre,
  DateTime? fechaCorte,
}) {
  final now = fechaCorte ?? DateTime.now();
  final fechaFormateada =
      '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';

  final doc = DocxBuilder();

  // Membrete
  doc.addReportHeader(
    empresa: empresaNombre,
    titulo: 'ESTADOS FINANCIEROS Y SITUACIÓN DE CARTERA',
    subtitulo: 'Informe Oficial de Liquidez, Balance y Cartera de Créditos',
    fechaEmision: fechaFormateada,
  );

  // Resumen Ejecutivo
  final totalActivos =
      caja.cajaActual + caja.cajaPrestamos + caja.bancos + cartera.totalCarteraAdeudada;
  final pctMora = cartera.totalCarteraAdeudada > 0
      ? (cartera.enMoraMonto / cartera.totalCarteraAdeudada) * 100
      : 0.0;

  doc.addCallout(
    'Al corte del $fechaFormateada, la institución cuenta con un total de activos de '
    '${Fmt.cordobas(totalActivos)}, una cartera exigible de ${Fmt.cordobas(cartera.totalCarteraAdeudada)} '
    'distribuida en ${cartera.prestamosCount} operaciones, y una liquidez disponible inmediata de '
    '${Fmt.cordobas(caja.cajaActual + caja.bancos)}. El índice de mora sobre la cartera es del ${pctMora.toStringAsFixed(2)}%.',
    title: 'RESUMEN EJECUTIVO',
    borderColor: '1B3B6F',
    bgColor: 'F0F7FA',
  );

  // 1. BALANCE GENERAL
  doc.addHeading1('1. Estado de Situación Financiera (Balance General)');
  doc.addParagraph(
    'Refleja la disponibilidad de recursos líquidos y la valuación de la cartera de crédito exigible:',
    italic: true,
  );

  final totalDisponible = caja.cajaActual + caja.cajaPrestamos + caja.bancos;
  final balanceRows = <List<Object?>>[
    // Activo Disponible
    ['Caja Operativa Actual', caja.cajaActual],
    ['Caja de Préstamos (Disponible para prestar)', caja.cajaPrestamos],
    ['Bancos (Cuentas de depósito)', caja.bancos],
    ['TOTAL ACTIVO DISPONIBLE', totalDisponible],
    // Cartera
    ['Cartera Vigente / Activa (${cartera.activosCount} créditos)', cartera.activosMonto],
    ['Cartera Por Vencer (${cartera.porVencerCount} créditos)', cartera.porVencerMonto],
    ['Cartera en Mora Vigente (${cartera.moraVigenteCount} créditos)', cartera.moraVigenteMonto],
    ['Cartera en Mora Vencida (${cartera.moraVencidaCount} créditos)', cartera.moraVencidaMonto],
    ['TOTAL CARTERA DE PRÉSTAMOS', cartera.totalCarteraAdeudada],
    // Gran Total
    ['TOTAL GENERAL DE ACTIVOS', totalActivos],
    // Patrimonio
    ['Capital Aportado Inicial', caja.capitalAportado],
    ['Capital Recuperado a la fecha', caja.capitalRecuperado],
    ['Rendimientos e Intereses Acumulados', caja.interesesAcumulados],
    ['TOTAL FONDOS Y PATRIMONIO', caja.capitalAportado + caja.interesesAcumulados],
  ];

  doc.addTable(
    headers: ['Rubro / Concepto Contable', 'Monto en Córdobas (C\$)'],
    rows: balanceRows,
    colWidthsPct: [70, 30],
    alignments: ['left', 'right'],
    isTotalRow: (idx, row) {
      final desc = row[0]?.toString() ?? '';
      return desc.startsWith('TOTAL');
    },
  );

  // 2. ESTADO DE RESULTADOS
  doc.addHeading1('2. Estado de Rendimiento Operativo (Resultados)');
  doc.addParagraph(
    'Muestra los ingresos percibidos por intereses y cobros frente a los egresos del ciclo:',
    italic: true,
  );

  final totalIngresos = caja.interesesCobrados + caja.ingresosNetos;
  final totalEgresos = caja.gastosDiarios + caja.egresos;
  final utilidadNeta = totalIngresos - totalEgresos;

  final resultadosRows = <List<Object?>>[
    ['(+) Intereses cobrados por financiamiento', caja.interesesCobrados],
    ['(+) Otros ingresos netos de cobranza', caja.ingresosNetos],
    ['TOTAL INGRESOS OPERATIVOS', totalIngresos],
    ['(-) Gastos operativos diarios', caja.gastosDiarios],
    ['(-) Egresos y costos administrativos', caja.egresos],
    ['TOTAL EGRESOS OPERATIVOS', totalEgresos],
    ['UTILIDAD NETA OPERATIVA', utilidadNeta],
  ];

  doc.addTable(
    headers: ['Concepto de Ingresos y Egresos', 'Monto (C\$)'],
    rows: resultadosRows,
    colWidthsPct: [70, 30],
    alignments: ['left', 'right'],
    isTotalRow: (idx, row) {
      final desc = row[0]?.toString() ?? '';
      return desc.startsWith('TOTAL') || desc.startsWith('UTILIDAD');
    },
  );

  // 3. ESTADO DE FLUJO DE EFECTIVO
  doc.addHeading1('3. Control de Flujo de Efectivo');
  final flujoRows = <List<Object?>>[
    ['Saldo en Caja Inicial', caja.cajaInicial],
    ['(+) Capital Recuperado ingresado a caja', caja.capitalRecuperado],
    ['(+) Cobro de intereses efectivo', caja.interesesCobrados],
    ['(-) Gastos operativos efectuados', caja.gastosDiarios],
    ['(-) Egresos desembolsados', caja.egresos],
    ['SALDO ACTUAL EN CAJA', caja.cajaActual],
  ];

  doc.addTable(
    headers: ['Movimiento de Flujo', 'Monto (C\$)'],
    rows: flujoRows,
    colWidthsPct: [70, 30],
    alignments: ['left', 'right'],
    isTotalRow: (idx, row) => idx == 0 || idx == flujoRows.length - 1,
  );

  // 4. CARTERA Y GESTIÓN DE RIESGO
  doc.addHeading1('4. Análisis de Cartera y Recuperación');
  final carteraRows = <List<Object?>>[
    ['Clientes atendidos en cartera', '${cartera.clientesCount} personas'],
    ['Total de créditos gestionados', '${cartera.prestamosCount} préstamos'],
    ['Créditos en estado normal / activo', '${cartera.activosCount} (${Fmt.cordobas(cartera.activosMonto)})'],
    ['Créditos completamente pagados', '${cartera.pagadosCount} (${Fmt.cordobas(cartera.pagadosMonto)})'],
    ['Créditos en mora total', '${cartera.enMoraCount} (${Fmt.cordobas(cartera.enMoraMonto)})'],
    ['Porcentaje de cartera en mora', '${pctMora.toStringAsFixed(2)}%'],
  ];

  doc.addTable(
    headers: ['Indicador de Cartera', 'Valor / Monto'],
    rows: carteraRows,
    colWidthsPct: [60, 40],
    alignments: ['left', 'right'],
  );

  // Firmas
  doc.addSignatures(
    cargo1: 'Elaborado por (Administración Findex)',
    cargo2: 'Revisado y Aprobado por (Gerencia General)',
  );

  return doc.buildBytes();
}