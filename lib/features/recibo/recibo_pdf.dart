import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/models/recibo_layout.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/monto_a_letras.dart';
import '../../data/utils/logo_monocromo.dart';
import '../../data/utils/papel_termica.dart';
import '../../data/models/pago.dart';
import '../shared/pdf/pdf_theme.dart';
import 'recibo_cargos.dart' show cargoEtiquetaRecibo;

// ---------------------------------------------------------------------------
// PDF generator del recibo — replica el ticket térmico (80mm o 58mm).
//
// Lo consumen SOLO tres cosas: descargar PDF, guardar PDF, e IMPRIMIR EN
// DESKTOP. El camino térmico (Bluetooth / mobile) NO pasa por acá: captura el
// widget `ReciboTicket` con Skia y lo manda como raster ESC/POS
// (`recibo_screen._capturarReciboPng`). El comentario viejo decía que este PDF
// era "fuente del raster" — quedó de una versión anterior y es FALSO desde que
// se pasó a la captura; casi cuesta un diagnóstico equivocado en el fix de
// impresión del 2026-07-27. Cambiar la geometría de acá NO afecta Android.
// ---------------------------------------------------------------------------

/// Ancho en puntos PDF según mm. 1 mm ≈ 2.8346 pt.
double _anchoPuntos(int mm) {
  // El ancho de PÁGINA es el área IMPRIMIBLE del cabezal, no el ancho físico
  // del rollo (fix 2026-07-27). Con 80mm de página el plugin de Windows dibuja
  // 80mm a tamaño real y se pierden ~8mm por la derecha; además 80mm cae en
  // 639,37 dots —fraccionario— y cada letra se reescala y sale gris. Con el
  // ancho imprimible cae en 576 dots exactos. Ver `papel_termica.dart`.
  return anchoPaginaPuntos(mm);
}

/// PDF para un recibo individual (cuota única).
///
/// [logoBytes] opcional: si se provee, se renderiza el logo de la empresa
/// centrado horizontalmente arriba del nombre de la empresa.
///
/// [moraRows] = detalle de mora del contrato YA filtrado por el call-site
/// (excluida la cuota cobrada). Estas funciones no tienen `ref` ni hacen IO,
/// así que la mora se calcula afuera (`fetchMoraContrato`) y se pasa hecha.
/// Vacío → el bloque `mora` no se muestra.
Future<pw.Document> buildReciboPdf({
  required Map<String, dynamic> row,
  required AppSettings settings,
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
  List<Map<String, dynamic>> cargosRows = const [],
}) async {
  final doc = pw.Document();
  final theme = await pdfTheme();
  final ancho = _anchoPuntos(settings.formatoReciboMm);

  // Se ITERA el layout configurable: cada bloque se construye en
  // `_pdfBloqueSingle` (devuelve [] si no hay nada que mostrar) y entre bloques
  // se emite SOLO espaciado (sin líneas de separación) — estilo limpio: las
  // secciones se distinguen por aire + negritas. Gap chico entre dos bloques
  // de header (van más juntos), gap mayor en el resto. El contenido/orden lo
  // manda `settings.reciboLayout`; el bloque `totales` (dinero) sigue intacto.
  final children = <pw.Widget>[];
  for (final b in settings.reciboLayout) {
    if (!b.visible) continue;
    final contenido = _pdfBloqueSingle(b, _pdfScale(b.size), row, settings,
        logoBytes: logoBytes, moraRows: moraRows, cargosRows: cargosRows);
    if (contenido.isEmpty) continue;
    if (children.isNotEmpty) {
      // Hueco ANTES del bloque = espaciado entre segmentos (no lineal, amplio
      // bien aireado ≈ 5mm; px × 0.6 pt).
      final gap = reciboEspacioPx(b.espacioAntes) * 0.6;
      if (gap > 0) children.add(pw.SizedBox(height: gap));
    }
    children.addAll(contenido);
  }

  doc.addPage(
    pw.Page(
      theme: theme,
      // El margen NO es estético: es la mitad de la zona muerta del cabezal,
      // para que el contenido caiga dentro de lo que la impresora imprime.
      // Ver `papel_termica.dart` (punto 3: cortaba a la izquierda).
      pageFormat: PdfPageFormat(ancho, double.infinity,
          marginLeft: margenHorizontalPuntos(settings.formatoReciboMm),
          marginRight: margenHorizontalPuntos(settings.formatoReciboMm),
          marginTop: 12, marginBottom: 12),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: children,
      ),
    ),
  );
  return doc;
}

/// Multiplicador de fontSize del bloque (chico/normal/grande) para el PDF.
/// Mismos factores que pantalla → consistencia entre los 3 renderers.
double _pdfScale(ReciboTextoSize s) => switch (s) {
      ReciboTextoSize.chico => 0.85,
      ReciboTextoSize.grande => 1.3,
      // extraGrande/gigante son SOLO del logo → en texto se topan en grande.
      ReciboTextoSize.extraGrande => 1.3,
      ReciboTextoSize.gigante => 1.3,
      ReciboTextoSize.normal => 1.0,
    };

/// Escala DEDICADA del logo en el PDF — 5 niveles (2 más que el texto). El
/// ancho lo topa el `BoxFit.contain` dentro de la página.
double _pdfLogoScale(ReciboTextoSize s) => switch (s) {
      ReciboTextoSize.chico => 0.85,
      ReciboTextoSize.normal => 1.0,
      ReciboTextoSize.grande => 1.3,
      ReciboTextoSize.extraGrande => 1.7,
      ReciboTextoSize.gigante => 2.2,
    };

/// True si el recibo single cobró SOLO el puente sobre una cuota YA pagada
/// (cambio de fecha al día). Mismo criterio que `ReciboTicket._esPuenteSolo`.
bool _esPuenteSoloPdf(
    Map<String, dynamic> row, List<Map<String, dynamic>> cargosRows) {
  final base = (row['cuota_monto'] as num?)?.toDouble() ?? 0;
  final aplicado = (row['monto_cordobas'] as num?)?.toDouble() ?? 0;
  final pagadoCuota = (row['monto_pagado_cuota'] as num? ?? aplicado).toDouble();
  final hayPuente = cargosRows.any((c) =>
      c['cuota_id'] == row['cuota_id'] && (c['origen'] as String?) == 'puente');
  return hayPuente && (pagadoCuota - aplicado) >= base - 0.01;
}

/// Líneas de descuentos/cargos de UNA cuota para el bloque `cuota` (single y
/// multi). El "Puente de pago" (origen='puente') SIEMPRE se muestra (es lo
/// cobrado); los descuentos/otros cargos quedan bajo `mostrar_descuentos`.
/// Mismo contenido que `_lineasCargos` del ticket (paridad de renderers).
List<pw.Widget> _pdfLineasCargos(
  List<Map<String, dynamic>> cargosRows,
  Object? cuotaId,
  AppSettings settings,
  double k,
) {
  if (cuotaId == null) return const [];
  final mostrar = settings.reciboMostrarDescuentos;
  final conMotivo = mostrar && settings.reciboMostrarMotivoDescuentos;
  return [
    for (final c in cargosRows)
      if (c['cuota_id'] == cuotaId &&
          ((c['origen'] as String?) == 'puente' || mostrar))
        _pdfRow(
          cargoEtiquetaRecibo(c, conMotivo: conMotivo),
          '${(c['tipo'] as String? ?? '').startsWith('descuento') ? '-' : '+'}'
          '${Fmt.cordobas(c['monto'] as num? ?? 0)}',
          k,
        ),
  ];
}

/// Construye las líneas de UN bloque del recibo single en PDF. Devuelve [] si
/// el bloque no tiene nada que mostrar (logo null, empresa vacía, pie vacío…).
/// Emite los campos de un bloque de info del PDF en el orden + visibilidad de
/// `b.campos` (nivel-campo). null = sin dato → no se emite. Fallback: si
/// `b.campos` viniera vacío, usa el orden del mapa.
List<pw.Widget> _pdfEmitirCampos(
    ReciboBloque b, Map<String, pw.Widget?> campos) {
  final orden = b.campos.isNotEmpty
      ? b.campos
      : [for (final id in campos.keys) ReciboCampo(id: id)];
  final out = <pw.Widget>[];
  for (final c in orden) {
    if (!c.visible) continue;
    final w = campos[c.id];
    if (w != null) out.add(w);
  }
  return out;
}

List<pw.Widget> _pdfBloqueSingle(
  ReciboBloque b,
  double k,
  Map<String, dynamic> row,
  AppSettings settings, {
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
  List<Map<String, dynamic>> cargosRows = const [],
}) {
  switch (b.id) {
    case 'logo':
      if (logoBytes == null) return const [];
      return [
        // Monocromo: el driver de Windows TRAMA las imágenes del PDF (el texto,
        // que es vectorial, sale sólido). Sin grises no hay nada que tramar.
        pw.Image(pw.MemoryImage(LogoMonocromo.convertir(logoBytes)),
            height: 50 * _pdfLogoScale(b.size), fit: pw.BoxFit.contain),
      ];
    case 'empresa':
      return _pdfEmitirCampos(b, {
        'empresa.nombre': settings.empresaNombre.isNotEmpty
            ? pw.Text(settings.empresaNombre.toUpperCase(),
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11 * k),
                textAlign: pw.TextAlign.center)
            : null,
        'empresa.direccion': settings.empresaDireccion.isNotEmpty
            ? pw.Text(settings.empresaDireccion,
                style: pw.TextStyle(fontSize: 8 * k),
                textAlign: pw.TextAlign.center)
            : null,
        'empresa.telefono': settings.empresaTelefono.isNotEmpty
            ? pw.Text('Tel: ${settings.empresaTelefono}',
                style: pw.TextStyle(fontSize: 8 * k))
            : null,
        'empresa.ruc': settings.empresaRuc.isNotEmpty
            ? pw.Text('RUC: ${settings.empresaRuc}',
                style: pw.TextStyle(fontSize: 8 * k))
            : null,
      });
    case 'titulo':
      if (settings.reciboTitulo.isEmpty) return const [];
      return [
        pw.Text(
          settings.reciboTitulo.toUpperCase(),
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k),
          textAlign: pw.TextAlign.center,
        ),
      ];
    case 'meta':
      final emision = DateTime.parse(row['fecha_pago'] as String);
      return _pdfEmitirCampos(b, {
        'meta.numero': _pdfRow('Recibo Nº', row['numero_completo'] as String, k),
        'meta.fecha': _pdfRow('Fecha', Fmt.fechaCorta(emision), k),
        'meta.hora': _pdfRow('Hora', Fmt.hora(emision), k),
        'meta.cobrador':
            _pdfRow('Colector', row['cobrador_nombre'] as String, k),
      });
    case 'cliente':
      return _pdfEmitirCampos(b, {
        'cliente.nombre': _pdfRow('Cliente', row['cliente_nombre'] as String, k),
        'cliente.id': row['cliente_codigo'] != null
            ? _pdfRow('ID', row['cliente_codigo'] as String, k)
            : null,
        'cliente.cedula': row['cliente_cedula'] != null
            ? _pdfRow('Cédula', row['cliente_cedula'] as String, k)
            : null,
      });
    case 'servicio':
      final periodoCuota = DateTime.parse(row['periodo'] as String);
      final esManual = row['plan_nombre'] == null;
      final diaPago = (row['dia_pago'] as num?)?.toInt();
      final periodoLabel = esManual || diaPago == null
          ? Fmt.mes(periodoCuota)
          : Fmt.periodoRecibo(diaPago, periodoCuota);
      return _pdfEmitirCampos(b, {
        'servicio.servicio': _pdfRow(
            'Servicio',
            esManual
                ? (row['cuota_descripcion'] as String? ?? 'Cuota manual')
                : row['plan_nombre'] as String,
            k),
        'servicio.ticket': row['ticket_correlativo'] != null
            ? _pdfRow('Ticket', '#${row['ticket_correlativo']}', k)
            : null,
        // Período: solo cuotas del CONTRATO (mensual); manual/puente-solo → se omite.
        'servicio.periodo': (!_esPuenteSoloPdf(row, cargosRows) && !esManual)
            ? _pdfRow('Período',
                periodoLabel[0].toUpperCase() + periodoLabel.substring(1), k)
            : null,
      });
    case 'cuota':
      // Saldo de la cuota tras este pago (sub-toggle `mostrar_adeudado`).
      final saldoCuota = ((row['cuota_monto'] as num).toDouble() +
              (row['cargos_neto'] as num? ?? 0).toDouble()) -
          (row['monto_pagado_cuota'] as num? ?? row['monto_cordobas'] as num)
              .toDouble();
      // Abono PREVIO a este pago (forzado, sin gatear por el setting de pago
      // parcial): deja claro que este cobro es el saldo restante de una cuota
      // ya abonada antes. Ver gemelo en recibo_ticket.dart.
      final abonoPrevio = (row['monto_pagado_cuota'] as num? ?? 0).toDouble() -
          (row['monto_cordobas'] as num).toDouble();
      final puenteSolo = _esPuenteSoloPdf(row, cargosRows);
      return [
        // Puente-solo (al día): la cuota host ya estaba saldada → no se muestra
        // su "Cuota base"; lo cobrado es solo el puente (línea de _pdfLineasCargos).
        if (!puenteSolo)
          _pdfRow('Cuota base', Fmt.cordobas(row['cuota_monto'] as num), k),
        if (!puenteSolo && abonoPrevio > 0.01)
          _pdfRow('Abono previo', Fmt.cordobas(abonoPrevio), k),
        // Desglose de descuentos/cargos (rediseño 2026-06-11) — informativo,
        // el dinero del recibo no cambia.
        ..._pdfLineasCargos(cargosRows, row['cuota_id'], settings, k),
        if (!puenteSolo && settings.reciboMostrarAdeudado && saldoCuota > 0.01)
          _pdfRow('Saldo cuota', Fmt.cordobas(saldoCuota), k),
      ];
    case 'metodo':
      return _pdfEmitirCampos(b, {
        'metodo.metodo': _pdfRow('Método',
            MetodoPago.fromString(row['metodo'] as String).label.toUpperCase(), k),
        'metodo.referencia': row['referencia'] != null
            ? _pdfRow('Ref.', row['referencia'] as String, k)
            : null,
        'metodo.recibido': (row['moneda'] as String) == 'USD'
            ? _pdfRow(
                'Recibido',
                'US\$${(row['monto_original'] as num).toStringAsFixed(2)} '
                    '(tasa ${(row['tasa_conversion'] as num).toStringAsFixed(2)})',
                k)
            : null,
      });
    case 'letras':
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Text(
            montoALetras(
              (row['monto_cordobas'] as num).toDouble(),
              moneda: (row['moneda'] as String?) ?? 'NIO',
            ),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontSize: 7 * k, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ];
    case 'totales':
      // EL BLOQUE DE DINERO. Matemática y contenido IDÉNTICOS al original:
      // COBRADO siempre, + VUELTO/PAGADO si hubo vuelto (con manejo USD).
      // Solo cambió su posición (la da el layout).
      return [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Monto',
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11 * k)),
            pw.Text(
              Fmt.cordobas(row['monto_cordobas'] as num),
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 11 * k),
            ),
          ],
        ),
        // VUELTO + PAGADO si hubo vuelto.
        ..._vueltoIfNeeded(row, k),
      ];
    case 'mora':
      // Detalle de mora del contrato (ya filtrado por el call-site). Resumen
      // informativo de lo que el cliente aún debe — no toca la matemática del
      // dinero del recibo (`cuota`/`totales`).
      return _pdfBloqueMoraRows(moraRows, k);
    case 'pie':
      if (settings.pieRecibo.isEmpty) return const [];
      return [
        pw.Text(settings.pieRecibo,
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center),
      ];
    case 'whatsapp':
      if (settings.empresaWhatsapp.isEmpty) return const [];
      return [
        pw.Text('WhatsApp: ${settings.empresaWhatsapp}',
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center),
      ];
    default:
      return const [];
  }
}

/// PDF para cobro múltiple (varios pagos agrupados).
///
/// [logoBytes] opcional: si se provee, se renderiza el logo de la empresa
/// centrado horizontalmente arriba del nombre de la empresa.
///
/// [moraRows] = detalle de mora del contrato YA filtrado por el call-site
/// (excluidas TODAS las cuotas del grupo). Vacío → el bloque `mora` no se
/// muestra. Ver `buildReciboPdf` para el razonamiento del parámetro.
Future<pw.Document> buildMultiReciboPdf({
  required List<Map<String, dynamic>> rows,
  required AppSettings settings,
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
  List<Map<String, dynamic>> cargosRows = const [],
}) async {
  final doc = pw.Document();
  final theme = await pdfTheme();
  final ancho = _anchoPuntos(settings.formatoReciboMm);

  // Se ITERA el MISMO layout configurable que el recibo single. Los ids mapean
  // a su contenido MULTI (lista de N cuotas, totales sumados). Entre bloques
  // SOLO espaciado (sin líneas) — estilo limpio. El bloque `totales` (dinero)
  // mantiene su matemática IDÉNTICA; solo cambia su posición.
  final children = <pw.Widget>[];
  for (final b in settings.reciboLayout) {
    if (!b.visible) continue;
    final contenido = _pdfBloqueMulti(b, _pdfScale(b.size), rows, settings,
        logoBytes: logoBytes, moraRows: moraRows, cargosRows: cargosRows);
    if (contenido.isEmpty) continue;
    if (children.isNotEmpty) {
      // Hueco ANTES del bloque = espaciado entre segmentos (px × 0.6 pt).
      final gap = reciboEspacioPx(b.espacioAntes) * 0.6;
      if (gap > 0) children.add(pw.SizedBox(height: gap));
    }
    children.addAll(contenido);
  }

  doc.addPage(
    pw.Page(
      theme: theme,
      // El margen NO es estético: es la mitad de la zona muerta del cabezal,
      // para que el contenido caiga dentro de lo que la impresora imprime.
      // Ver `papel_termica.dart` (punto 3: cortaba a la izquierda).
      pageFormat: PdfPageFormat(ancho, double.infinity,
          marginLeft: margenHorizontalPuntos(settings.formatoReciboMm),
          marginRight: margenHorizontalPuntos(settings.formatoReciboMm),
          marginTop: 12, marginBottom: 12),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: children,
      ),
    ),
  );
  return doc;
}

/// Construye las líneas de UN bloque del recibo MULTI en PDF. Devuelve [] si el
/// bloque no aplica. El bloque `servicio` va vacío en multi (la lista de cuotas
/// del bloque `cuota` ya lo cubre).
List<pw.Widget> _pdfBloqueMulti(
  ReciboBloque b,
  double k,
  List<Map<String, dynamic>> rows,
  AppSettings settings, {
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
  List<Map<String, dynamic>> cargosRows = const [],
}) {
  final first = rows.first;
  switch (b.id) {
    case 'logo':
      if (logoBytes == null) return const [];
      return [
        // Monocromo: el driver de Windows TRAMA las imágenes del PDF (el texto,
        // que es vectorial, sale sólido). Sin grises no hay nada que tramar.
        pw.Image(pw.MemoryImage(LogoMonocromo.convertir(logoBytes)),
            height: 50 * _pdfLogoScale(b.size), fit: pw.BoxFit.contain),
      ];
    case 'empresa':
      return _pdfEmitirCampos(b, {
        'empresa.nombre': settings.empresaNombre.isNotEmpty
            ? pw.Text(settings.empresaNombre.toUpperCase(),
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11 * k),
                textAlign: pw.TextAlign.center)
            : null,
        'empresa.direccion': settings.empresaDireccion.isNotEmpty
            ? pw.Text(settings.empresaDireccion,
                style: pw.TextStyle(fontSize: 8 * k),
                textAlign: pw.TextAlign.center)
            : null,
        'empresa.telefono': settings.empresaTelefono.isNotEmpty
            ? pw.Text('Tel: ${settings.empresaTelefono}',
                style: pw.TextStyle(fontSize: 8 * k))
            : null,
        'empresa.ruc': settings.empresaRuc.isNotEmpty
            ? pw.Text('RUC: ${settings.empresaRuc}',
                style: pw.TextStyle(fontSize: 8 * k))
            : null,
      });
    case 'titulo':
      if (settings.reciboTitulo.isEmpty) return const [];
      return [
        pw.Text(
          settings.reciboTitulo.toUpperCase(),
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k),
          textAlign: pw.TextAlign.center,
        ),
      ];
    case 'meta':
      final emision = DateTime.parse(first['fecha_pago'] as String);
      final cuerpoMeta = _pdfEmitirCampos(b, {
        'meta.numero': _pdfRow('Recibos',
            '${rows.first['numero_completo']} - ${rows.last['numero_completo']}',
            k),
        'meta.fecha': _pdfRow('Fecha', Fmt.fechaCorta(emision), k),
        'meta.hora': _pdfRow('Hora', Fmt.hora(emision), k),
        'meta.cobrador': _pdfRow('Colector', first['cobrador_nombre'] as String, k),
      });
      return [
        pw.Text('COBRO MÚLTIPLE (${rows.length} cuotas)',
            style:
                pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
        pw.SizedBox(height: 4),
        ...cuerpoMeta,
      ];
    case 'cliente':
      return _pdfEmitirCampos(b, {
        'cliente.nombre':
            _pdfRow('Cliente', first['cliente_nombre'] as String, k),
        'cliente.id': first['cliente_codigo'] != null
            ? _pdfRow('ID', first['cliente_codigo'] as String, k)
            : null,
        'cliente.cedula': first['cliente_cedula'] != null
            ? _pdfRow('Cédula', first['cliente_cedula'] as String, k)
            : null,
      });
    case 'servicio':
      // En multi la lista de cuotas (bloque `cuota`) ya cubre el servicio.
      return const [];
    case 'cuota':
      // La LISTA de N cuotas: período → monto aplicado de cada una, con sus
      // descuentos/cargos desgranados debajo (sub-toggle).
      return [
        for (final r in rows) ...[
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(
                  child: pw.Text(
                    Fmt.mesServicioLabel(
                        DateTime.parse(r['periodo'] as String),
                        (r['dia_pago'] as num?)?.toInt()),
                    style: pw.TextStyle(fontSize: 8 * k),
                  ),
                ),
                pw.Text(Fmt.cordobas(r['monto_cordobas'] as num),
                    style: pw.TextStyle(fontSize: 8 * k)),
              ],
            ),
          ),
          ..._pdfLineasCargos(cargosRows, r['cuota_id'], settings, k),
        ],
      ];
    case 'metodo':
      final totalOriginal = _multiTotalOriginal(rows);
      final esUsd = (first['moneda'] as String?) == 'USD';
      return _pdfEmitirCampos(b, {
        'metodo.metodo': _pdfRow('Método',
            MetodoPago.fromString(first['metodo'] as String).label.toUpperCase(),
            k),
        'metodo.referencia': first['referencia'] != null
            ? _pdfRow('Ref.', first['referencia'] as String, k)
            : null,
        'metodo.recibido': esUsd
            ? _pdfRow(
                'Recibido',
                'US\$${totalOriginal.toStringAsFixed(2)} '
                    '(tasa ${(first['tasa_conversion'] as num).toStringAsFixed(2)})',
                k)
            : null,
      });
    case 'letras':
      final totalCobrado = _multiTotalCobrado(rows);
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Text(
            // Monto en letras = COBRADO (lo que entró a caja).
            montoALetras(totalCobrado,
                moneda: (first['moneda'] as String?) ?? 'NIO'),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontSize: 7 * k, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ];
    case 'totales':
      // EL BLOQUE DE DINERO (multi). Matemática y contenido IDÉNTICOS al
      // original: TOTAL COBRADO + VUELTO/PAGADO sumados (USD = Σ monto_original).
      final totalCobrado = _multiTotalCobrado(rows);
      final totalVuelto = _multiTotalVuelto(rows);
      final totalOriginal = _multiTotalOriginal(rows);
      final totalEntregado = totalCobrado + totalVuelto;
      // Todo el grupo comparte moneda/tasa (registrarCobroMultiple usa una sola).
      final esUsd = (first['moneda'] as String?) == 'USD';
      return [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Total cobrado',
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11 * k)),
            pw.Text(Fmt.cordobas(totalCobrado),
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11 * k)),
          ],
        ),
        if (totalVuelto > 0.01) ...[
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
                    style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
                pw.Text(Fmt.cordobas(totalVuelto),
                    style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
              ],
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 2),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('PAGADO',
                    style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
                pw.Text(
                    esUsd
                        ? 'US\$${totalOriginal.toStringAsFixed(2)} = ${Fmt.cordobas(totalEntregado)}'
                        : Fmt.cordobas(totalEntregado),
                    style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
              ],
            ),
          ),
        ],
      ];
    case 'mora':
      // Detalle de mora del contrato (ya filtrado por el call-site, excluidas
      // las cuotas del grupo). Resumen informativo — no toca el dinero.
      return _pdfBloqueMoraRows(moraRows, k);
    case 'pie':
      if (settings.pieRecibo.isEmpty) return const [];
      return [
        pw.Text(settings.pieRecibo,
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center),
      ];
    case 'whatsapp':
      if (settings.empresaWhatsapp.isEmpty) return const [];
      return [
        pw.Text('WhatsApp: ${settings.empresaWhatsapp}',
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center),
      ];
    default:
      return const [];
  }
}

/// Bloque `mora` en PDF (compartido single + multi): título "EN MORA", una
/// línea por mes (`Fmt.mes` ↔ `Fmt.cordobas(saldo)`), y "TOTAL MORA" con la
/// suma. `moraRows` ya viene filtrado por el call-site; vacío → [].
List<pw.Widget> _pdfBloqueMoraRows(
    List<Map<String, dynamic>> moraRows, double k) {
  if (moraRows.isEmpty) return const [];
  final totalMora = moraRows.fold<double>(
      0, (s, m) => s + (m['saldo'] as num).toDouble());
  return [
    pw.Text('EN MORA',
        style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k),
        textAlign: pw.TextAlign.center),
    pw.SizedBox(height: 2),
    for (final m in moraRows)
      _pdfRow(
        Fmt.mesServicioLabel(
            DateTime.parse(m['periodo'] as String),
            (m['dia_pago'] as num?)?.toInt()),
        Fmt.cordobas(m['saldo'] as num),
        k,
      ),
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('Total en mora',
            style:
                pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
        pw.Text(Fmt.cordobas(totalMora),
            style:
                pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
      ],
    ),
  ];
}

// Totales del grupo (multi). Mismas sumas que antes (sin cambios de matemática).
double _multiTotalCobrado(List<Map<String, dynamic>> rows) {
  var t = 0.0;
  for (final r in rows) {
    t += (r['monto_cordobas'] as num).toDouble();
  }
  return t;
}

double _multiTotalVuelto(List<Map<String, dynamic>> rows) {
  var t = 0.0;
  for (final r in rows) {
    t += (r['vuelto_cordobas'] as num? ?? 0).toDouble();
  }
  return t;
}

// Σ monto_original = lo entregado en moneda original.
double _multiTotalOriginal(List<Map<String, dynamic>> rows) {
  var t = 0.0;
  for (final r in rows) {
    t += (r['monto_original'] as num? ?? 0).toDouble();
  }
  return t;
}

// ---------------------------------------------------------------------------
// Helpers internos
// ---------------------------------------------------------------------------

pw.Widget _pdfRow(String label, String value, [double k = 1]) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 60,
          child: pw.Text('$label:', style: pw.TextStyle(fontSize: 8 * k)),
        ),
        pw.Expanded(
          child: pw.Text(value,
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(fontSize: 8 * k)),
        ),
      ],
    ),
  );
}

List<pw.Widget> _vueltoIfNeeded(Map<String, dynamic> row, [double k = 1]) {
  // Lee el vuelto del pago directamente (columna vuelto_cordobas).
  // Defensivo para rows legacy (pre-migración 0061): 0 si no existe.
  // Regla de negocio: el vuelto SIEMPRE se da en córdobas, incluso si
  // el cliente pagó en USD. El label refleja eso para evitar confusión.
  final vuelto = (row['vuelto_cordobas'] as num? ?? 0).toDouble();
  if (vuelto <= 0.01) return const [];
  final cobrado = (row['monto_cordobas'] as num).toDouble();
  final entregado = cobrado + vuelto;
  final esUsd = (row['moneda'] as String) == 'USD';
  final pagadoLabel = esUsd
      ? 'US\$${(row['monto_original'] as num).toStringAsFixed(2)} = ${Fmt.cordobas(entregado)}'
      : Fmt.cordobas(entregado);
  return [
    pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
          pw.Text(Fmt.cordobas(vuelto),
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
        ],
      ),
    ),
    pw.Padding(
      padding: const pw.EdgeInsets.only(top: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('PAGADO',
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
          pw.Text(pagadoLabel,
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
        ],
      ),
    ),
  ];
}
