import 'dart:convert';

import 'package:archive/archive.dart';

import '../descarga_archivo.dart';

/// Generador de documentos Word (.docx) compatible con Microsoft Word, Google Docs,
/// LibreOffice y Apple Pages basado en el estándar OpenXML (ECMA-376).
///
/// Funciona en Dart puro usando `package:archive` para empaquetar el contenedor ZIP
/// sin necesidad de backend, Node.js ni librerías nativas.
class DocxBuilder {
  DocxBuilder({
    this.primaryColor = '1B3B6F',
    this.accentColor = '1ABC9C',
    this.defaultFont = 'Calibri',
  });

  final String primaryColor;
  final String accentColor;
  final String defaultFont;

  final StringBuffer _body = StringBuffer();

  /// Escapa caracteres especiales XML.
  static String _esc(String? text) {
    if (text == null) return '';
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  /// Agrega un encabezado de reporte con título, subtítulo, empresa y metadatos.
  void addReportHeader({
    required String empresa,
    required String titulo,
    String? subtitulo,
    String? periodo,
    String? fechaEmision,
  }) {
    // Nombre de la empresa / Tenant
    _body.writeln('''
<w:p>
  <w:pPr>
    <w:spacing w:before="0" w:after="60"/>
  </w:pPr>
  <w:r>
    <w:rPr>
      <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
      <w:b/>
      <w:color w:val="$accentColor"/>
      <w:sz w:val="24"/>
    </w:rPr>
    <w:t>${_esc(empresa.toUpperCase())}</w:t>
  </w:r>
</w:p>''');

    // Título Principal
    _body.writeln('''
<w:p>
  <w:pPr>
    <w:spacing w:before="0" w:after="100"/>
  </w:pPr>
  <w:r>
    <w:rPr>
      <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
      <w:b/>
      <w:color w:val="$primaryColor"/>
      <w:sz w:val="36"/>
    </w:rPr>
    <w:t>${_esc(titulo)}</w:t>
  </w:r>
</w:p>''');

    // Subtítulo
    if (subtitulo != null && subtitulo.isNotEmpty) {
      _body.writeln('''
<w:p>
  <w:pPr>
    <w:spacing w:before="0" w:after="100"/>
  </w:pPr>
  <w:r>
    <w:rPr>
      <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
      <w:i/>
      <w:color w:val="555555"/>
      <w:sz w:val="22"/>
    </w:rPr>
    <w:t>${_esc(subtitulo)}</w:t>
  </w:r>
</w:p>''');
    }

    // Metadatos (Período, Fecha emisión)
    final now = DateTime.now();
    final fechaDefault = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final fecha = fechaEmision ?? fechaDefault;

    _body.writeln('''
<w:p>
  <w:pPr>
    <w:pBdr>
      <w:bottom w:val="single" w:sz="12" w:space="8" w:color="$accentColor"/>
    </w:pBdr>
    <w:spacing w:before="60" w:after="240"/>
  </w:pPr>
  <w:r>
    <w:rPr>
      <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
      <w:b/>
      <w:color w:val="444444"/>
      <w:sz w:val="18"/>
    </w:rPr>
    <w:t>${_esc(periodo != null ? 'Período: $periodo   |   ' : '')}Fecha de emisión: ${_esc(fecha)}   |   Moneda: C\$ (Córdobas)</w:t>
  </w:r>
</w:p>''');
  }

  /// Título de sección (Heading 1).
  void addHeading1(String text) {
    _body.writeln('''
<w:p>
  <w:pPr>
    <w:spacing w:before="240" w:after="100"/>
  </w:pPr>
  <w:r>
    <w:rPr>
      <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
      <w:b/>
      <w:color w:val="$primaryColor"/>
      <w:sz w:val="28"/>
    </w:rPr>
    <w:t>${_esc(text)}</w:t>
  </w:r>
</w:p>''');
  }

  /// Subtítulo de sección (Heading 2).
  void addHeading2(String text) {
    _body.writeln('''
<w:p>
  <w:pPr>
    <w:spacing w:before="160" w:after="60"/>
  </w:pPr>
  <w:r>
    <w:rPr>
      <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
      <w:b/>
      <w:color w:val="$accentColor"/>
      <w:sz w:val="24"/>
    </w:rPr>
    <w:t>${_esc(text)}</w:t>
  </w:r>
</w:p>''');
  }

  /// Párrafo de texto con formato opcional.
  void addParagraph(
    String text, {
    bool bold = false,
    bool italic = false,
    String? color,
    int fontSizePt = 11,
    String align = 'left', // left, center, right, both
  }) {
    final jc = switch (align) {
      'center' => '<w:jc w:val="center"/>',
      'right' => '<w:jc w:val="right"/>',
      'both' => '<w:jc w:val="both"/>',
      _ => '<w:jc w:val="left"/>',
    };
    final clr = color != null ? '<w:color w:val="$color"/>' : '<w:color w:val="333333"/>';
    final sz = fontSizePt * 2;

    _body.writeln('''
<w:p>
  <w:pPr>
    $jc
    <w:spacing w:before="40" w:after="80"/>
  </w:pPr>
  <w:r>
    <w:rPr>
      <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
      ${bold ? '<w:b/>' : ''}
      ${italic ? '<w:i/>' : ''}
      $clr
      <w:sz w:val="$sz"/>
    </w:rPr>
    <w:t>${_esc(text)}</w:t>
  </w:r>
</w:p>''');
  }

  /// Caja destacada / Callout con borde lateral de color y fondo tenue.
  void addCallout(String text, {String? title, String borderColor = '1ABC9C', String bgColor = 'F0FDF4'}) {
    _body.writeln('''
<w:tbl>
  <w:tblPr>
    <w:tblW w:w="5000" w:type="pct"/>
    <w:tblBorders>
      <w:top w:val="none"/>
      <w:left w:val="single" w:sz="24" w:color="$borderColor"/>
      <w:bottom w:val="none"/>
      <w:right w:val="none"/>
    </w:tblBorders>
    <w:tblCellMar>
      <w:top w:w="120" w:type="dxa"/>
      <w:left w:w="180" w:type="dxa"/>
      <w:bottom w:w="120" w:type="dxa"/>
      <w:right w:w="180" w:type="dxa"/>
    </w:tblCellMar>
  </w:tblPr>
  <w:tr>
    <w:tc>
      <w:tcPr>
        <w:shd w:val="clear" w:color="auto" w:fill="$bgColor"/>
      </w:tcPr>
      ${title != null ? '''
      <w:p>
        <w:r>
          <w:rPr>
            <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
            <w:b/>
            <w:color w:val="$borderColor"/>
            <w:sz w:val="22"/>
          </w:rPr>
          <w:t>${_esc(title)}</w:t>
        </w:r>
      </w:p>''' : ''}
      <w:p>
        <w:r>
          <w:rPr>
            <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
            <w:color w:val="333333"/>
            <w:sz w:val="20"/>
          </w:rPr>
          <w:t>${_esc(text)}</w:t>
        </w:r>
      </w:p>
    </w:tc>
  </w:tr>
</w:tbl>
<w:p><w:pPr><w:spacing w:before="60" w:after="60"/></w:pPr></w:p>''');
  }

  /// Agrega una tabla estilizada nativa de Word.
  ///
  /// - [headers]: títulos de columna.
  /// - [rows]: filas de datos (celdas pueden ser texto o números).
  /// - [alignments]: alineación por columna ('left', 'center', 'right'). Si es nulo,
  ///   se asume 'left' salvo que el contenido sea numérico.
  /// - [isTotalRow]: función o lista para destacar filas de totales con negrita y fondo suave.
  void addTable({
    required List<String> headers,
    required List<List<Object?>> rows,
    List<String>? alignments,
    List<int>? colWidthsPct,
    bool Function(int rowIndex, List<Object?> row)? isTotalRow,
  }) {
    _body.writeln('''
<w:tbl>
  <w:tblPr>
    <w:tblW w:w="5000" w:type="pct"/>
    <w:jc w:val="center"/>
    <w:tblBorders>
      <w:top w:val="single" w:sz="6" w:color="D1D5DB"/>
      <w:left w:val="none"/>
      <w:bottom w:val="single" w:sz="12" w:color="$primaryColor"/>
      <w:right w:val="none"/>
      <w:insideH w:val="single" w:sz="4" w:color="E5E7EB"/>
      <w:insideV w:val="none"/>
    </w:tblBorders>
    <w:tblCellMar>
      <w:top w:w="120" w:type="dxa"/>
      <w:left w:w="140" w:type="dxa"/>
      <w:bottom w:w="120" w:type="dxa"/>
      <w:right w:w="140" w:type="dxa"/>
    </w:tblCellMar>
  </w:tblPr>''');

    // Header Row
    _body.writeln('<w:tr>');
    _body.writeln('<w:trPr><w:tblHeader/></w:trPr>');
    for (var c = 0; c < headers.length; c++) {
      final align = alignments != null && c < alignments.length ? alignments[c] : 'left';
      final jc = align == 'right' ? 'right' : (align == 'center' ? 'center' : 'left');
      final widthAttr = colWidthsPct != null && c < colWidthsPct.length
          ? '<w:tcW w:w="${(colWidthsPct[c] * 50)}" w:type="pct"/>'
          : '';

      _body.writeln('''
  <w:tc>
    <w:tcPr>
      $widthAttr
      <w:shd w:val="clear" w:color="auto" w:fill="$primaryColor"/>
    </w:tcPr>
    <w:p>
      <w:pPr>
        <w:jc w:val="$jc"/>
        <w:spacing w:before="60" w:after="60"/>
      </w:pPr>
      <w:r>
        <w:rPr>
          <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
          <w:b/>
          <w:color w:val="FFFFFF"/>
          <w:sz w:val="20"/>
        </w:rPr>
        <w:t>${_esc(headers[c])}</w:t>
      </w:r>
    </w:p>
  </w:tc>''');
    }
    _body.writeln('</w:tr>');

    // Data Rows
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      final isTotal = isTotalRow != null ? isTotalRow(r, row) : false;
      final bg = isTotal
          ? 'E8F4F8'
          : (r % 2 == 1 ? 'FAFAFA' : 'FFFFFF');

      _body.writeln('<w:tr>');
      for (var c = 0; c < headers.length; c++) {
        final val = c < row.length ? row[c] : '';
        final align = alignments != null && c < alignments.length
            ? alignments[c]
            : (val is num ? 'right' : 'left');
        final jc = align == 'right' ? 'right' : (align == 'center' ? 'center' : 'left');
        final isNum = val is num;
        final valStr = isNum
            ? (val is double ? val.toStringAsFixed(2) : val.toString())
            : (val?.toString() ?? '');

        _body.writeln('''
  <w:tc>
    <w:tcPr>
      <w:shd w:val="clear" w:color="auto" w:fill="$bg"/>
    </w:tcPr>
    <w:p>
      <w:pPr>
        <w:jc w:val="$jc"/>
        <w:spacing w:before="40" w:after="40"/>
      </w:pPr>
      <w:r>
        <w:rPr>
          <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont"/>
          ${isTotal ? '<w:b/>' : ''}
          <w:color w:val="${isTotal ? primaryColor : '222222'}"/>
          <w:sz w:val="${isTotal ? '20' : '19'}"/>
        </w:rPr>
        <w:t>${_esc(valStr)}</w:t>
      </w:r>
    </w:p>
  </w:tc>''');
      }
      _body.writeln('</w:tr>');
    }

    _body.writeln('</w:tbl>');
    _body.writeln('<w:p><w:pPr><w:spacing w:before="60" w:after="120"/></w:pPr></w:p>');
  }

  /// Agrega un bloque formal de firmas de responsabilidad.
  void addSignatures({
    String cargo1 = 'Elaborado por (Administración)',
    String cargo2 = 'Revisado por (Gerencia Financiera)',
    String? cargo3,
  }) {
    _body.writeln('<w:p><w:pPr><w:spacing w:before="360" w:after="200"/></w:pPr></w:p>');
    _body.writeln('''
<w:tbl>
  <w:tblPr>
    <w:tblW w:w="5000" w:type="pct"/>
    <w:jc w:val="center"/>
    <w:tblBorders>
      <w:top w:val="none"/>
      <w:left w:val="none"/>
      <w:bottom w:val="none"/>
      <w:right w:val="none"/>
      <w:insideH w:val="none"/>
      <w:insideV w:val="none"/>
    </w:tblBorders>
  </w:tblPr>
  <w:tr>
    <w:tc>
      <w:tcPr><w:tcW w:w="2200" w:type="pct"/></w:tcPr>
      <w:p>
        <w:pPr><w:jc w:val="center"/><w:spacing w:before="200" w:after="40"/></w:pPr>
        <w:r><w:t>_______________________________</w:t></w:r>
      </w:p>
      <w:p>
        <w:pPr><w:jc w:val="center"/><w:spacing w:before="40" w:after="40"/></w:pPr>
        <w:r><w:rPr><w:b/><w:sz w:val="18"/></w:rPr><w:t>${_esc(cargo1)}</w:t></w:r>
      </w:p>
      <w:p>
        <w:pPr><w:jc w:val="center"/><w:spacing w:before="20" w:after="40"/></w:pPr>
        <w:r><w:rPr><w:color w:val="777777"/><w:sz w:val="16"/></w:rPr><w:t>Firma y Fecha</w:t></w:r>
      </w:p>
    </w:tc>
    <w:tc>
      <w:tcPr><w:tcW w:w="600" w:type="pct"/></w:tcPr>
      <w:p><w:r><w:t></w:t></w:r></w:p>
    </w:tc>
    <w:tc>
      <w:tcPr><w:tcW w:w="2200" w:type="pct"/></w:tcPr>
      <w:p>
        <w:pPr><w:jc w:val="center"/><w:spacing w:before="200" w:after="40"/></w:pPr>
        <w:r><w:t>_______________________________</w:t></w:r>
      </w:p>
      <w:p>
        <w:pPr><w:jc w:val="center"/><w:spacing w:before="40" w:after="40"/></w:pPr>
        <w:r><w:rPr><w:b/><w:sz w:val="18"/></w:rPr><w:t>${_esc(cargo2)}</w:t></w:r>
      </w:p>
      <w:p>
        <w:pPr><w:jc w:val="center"/><w:spacing w:before="20" w:after="40"/></w:pPr>
        <w:r><w:rPr><w:color w:val="777777"/><w:sz w:val="16"/></w:rPr><w:t>Firma y Sello</w:t></w:r>
      </w:p>
    </w:tc>
  </w:tr>
</w:tbl>''');
  }

  /// Empaqueta el documento completo OpenXML en un archivo ZIP con extensión .docx.
  List<int> buildBytes() {
    final archive = Archive();

    const contentTypes = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>''';

    const rootRels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

    const docRels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''';

    final styles = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults>
    <w:rPrDefault>
      <w:rPr>
        <w:rFonts w:ascii="$defaultFont" w:hAnsi="$defaultFont" w:cs="$defaultFont"/>
        <w:sz w:val="22"/>
        <w:color w:val="333333"/>
        <w:lang w:val="es-NI"/>
      </w:rPr>
    </w:rPrDefault>
    <w:pPrDefault>
      <w:pPr>
        <w:spacing w:after="120" w:line="240" w:lineRule="auto"/>
      </w:pPr>
    </w:pPrDefault>
  </w:docDefaults>
</w:styles>''';

    final documentXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
${_body.toString()}
    <w:sectPr>
      <w:pgSz w:w="12240" w:h="15840"/>
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>''';

    void addXml(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    addXml('[Content_Types].xml', contentTypes);
    addXml('_rels/.rels', rootRels);
    addXml('word/_rels/document.xml.rels', docRels);
    addXml('word/styles.xml', styles);
    addXml('word/document.xml', documentXml);

    final zip = ZipEncoder().encode(archive);
    if (zip == null) {
      throw Exception('Error al empaquetar el documento Word (.docx)');
    }
    return zip;
  }

  /// Guarda y ofrece el archivo Word (.docx) para descarga mediante el diálogo nativo.
  Future<String?> descargar({
    required String fileName,
  }) async {
    final bytes = buildBytes();
    return guardarArchivo(
      fileName: fileName.endsWith('.docx') ? fileName : '$fileName.docx',
      bytes: bytes,
      extension: 'docx',
    );
  }
}
