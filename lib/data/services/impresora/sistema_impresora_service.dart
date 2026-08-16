import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../utils/papel_termica.dart';

/// Info liviana de una impresora del sistema operativo, desacoplada del tipo
/// `Printer` del paquete `printing` para que la UI no dependa de él.
class ImpresoraSistema {
  const ImpresoraSistema({
    required this.url,
    required this.nombre,
    this.esDefault = false,
    this.disponible = true,
  });

  /// Identificador de la impresora en el SO (lo que necesita `directPrintPdf`).
  final String url;

  /// Nombre visible.
  final String nombre;

  /// Es la impresora predeterminada del sistema.
  final bool esDefault;

  /// Está disponible para imprimir.
  final bool disponible;
}

/// Servicio de impresión para DESKTOP (Windows): usa las impresoras que el
/// sistema operativo YA tiene instaladas (USB, red, "Imprimir a PDF"...), vía el
/// paquete `printing`. El recibo se manda como el MISMO PDF de rollo que ya se
/// genera (`buildReciboPdf`), directo a la impresora elegida y sin diálogo.
///
/// Mobile NO pasa por acá: sigue con `print_bluetooth_thermal` (Bluetooth
/// térmico) intacto. El dispatch por plataforma lo hace `impresionPorSistema`
/// (ver `impresora_provider.dart`).
class SistemaImpresoraService {
  /// Enumera las impresoras instaladas en el SO. Ordena predeterminada y
  /// disponibles primero, luego alfabético. Devuelve `[]` si la plataforma no
  /// soporta el listado (o ante cualquier error) — el caller muestra el vacío.
  Future<List<ImpresoraSistema>> listar() async {
    try {
      final info = await Printing.info();
      if (!info.canListPrinters) return const [];
      final printers = await Printing.listPrinters();
      final list = printers
          .map((p) => ImpresoraSistema(
                url: p.url,
                nombre: p.name,
                esDefault: p.isDefault,
                disponible: p.isAvailable,
              ))
          .toList();
      list.sort((a, b) {
        if (a.esDefault != b.esDefault) return a.esDefault ? -1 : 1;
        if (a.disponible != b.disponible) return a.disponible ? -1 : 1;
        return a.nombre.toLowerCase().compareTo(b.nombre.toLowerCase());
      });
      return list;
    } catch (e) {
      if (kDebugMode) debugPrint('SistemaImpresora listar: $e');
      return const [];
    }
  }

  /// Imprime [pdfBytes] DIRECTO a la impresora [url] (sin diálogo). El PDF ya
  /// viene armado al ancho de rollo (58/80mm) por `buildReciboPdf`. Devuelve
  /// true al éxito, false si se cancela o falla.
  ///
  /// [ajustarADriver] (default `false`, v0.24.8) — mapea a `usePrinterSettings`
  /// del paquete `printing`:
  ///  - `false`: respeta el [PdfPageFormat] exacto del recibo (80/58mm, margen 0).
  ///    Fix del bug donde algunas térmicas USB con driver mal configurado
  ///    (papel = Letter/A4) estiraban el PDF y cortaban la derecha del recibo.
  ///  - `true`: comportamiento v0.24.1-v0.24.7 (el driver decide el ancho).
  ///    Escape hatch por si algún modelo lo necesita. Configurable en Perfil
  ///    → Impresora vía `impresoraAjustarADriverProvider`.
  Future<bool> imprimirPdf({
    required String url,
    required String nombre,
    required Uint8List pdfBytes,
    required int anchoMm,
    bool ajustarADriver = false,
  }) async {
    try {
      final ok = await Printing.directPrintPdf(
        printer: Printer(url: url, name: nombre),
        name: 'Recibo',
        format: await _formatoReal(pdfBytes, anchoMm),
        // El PDF ya está paginado al ancho de rollo → no re-layoutear.
        dynamicLayout: false,
        usePrinterSettings: ajustarADriver,
        onLayout: (_) => pdfBytes,
      );
      return ok;
    } catch (e) {
      if (kDebugMode) debugPrint('SistemaImpresora imprimirPdf: $e');
      return false;
    }
  }

  /// Imprime un ticket de PRUEBA (mismo camino que un recibo real) para validar
  /// la conexión con la impresora del sistema y el papel.
  Future<bool> imprimirPrueba({
    required String url,
    required String nombre,
    required int anchoMm,
    bool ajustarADriver = false,
  }) async {
    try {
      final bytes = await _pdfPrueba(anchoMm);
      return imprimirPdf(
        url: url,
        nombre: nombre,
        pdfBytes: bytes,
        anchoMm: anchoMm,
        ajustarADriver: ajustarADriver,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('SistemaImpresora imprimirPrueba: $e');
      return false;
    }
  }

  /// Formato de página "rollo": ancho = área IMPRIMIBLE, alto continuo.
  ///
  /// Solo para armar el PDF de prueba. Para IMPRIMIR se usa `_formatoReal`, que
  /// además mide el alto: este formato lleva `infinity` y eso no se le puede
  /// mandar al plugin (ver ahí).
  PdfPageFormat _rollFormat(int anchoMm) =>
      PdfPageFormat(anchoPaginaPuntos(anchoMm), double.infinity, marginAll: 0);

  /// Formato que se le pasa al plugin, con alto FINITO y medido.
  ///
  /// EL BUG DE FONDO (2026-07-27): el plugin de Windows convierte este formato
  /// en el `DEVMODE` que define el papel —
  /// `dmPaperLength = round(alto * 254 / 72)` en un `short`—. Le veníamos
  /// mandando `double.infinity`: convertir infinito a entero es comportamiento
  /// indefinido, el `DEVMODE` salía corrupto y **Windows lo descartaba entero**,
  /// así que la app NUNCA llegaba a controlar el papel y mandaba el driver.
  /// Por eso ni prender ni apagar "Ajustar al driver" cambiaba nada.
  ///
  /// El alto se MIDE del PDF ya generado (rasterizado a 18 dpi, unos pocos
  /// píxeles: alcanza para leer el tamaño y no cuesta nada). Si la medición
  /// falla se cae a un alto fijo válido — lo que no puede volver a pasar es
  /// mandar infinito.
  Future<PdfPageFormat> _formatoReal(Uint8List pdfBytes, int anchoMm) async {
    var alto = altoFallbackPuntos;
    try {
      const dpi = 18.0;
      await for (final pagina in Printing.raster(pdfBytes, dpi: dpi)) {
        alto = pagina.height / dpi * 72;
        break; // el recibo es una sola página
      }
    } catch (e) {
      if (kDebugMode) debugPrint('SistemaImpresora medir alto: $e');
    }
    return PdfPageFormat(anchoPaginaPuntos(anchoMm), alto, marginAll: 0);
  }

  /// PDF mínimo de prueba (ASCII, sin depender de la fuente embebida del recibo).
  Future<Uint8List> _pdfPrueba(int anchoMm) async {
    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: _rollFormat(anchoMm),
        build: (_) => pw.Padding(
          // Mismo margen que el recibo real: la prueba tiene que exponer la
          // MISMA geometría, si no valida nada del ancho. El margen depende del
          // rollo (es media zona muerta del cabezal), así que ya no es const.
          padding: pw.EdgeInsets.symmetric(
              horizontal: margenHorizontalPuntos(anchoMm), vertical: 8),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Text('PRUEBA DE IMPRESION',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              pw.Text('Si lees esto la impresora esta OK'),
              pw.SizedBox(height: 6),
              pw.Text('$anchoMm mm'),
              pw.SizedBox(height: 8),
              // Regla al ANCHO COMPLETO del contenido (fix 2026-07-27): antes la
              // prueba era texto corto centrado, así que salía bien aunque el
              // recibo real se cortara por los lados — daba falsa confianza.
              // Con las flechas tocando ambos extremos, si falta una punta el
              // problema se ve ACÁ y no recién en un recibo del cliente.
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('|<', style: const pw.TextStyle(fontSize: 9)),
                  pw.Expanded(
                      child: pw.Container(
                          height: 1.2,
                          margin: const pw.EdgeInsets.symmetric(horizontal: 2),
                          color: PdfColors.black)),
                  pw.Text('>|', style: const pw.TextStyle(fontSize: 9)),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Text('Si NO ves las dos puntas, se corta',
                  style: const pw.TextStyle(fontSize: 8)),
            ],
          ),
        ),
      ),
    );
    return doc.save();
  }
}
