import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../data/models/pago.dart';
import '../../../../data/utils/cobrador_helpers.dart';
import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte de cobros por cobrador. Acepta UNO o VARIOS cobradores (incluidos
/// admins que hayan ejecutado pagos): agrupa las filas por cobrador, con un
/// subtotal por cada uno y, si hay más de uno, un total general al final.
/// `rows` debe traer `cobrador_nombre` y `cobrador_rol`, ordenado por cobrador.
Future<pw.Document> buildReportePorCobrador({
  required String titulo,
  required String empresaNombre,
  required String periodo,
  required String subtitulo,
  required List<Map<String, dynamic>> rows,
  Uint8List? logoBytes,
}) async {
  final pdf = pw.Document();
  final theme = await pdfTheme();
  final logo = logoBytes == null ? null : pw.MemoryImage(logoBytes);

  // Agrupar por cobrador_id (estable ante homónimos), preservando el orden
  // (rows ya viene ordenado por nombre de cobrador). El nombre es solo label.
  final grupos = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    final key = (r['cobrador_id'] as String?) ??
        (r['cobrador_nombre'] as String?) ??
        '—';
    grupos.putIfAbsent(key, () => []).add(r);
  }

  pdf.addPage(
    pw.MultiPage(
      theme: theme,
      // Landscape: columnas extra de moneda/tasa/vuelto no entran en vertical.
      pageFormat: PdfPageFormat.letter.landscape,
      header: (context) => buildHeaderEstandar(
        empresaNombre: empresaNombre,
        titulo: '$titulo — $subtitulo',
        periodo: periodo,
        logo: logo,
      ),
      footer: (context) => buildFooterEstandar(context),
      build: (context) {
        if (rows.isEmpty) return [_buildTable(const [])];

        final unSoloGrupo = grupos.length == 1;
        final widgets = <pw.Widget>[];
        for (final entry in grupos.entries) {
          final gr = entry.value;
          final nombre = (gr.first['cobrador_nombre'] as String?) ?? '—';
          final rol = gr.first['cobrador_rol'] as String?;
          final encabezado =
              rol == null ? nombre : '$nombre — ${rolLabel(rol)}';
          widgets.add(pw.Padding(
            padding: const pw.EdgeInsets.only(top: 8, bottom: 4),
            child: pw.Text(encabezado,
                style: pw.TextStyle(
                    fontSize: 11, fontWeight: pw.FontWeight.bold)),
          ));
          widgets.add(_buildTable(gr));
          widgets.add(pw.SizedBox(height: 6));
          // Con un solo cobrador el subtotal ES el total.
          widgets.add(_buildTotalBox(gr, unSoloGrupo ? 'Total' : 'Subtotal'));
          widgets.add(pw.SizedBox(height: 14));
        }
        if (!unSoloGrupo) {
          widgets.add(_buildTotalBox(rows, 'TOTAL GENERAL'));
        }
        return widgets;
      },
    ),
  );

  return pdf;
}

pw.Widget _buildTable(List<Map<String, dynamic>> rows) {
  return pw.TableHelper.fromTextArray(
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    headerDecoration: const pw.BoxDecoration(color: colorHeaderTabla),
    headerStyle: estiloColumna,
    cellStyle: estiloCelda,
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignment: pw.Alignment.centerLeft,
    columnWidths: {
      0: const pw.FlexColumnWidth(1.4), // Fecha
      1: const pw.FlexColumnWidth(2.3), // Cliente
      2: const pw.FlexColumnWidth(1.4), // Monto cobrado (C$)
      3: const pw.FlexColumnWidth(0.9), // Moneda
      4: const pw.FlexColumnWidth(1.3), // Entregado (orig.)
      5: const pw.FlexColumnWidth(0.9), // Tasa
      6: const pw.FlexColumnWidth(1.2), // Vuelto (C$)
      7: const pw.FlexColumnWidth(1.2), // Método
      8: const pw.FlexColumnWidth(1.3), // Recibo
    },
    headers: ['Fecha de cobro', 'Cliente', 'Monto cobrado (C\$)',
        'Moneda', 'Entregado (orig.)', 'Tasa', 'Vuelto (C\$)',
        'Método de pago', 'Nro. de recibo'],
    data: rows.isEmpty
        ? [['', 'Sin cobros en el período', '', '', '', '', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            final moneda = r['moneda'] as String?;
            final esUsd = moneda == 'USD';
            final vuelto = ((r['vuelto_cordobas'] as num?) ?? 0).toDouble();
            return [
              _formatearFecha(r['fecha_pago'] as String? ?? ''),
              (r['cliente_nombre'] as String?) ?? '—',
              fmtCordobas((r['monto'] as num?) ?? 0),
              monedaSimbolo(moneda),
              fmtMontoMoneda((r['monto_original'] as num?) ?? 0, moneda),
              esUsd
                  ? ((r['tasa_conversion'] as num?) ?? 1).toStringAsFixed(2)
                  : '—',
              vuelto > 0 ? fmtCordobas(vuelto) : '—',
              MetodoPago.fromString((r['metodo'] as String?) ?? '').label,
              (r['numero_recibo'] as String?) ?? '—',
            ];
          }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

pw.Widget _buildTotalBox(List<Map<String, dynamic>> rows, String etiqueta) {
  final total = rows.fold<double>(
      0.0, (sum, r) => sum + ((r['monto'] as num?) ?? 0).toDouble());
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.blueGrey50,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('$etiqueta: ${rows.length} cobro(s)', style: estiloTotal),
        pw.Text(fmtCordobas(total), style: estiloTotal),
      ],
    ),
  );
}

String _formatearFecha(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  // fecha_pago es hora local Nicaragua (wall-clock): formatear directo, sin
  // shift de TZ. Coincide con el recibo y con el bucket date(fecha_pago).
  return fmtFechaCorta(d);
}
