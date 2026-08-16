import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../data/utils/formatters.dart';
import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

final _mesAnio = DateFormat("MMMM 'de' y", 'es_NI');

String _periodoLabel(String periodo) {
  try {
    final d = DateTime.parse(periodo);
    final s = _mesAnio.format(DateTime(d.year, d.month));
    return s.isEmpty ? periodo : (s[0].toUpperCase() + s.substring(1));
  } catch (_) {
    return periodo;
  }
}

/// PDF "Estado de deuda" del momento de suspender un contrato. Se arma del
/// SNAPSHOT guardado en `contrato_suspensiones` (reimprimible offline, sin
/// re-calcular). Reusa los helpers de los reportes (header/estilos/fuentes).
Future<pw.Document> buildPdfDeudaSuspension({
  required String empresaNombre,
  required String clienteNombre,
  String? codigo,
  String? planNombre,
  required String suspendidoEn,
  required String motivo,
  String? notas,
  int? diaPago,
  required List<Map<String, dynamic>> cuotas,
  required double total,
  // Parametrizable para reusar el mismo documento en la CANCELACIÓN (default =
  // suspensión, backward-compatible).
  String titulo = 'Estado de deuda — Suspensión de contrato',
  String fechaPrefijo = 'Suspensión',
  String fechaKvLabel = 'Suspendido el',
  String pieNota = 'Los meses suspendidos no se facturan. Documento informativo.',
}) async {
  final doc = pw.Document(theme: await pdfTheme());

  var fechaLabel = suspendidoEn;
  try {
    fechaLabel = fmtFechaCorta(DateTime.parse(suspendidoEn));
  } catch (_) {}

  pw.Widget kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(k, style: estiloSubtitulo()),
            pw.Text(v, style: estiloCelda),
          ],
        ),
      );

  doc.addPage(
    pw.MultiPage(
      footer: buildFooterEstandar,
      build: (context) => [
        buildHeaderEstandar(
          empresaNombre: empresaNombre,
          titulo: titulo,
          periodo: '$fechaPrefijo: $fechaLabel',
        ),
        kv(
            'Cliente',
            (codigo != null && codigo.isNotEmpty)
                ? '$clienteNombre · $codigo'
                : clienteNombre),
        if (planNombre != null && planNombre.isNotEmpty)
          kv('Contrato', planNombre),
        kv(fechaKvLabel, fechaLabel),
        kv('Motivo', motivo),
        if (notas != null && notas.isNotEmpty) kv('Notas', notas),
        pw.SizedBox(height: 12),
        pw.Table(
          border: pw.TableBorder.symmetric(
              inside: const pw.BorderSide(color: PdfColors.grey300)),
          columnWidths: const {
            0: pw.FlexColumnWidth(2),
            1: pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: colorHeaderTabla),
              children: [
                pw.Padding(
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Text('Período', style: estiloColumna)),
                pw.Padding(
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Text('Saldo',
                        style: estiloColumna, textAlign: pw.TextAlign.right)),
              ],
            ),
            for (final c in cuotas)
              pw.TableRow(children: [
                pw.Padding(
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Text(
                        diaPago != null
                            ? Fmt.mesServicioLabel(
                                DateTime.parse(c['periodo'] as String), diaPago)
                            : _periodoLabel(c['periodo'] as String),
                        style: estiloCelda)),
                pw.Padding(
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Text(
                        fmtCordobas((c['saldo'] as num).toDouble()),
                        style: estiloCelda,
                        textAlign: pw.TextAlign.right)),
              ]),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Total adeudado', style: estiloTotal),
            pw.Text(fmtCordobas(total), style: estiloTotal),
          ],
        ),
        pw.SizedBox(height: 16),
        pw.Text(pieNota, style: estiloSubtitulo()),
      ],
    ),
  );
  return doc;
}
