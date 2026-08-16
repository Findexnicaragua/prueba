import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte de eficiencia por cobrador: cobros realizados, clientes
/// visitados, tasa de exito.
///
/// [rows] viene de la query con keys: cobrador_nombre, total_cobros,
/// clientes_visitados, monto_total, cuotas_asignadas.
Future<pw.Document> buildReporteEficiencia({
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
// Tabla de eficiencia
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
      0: const pw.FlexColumnWidth(2.2), // Cobrador
      1: const pw.FlexColumnWidth(1.3), // Cobros realizados
      2: const pw.FlexColumnWidth(1.4), // Clientes cobrados
      3: const pw.FlexColumnWidth(1.9), // Total recaudado
      4: const pw.FlexColumnWidth(1.4), // Cuotas asignadas
      5: const pw.FlexColumnWidth(1.1), // % de éxito
    },
    headers: [
      'Cobrador',
      'Cobros realizados',
      'Clientes cobrados',
      'Total recaudado (C\$)',
      'Cuotas asignadas',
      '% de éxito',
    ],
    data: rows.isEmpty
        ? [['Sin datos de cobradores', '', '', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            final cobros = ((r['total_cobros'] as num?) ?? 0).toInt();
            final asignadas =
                ((r['cuotas_asignadas'] as num?) ?? 0).toInt();
            final tasa = asignadas > 0
                ? '${((cobros / asignadas) * 100).clamp(0, 100).toStringAsFixed(1)}%'
                : '—';
            return [
              (r['cobrador_nombre'] as String?) ?? '—',
              '$cobros',
              '${(r['clientes_visitados'] as num?) ?? 0}',
              fmtCordobas((r['monto_total'] as num?) ?? 0),
              '$asignadas',
              tasa,
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
  final totalCobros = rows.fold<int>(
    0,
    (sum, r) => sum + ((r['total_cobros'] as num?) ?? 0).toInt(),
  );
  final totalMonto = rows.fold<double>(
    0,
    (sum, r) => sum + ((r['monto_total'] as num?) ?? 0).toDouble(),
  );
  final totalAsignadas = rows.fold<int>(
    0,
    (sum, r) => sum + ((r['cuotas_asignadas'] as num?) ?? 0).toInt(),
  );
  final tasaGlobal = totalAsignadas > 0
      ? '${((totalCobros / totalAsignadas) * 100).clamp(0, 100).toStringAsFixed(1)}%'
      : '—';

  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.blueGrey50,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Resumen de eficiencia', style: estiloTotal),
        pw.SizedBox(height: 6),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('${rows.length} cobradores · $totalCobros cobros',
                style: estiloCelda),
            pw.Text('Tasa global: $tasaGlobal', style: estiloCelda),
            pw.Text('Total: ${fmtCordobas(totalMonto)}', style: estiloTotal),
          ],
        ),
      ],
    ),
  );
}
