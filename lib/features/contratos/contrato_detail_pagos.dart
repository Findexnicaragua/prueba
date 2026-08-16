part of 'contrato_detail_screen.dart';

// Sección "Historial de pagos". Visible para TODOS los roles (cobrador
// incluido) — la acción destructiva (anular) sigue gateada a
// admin dentro del `_PagoDetalleSheet`. Consume `contratoPagosProvider` vía
// Riverpod (mismo patrón que el resto del detalle, ver contrato_providers.dart).
class _PagosSection extends ConsumerStatefulWidget {
  const _PagosSection({required this.contratoId, required this.esAdmin});
  final String contratoId;
  final bool esAdmin;

  @override
  ConsumerState<_PagosSection> createState() => _PagosSectionState();
}

class _PagosSectionState extends ConsumerState<_PagosSection> {
  // true = más nuevos primero (el orden DESC que viene del provider).
  bool _masNuevosPrimero = true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.payments, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Historial de pagos',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            // Toggle de orden por flechas: ↑ más antiguos / ↓ más nuevos (default).
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: false,
                    icon: Icon(Icons.arrow_upward, size: 18),
                    tooltip: 'Más antiguos primero'),
                ButtonSegment(
                    value: true,
                    icon: Icon(Icons.arrow_downward, size: 18),
                    tooltip: 'Más nuevos primero'),
              ],
              selected: {_masNuevosPrimero},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (sel) =>
                  setState(() => _masNuevosPrimero = sel.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ref.watch(contratoPagosProvider(widget.contratoId)).when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Center(child: Text(mensajeErrorHumano(e))),
          data: (rows) {
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('Sin pagos registrados',
                      style: TextStyle(color: scheme.outline)),
                ),
              );
            }

            // Ordenamos por PERÍODO (mes de servicio de la cuota), igual que la
            // lista de cuotas — no por fecha de pago (que los desordenaba). El
            // toggle elige más nuevos (período DESC) / más antiguos (ASC); a
            // igual período, desempata por fecha de pago.
            final ordenadas = [...rows]..sort((a, b) {
                final cmp = ((a['periodo'] as String?) ?? '')
                    .compareTo((b['periodo'] as String?) ?? '');
                if (cmp != 0) return _masNuevosPrimero ? -cmp : cmp;
                final fcmp = ((a['fecha_pago'] as String?) ?? '')
                    .compareTo((b['fecha_pago'] as String?) ?? '');
                return _masNuevosPrimero ? -fcmp : fcmp;
              });

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Renglón gemelo de la fila de chips de cuotas (misma altura) →
                // en el doble panel de desktop alinea el arranque de ambas tarjetas.
                SizedBox(
                  height: 32,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${ordenadas.length} ${ordenadas.length == 1 ? "pago" : "pagos"} · ordenado por mes',
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < ordenadas.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _PagoTile(row: ordenadas[i], esAdmin: widget.esAdmin),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _PagoTile extends ConsumerStatefulWidget {
  const _PagoTile({required this.row, required this.esAdmin});
  final Map<String, dynamic> row;
  final bool esAdmin;

  @override
  ConsumerState<_PagoTile> createState() => _PagoTileState();
}

class _PagoTileState extends ConsumerState<_PagoTile> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pago = Pago.fromRow(widget.row);
    final periodo = widget.row['periodo'] != null
        ? DateTime.parse(widget.row['periodo'] as String)
        : null;

    final metodoLabel = pago.metodo.label;
    final montoLabel = pago.moneda == Moneda.nio
        ? Fmt.cordobas(pago.montoCordobas)
        : '${Fmt.dolares(pago.montoOriginal)} (${Fmt.cordobas(pago.montoCordobas)})';

    return InkWell(
      onTap: _abrirDetalle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Icono
            Icon(
              pago.anulado ? Icons.block : Icons.check_circle,
              size: 20,
              color: pago.anulado ? scheme.error : Colors.green,
            ),
            const SizedBox(width: 10),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    periodo != null
                        ? Fmt.mesServicioLabel(
                            periodo,
                            widget.row['tipo_cargo_manual'] != null
                                ? null
                                : (widget.row['dia_pago'] as num?)?.toInt())
                        : '—',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      decoration:
                          pago.anulado ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(
                    '${Fmt.fechaCorta(pago.fechaPago)} · $metodoLabel',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ],
              ),
            ),
            // Monto
            Text(
              montoLabel,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: pago.anulado ? scheme.error : null,
                decoration: pago.anulado ? TextDecoration.lineThrough : null,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  void _abrirDetalle() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PagoDetalleSheet(
        row: widget.row,
        esAdmin: widget.esAdmin,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom sheet con detalle completo del pago + acciones (admin)
// ---------------------------------------------------------------------------

class _PagoDetalleSheet extends ConsumerStatefulWidget {
  const _PagoDetalleSheet({required this.row, required this.esAdmin});
  final Map<String, dynamic> row;
  final bool esAdmin;

  @override
  ConsumerState<_PagoDetalleSheet> createState() => _PagoDetalleSheetState();
}

class _PagoDetalleSheetState extends ConsumerState<_PagoDetalleSheet> {
  String? _reciboId;
  String? _numeroRecibo;
  String? _cobradorNombre;
  bool _cargandoExtras = true;
  bool _ejecutandoAccion = false;

  // Desglose de la cuota asociada (para explicar de qué se compone el monto).
  double? _cuotaMonto;
  double _cuotaCargosNeto = 0;
  double _cuotaMontoPagado = 0;
  String? _cuotaEstado;
  List<Map<String, dynamic>> _cargos = const [];

  @override
  void initState() {
    super.initState();
    _cargarExtras();
  }

  /// Carga datos no presentes en la fila del stream:
  /// - recibo.id + recibo.numero_completo (para "Ver recibo")
  /// - cobrador.nombre
  Future<void> _cargarExtras() async {
    try {
      final pagoId = widget.row['id'] as String;
      final recRows = await ps.db.getAll(
        'SELECT id, numero_completo FROM recibos WHERE pago_id = ? LIMIT 1',
        [pagoId],
      );
      final cobradorId = widget.row['cobrador_id'] as String?;
      String? nombre;
      if (cobradorId != null) {
        final cRows = await ps.db.getAll(
          'SELECT nombre FROM cobradores WHERE id = ? LIMIT 1',
          [cobradorId],
        );
        if (cRows.isNotEmpty) nombre = cRows.first['nombre'] as String?;
      }
      // Desglose de la cuota asociada: base + sus cargos/descuentos. Explica
      // de qué se compone el monto (ej. cuota 500 + ajuste por cambio de plan).
      double? cuotaMonto;
      double cuotaCargosNeto = 0;
      double cuotaMontoPagado = 0;
      String? cuotaEstado;
      List<Map<String, dynamic>> cargos = const [];
      final cuotaId = widget.row['cuota_id'] as String?;
      if (cuotaId != null) {
        final cuRows = await ps.db.getAll(
          'SELECT monto, cargos_neto, monto_pagado, estado FROM cuotas WHERE id = ? LIMIT 1',
          [cuotaId],
        );
        if (cuRows.isNotEmpty) {
          cuotaMonto = (cuRows.first['monto'] as num?)?.toDouble();
          cuotaCargosNeto =
              (cuRows.first['cargos_neto'] as num?)?.toDouble() ?? 0;
          cuotaMontoPagado =
              (cuRows.first['monto_pagado'] as num?)?.toDouble() ?? 0;
          cuotaEstado = cuRows.first['estado'] as String?;
        }
        cargos = await ps.db.getAll(
          'SELECT tipo, monto, descripcion FROM cargos_extra '
          'WHERE cuota_id = ? ORDER BY aplicado_en',
          [cuotaId],
        );
      }
      if (!mounted) return;
      setState(() {
        _reciboId = recRows.isNotEmpty ? recRows.first['id'] as String? : null;
        _numeroRecibo = recRows.isNotEmpty
            ? recRows.first['numero_completo'] as String?
            : null;
        _cobradorNombre = nombre;
        _cuotaMonto = cuotaMonto;
        _cuotaCargosNeto = cuotaCargosNeto;
        _cuotaMontoPagado = cuotaMontoPagado;
        _cuotaEstado = cuotaEstado;
        _cargos = cargos;
        _cargandoExtras = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargandoExtras = false);
    }
  }

  // Abre el historial de cambios de la CUOTA asociada al pago en un bottom
  // sheet (mismo patrón que `_showChangeLog` del contrato).
  void _showCuotaChangeLog(String cuotaId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Historial de la cuota',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: ctrl,
                child: HistorialOpLog(entidad: 'cuotas', entidadId: cuotaId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pago = Pago.fromRow(widget.row);
    final periodo = widget.row['periodo'] != null
        ? DateTime.parse(widget.row['periodo'] as String)
        : null;
    final periodoLabel = periodo != null
        ? Fmt.mesServicioLabel(
            periodo,
            widget.row['tipo_cargo_manual'] != null
                ? null
                : (widget.row['dia_pago'] as num?)?.toInt())
        : null;

    final puedeAnular = widget.esAdmin && !pago.anulado;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          top: 8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header: monto + estado
              Row(
                children: [
                  Icon(
                    pago.anulado ? Icons.block : Icons.check_circle,
                    color: pago.anulado ? scheme.error : Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pago.moneda == Moneda.nio
                              ? Fmt.cordobas(pago.montoCordobas)
                              : '${Fmt.dolares(pago.montoOriginal)} '
                                  '(${Fmt.cordobas(pago.montoCordobas)})',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                decoration: pago.anulado
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                        ),
                        if (periodoLabel != null)
                          Text('Cuota $periodoLabel · aplicado a la cuota',
                              style: TextStyle(
                                  fontSize: 11.5, color: scheme.outline)),
                      ],
                    ),
                  ),
                  if (pago.anulado)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('ANULADO',
                          style: TextStyle(
                            color: scheme.onErrorContainer,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          )),
                    ),
                  // Historial de la cuota asociada al pago (creación + cambios
                  // de estado + pagos). Esquina superior derecha del sheet.
                  if (widget.row['cuota_id'] != null)
                    IconButton(
                      icon: const Icon(Icons.history),
                      tooltip: 'Historial de la cuota',
                      onPressed: () => _showCuotaChangeLog(
                          widget.row['cuota_id'] as String),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(),

              // 1) Desglose del monto — solo si la cuota tiene cargos/descuentos
              //    (explica el "¿por qué este monto y no la cuota pelada?").
              if (_cuotaMonto != null && _cargos.isNotEmpty) ...[
                _buildDesglose(scheme, periodoLabel),
                const SizedBox(height: 12),
              ],

              // 2) Cómo pagó (entregado/vuelto/moneda) + cómo quedó la cuota.
              _buildPagoEstado(scheme, pago),
              const SizedBox(height: 12),

              // 3) Datos del cobro (método, fecha, cobrador, referencia, notas…).
              _seccionHeader(scheme, 'Datos del cobro'),
              _kv('Método', pago.metodo.label),
              _kv('Fecha del cobro',
                  '${Fmt.fechaCorta(pago.fechaPago)} ${Fmt.hora(pago.fechaPago)}'),
              if (_cobradorNombre != null) _kv('Cobrador', _cobradorNombre!),
              if (pago.referencia != null && pago.referencia!.isNotEmpty)
                _kv('Referencia', pago.referencia!),
              if (pago.notas != null && pago.notas!.isNotEmpty)
                _kv('Notas', pago.notas!),
              if (_numeroRecibo != null) _kv('Recibo', _numeroRecibo!),
              if (pago.anulado && pago.motivoAnulacion != null)
                _kv('Motivo anulación', pago.motivoAnulacion!),
              if (pago.anulado && pago.anuladoEn != null)
                _kv('Anulado el',
                    '${Fmt.fechaCorta(pago.anuladoEn!)} ${Fmt.hora(pago.anuladoEn!)}'),

              // Comprobante (foto), si se adjuntó al cobrar.
              if (pago.fotoComprobantePath != null) ...[
                const SizedBox(height: 12),
                Text('Comprobante',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                FotoComprobanteView(path: pago.fotoComprobantePath),
              ],

              const SizedBox(height: 20),
              const Divider(),

              // Acciones
              if (_cargandoExtras)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else ...[
                // Reimprimir/Ver recibo: visible para TODOS los roles
                // (cobrador necesita reimprimir su propio recibo).
                FilledButton.icon(
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Reimprimir / Ver recibo'),
                  onPressed: (_reciboId == null || _ejecutandoAccion)
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          // Cobro agrupado → abrir el recibo combinado. PERO si
                          // ESTE pago está ANULADO, forzar el path SINGLE
                          // (/recibo/:id sin ?grupo): el query multi filtra
                          // p.anulado=0 y traería los pagos HERMANOS vivos del
                          // grupo → mostraría un recibo válido y REIMPRIMIBLE en
                          // vez del anulado. En single, WHERE r.id=? trae la fila
                          // anulada y dispara el sello "ANULADO" + oculta
                          // reimprimir (audit 2026-06-30, finding #1).
                          final grupo = pago.anulado
                              ? null
                              : widget.row['grupo_cobro'] as String?;
                          context.push(grupo != null
                              ? '/recibo/$_reciboId?grupo=$grupo'
                              : '/recibo/$_reciboId');
                        },
                ),
                // Acciones destructivas: solo admin/admin_cobranza.
                if (widget.esAdmin) ...[
                  const SizedBox(height: 8),
                  if (puedeAnular)
                    OutlinedButton.icon(
                      icon: Icon(Icons.block, color: scheme.error),
                      label: Text('Anular pago',
                          style: TextStyle(color: scheme.error)),
                      onPressed:
                          _ejecutandoAccion ? null : _anular,
                    ),
                ],
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: TextStyle(color: scheme.outline, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w500, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _seccionHeader(ColorScheme scheme, String titulo) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Text(titulo.toUpperCase(),
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: scheme.outline)),
    );
  }

  /// Desglose del monto: cuota base + cada cargo/descuento = total de la cuota.
  /// Explica de qué se compone (ej. cuota 500 + ajuste por cambio de plan 116,77).
  Widget _buildDesglose(ColorScheme scheme, String? periodoLabel) {
    final total = (_cuotaMonto ?? 0) + _cuotaCargosNeto;

    Widget linea(String label, String monto, {Color? color, bool bold = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
            ),
            Text(monto,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                    color: color)),
          ],
        ),
      );
    }

    final filas = <Widget>[
      linea(periodoLabel != null ? 'Cuota $periodoLabel' : 'Cuota',
          Fmt.cordobas(_cuotaMonto ?? 0)),
    ];
    for (final cg in _cargos) {
      final tipo = cg['tipo'] as String? ?? '';
      final esResta = tipo.startsWith('descuento') || tipo == 'credito_aplicado';
      final monto = (cg['monto'] as num?)?.toDouble() ?? 0;
      final desc = (cg['descripcion'] as String?)?.trim();
      final label = (desc != null && desc.isNotEmpty)
          ? desc
          : (esResta ? 'Descuento' : 'Cargo');
      filas
        ..add(Divider(height: 1, color: scheme.outlineVariant))
        ..add(linea(label, '${esResta ? "− " : "+ "}${Fmt.cordobas(monto)}',
            color: esResta ? Colors.green.shade700 : Colors.orange.shade800));
    }
    filas
      ..add(Divider(height: 1, color: scheme.outlineVariant))
      ..add(Container(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        child: linea('Total de la cuota', Fmt.cordobas(total), bold: true),
      ));

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text('DE QUÉ SE COMPONE',
                style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: scheme.outline)),
          ),
          ...filas,
        ],
      ),
    );
  }

  /// Cómo pagó (entregado/vuelto, o USD + tasa) + cómo quedó la cuota.
  Widget _buildPagoEstado(ColorScheme scheme, Pago pago) {
    final entregado = pago.moneda == Moneda.nio
        ? 'Entregó ${Fmt.cordobas(pago.montoOriginal)}'
        : 'Entregó ${Fmt.dolares(pago.montoOriginal)} @ ${pago.tasaConversion.toStringAsFixed(2)}';
    final vuelto = 'Vuelto ${Fmt.cordobas(pago.vueltoCordobas)}';

    String estadoTxt = '—';
    Color estadoColor = scheme.outline;
    String saldoTxt = '';
    if (_cuotaEstado != null) {
      final saldo = (_cuotaMonto ?? 0) + _cuotaCargosNeto - _cuotaMontoPagado;
      switch (_cuotaEstado) {
        case 'pagada':
          estadoTxt = 'PAGADA';
          estadoColor = Colors.green.shade700;
          saldoTxt = 'saldo ${Fmt.cordobas(0)}';
        case 'parcial':
          estadoTxt = 'PARCIAL';
          estadoColor = Colors.orange.shade800;
          saldoTxt = 'restan ${Fmt.cordobas(saldo < 0 ? 0 : saldo)}';
        default:
          estadoTxt = (_cuotaEstado ?? '').toUpperCase();
          saldoTxt = 'saldo ${Fmt.cordobas(saldo < 0 ? 0 : saldo)}';
      }
    }

    Widget caja(Color bg, String titulo, String l1, String l2, Color? c) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration:
              BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(titulo.toUpperCase(),
                  style: TextStyle(
                      fontSize: 9, letterSpacing: 0.3, color: scheme.outline)),
              const SizedBox(height: 2),
              Text(l1,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: c)),
              Text(l2, style: TextStyle(fontSize: 10.5, color: scheme.outline)),
            ],
          ),
        ),
      );
    }

    // IntrinsicHeight: acota la altura del Row (si no, con stretch dentro del
    // SingleChildScrollView reclama altura infinita y empuja lo de abajo al vacío).
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caja(scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              'Cómo pagó', entregado, vuelto, null),
          if (_cuotaEstado != null) ...[
            const SizedBox(width: 8),
            caja(estadoColor.withValues(alpha: 0.12), 'La cuota quedó',
                estadoTxt, saldoTxt, estadoColor),
          ],
        ],
      ),
    );
  }

  Future<void> _anular() async {
    // Anular es acción atribuida al usuario (anulado_por) → bloqueada al
    // impersonar: el super_admin impersonando la atribuiría a su fila real
    // (tenant System), no al tenant impersonado. Misma red que pagos_admin_screen
    // (M3); esta superficie la omitía (audit Fable 5).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => const _AnularPagoDialog(),
    );
    if (motivo == null || motivo.trim().isEmpty || !mounted) return;

    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;

    setState(() => _ejecutandoAccion = true);
    try {
      await ref.read(pagosRepoProvider).anularPago(
            pagoId: widget.row['id'] as String,
            anuladoPorId: me.id,
            motivo: motivo.trim(),
          );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pago anulado')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _ejecutandoAccion = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al anular: $e')),
        );
      }
    }
  }
}

// Dialog de anulación — local al sheet para no acoplarse al
// `pagos_admin_screen.dart`. Misma UX/copy.
class _AnularPagoDialog extends StatefulWidget {
  const _AnularPagoDialog();

  @override
  State<_AnularPagoDialog> createState() => _AnularPagoDialogState();
}

class _AnularPagoDialogState extends State<_AnularPagoDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anular pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              'Esta acción queda registrada en auditoría. La cuota volverá '
              'a su estado anterior y el recibo emitido queda inválido. '
              'Para volver a cobrar, registrá el cobro de nuevo desde la cuota.'),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo de anulación *',
              hintText: 'Ej. Monto incorrecto, registrado por error...',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (_ctrl.text.trim().isEmpty) return;
            Navigator.pop(context, _ctrl.text);
          },
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          child: const Text('Anular'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sección "Saldo a favor" (crédito por excedente, 0127)
// ---------------------------------------------------------------------------
// Muestra los movimientos de saldo a favor ligados al contrato (acreditado /
// aplicado a una cuota / devuelto / condonado / revertido). Hace VISIBLE que
// una cuota se cubrió con crédito (no efectivo) — el crédito no es un pago, así
// que no aparece en "Historial de pagos". Oculta si no hay movimientos.
class _SaldoFavorContratoSection extends ConsumerWidget {
  const _SaldoFavorContratoSection({required this.contratoId});
  final String contratoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows =
        ref.watch(contratoSaldosFavorProvider(contratoId)).valueOrNull ??
            const [];
    if (rows.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    String etiqueta(Map<String, dynamic> r) {
      final tipo = r['tipo'] as String? ?? '';
      final periodoRaw = r['periodo'] as String?;
      final mes = periodoRaw != null
          ? Fmt.mesServicioLabel(
              DateTime.parse(periodoRaw), (r['dia_pago'] as num?)?.toInt())
          : null;
      return switch (tipo) {
        'acreditado' =>
          mes != null ? 'Acreditado · excedente de $mes' : 'Acreditado',
        'aplicado' => mes != null ? 'Aplicado a $mes' : 'Aplicado a cuota',
        'devuelto' => 'Devuelto en efectivo',
        'condonado' => 'Condonado',
        'revertido' => 'Revertido',
        _ => tipo,
      };
    }

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.savings_outlined,
                  size: 18, color: Colors.green.shade700),
              const SizedBox(width: 6),
              Text('Saldo a favor',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                      child: Text(etiqueta(r),
                          style: const TextStyle(fontSize: 13))),
                  Text(
                    '${(r['tipo'] == 'acreditado') ? '+' : '−'} ${Fmt.cordobas((r['monto'] as num? ?? 0).toDouble())}',
                    style:
                        TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                'El crédito a favor no es un cobro: no entra a la caja ni al recaudado.',
                style: TextStyle(fontSize: 11, color: scheme.outline)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sección Documento del Contrato
// ---------------------------------------------------------------------------
// Admin/admin_cobranza pueden adjuntar/reemplazar/eliminar documento del
// contrato (PDF, Word, foto). Storage bucket: contratos-documentos.
// Path scheme: {tenant_id}/{contrato_id}/{timestamp}.{ext}

