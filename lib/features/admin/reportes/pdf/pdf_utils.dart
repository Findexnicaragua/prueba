import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// ---------------------------------------------------------------------------
// Estilos y helpers comunes para los PDFs de reportes.
// ---------------------------------------------------------------------------

/// Formateadores de moneda — mismos que Fmt pero devuelven String puro
/// (sin depender de Flutter, usables en el contexto pdf-only).
final _nio = NumberFormat.currency(
  locale: 'es_NI',
  symbol: r'C$',
  decimalDigits: 2,
);

final _usd = NumberFormat.currency(
  locale: 'es_NI',
  symbol: r'US$',
  decimalDigits: 2,
);

String fmtCordobas(num v) => _nio.format(v);
String fmtDolares(num v) => _usd.format(v);

/// Símbolo corto de una moneda guardada en `pagos.moneda` ('USD'/'NIO').
String monedaSimbolo(String? moneda) => moneda == 'USD' ? 'US\$' : 'C\$';

/// Formatea un monto en su moneda original ('USD' → US$, resto → C$).
String fmtMontoMoneda(num v, String? moneda) =>
    moneda == 'USD' ? fmtDolares(v) : fmtCordobas(v);

/// Fecha corta dd/MM/yyyy en locale es_NI.
final _fechaCorta = DateFormat('dd/MM/yyyy', 'es_NI');
String fmtFechaCorta(DateTime d) => _fechaCorta.format(d);

/// Fecha larga "24 de mayo de 2026".
final _fechaLarga = DateFormat("d 'de' MMMM 'de' y", 'es_NI');
String fmtFechaLarga(DateTime d) => _fechaLarga.format(d);

// ---------------------------------------------------------------------------
// Estilos de texto reutilizables
// ---------------------------------------------------------------------------

/// Nombre de la empresa en el header.
pw.TextStyle get estiloEmpresa => pw.TextStyle(
      fontSize: 16,
      fontWeight: pw.FontWeight.bold,
    );

/// Título del reporte.
pw.TextStyle get estiloTitulo => pw.TextStyle(
      fontSize: 13,
      fontWeight: pw.FontWeight.bold,
    );

/// Subtítulo / período.
pw.TextStyle estiloSubtitulo() => const pw.TextStyle(
      fontSize: 10,
      color: PdfColors.grey700,
    );

/// Header de columna en tablas.
pw.TextStyle get estiloColumna => pw.TextStyle(
      fontSize: 9,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.white,
    );

/// Celda normal de tabla.
pw.TextStyle get estiloCelda => const pw.TextStyle(fontSize: 9);

/// Celda de totales.
pw.TextStyle get estiloTotal => pw.TextStyle(
      fontSize: 10,
      fontWeight: pw.FontWeight.bold,
    );

// ---------------------------------------------------------------------------
// Colores
// ---------------------------------------------------------------------------

const colorHeaderTabla = PdfColors.blueGrey800;
const colorFilaPar = PdfColors.grey100;
const colorFilaImpar = PdfColors.white;

// ---------------------------------------------------------------------------
// Helpers de layout
// ---------------------------------------------------------------------------

/// Construye el header estándar de reportes (logo del tenant + empresa +
/// título + período + fecha). [logo] es opcional: sin logo configurado el
/// header queda igual que antes (solo texto). El caller crea el
/// `pw.MemoryImage` UNA vez por documento (el header corre por página).
pw.Widget buildHeaderEstandar({
  required String empresaNombre,
  required String titulo,
  required String periodo,
  pw.ImageProvider? logo,
}) {
  final textos = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(empresaNombre, style: estiloEmpresa),
      pw.SizedBox(height: 4),
      pw.Text(titulo, style: estiloTitulo),
    ],
  );
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      if (logo == null)
        textos
      else
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Container(
              height: 44,
              constraints: const pw.BoxConstraints(maxWidth: 130),
              child: pw.Image(logo, fit: pw.BoxFit.contain),
            ),
            pw.SizedBox(width: 14),
            pw.Expanded(child: textos),
          ],
        ),
      pw.SizedBox(height: 2),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(periodo, style: estiloSubtitulo()),
          pw.Text(
            'Generado: ${fmtFechaLarga(DateTime.now())}',
            style: estiloSubtitulo(),
          ),
        ],
      ),
      pw.SizedBox(height: 12),
      pw.Divider(thickness: 1, color: PdfColors.blueGrey300),
      pw.SizedBox(height: 8),
    ],
  );
}

/// Construye el footer estándar con número de página.
pw.Widget buildFooterEstandar(pw.Context context) {
  return pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Text(
        fmtFechaCorta(DateTime.now()),
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey),
      ),
      pw.Text(
        'Página ${context.pageNumber} de ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey),
      ),
    ],
  );
}
