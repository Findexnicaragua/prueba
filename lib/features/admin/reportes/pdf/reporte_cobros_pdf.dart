import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../data/models/pago.dart';
import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Genera un PDF de "Reporte de cobros" con los datos proporcionados.
///
/// Parámetros:
///   - [titulo]: ej "Reporte de cobros — Mayo 2026"
///   - [rows]: lista de Maps con keys: fecha_pago, cliente_nombre, monto,
///     metodo, cobrador_nombre, numero_recibo
///   - [empresaNombre]: nombre del ISP para el header
///   - [periodo]: texto descriptivo del período
///
/// Retorna el Document PDF listo para imprimir/descargar.
Future<pw.Document> buildReporteCobros({
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
      // Landscape: la tabla suma columnas de moneda/tasa/vuelto y no entra en
      // vertical.
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
        _buildTotals(rows),
      ],
    ),
  );

  return pdf;
}

// ---------------------------------------------------------------------------
// Tabla de cobros
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
      0: const pw.FlexColumnWidth(1.3), // Fecha de cobro
      1: const pw.FlexColumnWidth(2.0), // Cliente
      2: const pw.FlexColumnWidth(1.3), // Monto cobrado (C$)
      3: const pw.FlexColumnWidth(0.8), // Moneda
      4: const pw.FlexColumnWidth(1.2), // Entregado (orig.)
      5: const pw.FlexColumnWidth(0.8), // Tasa
      6: const pw.FlexColumnWidth(1.1), // Vuelto (C$)
      7: const pw.FlexColumnWidth(1.1), // Método de pago
      8: const pw.FlexColumnWidth(1.5), // Cobrador
      9: const pw.FlexColumnWidth(1.1), // N° de recibo
      10: const pw.FlexColumnWidth(1.2), // Ref. cobro múltiple
    },
    headers: ['Fecha de cobro', 'Cliente', 'Monto cobrado (C\$)',
        'Moneda', 'Entregado (orig.)', 'Tasa', 'Vuelto (C\$)',
        'Método de pago', 'Cobrador', 'Nro. de recibo', 'Ref. cobro múltiple'],
    data: rows.isEmpty
        ? [['', '', 'Sin cobros en el período', '', '', '', '', '', '', '', '']]
        : List.generate(rows.length, (i) {
      final r = rows[i];
      final fecha = r['fecha_pago'] as String? ?? '';
      final fechaFmt = _formatearFecha(fecha);
      final moneda = r['moneda'] as String?;
      final esUsd = moneda == 'USD';
      final vuelto = ((r['vuelto_cordobas'] as num?) ?? 0).toDouble();
      return [
        fechaFmt,
        (r['cliente_nombre'] as String?) ?? '—',
        fmtCordobas((r['monto'] as num?) ?? 0),
        monedaSimbolo(moneda),
        fmtMontoMoneda((r['monto_original'] as num?) ?? 0, moneda),
        // Tasa solo si es USD (en C$ siempre es 1 → '—').
        esUsd ? ((r['tasa_conversion'] as num?) ?? 1).toStringAsFixed(2) : '—',
        vuelto > 0 ? fmtCordobas(vuelto) : '—',
        MetodoPago.fromString((r['metodo'] as String?) ?? '').label,
        (r['cobrador_nombre'] as String?) ?? '—',
        (r['numero_recibo'] as String?) ?? '—',
        (r['ref_grupo'] as String?) ?? '',
      ];
    }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

// ---------------------------------------------------------------------------
// Totales
// ---------------------------------------------------------------------------

pw.Widget _buildTotals(List<Map<String, dynamic>> rows) {
  final totalMonto = rows.fold<double>(
    0,
    (sum, r) => sum + ((r['monto'] as num?) ?? 0).toDouble(),
  );
  final cantCobros = rows.length;

  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.blueGrey50,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('Total: $cantCobros cobros', style: estiloTotal),
        pw.Text('Monto total: ${fmtCordobas(totalMonto)}', style: estiloTotal),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Helpers internos
// ---------------------------------------------------------------------------

/// Convierte "2026-05-24" o "2026-05-24T14:30:00" → "24/05/2026".
String _formatearFecha(String raw) {
  final dt = DateTime.tryParse(raw);
  if (dt == null) return raw;
  // fecha_pago es hora local Nicaragua (wall-clock): formatear directo, sin
  // shift de TZ. Coincide con el recibo y con el bucket date(fecha_pago).
  return fmtFechaCorta(dt);
}
