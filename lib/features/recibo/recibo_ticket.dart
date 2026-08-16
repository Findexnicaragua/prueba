import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/models/pago.dart';
import '../../data/models/recibo_layout.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/monto_a_letras.dart';
import 'recibo_cargos.dart' show cargoEtiquetaRecibo;

// ---------------------------------------------------------------------------
// ReciboTicket — UN solo widget Flutter para el recibo, que se usa TANTO para
// la preview en pantalla COMO para imprimir en la térmica (capturándolo a
// imagen con `screenshot` y mandándolo como raster ESC/POS).
//
// Por qué un widget único:
//   - Lo renderiza Skia (el mismo motor que dibuja la pantalla) → las tildes
//     salen SIEMPRE bien en CUALQUIER impresora, sin depender del codepage del
//     modelo ni de fuentes embebidas (el problema del PDF + PDFium).
//   - La preview en pantalla = exactamente lo que se imprime (WYSIWYG).
//   - 100% offline: la captura no toca la red.
//
// La matemática del dinero (cobrado / vuelto / pagado / totales / mora) es
// IDÉNTICA a `recibo_pdf.dart`. Solo cambia el renderer (Flutter en vez de pw).
//
// El widget NO usa `ref`: recibe `logoBytes` (no URL) y `moraRows` (ya
// calculados/filtrados por el call-site), igual que los builders del PDF. Eso
// lo hace puro y capturable fuera del árbol (`captureFromWidget`).
// ---------------------------------------------------------------------------

/// Ancho del papel térmico en DOTS (px lógicos) según mm. 58mm→384, 80mm→576
/// (anchos útiles estándar ESC/POS). El ticket se construye a este ancho para
/// que la captura salga a la resolución exacta del papel (máxima nitidez sin
/// reescalado). Valores legacy (57) caen al angosto.
int reciboAnchoDots(int formatoMm) => formatoMm >= 80 ? 576 : 384;

class ReciboTicket extends StatelessWidget {
  const ReciboTicket({
    super.key,
    this.row,
    this.rows,
    required this.settings,
    this.logoBytes,
    this.moraRows = const [],
    this.cargosRows = const [],
    this.margenHorizontal = 6,
    this.offsetDerechaDots = 0,
  }) : assert(row != null || rows != null,
            'ReciboTicket requiere row (single) o rows (multi)');

  /// Recibo individual (cuota única). Mutuamente excluyente con [rows].
  final Map<String, dynamic>? row;

  /// Cobro múltiple (varias cuotas agrupadas). Si está presente y tiene >1
  /// fila, el ticket se renderiza en modo multi.
  final List<Map<String, dynamic>>? rows;

  final AppSettings settings;

  /// Bytes del logo (PNG/JPG). Null → el bloque `logo` no muestra nada. Se
  /// pasan bytes (no URL) para que el render sea offline y capturable.
  final Uint8List? logoBytes;

  /// Detalle de mora del contrato YA filtrado por el call-site (excluida(s) la(s)
  /// cuota(s) cobrada(s)). Vacío → el bloque `mora` no se muestra. No toca la
  /// matemática del dinero del recibo.
  final List<Map<String, dynamic>> moraRows;

  /// Cargos/descuentos vigentes de la(s) cuota(s) cobrada(s), ya buscados por
  /// el call-site (`fetchCargosCuotas`). Se desgranan dentro del bloque
  /// `cuota` (sub-toggle `mostrar_descuentos`). Informativo: el dinero del
  /// recibo NO cambia (los netos ya viven en cargos_neto/saldo).
  final List<Map<String, dynamic>> cargosRows;

  /// Padding horizontal (px lógicos = dots) a CADA lado del contenido. Default 6
  /// (Android/preview móvil, casi al ras). En Windows se sube para que el recibo
  /// salga con MÁRGENES simétricos visibles, renderizados a TAMAÑO COMPLETO (sin
  /// encoger la imagen → letras grandes y nítidas). El margen vive ACÁ, en el
  /// widget, no reescalando en `procesarParaTermica`.
  final double margenHorizontal;

  /// Corrimiento del CUERPO hacia la DERECHA (px lógicos = dots). Default 0
  /// (Android/preview → padding simétrico). En Windows se sube a ~30 para
  /// COMPENSAR la zona muerta física de la 3nStar RPT004: el papel mide ~636
  /// dots pero el imprimible son 576, y esos 60 dots muertos caen TODOS a la
  /// derecha. Sin compensar, el raster se apoya a la izquierda del papel y el
  /// margen derecho queda ~7.5mm mayor que el izquierdo (asimetría reportada).
  /// Corriendo el cuerpo (636−576)/2 = 30 dots a la derecha, los márgenes
  /// quedan simétricos EN EL PAPEL. El ancho del cuerpo NO cambia (el Container
  /// sigue fijo en 576): solo se re-reparte el padding izq/der.
  final double offsetDerechaDots;

  /// True si hay que renderizar el modo multi-cuota.
  bool get _esMulti => rows != null && rows!.length > 1;

  @override
  Widget build(BuildContext context) {
    final anchoDots = reciboAnchoDots(settings.formatoReciboMm);
    // Escala base de la tipografía. Antes era `anchoDots/384` → el 58mm quedaba
    // en 1.0× (fontSize body 13px ≈ 1.6mm a 8 dots/mm = la MITAD de la Font A
    // térmica estándar de ~24 dots/3mm → se veía diminuto). Ahora el angosto
    // (58mm) arranca en 1.5× (body ≈ 2.4mm) y el ancho (80mm) en 1.9× para
    // aprovechar el papel. Preview e impresión usan el MISMO factor (WYSIWYG).
    final baseFont = settings.formatoReciboMm >= 80 ? 1.9 : 1.5;

    final children = <Widget>[];
    for (final b in settings.reciboLayout) {
      if (!b.visible) continue;
      final contenido = _buildBloque(b, _scaleDe(b.size) * baseFont);
      if (contenido.isEmpty) continue;
      if (children.isNotEmpty) {
        // Hueco ANTES del bloque = el espaciado ENTRE SEGMENTOS configurable
        // (recibo.layout → espacioAntes), NO lineal: amplio ≈ 5mm (bien aireado),
        // chico bien pegado. Sin líneas divisorias: los segmentos se distinguen
        // por aire + negritas.
        final gap = reciboEspacioPx(b.espacioAntes) * baseFont;
        if (gap > 0) children.add(SizedBox(height: gap));
      }
      children.addAll(contenido);
    }

    // Texto NEGRO sobre fondo BLANCO (térmico: monocromo). Sin azul.
    return Container(
      width: anchoDots.toDouble(),
      color: Colors.white,
      // Margen horizontal parametrizable (`margenHorizontal`, default 6 ≈ 0.75mm
      // por lado). En Windows se sube (~32) para MÁRGENES simétricos visibles,
      // renderizados a tamaño completo. El recorte vertical de imprimirImagen saca
      // el blanco de arriba/abajo, así que el padding vertical es chico.
      //
      // `offsetDerechaDots` corre el cuerpo a la derecha para compensar la zona
      // muerta física de la impresora (ver el campo). Con default 0,
      // `EdgeInsets.only(left: m, right: m)` es IDÉNTICO a
      // `symmetric(horizontal: m)` → Android byte-idéntico.
      padding: EdgeInsets.only(
        left: margenHorizontal + offsetDerechaDots,
        right: (margenHorizontal - offsetDerechaDots).clamp(0.0, double.infinity),
        top: 4,
        bottom: 4,
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13 * baseFont,
          // Interlineado compacto: densar las líneas sin que se toquen. Antes
          // 1.3 dejaba demasiado aire vertical.
          height: 1.12,
          color: Colors.black,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }

  /// Multiplicador de fontSize según el tamaño del bloque (chico/normal/grande).
  /// Mismos factores que el PDF → consistencia entre renderers.
  double _scaleDe(ReciboTextoSize s) => switch (s) {
        ReciboTextoSize.chico => 0.85,
        ReciboTextoSize.grande => 1.3,
        // extraGrande/gigante son SOLO del logo → en texto se topan en grande.
        ReciboTextoSize.extraGrande => 1.3,
        ReciboTextoSize.gigante => 1.3,
        ReciboTextoSize.normal => 1.0,
      };

  /// Escala DEDICADA del logo — 5 niveles (2 más que el texto). Se aplica solo
  /// al bloque `logo`; el ancho lo topa el `BoxFit.contain` dentro del papel.
  static double _logoScale(ReciboTextoSize s) => switch (s) {
        ReciboTextoSize.chico => 0.85,
        ReciboTextoSize.normal => 1.0,
        ReciboTextoSize.grande => 1.3,
        ReciboTextoSize.extraGrande => 1.7,
        ReciboTextoSize.gigante => 2.2,
      };

  // Datos de referencia: en multi tomamos la primera fila para los campos
  // compartidos (cliente, método, fecha…). En single, `row`.
  Map<String, dynamic> get _ref => _esMulti ? rows!.first : (row ?? rows!.first);

  /// Construye las líneas de UN bloque. Devuelve [] si el bloque no tiene nada
  /// que mostrar — el loop del build salta los vacíos y su separador.
  ///
  /// Emite los campos de un bloque de info (empresa/meta/cliente/servicio/metodo)
  /// en el ORDEN + visibilidad de `b.campos` (nivel-campo). Cada valor del mapa
  /// ya trae su guard de dato (null = sin dato → no se emite). Fallback: si
  /// `b.campos` viniera vacío, usa el orden del mapa (todos visibles).
  List<Widget> _emitirCampos(ReciboBloque b, Map<String, Widget?> campos) {
    final orden = b.campos.isNotEmpty
        ? b.campos
        : [for (final id in campos.keys) ReciboCampo(id: id)];
    final out = <Widget>[];
    for (final c in orden) {
      if (!c.visible) continue;
      final w = campos[c.id];
      if (w != null) out.add(w);
    }
    return out;
  }

  List<Widget> _buildBloque(ReciboBloque b, double k) {
    final r = _ref;
    switch (b.id) {
      case 'logo':
        if (logoBytes == null) return const [];
        // Altura con la escala DEDICADA del logo (5 niveles). `k` ya incluye
        // baseFont y el _scaleDe (topado) del bloque → recupero baseFont con la
        // razón logoScale/textScale para no cambiar la firma.
        final logoK = k * _logoScale(b.size) / _scaleDe(b.size);
        return [
          Image.memory(
            logoBytes!,
            height: 60 * logoK,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ];
      case 'empresa':
        return _emitirCampos(b, {
          'empresa.nombre': settings.empresaNombre.isNotEmpty
              ? Text(settings.empresaNombre.toUpperCase(),
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * k),
                  textAlign: TextAlign.center)
              : null,
          'empresa.direccion': settings.empresaDireccion.isNotEmpty
              ? Text(settings.empresaDireccion,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13 * k))
              : null,
          'empresa.telefono': settings.empresaTelefono.isNotEmpty
              ? Text('Tel: ${settings.empresaTelefono}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13 * k))
              : null,
          'empresa.ruc': settings.empresaRuc.isNotEmpty
              ? Text('RUC: ${settings.empresaRuc}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13 * k))
              : null,
        });
      case 'titulo':
        if (settings.reciboTitulo.isEmpty) return const [];
        return [
          Text(
            settings.reciboTitulo.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k),
            textAlign: TextAlign.center,
          ),
        ];
      case 'meta':
        final emision = DateTime.parse(r['fecha_pago'] as String);
        final cuerpoMeta = _emitirCampos(b, {
          'meta.numero': _esMulti
              ? _ticketRow('Recibos',
                  '${rows!.first['numero_completo']} - ${rows!.last['numero_completo']}',
                  k)
              : _ticketRow('Recibo Nº', r['numero_completo'] as String, k),
          'meta.fecha': _ticketRow('Fecha', Fmt.fechaCorta(emision), k),
          'meta.hora': _ticketRow('Hora', Fmt.hora(emision), k),
          'meta.cobrador': _ticketRow('Colector', r['cobrador_nombre'] as String, k),
        });
        // El encabezado de cobro múltiple es CHROME del bloque (no un campo):
        // va fijo arriba cuando es multi.
        if (_esMulti) {
          return [
            Text('COBRO MÚLTIPLE (${rows!.length} cuotas)',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k)),
            SizedBox(height: 4 * k),
            ...cuerpoMeta,
          ];
        }
        return cuerpoMeta;
      case 'cliente':
        return _emitirCampos(b, {
          'cliente.nombre': _ticketRow('Cliente', r['cliente_nombre'] as String, k),
          'cliente.id': r['cliente_codigo'] != null
              ? _ticketRow('ID', r['cliente_codigo'] as String, k)
              : null,
          'cliente.cedula': r['cliente_cedula'] != null
              ? _ticketRow('Cédula', r['cliente_cedula'] as String, k)
              : null,
        });
      case 'servicio':
        // En multi la lista de cuotas (bloque `cuota`) ya cubre el servicio.
        if (_esMulti) return const [];
        final periodoCuota = DateTime.parse(r['periodo'] as String);
        final esManual = r['plan_nombre'] == null;
        final diaPago = (r['dia_pago'] as num?)?.toInt();
        final periodoLabel = esManual || diaPago == null
            ? Fmt.mes(periodoCuota)
            : Fmt.periodoRecibo(diaPago, periodoCuota);
        return _emitirCampos(b, {
          'servicio.servicio': _ticketRow(
              'Servicio',
              esManual
                  ? (r['cuota_descripcion'] as String? ?? 'Cuota manual')
                  : r['plan_nombre'] as String,
              k),
          // Cobro originado en un ticket (0173): referencia el N° de ticket.
          'servicio.ticket': r['ticket_correlativo'] != null
              ? _ticketRow('Ticket', '#${r['ticket_correlativo']}', k)
              : null,
          // Período: solo cuotas del CONTRATO (mensual). Manual o puente-solo → se
          // omite (audit 0173).
          'servicio.periodo': (!_esPuenteSolo && !esManual)
              ? _ticketRow('Período',
                  periodoLabel[0].toUpperCase() + periodoLabel.substring(1), k)
              : null,
        });
      case 'cuota':
        if (_esMulti) {
          // La LISTA de N cuotas: período → monto aplicado de cada una, con
          // sus descuentos/cargos desgranados debajo (sub-toggle).
          return [
            for (final cu in rows!) ...[
              Padding(
                padding: EdgeInsets.only(bottom: 2 * k),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        Fmt.mesServicioLabel(
                            DateTime.parse(cu['periodo'] as String),
                            (cu['dia_pago'] as num?)?.toInt()),
                        softWrap: true,
                        style: TextStyle(fontSize: 12 * k),
                      ),
                    ),
                    SizedBox(width: 8 * k),
                    Text(Fmt.cordobas(cu['monto_cordobas'] as num),
                        style: TextStyle(fontSize: 12 * k)),
                  ],
                ),
              ),
              ..._lineasCargos(cu['cuota_id'], k),
            ],
          ];
        }
        // Saldo de la cuota tras este pago (sub-toggle `mostrar_adeudado`).
        final saldoCuota = ((r['cuota_monto'] as num).toDouble() +
                (r['cargos_neto'] as num? ?? 0).toDouble()) -
            (r['monto_pagado_cuota'] as num? ?? r['monto_cordobas'] as num)
                .toDouble();
        // Abono PREVIO a este pago = lo ya pagado de la cuota (monto_pagado VIVO)
        // menos este pago. Forzado (sin gatear por el setting de pago parcial):
        // deja claro que este cobro es el saldo restante de una cuota ya abonada.
        // OJO: monto_pagado_cuota es el total ACTUAL → exacto para el pago que
        // COMPLETA la cuota (caso real con pago parcial off). Con pago parcial ON
        // y varios parciales, una reimpresión de un parcial intermedio
        // sobrecontaría → ahí haría falta el prev-pagado por timestamp (backlog).
        final abonoPrevio = (r['monto_pagado_cuota'] as num? ?? 0).toDouble() -
            (r['monto_cordobas'] as num).toDouble();
        return [
          // Puente-solo (al día): la cuota host ya estaba saldada en un recibo
          // previo → no se muestra su "Cuota base"; lo cobrado es solo el puente
          // (la línea "Puente de pago" la pone _lineasCargos).
          if (!_esPuenteSolo)
            _ticketRow('Cuota base', Fmt.cordobas(r['cuota_monto'] as num), k),
          if (!_esPuenteSolo && abonoPrevio > 0.01)
            _ticketRow('Abono previo', Fmt.cordobas(abonoPrevio), k),
          // Desglose de descuentos/cargos (rediseño 2026-06-11): el cliente
          // ve POR QUÉ el saldo es el que es. Informativo, no toca el dinero.
          ..._lineasCargos(r['cuota_id'], k),
          if (!_esPuenteSolo &&
              settings.reciboMostrarAdeudado &&
              saldoCuota > 0.01)
            _ticketRow('Saldo cuota', Fmt.cordobas(saldoCuota), k),
        ];
      case 'metodo':
        final esUsd = (r['moneda'] as String?) == 'USD';
        final recibidoOriginal =
            _esMulti ? _totalOriginal() : (r['monto_original'] as num).toDouble();
        return _emitirCampos(b, {
          'metodo.metodo': _ticketRow('Método',
              MetodoPago.fromString(r['metodo'] as String).label.toUpperCase(), k),
          'metodo.referencia': r['referencia'] != null
              ? _ticketRow('Ref.', r['referencia'] as String, k)
              : null,
          'metodo.recibido': esUsd
              ? _ticketRow(
                  'Recibido',
                  'US\$${recibidoOriginal.toStringAsFixed(2)} '
                      '(tasa ${(r['tasa_conversion'] as num).toStringAsFixed(2)})',
                  k)
              : null,
        });
      case 'letras':
        // Monto en letras = COBRADO (lo que entró a caja).
        final cobrado =
            _esMulti ? _totalCobrado() : (r['monto_cordobas'] as num).toDouble();
        return [
          Padding(
            padding: EdgeInsets.symmetric(vertical: 4 * k),
            child: Text(
              montoALetras(cobrado, moneda: (r['moneda'] as String?) ?? 'NIO'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11 * k, fontWeight: FontWeight.w600),
            ),
          ),
        ];
      case 'totales':
        return _buildTotales(k);
      case 'mora':
        return _buildMora(k);
      case 'pie':
        if (settings.pieRecibo.isEmpty) return const [];
        return [
          Text(settings.pieRecibo,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)),
        ];
      case 'whatsapp':
        if (settings.empresaWhatsapp.isEmpty) return const [];
        return [
          Text('WhatsApp: ${settings.empresaWhatsapp}',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)),
        ];
      default:
        return const [];
    }
  }

  /// EL BLOQUE DE DINERO. Matemática y contenido IDÉNTICOS a `recibo_pdf.dart`:
  /// COBRADO (o TOTAL COBRADO en multi) siempre, + VUELTO/PAGADO si hubo vuelto
  /// (con manejo USD). Separación clara etiqueta↔valor con `spaceBetween` +
  /// `Expanded` → nunca se pegan ("COBRADO800,00").
  List<Widget> _buildTotales(double k) {
    if (_esMulti) {
      final totalCobrado = _totalCobrado();
      final totalVuelto = _totalVuelto();
      final totalOriginal = _totalOriginal();
      final totalEntregado = totalCobrado + totalVuelto;
      // Todo el grupo comparte moneda/tasa (registrarCobroMultiple usa una sola).
      final esUsd = (rows!.first['moneda'] as String?) == 'USD';
      return [
        _totalLine('Total cobrado', Fmt.cordobas(totalCobrado), 13 * k,
            bold: true),
        if (totalVuelto > 0.01) ...[
          SizedBox(height: 4 * k),
          _totalLine(esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
              Fmt.cordobas(totalVuelto), 13 * k,
              bold: true),
          SizedBox(height: 2 * k),
          _totalLine(
            'PAGADO',
            esUsd
                ? 'US\$${totalOriginal.toStringAsFixed(2)} = ${Fmt.cordobas(totalEntregado)}'
                : Fmt.cordobas(totalEntregado),
            14 * k,
            bold: true,
          ),
        ],
      ];
    }
    final r = row!;
    final vuelto = (r['vuelto_cordobas'] as num? ?? 0).toDouble();
    final cobrado = (r['monto_cordobas'] as num).toDouble();
    final entregado = cobrado + vuelto;
    final esUsd = (r['moneda'] as String) == 'USD';
    return [
      // Monto = lo aplicado a la cuota (lo que entra a la caja). Estilo fila
      // (13·k = tamaño de cuerpo, en negrita), como el template pedido.
      _totalLine('Monto', Fmt.cordobas(r['monto_cordobas'] as num), 13 * k,
          bold: true),
      // VUELTO + PAGADO: si hubo vuelto, mostrar ambos. Si no, COBRADO basta
      // (PAGADO == COBRADO en ese caso).
      if (vuelto > 0.01) ...[
        SizedBox(height: 4 * k),
        _totalLine(esUsd ? 'VUELTO (en C\$)' : 'VUELTO', Fmt.cordobas(vuelto),
            13 * k,
            bold: true),
        SizedBox(height: 4 * k),
        _totalLine(
          'PAGADO',
          esUsd
              ? 'US\$${(r['monto_original'] as num).toStringAsFixed(2)} = ${Fmt.cordobas(entregado)}'
              : Fmt.cordobas(entregado),
          14 * k,
          bold: true,
        ),
      ],
    ];
  }

  /// True si este recibo cobró SOLO el puente sobre una cuota YA pagada (cambio
  /// de fecha de un cliente al día): el host es una cuota saldada en un recibo
  /// previo, así que su "Cuota base"/período NO corresponden a lo cobrado hoy
  /// (solo el puente). En 1-mora la cuota SÍ se cobra → no aplica.
  bool get _esPuenteSolo {
    if (_esMulti || row == null) return false;
    final r = row!;
    final base = (r['cuota_monto'] as num?)?.toDouble() ?? 0;
    final aplicado = (r['monto_cordobas'] as num?)?.toDouble() ?? 0;
    final pagadoCuota = (r['monto_pagado_cuota'] as num? ?? aplicado).toDouble();
    final hayPuente = cargosRows.any((c) =>
        c['cuota_id'] == r['cuota_id'] && (c['origen'] as String?) == 'puente');
    // El host ya estaba saldado ANTES de este pago (lo cobrado fue solo el puente).
    return hayPuente && (pagadoCuota - aplicado) >= base - 0.01;
  }

  /// Líneas de descuentos/cargos de UNA cuota para el bloque `cuota`.
  /// El "Puente de pago" (origen='puente') SIEMPRE se muestra (es lo cobrado, no
  /// un descuento opcional); los descuentos/otros cargos quedan bajo el sub-toggle
  /// `mostrar_descuentos`. Descuentos con "-" y cargos con "+", igual que la app.
  List<Widget> _lineasCargos(Object? cuotaId, double k) {
    if (cuotaId == null) return const [];
    final mostrar = settings.reciboMostrarDescuentos;
    final conMotivo = mostrar && settings.reciboMostrarMotivoDescuentos;
    return [
      for (final c in cargosRows)
        if (c['cuota_id'] == cuotaId &&
            ((c['origen'] as String?) == 'puente' || mostrar))
          _ticketRow(
            cargoEtiquetaRecibo(c, conMotivo: conMotivo),
            '${(c['tipo'] as String? ?? '').startsWith('descuento') ? '-' : '+'}'
            '${Fmt.cordobas(c['monto'] as num? ?? 0)}',
            k,
          ),
    ];
  }

  /// Bloque `mora` (single + multi): título "EN MORA", una línea por mes
  /// (`Fmt.mes` ↔ saldo), y "TOTAL MORA". `moraRows` ya viene filtrado por el
  /// call-site. Resumen informativo — no toca la matemática del dinero.
  List<Widget> _buildMora(double k) {
    if (moraRows.isEmpty) return const [];
    final totalMora =
        moraRows.fold<double>(0, (s, m) => s + (m['saldo'] as num).toDouble());
    return [
      Text('EN MORA',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * k)),
      SizedBox(height: 2 * k),
      for (final m in moraRows)
        _ticketRow(
          Fmt.mesServicioLabel(
              DateTime.parse(m['periodo'] as String),
              (m['dia_pago'] as num?)?.toInt()),
          Fmt.cordobas(m['saldo'] as num),
          k,
        ),
      _totalLine('Total en mora', Fmt.cordobas(totalMora), 13 * k, bold: true),
    ];
  }

  // ----- Sumas del grupo (multi). Matemática idéntica a `recibo_pdf.dart`. ----
  double _totalCobrado() {
    var t = 0.0;
    for (final r in rows!) {
      t += (r['monto_cordobas'] as num).toDouble();
    }
    return t;
  }

  double _totalVuelto() {
    var t = 0.0;
    for (final r in rows!) {
      t += (r['vuelto_cordobas'] as num? ?? 0).toDouble();
    }
    return t;
  }

  // Σ monto_original = lo entregado en moneda original.
  double _totalOriginal() {
    var t = 0.0;
    for (final r in rows!) {
      t += (r['monto_original'] as num? ?? 0).toDouble();
    }
    return t;
  }

  // ----- Helpers de layout (SIN overflow) -----------------------------------

  /// Fila "etiqueta: valor" — la etiqueta a la izquierda, el valor a la derecha
  /// alineado al final. El valor está `Expanded` + `softWrap` + `textAlign:end`
  /// → un valor largo BAJA de línea en vez de cortarse (el bug actual). El gap
  /// entre etiqueta y valor evita que se peguen.
  Widget _ticketRow(String label, String value, [double k = 1]) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 0.5 * k),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            flex: 0,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 96 * k),
              child: Text('$label:', style: TextStyle(fontSize: 13 * k)),
            ),
          ),
          SizedBox(width: 6 * k),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              softWrap: true,
              style: TextStyle(fontSize: 13 * k),
            ),
          ),
        ],
      ),
    );
  }

  /// Línea de total: etiqueta a la izquierda, valor a la derecha, SIEMPRE
  /// separados (`Expanded` en el valor con `textAlign: end`). Resuelve el bug
  /// "COBRADO800,00" pegado. Negrita para destacar el dinero (sin color, B/N).
  Widget _totalLine(String label, String value, double fontSize,
      {bool bold = false}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.bold : FontWeight.w600,
      fontSize: fontSize,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // flex: 0 → la etiqueta toma su ancho natural y el valor (Expanded) se
        // queda con TODO el resto del ancho, alineándose contra el margen
        // derecho del papel (mismo "justificado" que las filas normales). Sin
        // esto la etiqueta tomaba flex 1 y el valor quedaba a media página.
        Flexible(flex: 0, child: Text(label, style: style)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(value,
              textAlign: TextAlign.end, softWrap: true, style: style),
        ),
      ],
    );
  }
}
