import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:screenshot/screenshot.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impresora_provider.dart';
import '../../data/providers/logo_empresa_provider.dart';
import '../../data/services/impresora/recibo_escpos.dart';
import '../../data/services/impresora/windows_raw_printer.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/models/recibo_layout.dart';
import '../../data/utils/papel_termica.dart';
import '../../data/utils/logo_termica.dart';
import '../../powersync/db.dart' as ps;
import '../admin/reportes/descarga_archivo.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/foto_comprobante_view.dart';
import '../shared/widgets/impersonation_banner.dart';
import 'recibo_cargos.dart';
import 'recibo_mora.dart';
import 'recibo_pdf.dart';
import 'recibo_texto_escpos.dart';
import 'recibo_ticket.dart';
import '../../data/utils/errores.dart';

/// Cache en memoria del logo YA procesado para térmica. Procesarlo (decodificar
/// + redimensionar + híbrido) cuesta segundos con logos grandes, así que se hace
/// UNA vez por logo+tamaño y se reusa (evita reprocesar en cada impresión). La
/// clave mezcla tamaño de bytes + altura + un byte de muestra → si el admin cambia
/// el logo, cambia la clave y se reprocesa.
final Map<String, Uint8List> _logoTermicaCache = {};

/// Preview visual del recibo + acción para imprimir.
/// La impresión Bluetooth real se conecta en una iteración siguiente.
class ReciboScreen extends ConsumerStatefulWidget {
  const ReciboScreen({super.key, required this.reciboId, this.grupoCobro});
  final String reciboId;
  final String? grupoCobro;

  @override
  ConsumerState<ReciboScreen> createState() => _ReciboScreenState();
}

class _ReciboScreenState extends ConsumerState<ReciboScreen> {
  late final Stream<List<Map<String, dynamic>>> _reciboStream;

  // Cargos/descuentos vigentes de la(s) cuota(s) del recibo, para el
  // desglose del bloque `cuota` (rediseño 2026-06-11). Stream propio (no se
  // puede joinear N cargos en la fila única del recibo); reactivo: si el
  // admin quita un ajuste, el preview se actualiza solo.
  late final Stream<List<Map<String, dynamic>>> _cargosStream;

  // Vista preview: si está activa, el body del recibo se constraine al
  // ancho visual de la tira térmica (según `cobranza.formato_recibo_mm`).
  // El recibo se muestra SIEMPRE simulando el ancho real del papel
  // térmico (80mm/58mm). Sin toggle: la vista preview es permanente.

  bool get _esMultiCuota => widget.grupoCobro != null;

  /// Ancho en píxeles para simular la tira térmica.
  /// 80mm ≈ 300px, 58mm ≈ 215px. Cualquier ancho que no sea 80 (incl. el
  /// legacy 57) se trata como angosto.
  double _previewWidthPx(int formatoMm) {
    if (formatoMm != 80) return 215;
    return 300;
  }

  @override
  void initState() {
    super.initState();
    if (_esMultiCuota) {
      _reciboStream = ps.db.watch(
        '''
        SELECT r.id, r.numero_completo, r.prefijo, r.correlativo,
               r.created_at, r.impreso_en, r.reimpresiones,
               p.monto_cordobas, p.vuelto_cordobas, p.moneda, p.monto_original,
               p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
               p.foto_comprobante_path, p.grupo_cobro,
               p.anulado AS pago_anulado, p.id AS pago_id,
               cu.id AS cuota_id, cu.contrato_id,
               cu.periodo, cu.fecha_vencimiento, cu.monto AS cuota_monto,
               cu.monto_pagado AS monto_pagado_cuota,
               cu.cargos_neto,
               ct.dia_pago,
               c.id AS cliente_id, c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
               c.codigo AS cliente_codigo,
               pl.nombre AS plan_nombre,
               cu.descripcion AS cuota_descripcion,
               tk.correlativo AS ticket_correlativo,
               co.nombre AS cobrador_nombre
          FROM recibos r
          JOIN pagos p     ON p.id = r.pago_id
          JOIN cuotas cu   ON cu.id = p.cuota_id
          JOIN clientes c  ON c.id = cu.cliente_id
     LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     LEFT JOIN planes pl   ON pl.id = ct.plan_id
     LEFT JOIN tickets tk  ON tk.id = cu.ticket_id
          JOIN cobradores co ON co.id = r.cobrador_id
         WHERE p.grupo_cobro = ? AND p.anulado = 0
         ORDER BY cu.periodo ASC
        ''',
        parameters: [widget.grupoCobro],
      );
    } else {
      _reciboStream = ps.db.watch(
        '''
        SELECT r.id, r.numero_completo, r.prefijo, r.correlativo,
               r.created_at, r.impreso_en, r.reimpresiones,
               p.monto_cordobas, p.vuelto_cordobas, p.moneda, p.monto_original,
               p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
               p.foto_comprobante_path, p.anulado AS pago_anulado, p.id AS pago_id,
               cu.id AS cuota_id, cu.contrato_id,
               cu.periodo, cu.fecha_vencimiento, cu.monto AS cuota_monto,
               cu.monto_pagado AS monto_pagado_cuota,
               cu.cargos_neto,
               ct.dia_pago,
               c.id AS cliente_id, c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
               c.codigo AS cliente_codigo,
               pl.nombre AS plan_nombre,
               cu.descripcion AS cuota_descripcion,
               tk.correlativo AS ticket_correlativo,
               co.nombre AS cobrador_nombre
          FROM recibos r
          JOIN pagos p     ON p.id = r.pago_id
          JOIN cuotas cu   ON cu.id = p.cuota_id
          JOIN clientes c  ON c.id = cu.cliente_id
     LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     LEFT JOIN planes pl   ON pl.id = ct.plan_id
     LEFT JOIN tickets tk  ON tk.id = cu.ticket_id
          JOIN cobradores co ON co.id = r.cobrador_id
         WHERE r.id = ?
        ''',
        parameters: [widget.reciboId],
      );
    }
    // Cargos de la(s) cuota(s) cobrada(s). El IN (SELECT) acá es válido:
    // lee data viva (no snapshots de change log como los agregadores M22).
    // Scope del puente: los cargos `origen='puente'` se muestran SOLO si su
    // `pago_id` pertenece a ESTE recibo (una cuota con varios cambios de fecha
    // acumula varios puentes; mostrarlos todos no cuadra con el COBRADO). El
    // resto de cargos (descuentos/reconexión/ajustes) no se toca.
    _cargosStream = _esMultiCuota
        ? ps.db.watch(
            '''
            SELECT ce.cuota_id, ce.tipo, ce.monto, ce.porcentaje,
                   ce.descripcion, ce.origen, ce.aplicado_en
              FROM cargos_extra ce
             WHERE ce.cuota_id IN (
                     SELECT cuota_id FROM pagos
                      WHERE grupo_cobro = ? AND anulado = 0)
               AND (ce.origen IS NULL OR ce.origen != 'puente'
                    OR ce.pago_id IN (
                         SELECT id FROM pagos
                          WHERE grupo_cobro = ? AND anulado = 0))
             ORDER BY ce.aplicado_en ASC
            ''',
            parameters: [widget.grupoCobro, widget.grupoCobro],
          )
        : ps.db.watch(
            '''
            SELECT ce.cuota_id, ce.tipo, ce.monto, ce.porcentaje,
                   ce.descripcion, ce.origen, ce.aplicado_en
              FROM cargos_extra ce
             WHERE ce.cuota_id IN (
                     SELECT p.cuota_id FROM pagos p
                       JOIN recibos r ON r.pago_id = p.id
                      WHERE r.id = ?)
               AND (ce.origen IS NULL OR ce.origen != 'puente'
                    OR ce.pago_id = (
                         SELECT r2.pago_id FROM recibos r2 WHERE r2.id = ?))
             ORDER BY ce.aplicado_en ASC
            ''',
            parameters: [widget.reciboId, widget.reciboId],
          );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    // Logo del recibo: una sola fuente de verdad, la visibilidad del bloque
    // `logo` del layout. Si está visible y hay logo configurado, se cargan los
    // BYTES (no URL): `ReciboTicket` se captura a imagen para imprimir, así que
    // necesita bytes. El provider es offline-first (cache local + fallback red)
    // y reactivo (se refresca si cambia el logo o la visibilidad del bloque).
    final logoVisible =
        settings.reciboLayout.any((b) => b.id == 'logo' && b.visible);
    final logoBytes =
        logoVisible ? ref.watch(logoEmpresaBytesProvider).valueOrNull : null;

    // Rol del usuario: el admin navega DENTRO del AdminShell (con panel
    // lateral); el cobrador a sus rutas full-screen. Sin esto, "home" y "ver
    // detalle del cliente" mandaban al admin a las rutas del cobrador (/ y
    // /clientes/:id), que viven fuera del shell → quedaba sin menú izquierdo.
    final esAdmin =
        ref.watch(cobradorActualProvider).valueOrNull?.tieneAccesoAdmin ?? false;
    final maxWidth = _previewWidthPx(settings.formatoReciboMm);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recibo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            onPressed: () => context.go(esAdmin ? '/admin' : '/'),
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _reciboStream,
        builder: (context, snap) {
          if (snap.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              titulo: 'Error al cargar el recibo',
            );
          }
          // M11: sin initialData, el primer frame muestra carga en vez de
          // flashear "Recibo no encontrado" antes de que llegue la data real.
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_long,
              titulo: 'Recibo no encontrado',
            );
          }
          final r = rows.first;
          final esMulti = _esMultiCuota && rows.length > 1;
          // Recibo de un pago ANULADO (llegado por "Ver recibo" del detalle de
          // pago o la búsqueda global de recibos): se muestra como referencia
          // con sello, pero SIN reimprimir — un ticket térmico reimpreso no
          // llevaría la marca de anulado y parecería un comprobante válido de
          // plata devuelta (audit 2026-06-30). Un anulado SIEMPRE llega por el
          // path SINGLE (WHERE r.id=? trae la fila anulada): los callers fuerzan
          // grupo=null para pagos anulados (contrato_detail_pagos, finding #1) y
          // la búsqueda global nunca pasa grupo. El path MULTI filtra
          // p.anulado=0 → ahí pago_anulado es siempre 0, y justamente por eso un
          // anulado NO debe entrar por multi (mostraría los hermanos vivos sin
          // el sello).
          final pagoAnulado = (r['pago_anulado'] as int?) == 1;

          // Detalle de mora del contrato para el bloque `mora`. Mismo cálculo
          // que el path de impresión: se excluye(n) la(s) cuota(s) cobrada(s).
          // Cuota manual (contrato_id null) → mora vacía.
          final moraRows = _moraParaPreview(rows, esMulti, settings);

          return StreamBuilder<List<Map<String, dynamic>>>(
            stream: _cargosStream,
            builder: (context, cargosSnap) {
              // El desglose es informativo: mientras carga (o si el toggle
              // está apagado) el recibo se muestra igual, sin esas líneas.
              // SIEMPRE se pasan los cargos: la línea "Puente de pago" debe verse
              // aunque el toggle de descuentos esté off (es lo cobrado, no un
              // descuento). El gating de descuentos vive en _lineasCargos.
              final cargosRows =
                  cargosSnap.data ?? const <Map<String, dynamic>>[];
              return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const ImpersonationBanner(), // #9a
                  if (pagoAnulado)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.block,
                              size: 18,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Pago ANULADO. Este recibo se muestra solo como '
                              'referencia; no se puede reimprimir.',
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Preview = EXACTAMENTE el widget que se imprime (WYSIWYG).
                  // Se construye al ancho real del papel (dots) y se escala a la
                  // tira de pantalla con FittedBox → lo que ve el cobrador es
                  // lo que sale por la térmica.
                  Center(
                    child: FittedBox(
                      // contain (no scaleDown): escala para LLENAR el ancho de
                      // la preview (arriba o abajo), no solo achicar — sino en
                      // pantalla ancha el ticket se ve diminuto.
                      fit: BoxFit.contain,
                      alignment: Alignment.topCenter,
                      child: ReciboTicket(
                        row: esMulti ? null : r,
                        rows: esMulti ? rows : null,
                        settings: settings,
                        logoBytes: logoBytes,
                        moraRows: moraRows,
                        cargosRows: cargosRows,
                        // Margen simétrico en Windows (WYSIWYG con la impresión).
                        margenHorizontal: impresionPorSistema ? 32 : 6,
                      ),
                    ),
                  ),
                  if (r['foto_comprobante_path'] != null) ...[
                    const SizedBox(height: 16),
                    Text('Comprobante adjunto',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    FotoComprobanteView(
                        path: r['foto_comprobante_path'] as String?),
                  ],
                  const SizedBox(height: 24),
                  if (!pagoAnulado)
                    _AccionesImpresion(
                      reciboId: widget.reciboId,
                      recibo: r,
                      settings: settings,
                      multiRows: esMulti ? rows : null,
                    ),
                  const SizedBox(height: 16),
                  _PostCobroActions(clienteId: r['cliente_id'] as String?),
                ],
              ),
            ),
              );
            },
          );
        },
      ),
    );
  }

  /// Mora del contrato para la PREVIEW (vía `moraContratoProvider`, reactivo).
  /// Single: excluye la cuota cobrada. Multi: excluye TODAS las del grupo.
  /// Cuota manual (sin contrato) → vacío. El path de impresión calcula lo mismo
  /// con `fetchMoraContrato` (no puede usar `ref` adentro del service).
  List<Map<String, dynamic>> _moraParaPreview(
      List<Map<String, dynamic>> rows, bool esMulti, AppSettings settings) {
    final contratoId = rows.first['contrato_id'] as String?;
    if (contratoId == null) return const [];
    final cobradas = (esMulti ? rows.map((r) => r['cuota_id']) : [rows.first['cuota_id']])
        .whereType<Object>()
        .toSet();
    final todas = ref
            .watch(moraContratoProvider((
              contratoId: contratoId,
              diasGracia: settings.diasGracia,
            )))
            .valueOrNull ??
        const [];
    return todas.where((m) => !cobradas.contains(m['cuota_id'])).toList();
  }
}

class _AccionesImpresion extends ConsumerStatefulWidget {
  const _AccionesImpresion({
    required this.reciboId,
    required this.recibo,
    required this.settings,
    this.multiRows,
  });
  final String reciboId;
  final Map<String, dynamic> recibo;
  final AppSettings settings;

  /// Si está presente, el recibo es un cobro múltiple (todas las filas del
  /// grupo). Caso contrario, recibo individual.
  final List<Map<String, dynamic>>? multiRows;

  @override
  ConsumerState<_AccionesImpresion> createState() => _AccionesImpresionState();
}

class _AccionesImpresionState extends ConsumerState<_AccionesImpresion> {
  bool _imprimiendo = false;
  bool _descargandoPdf = false;
  bool _guardandoPdf = false;

  /// Construye los bytes del PDF del recibo + un filename legible. Lo COMPARTEN
  /// "Descargar PDF" (web) e "Imprimir en impresora del sistema" (desktop), así
  /// la lógica de logo/mora no se duplica.
  Future<({Uint8List bytes, String filename})> _generarReciboPdf() async {
    // Logo del PDF (best-effort): bytes del provider offline-first (cache +
    // fallback red). Si no hay, el PDF se genera sin logo — no rompemos por un
    // error de red en una imagen. Solo si el bloque `logo` está visible.
    final logoVisible = widget.settings.reciboLayout
        .any((b) => b.id == 'logo' && b.visible);
    final logoBytes = logoVisible
        ? ref.read(logoEmpresaBytesProvider).valueOrNull
        : null;

    // Detalle de mora del contrato para el bloque `mora` del PDF. Single:
    // excluir la cuota cobrada. Multi: excluir TODAS las del grupo. Cuota
    // manual (contrato_id null) → mora vacía.
    final multiRows = widget.multiRows;
    final contratoId = (multiRows != null ? multiRows.first : widget.recibo)[
        'contrato_id'] as String?;
    final excluir = (multiRows != null
            ? multiRows.map((r) => r['cuota_id'])
            : [widget.recibo['cuota_id']])
        .whereType<Object>()
        .toSet();
    final moraRows = contratoId == null
        ? const <Map<String, dynamic>>[]
        : (await fetchMoraContrato(contratoId, widget.settings.diasGracia))
            .where((m) => !excluir.contains(m['cuota_id']))
            .toList();

    final doc = await _construirReciboDoc(
        logoBytes: logoBytes,
        moraRows: moraRows,
        cargosRows: await _cargosParaRecibo());
    final bytes = await doc.save();
    final numero =
        (widget.recibo['numero_completo'] as String?) ?? widget.reciboId;
    final filename =
        'recibo_${numero.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.pdf';
    return (bytes: bytes, filename: filename);
  }

  Future<void> _descargarPdf() async {
    setState(() => _descargandoPdf = true);
    try {
      final pdf = await _generarReciboPdf();
      await Printing.sharePdf(bytes: pdf.bytes, filename: pdf.filename);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF generado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al generar PDF: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _descargandoPdf = false);
    }
  }

  /// Guarda el recibo como PDF vía el guardado nativo (`guardarArchivo`): en
  /// desktop abre "Guardar como"; en Android abre el selector de ubicación del
  /// sistema y escribe el archivo SIN pedir permisos de almacenamiento (el usuario
  /// elige la carpeta). Mismo flujo que los reportes; el nombre lleva timestamp.
  /// El PDF usa el ancho de rollo configurado y se genera 100% OFFLINE (fuente
  /// embebida + logo del cache + datos de PowerSync local) → sirve sin internet
  /// para verlo, guardarlo o reimprimirlo. En web se usa "Descargar PDF" (share).
  Future<void> _guardarPdf() async {
    setState(() => _guardandoPdf = true);
    try {
      final pdf = await _generarReciboPdf();
      if (!mounted) return;
      await guardarPdfConAviso(
        context,
        fileName: pdf.filename,
        bytes: pdf.bytes,
        mensaje: 'Recibo guardado',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar el PDF: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _guardandoPdf = false);
    }
  }

  /// Construye el `Document` PDF del recibo (single o multi según
  /// `widget.multiRows`). Lo COMPARTEN el path de "Descargar PDF" (logo de red)
  /// y el de impresión térmica (logo del cache local), para no duplicar la
  /// construcción. El call-site provee `logoBytes` (de su fuente) y `moraRows`
  /// (ya filtrado).
  Future<pw.Document> _construirReciboDoc({
    required Uint8List? logoBytes,
    required List<Map<String, dynamic>> moraRows,
    List<Map<String, dynamic>> cargosRows = const [],
  }) {
    final multiRows = widget.multiRows;
    return multiRows != null
        ? buildMultiReciboPdf(
            rows: multiRows,
            settings: widget.settings,
            logoBytes: logoBytes,
            moraRows: moraRows,
            cargosRows: cargosRows)
        : buildReciboPdf(
            row: widget.recibo,
            settings: widget.settings,
            logoBytes: logoBytes,
            moraRows: moraRows,
            cargosRows: cargosRows);
  }

  /// Cargos/descuentos de la(s) cuota(s) del recibo para el desglose del
  /// bloque `cuota` en los paths de impresión (PDF + térmica). 100% offline.
  /// SIEMPRE se buscan: la línea "Puente de pago" (origen='puente') debe
  /// imprimirse aunque el toggle de descuentos esté off; los renderers gatean
  /// los descuentos por-cargo (el puente se muestra siempre).
  Future<List<Map<String, dynamic>>> _cargosParaRecibo() async {
    final multiRows = widget.multiRows;
    final cuotaIds = (multiRows != null
            ? multiRows.map((r) => r['cuota_id'])
            : [widget.recibo['cuota_id']])
        .whereType<String>()
        .toList();
    // pago_id(s) de este recibo: scope del puente (ver fetchCargosCuotas).
    final pagoIds = (multiRows != null
            ? multiRows.map((r) => r['pago_id'])
            : [widget.recibo['pago_id']])
        .whereType<String>()
        .toList();
    return fetchCargosCuotas(cuotaIds, pagoIds: pagoIds);
  }

  /// Calcula la mora del contrato para el bloque `mora` (mismo cálculo que
  /// pantalla/PDF). Single: excluir la cuota cobrada. Multi: excluir TODAS las
  /// del grupo. Cuota manual (contrato_id null) → mora vacía.
  Future<List<Map<String, dynamic>>> _moraParaImpresion() async {
    final multiRows = widget.multiRows;
    final contratoId = (multiRows != null ? multiRows.first : widget.recibo)[
        'contrato_id'] as String?;
    final excluir = (multiRows != null
            ? multiRows.map((r) => r['cuota_id'])
            : [widget.recibo['cuota_id']])
        .whereType<Object>()
        .toSet();
    return contratoId == null
        ? const <Map<String, dynamic>>[]
        : (await fetchMoraContrato(contratoId, widget.settings.diasGracia))
            .where((m) => !excluir.contains(m['cuota_id']))
            .toList();
  }

  /// CAPTURA el widget `ReciboTicket` a PNG (al ancho exacto del papel en
  /// dots). Lo COMPARTEN el path de impresión real y el de diagnóstico, así lo
  /// que se diagnostica es BYTE-POR-BYTE lo que se imprime. Devuelve null y
  /// muestra un snackbar si la captura falla.
  /// Logo pre-procesado para térmica (chico + binarización híbrida), tomado del
  /// MISMO provider que preview/PDF (`logoEmpresaBytesProvider`, offline-first).
  /// Se procesa FUERA del hilo de UI (isolate vía `compute`) + cache (un logo
  /// grande decodificado en el hilo de UI dispara ANR). Null si no hay logo
  /// visible. Lo COMPARTEN el modo Imagen y el modo Compatible.
  Future<Uint8List?> _logoProcesado() async {
    ReciboBloque? logoBloque;
    for (final b in widget.settings.reciboLayout) {
      if (b.id == 'logo' && b.visible) {
        logoBloque = b;
        break;
      }
    }
    if (logoBloque == null) return null;
    final crudo = ref.read(logoEmpresaBytesProvider).valueOrNull;
    if (crudo == null) return null;
    final baseFont = widget.settings.formatoReciboMm >= 80 ? 1.9 : 1.5;
    // Escala DEDICADA del logo (5 niveles; 'extraGrande'/'gigante' agregan 2
    // tamaños más que el texto). Mismos factores que ReciboTicket._logoScale.
    final escala = switch (logoBloque.size) {
      ReciboTextoSize.chico => 0.85,
      ReciboTextoSize.normal => 1.0,
      ReciboTextoSize.grande => 1.3,
      ReciboTextoSize.extraGrande => 1.7,
      ReciboTextoSize.gigante => 2.2,
    };
    final alturaLogoDots = (60 * escala * baseFont).round();
    // Tope de ancho = dots del papel: en modo compatible el raster se manda tal
    // cual, así que un logo grande no debe pasarse del ancho (se recortaría).
    final anchoDots = reciboAnchoDots(widget.settings.formatoReciboMm);
    final tenantId = ref.read(tenantIdProvider) ?? '';
    final key = '${tenantId}_${crudo.length}_${alturaLogoDots}_${anchoDots}_'
        '${crudo.isEmpty ? 0 : crudo[crudo.length ~/ 2]}';
    final cacheado = _logoTermicaCache[key];
    if (cacheado != null) return cacheado;
    // `suavizado` SOLO en desktop: mejora el achicado (promediado + dither
    // acotado) pero cambia el bitmap → Android sigue con el pipeline de siempre.
    final proc = await compute(procesarLogoTermicaIsolate,
        (crudo, alturaLogoDots, anchoDots, impresionPorSistema));
    if (proc != null) _logoTermicaCache[key] = proc;
    return proc ?? crudo;
  }

  /// Construye los bytes ESC/POS del recibo (modo COMPATIBLE — texto nativo +
  /// codepage español). Reúne la MISMA data que el modo Imagen (mora + logo chico
  /// + cargos). Null (con snackbar) si falla.
  Future<List<int>?> _construirTextoEscPos({
    bool aplicarTamanos = false,
    bool logoRasterManual = false,
    int? maxCharsPorLinea,
    int margenIzqDots = 0,
    int feedFinalLineas = 2,
    int reservaDerechaDots = 0,
    bool filasPlanas = false,
  }) async {
    try {
      final moraRows = await _moraParaImpresion();
      final logoBytes = await _logoProcesado();
      final cargosRows = await _cargosParaRecibo();
      final multiCuota = widget.multiRows != null;
      return await construirReciboTextoEscPos(
        row: multiCuota ? null : widget.recibo,
        rows: multiCuota ? widget.multiRows : null,
        settings: widget.settings,
        logoBytes: logoBytes,
        moraRows: moraRows,
        cargosRows: cargosRows,
        anchoMm: widget.settings.formatoReciboMm,
        // Estrategia de tildes por-dispositivo: cp850 (occidental) / gbk
        // (alfabeto nativo chino, para firmware que ignora el FS .) / ascii
        // (sin acentos, infalible).
        tildesModo:
            ref.read(impresoraTildesModoProvider).valueOrNull ?? 'cp850',
        // Solo Windows: en Android los tamaños quedan como siempre.
        aplicarTamanos: aplicarTamanos,
        // Solo Windows: el logo por GS v 0 manual (la 3nStar no dibuja el ESC *
        // de gen.image). Android lo deja en false → gen.image byte-idéntico.
        logoRasterManual: logoRasterManual,
        maxCharsPorLinea: maxCharsPorLinea,
        margenIzqDots: margenIzqDots,
        feedFinalLineas: feedFinalLineas,
        reservaDerechaDots: reservaDerechaDots,
        filasPlanas: filasPlanas,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo generar el recibo: $e')),
        );
      }
      return null;
    }
  }

  /// Margen horizontal (dots) con el que se hornea el cuerpo en la captura.
  /// Windows lo sube para que el recibo tenga márgenes visibles a tamaño completo.
  int get _margenImpresion => impresionPorSistema ? 32 : 6;

  /// Corrimiento del contenido para compensar la zona muerta FÍSICA del cabezal
  /// (papel 636 vs imprimible 576 dots en la 3nStar 80mm). Lo comparten la captura
  /// del cuerpo y el raster del logo — si divergieran, el logo saldría corrido
  /// respecto del resto del recibo.
  int get _offsetDerechaImpresion =>
      impresionPorSistema && widget.settings.formatoReciboMm >= 80 ? 30 : 0;

  /// [sinLogo] excluye el logo de la captura: en Windows el logo se imprime
  /// APARTE, como raster nativo (`rasterLogoCentrado`), porque dentro de la
  /// captura lo re-binarizaba el umbral grueso del texto y se le cerraban los
  /// huecos a los arcos finos. Android captura CON logo (default) → idéntico.
  Future<Uint8List?> _capturarReciboPng({bool sinLogo = false}) async {
    final moraRows = await _moraParaImpresion();
    // Logo a resolución NATIVA. Si `sinLogo`, no va en la captura: se emite
    // aparte con su propio umbral fino (ver `rasterLogoCentrado`).
    final logoBytes = sinLogo ? null : await _logoProcesado();

    // WYSIWYG: se CAPTURA a imagen el MISMO widget `ReciboTicket` que muestra
    // la preview (lo renderiza Skia), y se manda como raster ESC/POS. Así las
    // tildes salen perfectas en CUALQUIER impresora, 100% OFFLINE (sin PDFium
    // ni fuentes embebidas). El layout/orden/mora/multi ya viven en el widget.
    final anchoDots = reciboAnchoDots(widget.settings.formatoReciboMm);
    final multiCuota = widget.multiRows != null;
    final ticket = ReciboTicket(
      row: multiCuota ? null : widget.recibo,
      rows: multiCuota ? widget.multiRows : null,
      settings: widget.settings,
      logoBytes: logoBytes,
      moraRows: moraRows,
      cargosRows: await _cargosParaRecibo(),
      // Windows: margen simétrico horneado a TAMAÑO COMPLETO (sin encoger la
      // imagen). Android/móvil sigue en 6 → captura y bytes idénticos.
      margenHorizontal: _margenImpresion.toDouble(),
      // Corrimiento para compensar la zona muerta física del cabezal (ver el
      // getter). La preview NO lo usa (no tiene zona muerta → queda centrada).
      offsetDerechaDots: _offsetDerechaImpresion.toDouble(),
    );
    final ticketCapturable = Directionality(
      textDirection: TextDirection.ltr,
      // Container BLANCO que cubre TODO el targetSize (anchoDots × 5000): así
      // NO queda ninguna zona no-blanca en la captura. El ticket va arriba; el
      // blanco sobrante lo recorta imprimirImagen.
      child: Container(
        width: anchoDots.toDouble(),
        height: 5000,
        color: Colors.white,
        alignment: Alignment.topCenter,
        child: Material(type: MaterialType.transparency, child: ticket),
      ),
    );

    try {
      return await ScreenshotController().captureFromWidget(
        ticketCapturable,
        // Supersampling SOLO en Windows/desktop: captura a 2× y el downscale con
        // `average` (procesarParaTermica) da letras más nítidas en la térmica.
        // Android/móvil sigue a 1× → captura y bytes idénticos a los de siempre.
        pixelRatio: impresionPorSistema ? 2.0 : 1.0,
        targetSize: Size(anchoDots.toDouble(), 5000),
        // delay para que las imágenes (logo) terminen de pintar antes del
        // snapshot — si no, el logo puede salir en blanco.
        delay: const Duration(milliseconds: 80),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo generar el recibo: $e')),
        );
      }
      return null;
    }
  }

  /// Impresión en DESKTOP (Windows): manda el MISMO PDF de rollo del recibo a
  /// Imprime vía el diálogo nativo del SO (Windows: print dialog donde el
  /// usuario elige impresora y papel). El camino Bluetooth (`_imprimir`) queda
  /// SOLO para mobile. Reutiliza `_generarReciboPdf` (100% offline).
  /// Alto REAL del PDF en puntos, medido del documento ya generado.
  ///
  /// El formato que recibe el plugin define el papel (`dmPaperLength`), así que
  /// tiene que ser finito. Se rasteriza a 18 dpi —unos pocos píxeles, costo
  /// despreciable— solo para leer el tamaño. Si falla, cae a un alto fijo
  /// válido: lo único inaceptable es volver a mandar `infinity`.
  Future<double> _altoPdfPuntos(Uint8List bytes) async {
    try {
      const dpi = 18.0;
      await for (final pagina in Printing.raster(bytes, dpi: dpi)) {
        return pagina.height / dpi * 72;
      }
    } catch (_) {
      // Sin telemetría acá: el fallback ya deja el papel en un valor usable.
    }
    return altoFallbackPuntos;
  }

  Future<void> _imprimirSistema() async {
    setState(() => _imprimiendo = true);
    try {
      final pdf = await _generarReciboPdf();
      final anchoMm = widget.settings.formatoReciboMm;
      // ESTE es el camino real de impresión en Windows (el servicio sin diálogo
      // solo lo usa la prueba). Tenía los DOS bugs del fix 2026-07-27:
      //
      //  · ancho = 80mm FÍSICO en vez de los 72,07mm IMPRIMIBLES → el plugin
      //    dibujaba a tamaño real apoyado en el borde y se perdían ~8mm por la
      //    derecha; además caía en 639,37 dots (fraccionario) y el texto salía
      //    gris por el reescalado.
      //  · alto `infinity` → el plugin lo mete en `dmPaperLength` (un `short`)
      //    y convertir infinito a entero es UB: el DEVMODE salía corrupto,
      //    Windows lo descartaba y la app NUNCA controlaba el papel.
      final ok = await Printing.layoutPdf(
        onLayout: (_) => pdf.bytes,
        format: PdfPageFormat(
            anchoPaginaPuntos(anchoMm), await _altoPdfPuntos(pdf.bytes),
            marginAll: 0),
        name: 'Recibo',
      );
      if (!mounted) return;
      if (ok) {
        await _marcarImpreso();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recibo enviado a impresora')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo imprimir el recibo')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _imprimiendo = false);
    }
  }

  /// Marca el recibo como impreso en la BD local.
  ///
  /// `impreso_en` se conserva para mostrar la fecha de impresión en el recibo
  /// (NO lo usa el guard del correlativo — audit 2026-06-24); el CONTEO de
  /// reimpresiones se quitó (no se muestra ni se incrementa; la columna quedó
  /// inerte).
  Future<void> _marcarImpreso() async {
    await ps.dbW.execute(
      '''
      UPDATE recibos
         SET impreso_en = ?,
             ultimo_formato_mm = ?,
             ocurrido_en = ?
       WHERE id = ?
      ''',
      [
        DateTime.now().toIso8601String(),
        widget.settings.formatoReciboMm,
        DateTime.now().toUtc().toIso8601String(),
        widget.reciboId,
      ],
    );
  }

  /// Imprime mandando el raster ESC/POS DIRECTO a la cola de Windows, sin
  /// driver gráfico en el medio. Es el mismo camino que Android usa por
  /// Bluetooth (misma captura, mismo raster), y por eso sale igual a la vista
  /// previa: no hay escala ni posición que el driver pueda reinterpretar.
  ///
  /// Devuelve false si no se pudo (la impresora no habla ESC/POS, la cola no
  /// existe, no hay captura) para que el caller caiga al camino PDF.
  /// Arma los bytes del recibo según el modo elegido en ESTA PC.
  ///
  /// `imagen` rasteriza la captura del widget (fidelidad exacta al diseñador),
  /// con los ajustes de margen, grosor y densidad. `texto` usa el constructor
  /// de texto nativo — el MISMO que Android, sin modificar — que imprime con la
  /// fuente interna de la impresora: negro pleno, sin suavizado ni umbral.
  Future<List<int>?> _bytesRecibo(AjustesImpresionWin aj) async {
    // Avance antes del corte (Windows): empuja el pie/slogan más allá de la
    // cuchilla antes de cortar (si no, se pierde el último bloque). Default 6.
    final avanceCorte =
        ref.read(impresoraAvanceCorteProvider).valueOrNull ?? 6;
    // Reusa el MISMO constructor que el modo compatible de Bluetooth — misma
    // data (mora + logo chico + cargos) y misma estrategia de tildes. No se
    // duplica nada: si mañana cambia el recibo de texto, cambia para los dos.
    if (aj.modo == 'texto') {
      // 3nStar RPT004 — el corte a la DERECHA en texto: `gen.row` ancla el valor
      // por POSICIÓN ABSOLUTA (`ESC $`) + `ESC a 2` (right-justify), y esta térmica
      // IGNORA el `ESC $` y justifica al BORDE FÍSICO del papel → se come 2-3 chars
      // (por eso ni bajar columnas ni `spaceBetweenRows` lo arreglaban). Fix
      // robusto: `filasPlanas: true` → las filas etiqueta:valor salen como texto
      // plano rellenado con espacios (posición por CONTEO de chars desde x=0,
      // inmune a que el firmware no honre `ESC $`/`ESC a`/`GS L`). `kColsTextoWin:
      // 42` → 42×12 = 504 dots (~6mm de aire; imprimible ≈576, medido por imagen
      // que NO corta); bajar a 40 si aún corta (o el slider `charsPorLinea`).
      // `margenIzqDots: 0` = sin GS L. OJO: solo engancha si las tildes NO están en
      // "Acentos" (gbk) — en la RPT004 el default correcto es "Sin tildes" (ascii).
      // `aplicarTamanos:false` = fuente A 1×1 (jerarquía por negrita, como Android).
      // El ancho lo MIDE la "regla de ancho" (Perfil → Impresora) y se carga en
      // el slider: si el usuario lo seteó, MANDA (es el dato real de ESA
      // impresora). 42 es solo el default conservador para la RPT004.
      const kColsTextoWin = 42;
      final cols = aj.charsPorLinea ?? kColsTextoWin;
      return _construirTextoEscPos(
        aplicarTamanos: false,
        logoRasterManual: true,
        maxCharsPorLinea: cols,
        margenIzqDots: 0,
        filasPlanas: true,
        feedFinalLineas: avanceCorte,
      );
    }
    // El logo se imprime APARTE (raster nativo, umbral fino) y se excluye de la
    // captura: dentro de ella lo re-binarizaba el umbral grueso del texto y los
    // arcos finos del ícono se empastaban (confirmado en papel: en modo TEXTO,
    // que ya lo emite así, el mismo logo sale bien).
    final logoNativo = await _logoProcesado();
    final png = await _capturarReciboPng(sinLogo: true);
    if (png == null) return null;
    // El logo tiene que quedar centrado sobre el MISMO eje que el cuerpo: la
    // captura corre el contenido `offsetDerechaDots` (compensa la zona muerta del
    // cabezal) y lo encierra en `margenHorizontal` a cada lado. Sin esto el logo
    // saldría ~30 dots a la izquierda del resto y más ancho que el cuerpo.
    final offsetLogo = _offsetDerechaImpresion;
    final anchoUtilCuerpo =
        reciboAnchoDots(widget.settings.formatoReciboMm) - 2 * _margenImpresion;
    // El margen va HORNEADO en el widget (`ReciboTicket.margenHorizontal`), a
    // TAMAÑO COMPLETO → acá NO se hornea margen (margenIzqDots: 0). Sin encoger la
    // imagen: letras grandes y nítidas + márgenes simétricos.
    return comandosReciboEscPos(
      png,
      widget.settings.formatoReciboMm,
      umbral: aj.umbral,
      margenIzqDots: 0,
      tiempoCalor: aj.tiempoCalor,
      compatible: aj.imagenCompatible,
      feedFinalLineas: avanceCorte,
      logoNativo: logoNativo,
      logoOffsetDots: offsetLogo,
      logoMaxAnchoDots: anchoUtilCuerpo,
    );
  }

  Future<bool> _imprimirDirectoWindows(
      String nombreImpresora, AjustesImpresionWin aj) async {
    // Envío lento (opt-in por-PC, default OFF): SOLO modo imagen. Dosifica el
    // raster por bandas para no desbordar el buffer de las térmicas USB que
    // pierden el pie del recibo en tiradas largas (3nStar RPT004, 128 KB). Con
    // OFF —o en modo texto, cuyo payload es liviano y nunca desborda— va el
    // camino de una sola escritura, byte-idéntico al de siempre.
    final envioLento =
        ref.read(impresoraEnvioLentoProvider).valueOrNull ?? false;
    if (aj.modo == 'imagen' && envioLento) {
      // Logo aparte, igual que el camino normal (ver `rasterLogoCentrado`).
      final logoNativo = await _logoProcesado();
      final png = await _capturarReciboPng(sinLogo: true);
      if (png == null) return false;
      final segmentos = comandosReciboEscPosSegmentado(
        png,
        widget.settings.formatoReciboMm,
        umbral: aj.umbral,
        margenIzqDots: 0,
        tiempoCalor: aj.tiempoCalor,
        compatible: aj.imagenCompatible,
        feedFinalLineas: ref.read(impresoraAvanceCorteProvider).valueOrNull ?? 6,
        logoNativo: logoNativo,
        logoOffsetDots: _offsetDerechaImpresion,
        logoMaxAnchoDots:
            reciboAnchoDots(widget.settings.formatoReciboMm) - 2 * _margenImpresion,
      );
      if (segmentos == null) return false;
      return const WindowsRawPrinter().enviarSegmentos(
        nombreImpresora: nombreImpresora,
        segmentos: segmentos,
      );
    }
    final bytes = await _bytesRecibo(aj);
    if (bytes == null) return false;
    return const WindowsRawPrinter()
        .enviarBytes(nombreImpresora: nombreImpresora, bytes: bytes);
  }

  Future<void> _imprimir() async {
    // DESKTOP (Windows): impresora del sistema (USB/red). El resto de este
    // método es el camino Bluetooth térmico, SOLO mobile.
    if (impresionPorSistema) {
      // Modo de ESTA PC (imagen / texto / driver). Si el directo falla, NO se
      // pierde el recibo — se cae al camino PDF de siempre.
      final aj = ref.read(ajustesImpresionWinProvider).value ??
          AjustesImpresionWin.inicial;
      final fav = ref.read(impresoraSistemaFavoritaProvider).value;
      if (aj.modo != 'driver' && fav != null) {
        setState(() => _imprimiendo = true);
        var ok = false;
        try {
          ok = await _imprimirDirectoWindows(fav.nombre, aj);
        } finally {
          if (mounted) setState(() => _imprimiendo = false);
        }
        if (ok) {
          await _marcarImpreso();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recibo enviado a impresora')),
          );
          return;
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Modo directo falló; probando por el driver…')),
        );
      }
      await _imprimirSistema();
      return;
    }

    final favState = ref.read(impresoraFavoritaProvider);
    // Si todavía no se leyó SharedPreferences, esperar y reintentar.
    if (!favState.hasValue) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cargando preferencias…')),
      );
      return;
    }
    final fav = favState.value;
    if (fav == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No tenés impresora configurada'),
          action: SnackBarAction(
            label: 'Configurar',
            onPressed: () => context.push('/perfil/impresora'),
          ),
        ),
      );
      return;
    }

    setState(() => _imprimiendo = true);
    try {
      final service = ref.read(impresoraServiceProvider);
      final s = widget.settings;

      // Resolver el MODO: el super_admin habilita cuáles están disponibles (Imagen
      // siempre; Compatible opt-in). Si ambos → el device elige (impresoraModo);
      // si solo uno → ese. Default Imagen.
      final modoDevice = ref.read(impresoraModoProvider).valueOrNull ?? 'imagen';
      final usarCompatible = s.modoCompatibleHabilitado &&
          (!s.modoImagenHabilitado || modoDevice == 'compatible');

      // Envío lento (opt-in por dispositivo): para impresoras que cortan el
      // final del recibo. OFF (default) = transporte idéntico al de siempre.
      final envioLento =
          ref.read(impresoraEnvioLentoProvider).valueOrNull ?? false;

      final bool ok;
      if (usarCompatible) {
        final bytes = await _construirTextoEscPos();
        if (bytes == null) return;
        ok = await service.imprimirTexto(
          macImpresora: fav.mac,
          bytes: bytes,
          envioLento: envioLento,
        );
      } else {
        final pngBytes = await _capturarReciboPng();
        if (pngBytes == null) return;
        ok = await service.imprimirImagen(
          macImpresora: fav.mac,
          pngBytes: pngBytes,
          anchoMm: s.formatoReciboMm,
          envioLento: envioLento,
        );
      }

      if (!mounted) return;
      if (ok) {
        // Actualizar BD local: impreso_en + formato. `impreso_en` se conserva
        // para mostrar la fecha de impresión en el recibo (NO lo usa el guard
        // del correlativo — audit 2026-06-24); el CONTEO de reimpresiones se
        // quitó (no se muestra ni se incrementa; la columna quedó inerte).
        await _marcarImpreso();
        // C7: re-chequear tras el await — el execute pudo resolver con la
        // pantalla ya desmontada (context muerto para el SnackBar).
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recibo enviado a impresora')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo conectar a la impresora')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _imprimiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nombre de la impresora configurada según plataforma: desktop = impresora
    // del sistema (USB/red); mobile = Bluetooth térmica.
    final favNombre = impresionPorSistema
        ? ref.watch(impresoraSistemaFavoritaProvider).valueOrNull?.nombre
        : ref.watch(impresoraFavoritaProvider).valueOrNull?.nombre;
    const puedeImprimir = !kIsWeb;
    return Column(
      children: [
        // Imprimir: desktop → impresora del sistema (USB/red); mobile →
        // Bluetooth térmica. En web se usa el PDF (abajo). El dispatch por
        // plataforma vive en `_imprimir`.
        if (!kIsWeb)
          FilledButton.icon(
            icon: _imprimiendo
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.print),
            label: Text(_imprimiendo
                ? 'Enviando...'
                : 'Imprimir ${widget.settings.formatoReciboMm}mm'),
            onPressed: _imprimiendo || !puedeImprimir ? null : _imprimir,
          ),
        // Guardar PDF (desktop + Android) — "Guardar como" nativo / selector de
        // ubicación del sistema, igual que los reportes. El PDF sale al ancho de
        // rollo y se genera 100% OFFLINE; en Android `guardarArchivo` escribe el
        // archivo sin pedir permisos. En web se usa "Descargar PDF" (share) abajo.
        if (!kIsWeb) ...[
          const SizedBox(height: 8),
          Tooltip(
            message:
                'Guarda el recibo como PDF (ancho de rollo ${widget.settings.formatoReciboMm}mm). '
                'Elegís dónde guardarlo; funciona sin internet.',
            child: FilledButton.tonalIcon(
              icon: _guardandoPdf
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_alt),
              label: Text(_guardandoPdf
                  ? 'Guardando...'
                  : 'Guardar PDF ${widget.settings.formatoReciboMm}mm'),
              onPressed: _guardandoPdf ? null : _guardarPdf,
            ),
          ),
        ],
        // PDF download — solo visible en web. En mobile usan la impresora
        // Bluetooth térmica, así que el PDF no aporta nada.
        if (kIsWeb) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: _descargandoPdf
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf),
            label: Text(_descargandoPdf
                ? 'Generando PDF...'
                : 'Descargar PDF ${widget.settings.formatoReciboMm}mm'),
            onPressed: _descargandoPdf ? null : _descargarPdf,
          ),
        ],
        const SizedBox(height: 8),
        if (!kIsWeb)
          OutlinedButton.icon(
            icon: Icon(impresionPorSistema
                ? Icons.print
                : Icons.bluetooth_searching),
            label: Text(favNombre == null
                ? 'Configurar impresora'
                : 'Cambiar impresora ($favNombre)'),
            onPressed: () => context.push('/perfil/impresora'),
          ),
        const SizedBox(height: 16),
        Text(
          'El recibo queda guardado y sincronizado aunque la impresora '
          'falle. Podés reintentar imprimir cuando quieras.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _PostCobroActions extends ConsumerWidget {
  const _PostCobroActions({required this.clienteId});
  final String? clienteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = clienteId;
    if (id == null) return const SizedBox.shrink();
    // Ruta según rol: el admin va al detalle dentro del AdminShell (con panel
    // lateral). El cobrador a /clientes/:id (full-screen). Antes era fijo a
    // /clientes/:id y el admin quedaba sin menú izquierdo.
    final esAdmin =
        ref.watch(cobradorActualProvider).valueOrNull?.tieneAccesoAdmin ?? false;
    final clientePath = esAdmin ? '/admin/clientes/$id' : '/clientes/$id';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.person),
          label: const Text('Ver detalle del cliente'),
          onPressed: () => context.push(clientePath),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
