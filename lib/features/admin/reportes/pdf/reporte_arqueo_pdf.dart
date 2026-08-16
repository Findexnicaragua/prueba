import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pdf_theme.dart';
import '../arqueo_calculo.dart';
import 'pdf_utils.dart';

/// Reporte de arqueo / cierre por cobrador.
///
/// READ-ONLY: a partir de los pagos del rango, arma por cada cobrador un
/// bloque con el efectivo físico (separado por moneda US$/C$), el vuelto que
/// entregó, el electrónico (transferencia/depósito/tarjeta), y dos totales que
/// DEBEN cuadrar entre sí:
///   - Equivalente total en C$, valuando los dólares a la tasa de CADA cobro.
///   - Ingreso registrado (recaudado contable, misma tasa de cada cobro).
/// Si difieren, hay data de pago corrupta (violación del invariante #3).
///
/// [rows] viene de la query del screen con keys: cobrador_nombre,
/// total_cobros, efectivo_usd, efectivo_usd_qty, efectivo_usd_equiv,
/// efectivo_nio, efectivo_nio_qty, efectivo_vuelto, efectivo_ingreso,
/// transferencia, transferencia_qty, deposito, deposito_qty, tarjeta,
/// tarjeta_qty, ingreso_total.
Future<pw.Document> buildReporteArqueo({
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
      build: (context) {
        if (rows.isEmpty) {
          return [
            pw.Text('Sin cobros en el período seleccionado.',
                style: estiloCelda),
          ];
        }
        return [
          for (final r in rows) ...[
            _bloqueCobrador(_Arqueo.fromRow(r)),
            pw.SizedBox(height: 14),
          ],
          pw.SizedBox(height: 6),
          _bloqueTotalGeneral(_Arqueo.total(rows)),
        ];
      },
    ),
  );

  return pdf;
}

// ---------------------------------------------------------------------------
// Modelo de arqueo (matemática del cierre)
// ---------------------------------------------------------------------------

class _Arqueo {
  _Arqueo({
    required this.nombre,
    required this.totalCobros,
    required this.efectivoUsd,
    required this.efectivoUsdQty,
    required this.efectivoNio,
    required this.efectivoNioQty,
    required this.efectivoVuelto,
    required this.transferencia,
    required this.transferenciaQty,
    required this.deposito,
    required this.depositoQty,
    required this.tarjeta,
    required this.tarjetaQty,
    required this.ingresoTotal,
    required this.efectivoUsdEquiv,
    required this.devoluciones,
  });

  final String nombre;
  final int totalCobros;
  final double efectivoUsd; // US$ físicos recibidos (monto_original)
  final int efectivoUsdQty;
  final double efectivoNio; // C$ físicos recibidos (monto_original)
  final int efectivoNioQty;
  final double efectivoVuelto; // C$ devueltos al cliente (todos los efectivo)
  final double transferencia;
  final int transferenciaQty;
  final double deposito;
  final int depositoQty;
  final double tarjeta;
  final int tarjetaQty;
  final double ingresoTotal; // recaudado contable (monto_cordobas)
  // Equivalente en C$ del efectivo USD, a la tasa de cada cobro
  // (monto_cordobas + vuelto_cordobas). Tasa histórica, no la de hoy.
  final double efectivoUsdEquiv;
  // Devoluciones de saldo a favor en efectivo (0127): salen de la caja.
  final double devoluciones;

  static double _d(Map<String, dynamic> r, String k) =>
      ((r[k] as num?) ?? 0).toDouble();
  static int _i(Map<String, dynamic> r, String k) =>
      ((r[k] as num?) ?? 0).toInt();

  factory _Arqueo.fromRow(Map<String, dynamic> r) {
    return _Arqueo(
      nombre: (r['cobrador_nombre'] as String?) ?? '—',
      totalCobros: _i(r, 'total_cobros'),
      efectivoUsd: _d(r, 'efectivo_usd'),
      efectivoUsdQty: _i(r, 'efectivo_usd_qty'),
      efectivoNio: _d(r, 'efectivo_nio'),
      efectivoNioQty: _i(r, 'efectivo_nio_qty'),
      efectivoVuelto: _d(r, 'efectivo_vuelto'),
      transferencia: _d(r, 'transferencia'),
      transferenciaQty: _i(r, 'transferencia_qty'),
      deposito: _d(r, 'deposito'),
      depositoQty: _i(r, 'deposito_qty'),
      tarjeta: _d(r, 'tarjeta'),
      tarjetaQty: _i(r, 'tarjeta_qty'),
      ingresoTotal: _d(r, 'ingreso_total'),
      efectivoUsdEquiv: _d(r, 'efectivo_usd_equiv'),
      devoluciones: _d(r, 'devoluciones'),
    );
  }

  /// Suma todas las filas en un solo arqueo "TOTAL GENERAL".
  factory _Arqueo.total(List<Map<String, dynamic>> rows) {
    double sumD(String k) =>
        rows.fold<double>(0, (s, r) => s + _d(r, k));
    int sumI(String k) => rows.fold<int>(0, (s, r) => s + _i(r, k));
    return _Arqueo(
      nombre: 'TOTAL GENERAL (todos los cobradores)',
      totalCobros: sumI('total_cobros'),
      efectivoUsd: sumD('efectivo_usd'),
      efectivoUsdQty: sumI('efectivo_usd_qty'),
      efectivoNio: sumD('efectivo_nio'),
      efectivoNioQty: sumI('efectivo_nio_qty'),
      efectivoVuelto: sumD('efectivo_vuelto'),
      transferencia: sumD('transferencia'),
      transferenciaQty: sumI('transferencia_qty'),
      deposito: sumD('deposito'),
      depositoQty: sumI('deposito_qty'),
      tarjeta: sumD('tarjeta'),
      tarjetaQty: sumI('tarjeta_qty'),
      ingresoTotal: sumD('ingreso_total'),
      efectivoUsdEquiv: sumD('efectivo_usd_equiv'),
      devoluciones: sumD('devoluciones'),
    );
  }

  /// Matemática de dinero delegada al helper compartido con el Excel, para
  /// que el PDF y el Excel no se desincronicen.
  ArqueoCalculo get _money => ArqueoCalculo(
        efectivoUsd: efectivoUsd,
        efectivoUsdEquiv: efectivoUsdEquiv,
        efectivoNio: efectivoNio,
        efectivoVuelto: efectivoVuelto,
        transferencia: transferencia,
        deposito: deposito,
        tarjeta: tarjeta,
        ingresoTotal: ingresoTotal,
        devoluciones: devoluciones,
      );

  /// Córdobas físicos netos: lo recibido en C$ menos TODO el vuelto entregado
  /// (el vuelto de pagos USD también sale de la caja en córdobas).
  double get efectivoNetoC => _money.efectivoNetoC;

  /// Gran total en córdobas (NETO de devoluciones), valuando el USD a la tasa de
  /// cada cobro. Cuadra con `ingresoTotal − devoluciones` (0127) salvo data corrupta.
  double get equivalenteTotalC => _money.equivalenteTotalC;

  bool get tieneUsd => efectivoUsd != 0;
}

// ---------------------------------------------------------------------------
// Bloques del PDF
// ---------------------------------------------------------------------------

pw.Widget _bloqueCobrador(_Arqueo a) => _bloque(a, destacado: false);

pw.Widget _bloqueTotalGeneral(_Arqueo a) => _bloque(a, destacado: true);

pw.Widget _bloque(_Arqueo a, {required bool destacado}) {
  // Líneas del sub-bloque ELECTRÓNICO: omitir depósito/tarjeta si monto y qty
  // son 0. Transferencia se muestra siempre que haya algo (consistencia).
  final electronico = <pw.Widget>[];
  if (a.transferencia != 0 || a.transferenciaQty != 0) {
    electronico.add(_renglonMetodo(
        'Transferencia', a.transferencia, a.transferenciaQty));
  }
  if (a.deposito != 0 || a.depositoQty != 0) {
    electronico
        .add(_renglonMetodo('Depósito', a.deposito, a.depositoQty));
  }
  if (a.tarjeta != 0 || a.tarjetaQty != 0) {
    electronico.add(_renglonMetodo('Tarjeta', a.tarjeta, a.tarjetaQty));
  }

  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: destacado ? PdfColors.blueGrey50 : PdfColors.white,
      borderRadius: pw.BorderRadius.circular(4),
      border: pw.Border.all(
        color: destacado ? PdfColors.blueGrey400 : PdfColors.grey300,
        width: destacado ? 1 : 0.5,
      ),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        // Encabezado: nombre + cantidad de cobros.
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Text(a.nombre.toUpperCase(), style: estiloTotal),
            ),
            pw.Text('${a.totalCobros} cobros', style: estiloCelda),
          ],
        ),
        pw.SizedBox(height: 6),

        // EFECTIVO (caja física).
        _subtitulo('EFECTIVO (caja física)'),
        if (a.tieneUsd)
          _renglon('Dólares recibidos',
              '${fmtDolares(a.efectivoUsd)}  (${a.efectivoUsdQty})'),
        _renglon('Córdobas recibidos',
            '${fmtCordobas(a.efectivoNio)}  (${a.efectivoNioQty})'),
        _renglon('(−) Vuelto entregado', fmtCordobas(a.efectivoVuelto)),
        if (a.devoluciones != 0)
          _renglon('(−) Devoluciones de saldo a favor',
              fmtCordobas(a.devoluciones)),
        _renglon(
          'Neto a entregar',
          a.tieneUsd
              ? '${fmtDolares(a.efectivoUsd)}  +  ${fmtCordobas(a.efectivoNetoC)}'
              : fmtCordobas(a.efectivoNetoC),
          bold: true,
        ),
        // El neto en córdobas da negativo cuando el cobrador tomó pagos en
        // dólares y devolvió el vuelto en córdobas de su caja: adelantó ese
        // cambio, así que la oficina se lo reembolsa (no es un faltante).
        if (a.efectivoNetoC < 0)
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 12, top: 1, bottom: 1),
            child: pw.Text(
              'Neto en córdobas negativo: el cobrador adelantó el vuelto de '
              'pagos en dólares. La oficina le reembolsa esa diferencia.',
              // Sin fontStyle.italic: el tema embebe NotoSans regular + bold, no
              // una variante itálica → el PDF sintetizaba/caía a otra fuente
              // (audit 2026-06-30). El gris + el tamaño 8 ya diferencian la nota.
              style: const pw.TextStyle(
                fontSize: 8,
                color: PdfColors.grey600,
              ),
            ),
          ),
        if (a.tieneUsd)
          _renglon('US\$ en córdobas (tasa del cobro)',
              fmtCordobas(a.efectivoUsdEquiv)),

        // ELECTRÓNICO (al banco) — solo si hay algún método con movimiento.
        if (electronico.isNotEmpty) ...[
          pw.SizedBox(height: 6),
          _subtitulo('ELECTRÓNICO (al banco)'),
          ...electronico,
        ],

        pw.SizedBox(height: 8),
        pw.Divider(thickness: 0.5, color: PdfColors.grey400),
        _renglon('Equivalente total (C\$)',
            fmtCordobas(a.equivalenteTotalC),
            bold: true),
        _renglon('Ingreso registrado (recaudado)',
            fmtCordobas(a.ingresoTotal)),
      ],
    ),
  );
}

pw.Widget _subtitulo(String texto) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 2, bottom: 2),
      child: pw.Text(
        texto,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.blueGrey700,
        ),
      ),
    );

/// Renglón etiqueta → valor (valor alineado a la derecha).
pw.Widget _renglon(String etiqueta, String valor, {bool bold = false}) {
  final estilo = bold ? estiloTotal : estiloCelda;
  return pw.Padding(
    padding: const pw.EdgeInsets.only(left: 12, top: 1, bottom: 1),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Expanded(child: pw.Text(etiqueta, style: estilo)),
        pw.Text(valor, style: estilo),
      ],
    ),
  );
}

/// Renglón de método electrónico con monto + cantidad entre paréntesis.
pw.Widget _renglonMetodo(String etiqueta, double monto, int qty) =>
    _renglon(etiqueta, '${fmtCordobas(monto)}  ($qty)');
