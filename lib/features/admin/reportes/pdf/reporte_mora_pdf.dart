import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Genera un PDF de "Reporte de mora" con clientes en estado deudor.
///
/// Parámetros:
///   - [titulo]: ej "Reporte de mora — Mayo 2026"
///   - [rows]: lista de Maps con keys: cliente_nombre, cuotas_vencidas,
///     monto_adeudado, dias_mora, comunidad
///   - [empresaNombre]: nombre del ISP para el header
///   - [periodo]: texto descriptivo del período
///
/// Las filas vienen pre-ordenadas por dias_mora DESC desde la query.
/// Retorna el Document PDF listo para imprimir/descargar.
Future<pw.Document> buildReporteMora({
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
      pageFormat: PdfPageFormat.letter,
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
// Tabla de mora
// ---------------------------------------------------------------------------

pw.Widget _buildTable(List<Map<String, dynamic>> rows) {
  return pw.TableHelper.fromTextArray(
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    headerDecoration: const pw.BoxDecoration(color: colorHeaderTabla),
    headerStyle: estiloColumna,
    cellStyle: estiloCelda,
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignment: pw.Alignment.centerLeft,
    // Orden de columnas alineado con el export Excel: Comunidad como 2ª.
    columnWidths: {
      0: const pw.FlexColumnWidth(2.5), // Cliente
      1: const pw.FlexColumnWidth(2),   // Comunidad
      2: const pw.FlexColumnWidth(1.5), // Cuotas vencidas
      3: const pw.FlexColumnWidth(1.8), // Monto adeudado
      4: const pw.FlexColumnWidth(1.2), // Días de mora
    },
    headers: [
      'Cliente',
      'Comunidad',
      'Cuotas vencidas',
      'Monto adeudado (C\$)',
      'Días de mora',
    ],
    data: rows.isEmpty
        ? [['Sin clientes en mora', '', '', '', '']]
        : List.generate(rows.length, (i) {
      final r = rows[i];
      return [
        (r['cliente_nombre'] as String?) ?? '—',
        (r['comunidad'] as String?) ?? '—',
        '${(r['cuotas_vencidas'] as num?) ?? 0}',
        fmtCordobas((r['monto_adeudado'] as num?) ?? 0),
        '${(r['dias_mora'] as num?) ?? 0}',
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
  final totalAdeudo = rows.fold<double>(
    0,
    (sum, r) => sum + ((r['monto_adeudado'] as num?) ?? 0).toDouble(),
  );
  final totalCuotas = rows.fold<int>(
    0,
    (sum, r) => sum + ((r['cuotas_vencidas'] as num?) ?? 0).toInt(),
  );
  final cantClientes = rows.length;

  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.red50,
      borderRadius: pw.BorderRadius.circular(4),
      border: pw.Border.all(color: PdfColors.red200),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Resumen de mora', style: estiloTotal),
        pw.SizedBox(height: 6),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Clientes en mora: $cantClientes',
              style: estiloCelda,
            ),
            pw.Text(
              'Cuotas vencidas: $totalCuotas',
              style: estiloCelda,
            ),
            pw.Text(
              'Adeudo total: ${fmtCordobas(totalAdeudo)}',
              style: estiloTotal,
            ),
          ],
        ),
      ],
    ),
  );
}
