import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte de clientes con estado de cuenta.
/// Columnas: Cliente, Comunidad, Cuotas pendientes, Saldo, Último pago.
Future<pw.Document> buildReporteClientes({
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
        _buildSummary(rows),
      ],
    ),
  );

  return pdf;
}

/// Marca de fila para la deuda que sigue en cartera pero FUERA DE RUTAS:
/// contratos suspendidos y cancelados. Antes solo se marcaban los suspendidos,
/// así que la deuda de contratos cancelados salía sin ninguna señal (y peor:
/// el pie la contaba como activa — audit 2026-08-08). La usan el PDF y el Excel.
String marcaFueraDeRuta(String nombre, Map<String, dynamic> r) {
  final susp = ((r['saldo_suspendido'] as num?) ?? 0).toDouble();
  final canc = ((r['saldo_cancelado'] as num?) ?? 0).toDouble();
  final marcas = <String>[
    if (susp > 0.009) 'susp.',
    if (canc > 0.009) 'canc.',
  ];
  return marcas.isEmpty ? nombre : '$nombre (${marcas.join(' + ')})';
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
      0: const pw.FlexColumnWidth(2.5),
      1: const pw.FlexColumnWidth(2),
      2: const pw.FlexColumnWidth(1.3),
      3: const pw.FlexColumnWidth(1.5),
      4: const pw.FlexColumnWidth(1.5),
    },
    headers: ['Cliente', 'Comunidad', 'Cuotas pendientes',
        'Saldo pendiente (C\$)', 'Último pago'],
    data: rows.isEmpty
        ? [['Sin clientes', '', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            final ultimoPago = r['ultimo_pago'] as String?;
            final nombre = (r['nombre'] as String?) ?? '—';
            return [
              marcaFueraDeRuta(nombre, r),
              (r['comunidad'] as String?) ?? '—',
              '${(r['pendientes'] as num?) ?? 0}',
              fmtCordobas((r['saldo'] as num?) ?? 0),
              ultimoPago != null ? _formatearFecha(ultimoPago) : 'Sin pagos',
            ];
          }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

pw.Widget _buildSummary(List<Map<String, dynamic>> rows) {
  final totalSaldo = rows.fold<double>(
      0.0, (sum, r) => sum + ((r['saldo'] as num?) ?? 0).toDouble());
  final totalSuspendido = rows.fold<double>(
      0.0, (sum, r) => sum + ((r['saldo_suspendido'] as num?) ?? 0).toDouble());
  final totalCancelado = rows.fold<double>(
      0.0, (sum, r) => sum + ((r['saldo_cancelado'] as num?) ?? 0).toDouble());
  // En ruta = lo que queda tras sacar TODO lo fuera de ruta. Antes se restaban
  // solo los suspendidos y la deuda de contratos cancelados se imprimía como
  // activa (audit 2026-08-08: C$168.987,21 de más en Telecable Mairena).
  final totalActivo = totalSaldo - totalSuspendido - totalCancelado;
  final hayFueraDeRuta =
      totalSuspendido > 0.009 || totalCancelado > 0.009;
  final totalPendientes = rows.fold<int>(
      0, (sum, r) => sum + ((r['pendientes'] as num?) ?? 0).toInt());
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.blueGrey50,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
                '${rows.length} clientes · $totalPendientes cuotas pendientes',
                style: estiloTotal),
            pw.Text('Saldo total: ${fmtCordobas(totalSaldo)}',
                style: estiloTotal),
          ],
        ),
        // Desglose: el saldo total incluye deuda FUERA DE RUTA (contratos
        // suspendidos y cancelados — sigue en cartera y se sigue cobrando).
        // Se imprimen los tres renglones para que el total cierre a la vista.
        //
        // Un renglón por línea, con el monto a la derecha: en un Row horizontal
        // del paquete pdf, un Text NO flexible recibe maxWidth infinito y NO
        // envuelve, así que los tres desgloses en un solo Text se dibujaban en
        // una línea de 499pt dentro de 444pt útiles y se salían del recuadro
        // (audit 2026-08-08). Mismo patrón que reporte_arqueo_pdf.
        if (hayFueraDeRuta) ...[
          pw.SizedBox(height: 6),
          _renglonDesglose('En ruta (contratos activos)', totalActivo),
          _renglonDesglose('Fuera de ruta — suspendidos', totalSuspendido),
          _renglonDesglose('Fuera de ruta — cancelados', totalCancelado),
        ],
      ],
    ),
  );
}

/// Renglón del desglose del pie: etiqueta a la izquierda (flexible, envuelve si
/// hace falta) y monto pegado a la derecha.
pw.Widget _renglonDesglose(String etiqueta, double monto) {
  const estilo = pw.TextStyle(fontSize: 9, color: PdfColors.grey700);
  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 2),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Expanded(child: pw.Text(etiqueta, style: estilo)),
        pw.Text(fmtCordobas(monto), style: estilo),
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
