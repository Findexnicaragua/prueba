import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../data/utils/formatters.dart';
import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Genera el PDF "Historial de pagos" de UN cliente (estado de cuenta
/// imprimible, hasta 1 año). Encabezado estándar + datos personales del
/// cliente + tabla de pagos (de TODOS sus contratos) + total del período.
///
/// Parámetros:
///   - [empresaNombre] / [periodo]: para el header estándar.
///   - [cliente]: Map con codigo, nombre, cedula, telefono, direccion,
///     direccion_referencia, comunidad, cobrador_asignado.
///   - [rows]: pagos NO anulados del rango, pre-ordenados por fecha DESC, con
///     keys: fecha_pago, periodo, recibo, cobrador, metodo, referencia,
///     moneda, monto_cordobas, monto_original.
///
/// Retorna el Document listo para guardar/imprimir (el caller hace `.save()`).
Future<pw.Document> buildHistorialClientePdf({
  required String empresaNombre,
  required String periodo,
  required Map<String, dynamic> cliente,
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
        titulo: 'Historial de pagos',
        periodo: periodo,
        logo: logo,
      ),
      footer: (context) => buildFooterEstandar(context),
      build: (context) => [
        _bloqueCliente(cliente),
        pw.SizedBox(height: 12),
        _buildTabla(rows),
        pw.SizedBox(height: 12),
        _buildTotal(rows),
      ],
    ),
  );

  return pdf;
}

// ---------------------------------------------------------------------------
// Datos personales del cliente
// ---------------------------------------------------------------------------

pw.Widget _bloqueCliente(Map<String, dynamic> c) {
  pw.Widget par(String label, String? value) => pw.Expanded(
        child: pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.RichText(
            text: pw.TextSpan(children: [
              pw.TextSpan(text: '$label: ', style: estiloSubtitulo()),
              pw.TextSpan(
                text: (value == null || value.trim().isEmpty) ? '—' : value,
                style: estiloCelda,
              ),
            ]),
          ),
        ),
      );

  final dir = [c['direccion'], c['direccion_referencia']]
      .where((x) => x != null && x.toString().trim().isNotEmpty)
      .join(' — ');

  return pw.Container(
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(
      color: PdfColors.grey100,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(children: [
          par('Código', c['codigo']?.toString()),
          par('Nombre', c['nombre']?.toString()),
        ]),
        pw.Row(children: [
          par('Cédula', c['cedula']?.toString()),
          par('Teléfono', c['telefono']?.toString()),
        ]),
        pw.Row(children: [par('Dirección', dir.isEmpty ? null : dir)]),
        pw.Row(children: [
          par('Comunidad', c['comunidad']?.toString()),
          par('Cobrador asignado', c['cobrador_asignado']?.toString()),
        ]),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Tabla de pagos
// ---------------------------------------------------------------------------

pw.Widget _buildTabla(List<Map<String, dynamic>> rows) {
  return pw.TableHelper.fromTextArray(
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    headerDecoration: const pw.BoxDecoration(color: colorHeaderTabla),
    headerStyle: estiloColumna,
    cellStyle: estiloCelda,
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignment: pw.Alignment.centerLeft,
    cellAlignments: {6: pw.Alignment.centerRight},
    columnWidths: {
      0: const pw.FlexColumnWidth(1.2), // Fecha
      1: const pw.FlexColumnWidth(1.3), // Período
      2: const pw.FlexColumnWidth(1.1), // Recibo #
      3: const pw.FlexColumnWidth(1.7), // Cobrador
      4: const pw.FlexColumnWidth(1.4), // Método
      5: const pw.FlexColumnWidth(1.5), // Referencia
      6: const pw.FlexColumnWidth(1.5), // Monto
    },
    headers: [
      'Fecha',
      'Período',
      'Recibo #',
      'Cobrador',
      'Método',
      'Referencia',
      'Monto',
    ],
    data: rows.isEmpty
        ? [
            ['Sin pagos en el período', '', '', '', '', '', '']
          ]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            final monto = (r['monto_cordobas'] as num?) ?? 0;
            final esUsd = (r['moneda']?.toString() ?? 'NIO') == 'USD';
            final montoStr = esUsd
                ? '${fmtCordobas(monto)} (US\$ ${((r['monto_original'] as num?) ?? 0).toStringAsFixed(2)})'
                : fmtCordobas(monto);
            final ref = r['referencia']?.toString().trim();
            return [
              _fechaLabel(r['fecha_pago'] as String?),
              _periodoLabel(r['dia_pago'], r['periodo'] as String?),
              (r['recibo']?.toString().trim().isNotEmpty ?? false)
                  ? r['recibo'].toString()
                  : '—',
              (r['cobrador']?.toString().trim().isNotEmpty ?? false)
                  ? r['cobrador'].toString()
                  : '—',
              _metodoLabel(r['metodo'] as String?),
              (ref == null || ref.isEmpty) ? '—' : ref,
              montoStr,
            ];
          }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

// ---------------------------------------------------------------------------
// Total del período
// ---------------------------------------------------------------------------

pw.Widget _buildTotal(List<Map<String, dynamic>> rows) {
  final total = rows.fold<double>(
    0,
    (sum, r) => sum + ((r['monto_cordobas'] as num?) ?? 0).toDouble(),
  );
  return pw.Container(
    alignment: pw.Alignment.centerRight,
    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: pw.BoxDecoration(
      color: PdfColors.blueGrey50,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Text(
      'Total pagado en el período: ${fmtCordobas(total)}',
      style: estiloTotal,
    ),
  );
}

// ---------------------------------------------------------------------------
// Formato
// ---------------------------------------------------------------------------

const _meses = [
  '', 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'
];

/// `fecha_pago` (ISO/local-naive) → 'dd/MM/yyyy'.
String _fechaLabel(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  final d = DateTime.tryParse(iso);
  return d == null ? '—' : fmtFechaCorta(d);
}

/// Mes de SERVICIO de la cuota → 'Mes Año' (ej. 'Junio 2026').
///
/// NO sale de `cuotas.periodo`: ese es el mes de VENCIMIENTO y ARQUITECTURA
/// §3.5 lo declara etiqueta interna que no se muestra cruda (con `dia_pago` 14,
/// la cuota de periodo julio es la de servicio de junio).
///
/// Se ancla al `dia_pago` y NO al día del vencimiento: ese trae el ajuste
/// domingo→lunes, que es de COBRO y no de servicio, y hacía que dos cuotas
/// consecutivas salieran con el mismo mes (ver `_mesDeServicio` del Excel).
String _periodoLabel(Object? diaPago, String? periodo) {
  final d = _fecha(periodo);
  if (d == null) return '—';
  final dia = diaPago is int ? diaPago : int.tryParse('${diaPago ?? ''}');
  if (dia == null) return '${_meses[d.month]} ${d.year}';
  final m = Fmt.mesServicio(dia, d);
  return '${_meses[m.month]} ${m.year}';
}

DateTime? _fecha(String? v) {
  if (v == null || v.isEmpty) return null;
  return DateTime.tryParse(v.length == 7 ? '$v-01' : v);
}

String _metodoLabel(String? m) {
  switch (m) {
    case 'efectivo':
      return 'Efectivo';
    case 'transferencia':
      return 'Transferencia';
    case 'deposito':
      return 'Depósito';
    case 'tarjeta':
      return 'Tarjeta';
    default:
      return (m == null || m.isEmpty) ? '—' : m;
  }
}
