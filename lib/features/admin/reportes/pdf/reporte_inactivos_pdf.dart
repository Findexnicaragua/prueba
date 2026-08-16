import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte de clientes inactivos: clientes sin pagos en los ultimos N meses.
///
/// [rows] viene de la query con keys: nombre, comunidad, telefono,
/// ultimo_pago, dias_sin_pago.
Future<pw.Document> buildReporteInactivos({
  required String titulo,
  required String empresaNombre,
  required String periodo,
  required List<Map<String, dynamic>> rows,
  required int mesesInactividad,
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
        periodo: 'Sin pagos en los últimos $mesesInactividad meses',
        logo: logo,
      ),
      footer: (context) => buildFooterEstandar(context),
      build: (context) => [
        _buildTable(rows),
        pw.SizedBox(height: 20),
        _buildResumen(rows, mesesInactividad),
      ],
    ),
  );

  return pdf;
}

// ---------------------------------------------------------------------------
// Tabla de inactivos
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
      0: const pw.FlexColumnWidth(2.5), // Cliente
      1: const pw.FlexColumnWidth(2),   // Comunidad
      2: const pw.FlexColumnWidth(1.5), // Telefono
      3: const pw.FlexColumnWidth(1.5), // Ultimo pago
      4: const pw.FlexColumnWidth(1.2), // Dias sin pago
    },
    headers: ['Cliente', 'Comunidad', 'Teléfono', 'Último pago',
        'Días sin pagar'],
    data: rows.isEmpty
        ? [['Sin clientes inactivos', '', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            final ultimoPago = r['ultimo_pago'] as String?;
            return [
              (r['nombre'] as String?) ?? '—',
              (r['comunidad'] as String?) ?? '—',
              (r['telefono'] as String?) ?? '—',
              ultimoPago != null
                  ? _formatearFecha(ultimoPago)
                  : 'Sin pagos',
              '${(r['dias_sin_pago'] as num?) ?? '—'}',
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

pw.Widget _buildResumen(List<Map<String, dynamic>> rows, int meses) {
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.orange50,
      borderRadius: pw.BorderRadius.circular(4),
      border: pw.Border.all(color: PdfColors.orange200),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          '${rows.length} clientes sin pagos en los ultimos $meses meses',
          style: estiloTotal,
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
