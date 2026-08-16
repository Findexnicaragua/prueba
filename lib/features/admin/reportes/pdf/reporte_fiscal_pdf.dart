import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../data/models/pago.dart';
import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte fiscal/contable: ingresos por mes con desglose por plan y
/// metodo de pago.
///
/// [rows] viene de la query con keys: mes, plan_nombre, metodo,
/// total_monto, cantidad.
Future<pw.Document> buildReporteFiscal({
  required String titulo,
  required String empresaNombre,
  required String periodo,
  required List<Map<String, dynamic>> rows,
  Uint8List? logoBytes,
}) async {
  final pdf = pw.Document();
  final theme = await pdfTheme();
  final logo = logoBytes == null ? null : pw.MemoryImage(logoBytes);

  pdf.addPage(
    pw.MultiPage(
      theme: theme,
      // Landscape: el desglose por moneda agrega columnas.
      pageFormat: PdfPageFormat.letter.landscape,
      margin: const pw.EdgeInsets.all(40),
      header: (context) => buildHeaderEstandar(
        empresaNombre: empresaNombre,
        titulo: titulo,
        periodo: periodo,
        logo: logo,
      ),
      footer: (context) => buildFooterEstandar(context),
      build: (context) => [
        _buildTable(rows),
        pw.SizedBox(height: 20),
        _buildResumen(rows),
      ],
    ),
  );

  return pdf;
}

// ---------------------------------------------------------------------------
// Tabla fiscal
// ---------------------------------------------------------------------------

pw.Widget _buildTable(List<Map<String, dynamic>> rows) {
  return pw.TableHelper.fromTextArray(
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    headerDecoration: const pw.BoxDecoration(color: colorHeaderTabla),
    headerStyle: estiloColumna,
    cellStyle: estiloCelda,
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignment: pw.Alignment.centerLeft,
    columnWidths: {
      0: const pw.FlexColumnWidth(1.0), // Mes
      1: const pw.FlexColumnWidth(2.2), // Plan
      2: const pw.FlexColumnWidth(1.4), // Método de pago
      3: const pw.FlexColumnWidth(0.8), // Moneda
      4: const pw.FlexColumnWidth(1.6), // Total recaudado (C$)
      5: const pw.FlexColumnWidth(1.6), // Total entregado (orig.)
      6: const pw.FlexColumnWidth(1.2), // Cantidad de cobros
    },
    headers: ['Mes', 'Plan', 'Método de pago', 'Moneda',
        'Total recaudado (C\$)', 'Total entregado (orig.)',
        'Cantidad de cobros'],
    data: rows.isEmpty
        ? [['', '', 'Sin ingresos en el periodo', '', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            final moneda = r['moneda'] as String?;
            final esUsd = moneda == 'USD';
            return [
              _mesLabel(r['mes'] as String? ?? ''),
              (r['plan_nombre'] as String?) ?? 'Sin plan',
              MetodoPago.fromString((r['metodo'] as String?) ?? '').label,
              monedaSimbolo(moneda),
              fmtCordobas((r['total_monto'] as num?) ?? 0),
              // "Entregado (orig.)" solo en USD (dólares físicos). En C$ sería
              // recaudado+vuelto → confunde; va '—'.
              esUsd ? fmtDolares((r['total_entregado'] as num?) ?? 0) : '—',
              '${(r['cantidad'] as num?) ?? 0}',
            ];
          }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

// ---------------------------------------------------------------------------
// Resumen
// ---------------------------------------------------------------------------

pw.Widget _buildResumen(List<Map<String, dynamic>> rows) {
  final totalMonto = rows.fold<double>(
    0,
    (sum, r) => sum + ((r['total_monto'] as num?) ?? 0).toDouble(),
  );
  final totalCobros = rows.fold<int>(
    0,
    (sum, r) => sum + ((r['cantidad'] as num?) ?? 0).toInt(),
  );

  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.green50,
      borderRadius: pw.BorderRadius.circular(4),
      border: pw.Border.all(color: PdfColors.green200),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Resumen fiscal', style: estiloTotal),
        pw.SizedBox(height: 6),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Total cobros: $totalCobros', style: estiloCelda),
            pw.Text(
              'Ingresos totales: ${fmtCordobas(totalMonto)}',
              style: estiloTotal,
            ),
          ],
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Convierte "2026-05" → "May 2026".
String _mesLabel(String yyyyMm) {
  if (yyyyMm.length < 7) return yyyyMm;
  final parts = yyyyMm.split('-');
  if (parts.length < 2) return yyyyMm;
  final mes = int.tryParse(parts[1]);
  if (mes == null || mes < 1 || mes > 12) return yyyyMm;
  const nombres = [
    'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
    'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic',
  ];
  return '${nombres[mes - 1]} ${parts[0]}';
}
