import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/repositories/contratos_repo.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/prorrateo.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/selector_buscable.dart';

/// Diálogo "Cambiar de plan" (feature contract-new-feature). Mantiene el contrato
/// y su vigencia; solo cambia el plan. Dos efectos (SegmentedButton):
/// - **Próximo ciclo** (default): las cuotas FUTURAS pasan al precio nuevo; el
///   ciclo en curso queda al plan viejo. CERO plata en el acto.
/// - **Hoy con prorrateo**: además ajusta los días NO servidos del ciclo en curso
///   a la diferencia — upgrade → cargo cobrable en la cuota en curso; downgrade →
///   crédito a favor (R17).
///
/// Bloqueado al impersonar (como el cobro). Llama a `ContratosRepo.cambiarPlan`
/// (transacción única, ya testeada). Devuelve `true` por `Navigator.pop` si se
/// cambió el plan (el caller refresca / muestra el snack).
class CambioPlanDialog extends ConsumerStatefulWidget {
  const CambioPlanDialog({
    super.key,
    required this.contratoId,
    required this.diaPago,
    required this.planActualId,
    required this.precioActual,
    this.planActualNombre,
    this.clienteNombre,
    this.soloSeleccionar = false,
  });

  final String contratoId;
  final int diaPago;
  final String? planActualId;
  final double precioActual;
  final String? planActualNombre;
  final String? clienteNombre;

  /// Modo PEDIR en vez de EJECUTAR. El diálogo muestra exactamente la misma
  /// vista previa —que es justo lo que el solicitante tiene que ver antes de
  /// pedir— pero al confirmar NO cambia nada: devuelve la selección para que
  /// el llamador arme la solicitud. Lo usa el rol que necesita aprobación.
  final bool soloSeleccionar;

  @override
  ConsumerState<CambioPlanDialog> createState() => _CambioPlanDialogState();
}

class _CambioPlanDialogState extends ConsumerState<CambioPlanDialog> {
  String? _planNuevoId;
  String? _planNuevoNombre;
  double? _precioNuevo;
  bool _modoHoy = false;

  bool _cargando = true;
  String? _noElegible; // motivo por el que NO se puede (impersonación / error)
  DateTime? _finVentanaActual; // fin del ciclo en curso (para el preview Hoy)
  DateTime? _cicloInicio; // inicio de la ventana del ciclo en curso
  String? _enCursoLabel; // ej. "Junio 2026" — la cuota en curso (resumen)
  String? _proxCicloLabel; // ej. "Julio 2026" — primer ciclo futuro
  DateTime? _fechaFin; // vencimiento del contrato (la vigencia no cambia)
  int _futurasCount = 0; // cuántas cuotas futuras se re-valúan (resumen)

  bool _enviando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  DateTime _parsePeriodo(String s) {
    final p = s.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), 1);
  }

  // Día local de Nicaragua (UTC-6, sin DST), igual que el resto de la lógica de
  // día/servicio (regla #1b). Mismo valor que se pasa al repo.
  DateTime get _hoy =>
      DateTime.now().toUtc().subtract(const Duration(hours: 6));

  Future<void> _cargar() async {
    try {
      // Bloqueo de impersonación (como el cobro): el super_admin impersonando no
      // ejecuta acciones atribuibles. El botón ya se oculta; esto es defensa.
      if (ref.read(estaImpersonandoProvider)) {
        setState(() {
          _cargando = false;
          _noElegible = 'No disponible mientras impersonás un tenant.';
        });
        return;
      }
      // Si no hay OTRO plan activo al cual cambiar, avisar de entrada (en vez de
      // dejar el botón Confirmar deshabilitado sin pista).
      final otros = await ps.db.getAll(
        'SELECT 1 FROM planes WHERE activo = 1 AND id <> ? LIMIT 1',
        [widget.planActualId],
      );
      if (otros.isEmpty) {
        if (!mounted) return;
        setState(() {
          _cargando = false;
          _noElegible = 'No hay otros planes activos para cambiar. Creá uno en '
              'el catálogo de planes.';
        });
        return;
      }
      // Buscar el período del ciclo EN CURSO → su fin de ventana, para el preview
      // del prorrateo del modo Hoy (anclado al día_pago).
      final cuotas = await ps.db.getAll(
        "SELECT periodo FROM cuotas WHERE contrato_id = ? AND estado <> 'anulada'",
        [widget.contratoId],
      );
      var futuras = 0;
      for (final c in cuotas) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final est = estadoServicio(periodo, widget.diaPago, _hoy);
        if (est == 'en_curso') {
          _finVentanaActual = servicioFin(periodo, widget.diaPago);
          _cicloInicio = ventanaServicio(periodo, widget.diaPago).inicio;
          _enCursoLabel = Fmt.mesServicioLabel(periodo, widget.diaPago);
          _proxCicloLabel = Fmt.mesServicioLabel(
              DateTime(periodo.year, periodo.month + 1, 1), widget.diaPago);
        } else if (est == 'futuro') {
          futuras++;
        }
      }
      _futurasCount = futuras;
      // Vencimiento del contrato (para la nota "la vigencia no cambia").
      final ctRows = await ps.db.getAll(
        'SELECT fecha_fin FROM contratos WHERE id = ? LIMIT 1',
        [widget.contratoId],
      );
      final ff = ctRows.isNotEmpty ? ctRows.first['fecha_fin'] as String? : null;
      if (ff != null) _fechaFin = DateTime.tryParse(ff);
      if (!mounted) return;
      setState(() => _cargando = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _noElegible = mensajeErrorHumano(e);
        });
      }
    }
  }

  Future<void> _elegirPlan() async {
    final planes = await ps.db.getAll(
      'SELECT id, nombre, precio_mensual FROM planes '
      'WHERE activo = 1 AND id <> ? ORDER BY nombre',
      [widget.planActualId],
    );
    if (!mounted) return;
    if (planes.isEmpty) {
      _snack('No hay otros planes activos.');
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí el plan nuevo',
      hint: 'Buscar plan...',
      opciones: [
        for (final p in planes)
          OpcionSelector(
            valor: p,
            nombre:
                '${p['nombre']} · ${Fmt.cordobas((p['precio_mensual'] as num).toDouble())}',
          ),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _planNuevoId = elegido['id'] as String;
      _planNuevoNombre = elegido['nombre'] as String;
      _precioNuevo = (elegido['precio_mensual'] as num).toDouble();
    });
  }

  /// Prorrateo del modo Hoy (preview). null si no aplica.
  ProrrateoCambioPlan? get _prorrateoHoy {
    if (!_modoHoy || _precioNuevo == null || _finVentanaActual == null) {
      return null;
    }
    return prorrateoCambioPlanHoy(
      hoy: _hoy,
      finVentanaActual: _finVentanaActual!,
      precioViejo: widget.precioActual,
      precioNuevo: _precioNuevo!,
    );
  }

  Future<void> _confirmar() async {
    if (_planNuevoId == null || _precioNuevo == null) {
      _snack('Elegí el plan nuevo.');
      return;
    }
    setState(() {
      _enviando = true;
      _error = null;
    });
    try {
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final tenantId = ref.read(tenantIdProvider);
      if (me == null || tenantId == null) {
        throw StateError('No se pudo identificar el usuario o el tenant.');
      }
      // Defensa contra preview viejo: re-lee el plan FRESCO y aborta si cambió
      // desde que se abrió el diálogo (otro device sincronizó).
      final fresh = await ps.db.getOptional(
        'SELECT plan_id FROM contratos WHERE id = ?',
        [widget.contratoId],
      );
      if (fresh != null && fresh['plan_id'] != widget.planActualId) {
        throw StateError('El plan del contrato cambió. Reabrí el diálogo.');
      }
      if (widget.soloSeleccionar) {
        // No se toca nada: se devuelve QUÉ se pidió. El precio viaja como
        // snapshot del momento del pedido; al aprobar se re-lee el vivo y, si
        // cambió, queda escrito en el motivo (solicitudes_repo).
        if (mounted) {
          Navigator.pop(context, (
            planId: _planNuevoId!,
            planNombre: _planNuevoNombre,
            precio: _precioNuevo!,
            modoHoy: _modoHoy,
          ));
        }
        return;
      }
      await ContratosRepo().cambiarPlan(
        tenantId: tenantId,
        contratoId: widget.contratoId,
        cobradorId: me.id,
        planNuevoId: _planNuevoId!,
        precioNuevo: _precioNuevo!,
        hoy: _hoy,
        modoHoy: _modoHoy,
        precioViejo: widget.precioActual,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _enviando = false;
          _error = mensajeErrorHumano(e);
        });
      }
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_cargando) {
      return const AlertDialog(
        content: SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_noElegible != null) {
      return AlertDialog(
        title: const Text('Cambiar de plan'),
        content: Text(_noElegible!),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      );
    }

    final prorr = _prorrateoHoy;
    final esDowngrade =
        _precioNuevo != null && _precioNuevo! < widget.precioActual;

    // No se puede cerrar con back / tap-afuera mientras se está confirmando
    // (evita dejar la transacción a medias o un doble-envío). Regla #9.
    return PopScope(
      canPop: !_enviando,
      child: AlertDialog(
      title: const Text('Cambiar de plan'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Plan actual → nuevo (nombre + precio + delta). El recuadro
              // "nuevo" es el SelectorBuscable (regla #10 — lista DB en diálogo).
              _buildDeA(scheme),
              const SizedBox(height: 12),
              // Contexto de fechas: día de pago, ciclo actual, vencimiento.
              _buildFechaBar(scheme),
              const SizedBox(height: 16),
              const Text('¿Cuándo aplica?',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Próximo ciclo')),
                  ButtonSegment(value: true, label: Text('Hoy con prorrateo')),
                ],
                selected: {_modoHoy},
                onSelectionChanged: _enviando
                    ? null
                    : (s) => setState(() => _modoHoy = s.first),
              ),
              const SizedBox(height: 5),
              Text(
                _modoHoy
                    ? 'Arranca ya. Se ajustan los días que faltan del ciclo actual.'
                    : 'Arranca el próximo mes. No se cobra nada hoy.',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
              const SizedBox(height: 14),
              _buildResumen(scheme, prorr, esDowngrade),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: (_planNuevoId == null || _enviando) ? null : _confirmar,
          child: _enviando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Confirmar'),
        ),
      ],
      ),
    );
  }

  /// Plan actual → nuevo, con nombre + precio + el delta (↑ sube / ↓ baja). El
  /// recuadro "nuevo" es tappable y abre el SelectorBuscable.
  Widget _buildDeA(ColorScheme scheme) {
    // IntrinsicHeight: acota la altura del Row (si no, con stretch dentro del
    // SingleChildScrollView reclama altura infinita y empuja lo de abajo al vacío).
    return IntrinsicHeight(
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ACTUAL',
                    style: TextStyle(
                        fontSize: 9, letterSpacing: 0.4, color: scheme.outline)),
                const SizedBox(height: 2),
                Text(widget.planActualNombre ?? 'Plan actual',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600)),
                Text('${Fmt.cordobas(widget.precioActual)} / mes',
                    style: TextStyle(fontSize: 10.5, color: scheme.outline)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Icon(Icons.arrow_forward, size: 18, color: scheme.primary),
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _enviando ? null : _elegirPlan,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.35),
                border: Border.all(color: scheme.primary),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('NUEVO',
                        style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 0.4,
                            color: scheme.primary)),
                    Icon(Icons.arrow_drop_down, size: 14, color: scheme.primary),
                  ]),
                  const SizedBox(height: 2),
                  Text(_planNuevoNombre ?? 'Tocá para elegir',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _planNuevoNombre == null
                              ? scheme.outline
                              : scheme.primary)),
                  if (_precioNuevo != null) _deltaLine(scheme),
                ],
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }

  Widget _deltaLine(ColorScheme scheme) {
    final delta = _precioNuevo! - widget.precioActual;
    final String suf;
    if (delta > 0) {
      suf = ' · ↑ sube ${Fmt.cordobas(delta)}';
    } else if (delta < 0) {
      suf = ' · ↓ baja ${Fmt.cordobas(-delta)}';
    } else {
      suf = ' · = igual';
    }
    return Text('${Fmt.cordobas(_precioNuevo!)} / mes$suf',
        style: TextStyle(fontSize: 10.5, color: scheme.primary));
  }

  /// Resumen estructurado: ciclo en curso · cuotas futuras · plata de hoy.
  /// Calca el cálculo del repo (no inventa números).
  Widget _buildResumen(
      ColorScheme scheme, ProrrateoCambioPlan? prorr, bool esDowngrade) {
    if (_precioNuevo == null) {
      return Text('Elegí el plan nuevo para ver el detalle.',
          style: TextStyle(color: scheme.outline, fontSize: 12));
    }
    final nuevo = Fmt.cordobas(_precioNuevo!);
    final verde = Colors.green.shade700;
    final ambar = Colors.orange.shade800;
    final enCurso = _enCursoLabel != null ? ' ($_enCursoLabel)' : '';
    // Rango de días que faltan del ciclo (del que paga hoy al fin de ventana).
    final rango = _finVentanaActual != null
        ? ' (${_ddmm(_hoy.add(const Duration(days: 1)))} → ${_ddmm(_finVentanaActual!)})'
        : '';
    final desdeProx = _proxCicloLabel != null ? 'desde $_proxCicloLabel · ' : '';

    final rows = <Widget>[];
    // 1) Ciclo en curso
    if (!_modoHoy || prorr == null || prorr.sinAjuste) {
      rows.add(_resumenRow(
          scheme,
          Icons.flash_on,
          scheme.outline,
          'Ciclo en curso$enCurso',
          !_modoHoy
              ? 'Sigue al plan actual, sin cambio'
              : 'Sin ajuste (precio casi igual o sin días por correr)',
          true));
    } else if (prorr.esUpgrade) {
      rows.add(_resumenRow(
          scheme,
          Icons.flash_on,
          ambar,
          'Cuota en curso$enCurso',
          '+ ${Fmt.cordobas(prorr.monto)} por los ${prorr.dias} días que faltan$rango',
          true));
    } else {
      rows.add(_resumenRow(
          scheme,
          Icons.savings_outlined,
          verde,
          'Crédito a favor',
          '${Fmt.cordobas(prorr.monto)} por los ${prorr.dias} días que faltan$rango',
          true));
    }
    // 2) Cuotas futuras
    rows.add(_resumenRow(
        scheme,
        Icons.event_repeat,
        scheme.primary,
        '$_futurasCount ${_futurasCount == 1 ? "cuota futura" : "cuotas futuras"}',
        '${desdeProx}pasan a $nuevo',
        true));
    // 3) Se cobra hoy
    final String hoyDetalle;
    if (_modoHoy && prorr != null && prorr.esUpgrade && !prorr.sinAjuste) {
      hoyDetalle = 'nada ahora — el ajuste entra en la próxima cobranza';
    } else if (_modoHoy &&
        prorr != null &&
        !prorr.esUpgrade &&
        !prorr.sinAjuste) {
      hoyDetalle = 'nada — queda como crédito a favor del cliente';
    } else {
      hoyDetalle = 'nada';
    }
    rows.add(_resumenRow(scheme, Icons.payments_outlined, verde, 'Se cobra hoy',
        hoyDetalle, false));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(9)),
                ),
                child: Text('QUÉ CAMBIA, CUÁNDO Y POR QUÉ',
                    style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        color: scheme.outline)),
              ),
              ...rows,
            ],
          ),
        ),
        const SizedBox(height: 9),
        _buildVigenciaNota(scheme),
      ],
    );
  }

  Widget _resumenRow(ColorScheme scheme, IconData icon, Color color,
      String titulo, String detalle, bool divider) {
    return Container(
      decoration: divider
          ? BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: scheme.outlineVariant, width: 0.5)))
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600)),
                Text(detalle,
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _ddmm(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  /// Barra de contexto: día de pago · ciclo actual (ventana) · vencimiento del
  /// contrato. Para que el admin tenga las fechas a la vista.
  Widget _buildFechaBar(ColorScheme scheme) {
    Widget box(IconData icon, String label, String valor) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 11, color: scheme.outline),
                const SizedBox(width: 3),
                Text(label,
                    style: TextStyle(fontSize: 9, color: scheme.outline)),
              ]),
              const SizedBox(height: 1),
              Text(valor,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
    }

    final ciclo = (_cicloInicio != null && _finVentanaActual != null)
        ? '${_ddmm(_cicloInicio!)} → ${_ddmm(_finVentanaActual!)}'
        : '—';
    final vence = _fechaFin != null ? Fmt.fechaCorta(_fechaFin!) : 'Indefinido';
    // IntrinsicHeight: acota el Row stretch dentro del scroll (ver _buildDeA).
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          box(Icons.event_available, 'Día de pago',
              '${widget.diaPago} de cada mes'),
          const SizedBox(width: 6),
          box(Icons.sync, 'Ciclo actual', ciclo),
          const SizedBox(width: 6),
          box(Icons.flag_outlined, 'Vence', vence),
        ],
      ),
    );
  }

  /// Nota: qué NO cambia (día de pago, vigencia, conteo). El feature solo cambia
  /// el plan + el precio de las cuotas futuras.
  Widget _buildVigenciaNota(ColorScheme scheme) {
    final verde = Colors.green.shade700;
    final vence =
        _fechaFin != null ? ' (hasta ${Fmt.fechaCorta(_fechaFin!)})' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: verde.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 13, color: verde),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'No cambian: el día de pago, la vigencia del contrato$vence ni el '
              'conteo de cuotas. Solo el plan y el precio de las cuotas futuras.',
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
