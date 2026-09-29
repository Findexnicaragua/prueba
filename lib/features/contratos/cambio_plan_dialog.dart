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

  /// Monto NOMINAL de la cuota en curso (sin el cargo del prorrateo). Es "el
  /// mes al plan anterior" de la tabla: hace falta para poder mostrar la suma
  /// completa y a cuánto queda la cuota, que es justo lo que faltaba.
  double? _montoEnCurso;

  /// La cuota del ciclo en curso YA está saldada (pagada por completo).
  ///
  /// Cuando pasa, el cargo del prorrateo NO se asienta sobre ella —la reabriría
  /// y el cliente tiene un recibo que dice que ese mes está pagado— sino sobre
  /// la siguiente (`contratos_repo`, regla del 2026-09-03). El diálogo tiene que
  /// DECIRLO antes de que el admin firme: el número es el mismo, pero la cuota
  /// que se mueve es otra.
  bool _enCursoSaldada = false;

  /// Si existe una cuota posterior donde asentar el cargo diferido. Sin ella
  /// (contrato terminándose) la diferencia no se cobra, y eso también se avisa.
  bool _haySiguiente = false;

  /// Deuda ya vencida y sin pagar del contrato, y en cuántas cuotas. Se muestra
  /// ARRIBA de todo: cambiar el plan de un cliente que debe es legítimo (por
  /// decisión de diseño la mora NO bloquea), pero quien lo hace tiene que
  /// saberlo — hoy la pantalla no lo menciona en ningún lado.
  double _deudaPrevia = 0;

  /// Los meses que se deben, del MAS VIEJO al mas nuevo, con su saldo.
  ///
  /// Antes solo se guardaba el total y el conteo, y el aviso decia "debe
  /// C\$500 · una cuota vencida" sin decir DE QUE MES. Rubén lo pidió
  /// (2026-09-02): *"me sale que debe 500 pero no me sale a qué mes (ciclo)
  /// pertenece, y en caso que deba varias deberían mostrarse también"*.
  /// El dato ya estaba en la consulta —`periodo` se lee y se parsea— y se
  /// descartaba.
  final List<({DateTime periodo, double saldo})> _deudaMeses = [];
  int _deudaCuotas = 0;

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
        'SELECT periodo, estado, monto, '
        'COALESCE(cargos_neto,0) AS cargos_neto, '
        'COALESCE(monto_pagado,0) AS monto_pagado '
        "  FROM cuotas WHERE contrato_id = ? AND estado <> 'anulada'",
        [widget.contratoId],
      );
      var futuras = 0;
      var deuda = 0.0;
      var deudaCuotas = 0;
      final meses = <({DateTime periodo, double saldo})>[];
      for (final c in cuotas) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final est = estadoServicio(periodo, widget.diaPago, _hoy);
        if (est == 'en_curso') {
          _finVentanaActual = servicioFin(periodo, widget.diaPago);
          _cicloInicio = ventanaServicio(periodo, widget.diaPago).inicio;
          _enCursoLabel = Fmt.mesServicioLabel(periodo, widget.diaPago);
          _proxCicloLabel = Fmt.mesServicioLabel(
              DateTime(periodo.year, periodo.month + 1, 1), widget.diaPago);
          _montoEnCurso = (c['monto'] as num).toDouble();
          // ¿Ya está saldada? Mismo criterio y mismo epsilon que la mutación
          // (`contratos_repo`), para que el preview y lo que se ejecuta no
          // puedan discrepar — principio #6 del AGENTS: quien firma tiene que
          // ver el número calculado con el MISMO criterio.
          _enCursoSaldada = (c['monto_pagado'] as num).toDouble() >=
              (c['monto'] as num).toDouble() +
                  (c['cargos_neto'] as num).toDouble() -
                  0.009;
        } else if (est == 'futuro') {
          // Hay dónde asentar un cargo diferido. A diferencia de `futuras`, acá
          // NO se filtra por `estado='pendiente'`: el repo elige la siguiente
          // entre TODAS las no anuladas, así que el aviso tiene que mirar lo
          // mismo o prometería distinto de lo que hace.
          _haySiguiente = true;
          // El conteo del resumen cuenta lo mismo que re-valúa el repo
          // (`estado='pendiente'` AND servicio futuro, contratos_repo:394).
          // Antes contaba TODAS las no anuladas, así que una cuota futura con
          // un adelanto entraba en el número prometido y quedaba afuera de la
          // operación: la pantalla ofrecía más cuotas de las que tocaba.
          if (c['estado'] == 'pendiente') futuras++;
        } else if (est == 'cumplido') {
          // Servicio ya prestado y todavía impago = deuda. Saldo canónico
          // (invariante #10): monto + cargos_neto − monto_pagado.
          final saldo = (c['monto'] as num).toDouble() +
              (c['cargos_neto'] as num).toDouble() -
              (c['monto_pagado'] as num).toDouble();
          if (saldo > 0.009) {
            deuda += saldo;
            deudaCuotas++;
            meses.add((periodo: periodo, saldo: saldo));
          }
        }
      }
      _futurasCount = futuras;
      _deudaPrevia = deuda;
      _deudaCuotas = deudaCuotas;
      // Del mas viejo al mas nuevo: una deuda se lee en el orden en que se
      // genero, y el mes mas viejo es el que decide si esto es un atraso o un
      // abandono.
      meses.sort((a, b) => a.periodo.compareTo(b.periodo));
      _deudaMeses
        ..clear()
        ..addAll(meses);
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
    // ORDER BY nombre, precio: en Mairena 18 de 25 planes COMPARTEN nombre
    // (7 se llaman "CATV", 5 "COMBO INTERNET+CATV 20MB"), así que ordenar solo
    // por nombre los dejaba en orden azaroso —366, 769, 1.831, 732…— y el ISP
    // reportó que "faltaban planes" cuando en realidad estaban todos pero no se
    // podían distinguir ni encontrar.
    // El conteo de contratos es la SEÑA que resuelve el empate: de los 7 CATV,
    // uno lo usan 2.106 clientes y los otros seis son casos sueltos de 1 a 6.
    final planes = await ps.db.getAll(
      'SELECT p.id, p.nombre, p.precio_mensual, '
      '(SELECT COUNT(*) FROM contratos c '
      "  WHERE c.plan_id = p.id AND c.estado = 'activo') AS contratos "
      'FROM planes p '
      'WHERE p.activo = 1 AND p.id <> ? '
      'ORDER BY p.nombre, p.precio_mensual',
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
            subtitulo: switch ((p['contratos'] as int?) ?? 0) {
              0 => 'sin contratos activos',
              1 => '1 contrato activo',
              final n => '$n contratos activos',
            },
            // El precio SIN formato, para poder encontrarlo tipeando `1282`
            // además de `1.282`.
            textoBusqueda: (p['precio_mensual'] as num).toStringAsFixed(0),
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
              // La deuda que el cliente YA tiene. Arriba de todo y no escondida
              // en el detalle: cambiarle el plan a alguien que debe es
              // legítimo (la mora NO bloquea, por decisión de diseño), pero
              // quien lo hace tiene que enterarse ANTES de confirmar.
              if (_deudaPrevia > 0) ...[
                _buildAvisoDeuda(scheme),
                const SizedBox(height: 12),
              ],
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
  /// Aviso de la deuda previa del contrato. Rojo y arriba: es un dato que
  /// cambia la decisión, no una nota al pie.
  Widget _buildAvisoDeuda(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border(
            left: BorderSide(color: scheme.error.withValues(alpha: 0.7), width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: scheme.error),
          const SizedBox(width: 7),
          // UN SOLO Expanded, y a la izquierda (checklist 15 de AGENTS):
          // absorbe el sobrante sin dejar hueco muerto.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Este cliente debe ${Fmt.cordobas(_deudaPrevia)}',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onErrorContainer)),
                // QUE MESES, y cuanto de cada uno. Saber que debe C\$2.150 no
                // dice si es un mes caro o cuatro seguidos, y esa diferencia
                // cambia la decision de cambiarle el plan.
                //
                // El rotulo sale de `Fmt.mesServicioLabel`, anclado al
                // dia_pago: es el MISMO helper que usa el resto del dialogo
                // (`_enCursoLabel`, `_proxCicloLabel`) y el que manda la regla
                // del mes de servicio. Con el mes calendario, este aviso
                // nombraria un mes distinto al del bloque de abajo para la
                // misma cuota.
                if (_deudaMeses.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, bottom: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final m in _deudaMeses)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Row(
                              children: [
                                // Un solo Expanded y a la izquierda (regla
                                // #15): los saldos forman columna sin importar
                                // cuanto mida el nombre del mes.
                                Expanded(
                                  child: Text(
                                      Fmt.mesServicioLabel(
                                          m.periodo, widget.diaPago),
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: scheme.onErrorContainer)),
                                ),
                                const SizedBox(width: 10),
                                Text(Fmt.cordobas(m.saldo),
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onErrorContainer)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                Text(
                    _deudaCuotas == 1
                        ? 'El cambio de plan no la toca: ese servicio ya se prestó.'
                        : 'El cambio de plan no las toca: ese servicio ya se prestó.',
                    style: TextStyle(
                        fontSize: 10.5, color: scheme.onErrorContainer)),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
    final desdeProx = _proxCicloLabel != null ? 'desde $_proxCicloLabel · ' : '';

    final rows = <Widget>[];
    // 0) La cuota que YA venció y sigue impaga. No se toca en ningún modo —su
    //    servicio se prestó con el plan viejo— pero decirlo evita la pregunta
    //    obvia de "¿y la de junio qué?" y explica POR QUÉ no aparece abajo.
    if (_deudaCuotas > 0) {
      rows.add(_resumenRow(
          scheme,
          Icons.history,
          scheme.outline,
          // Con UNA sola se la nombra: "la de agosto" es lo que el usuario
          // tiene en la cabeza, y deja este renglon diciendo lo mismo que el
          // aviso rojo de arriba. Con varias se mantiene el conteo — la lista
          // completa ya esta arriba y repetirla aca seria ruido.
          _deudaCuotas == 1 && _deudaMeses.isNotEmpty
              ? 'La cuota de '
                  '${Fmt.mesServicioLabel(_deudaMeses.first.periodo, widget.diaPago)}'
                  ' no se toca'
              : _deudaCuotas == 1
                  ? 'La cuota que ya venció no se toca'
                  : 'Las $_deudaCuotas cuotas vencidas no se tocan',
          'quedan en ${Fmt.cordobas(_deudaPrevia)}: ese servicio ya se prestó '
          'con ${widget.planActualNombre ?? "el plan actual"}',
          true));
    }
    // 1) Ciclo en curso
    if (!_modoHoy || prorr == null || prorr.sinAjuste) {
      rows.add(_resumenRow(
          scheme,
          Icons.flash_on,
          scheme.outline,
          'Ciclo en curso$enCurso',
          !_modoHoy
              ? 'Sigue a ${widget.planActualNombre ?? "el plan actual"}, sin cambio'
              : 'Sin ajuste (precio casi igual o sin días por correr)',
          true));
    } else {
      // La TABLA de la transición: es el corazón del pedido de Rubén
      // (2026-09-02). El texto viejo decía "+C$245,16 por los 25 días que
      // faltan" y no contestaba las dos preguntas que el dueño hizo: bajo QUÉ
      // PLAN se prorratea y a QUÉ PERÍODO se le suma. Ahora cada renglón
      // nombra un plan, el período se nombra una sola vez arriba, y la cuenta
      // cierra a la vista.
      rows.add(_tablaTransicion(scheme, prorr, ambar, verde));
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
    if (_modoHoy &&
        prorr != null &&
        prorr.esUpgrade &&
        !prorr.sinAjuste &&
        _enCursoSaldada &&
        !_haySiguiente) {
      // No alcanza con decir "nada ahora": acá no se cobra NUNCA.
      hoyDetalle = 'nada — y la diferencia tampoco se cobra después';
    } else if (_modoHoy &&
        prorr != null &&
        prorr.esUpgrade &&
        !prorr.sinAjuste &&
        _enCursoSaldada) {
      hoyDetalle = 'nada ahora — el ajuste va a la cuota de '
          '${_proxCicloLabel ?? "el próximo mes"}';
    } else if (_modoHoy && prorr != null && prorr.esUpgrade && !prorr.sinAjuste) {
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

  /// La tabla de la transición: cómo se arma la cuota del ciclo en curso.
  ///
  /// Contesta las dos preguntas que el texto viejo no contestaba: **bajo qué
  /// plan** se prorratea y **a qué período** se le suma. Cada renglón nombra un
  /// plan; el período se nombra UNA vez, arriba, con su ventana de servicio.
  ///
  /// El desglose por mes es lo que permite rehacer la multiplicación a mano
  /// (pedido explícito de Rubén). Son varios renglones y no uno porque **no
  /// existe un precio por día único**: cada día vale la diferencia dividida por
  /// los días de SU mes, así que un tramo a caballo de junio y julio tiene dos
  /// precios distintos. El promedio no es el precio de ningún día real.
  ///
  /// `Table` con `IntrinsicColumnWidth` a propósito: alinea las cifras **por
  /// construcción**. Con `Flexible`/`Expanded` la alineación depende del largo
  /// del texto de cada fila y se corre (checklist 15 de AGENTS).
  Widget _tablaTransicion(ColorScheme scheme, ProrrateoCambioPlan prorr,
      Color ambar, Color verde) {
    final sube = prorr.esUpgrade;
    final planViejo = widget.planActualNombre ?? 'el plan actual';
    final planNuevo = _planNuevoNombre ?? 'el plan nuevo';
    final dif = ((_precioNuevo ?? 0) - widget.precioActual).abs();

    TableRow fila(String texto, String? sub, String? valor,
        {bool fuerte = false, Color? color}) {
      return TableRow(children: [
        Padding(
          padding: const EdgeInsets.only(right: 10, top: 3, bottom: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(texto,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: color,
                      fontWeight: fuerte ? FontWeight.w700 : FontWeight.w500)),
              if (sub != null)
                Text(sub,
                    style: TextStyle(fontSize: 10.5, color: scheme.outline)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 3, bottom: 3),
          child: Text(valor ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 11.5,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: fuerte ? FontWeight.w700 : FontWeight.w500)),
        ),
      ]);
    }

    final ventana = (_cicloInicio != null && _finVentanaActual != null)
        ? ' · servicio del ${_ddmm(_cicloInicio!)} al ${_ddmm(_finVentanaActual!)}'
        : '';
    final filas = <TableRow>[];

    if (sube && _montoEnCurso != null) {
      filas.add(fila('Mes completo a $planViejo', 'como ya estaba facturado',
          Fmt.cordobas(_montoEnCurso!)));
    } else if (!sube && _montoEnCurso != null) {
      filas.add(fila('Este mes se factura completo a $planViejo',
          'la cuota NO baja: el servicio del mes ya empezó con ese plan',
          Fmt.cordobas(_montoEnCurso!)));
    }

    filas.add(fila(
        sube ? 'Diferencia hasta $planNuevo' : 'A favor del cliente',
        '${Fmt.cordobas(widget.precioActual)} → '
            '${Fmt.cordobas(_precioNuevo ?? 0)} = '
            '${Fmt.cordobas(dif)} al mes de diferencia',
        '${sube ? '+ ' : ''}${Fmt.cordobas(prorr.monto)}',
        color: sube ? ambar : verde));

    for (final t in prorr.tramos) {
      final dm = DateTime(t.anio, t.mes);
      filas.add(fila(
          '   ${t.dias} ${t.dias == 1 ? "día" : "días"} de ${Fmt.mes(dm)}',
          '   ${Fmt.cordobas(dif)} ÷ ${diasDelMes(t.anio, t.mes)} = '
              'C\$${t.precioDia.toStringAsFixed(4)} por día',
          Fmt.cordobas(t.subtotal),
          color: scheme.outline));
    }
    if (prorr.desde != null && prorr.hasta != null) {
      filas.add(fila(
          '   ${prorr.dias} ${prorr.dias == 1 ? "día" : "días"}, '
              'del ${_ddmm(prorr.desde!)} al ${_ddmm(prorr.hasta!)}',
          null,
          null,
          color: scheme.outline));
    }

    if (sube && _enCursoSaldada && !_haySiguiente) {
      // Contrato terminándose y el mes ya cobrado: la diferencia no se cobra.
      // Se dice ACÁ y no después, porque es plata que el ISP no va a ver.
      filas.add(fila(
          '${_enCursoLabel ?? "Este mes"} ya está pagada y no hay cuota '
              'siguiente: esta diferencia NO se cobra',
          null,
          null,
          fuerte: true,
          color: scheme.error));
    } else if (sube && _enCursoSaldada) {
      // El mes en curso ya está cobrado y con recibo entregado. El cargo se
      // asienta en la SIGUIENTE para no reabrirlo (regla del 2026-09-03). El
      // admin tiene que ver QUÉ cuota se mueve, no sólo cuánto.
      filas.add(fila(
          '${_enCursoLabel ?? "Este mes"} ya está pagada — no se toca',
          null,
          null,
          color: scheme.outline));
      filas.add(fila(
          'La diferencia se suma a la cuota de '
              '${_proxCicloLabel ?? "el próximo mes"}',
          null,
          Fmt.cordobas(prorr.monto),
          fuerte: true));
    } else if (sube && _montoEnCurso != null) {
      filas.add(fila('La cuota de ${_enCursoLabel ?? "este mes"} pasa a', null,
          Fmt.cordobas(_montoEnCurso! + prorr.monto),
          fuerte: true));
    } else if (!sube) {
      filas.add(fila('Queda a favor para la próxima factura', null,
          Fmt.cordobas(prorr.monto),
          fuerte: true, color: verde));
    }

    return Container(
      decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: scheme.outlineVariant, width: 0.5))),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
              'LA CUOTA DE ${(_enCursoLabel ?? "ESTE MES").toUpperCase()}'
              '${ventana.toUpperCase()}',
              style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: scheme.outline)),
          const SizedBox(height: 5),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(),
              1: IntrinsicColumnWidth(),
            },
            children: filas,
          ),
        ],
      ),
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
    // El cierre de la frase depende del MODO. Decía siempre "Solo el plan y el
    // precio de las cuotas futuras", y en modo Hoy eso CONTRADECÍA al renglón
    // de arriba, que acababa de mostrar que la cuota en curso sube. Una caja
    // que desmiente a la tabla que tiene encima es peor que no estar.
    final cierre = _modoHoy
        ? 'Sí cambian el plan, el precio de las cuotas futuras y la cuota en '
            'curso, como muestra el detalle de arriba.'
        : 'Solo el plan y el precio de las cuotas futuras.';
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
              'conteo de cuotas. $cierre',
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
