import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte de anulaciones: cobros/recibos anulados con motivo, fecha,
/// quien anulo.
///
/// [rows] viene de la query con keys: fecha_pago, cliente_nombre,
/// monto, motivo_anulacion, anulado_por_nombre, numero_recibo.
Future<pw.Document> buildReporteAnulaciones({
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
// Tabla de anulaciones
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
      0: const pw.FlexColumnWidth(1.5), // Fecha de cobro
      1: const pw.FlexColumnWidth(1.9), // Cliente
      2: const pw.FlexColumnWidth(1.4), // Monto anulado
      3: const pw.FlexColumnWidth(2),   // Motivo de anulación
      4: const pw.FlexColumnWidth(1.7), // Anulado por
      5: const pw.FlexColumnWidth(1.2), // N° de recibo
    },
    headers: [
      'Fecha de cobro',
      'Cliente',
      'Monto anulado (C\$)',
      'Motivo de anulación',
      'Anulado por',
      'Nro. de recibo',
    ],
    data: rows.isEmpty
        ? [['', '', 'Sin anulaciones', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            return [
              _formatearFecha(r['fecha_pago'] as String? ?? ''),
              (r['cliente_nombre'] as String?) ?? '—',
              fmtCordobas((r['monto'] as num?) ?? 0),
              (r['motivo_anulacion'] as String?) ?? 'Sin motivo',
              (r['anulado_por_nombre'] as String?) ?? '—',
              (r['numero_recibo'] as String?) ?? '—',
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
  final totalAnulado = rows.fold<double>(
    0,
    (sum, r) => sum + ((r['monto'] as num?) ?? 0).toDouble(),
  );

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
        pw.Text('Resumen de anulaciones', style: estiloTotal),
        pw.SizedBox(height: 6),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Total anulaciones: ${rows.length}',
              style: estiloCelda,
            ),
            pw.Text(
              'Monto anulado: ${fmtCordobas(totalAnulado)}',
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

String _formatearFecha(String raw) {
  final dt = DateTime.tryParse(raw);
  if (dt == null) return raw;
  // fecha_pago es hora local Nicaragua (wall-clock): formatear directo, sin
  // shift de TZ. Coincide con el recibo y con el bucket date(fecha_pago).
  return fmtFechaCorta(dt);
}
