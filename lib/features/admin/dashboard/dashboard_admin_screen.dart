import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/providers/dashboard_providers.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log.dart';
import '../../../data/utils/periodo_dashboard.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/rango_fechas_dialog.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';
import 'mora_historica_card.dart';
import 'tendencia_cobros_card.dart';

/// Gate del resumen financiero: pide el PIN del admin ANTES de mostrarlo.
///
/// El desbloqueo es por VISITA, no por sesión de app: `_desbloqueado` vive en
/// el State, así que al navegar fuera de Resumen el widget se destruye y al
/// volver se vuelve a pedir. Además se re-bloquea cuando la app pasa a segundo
/// plano (minimizar / cambiar de app), para que una máquina desatendida con
/// Resumen abierto no quede expuesta.
class DashboardPinGate extends ConsumerStatefulWidget {
  const DashboardPinGate({super.key});

  @override
  ConsumerState<DashboardPinGate> createState() => _DashboardPinGateState();
}

class _DashboardPinGateState extends ConsumerState<DashboardPinGate>
    with WidgetsBindingObserver {
  bool _desbloqueado = false;
  String _entrada = '';
  bool _error = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `hidden`/`paused` = la app dejó de estar visible (minimizada en Windows,
    // en background en Android). NO usamos `inactive`: en desktop se dispara al
    // perder el foco de la ventana, lo que re-bloquearía al alternar de app por
    // un segundo. Al volver, el PIN se pide de nuevo.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (_desbloqueado && mounted) {
        setState(() {
          _desbloqueado = false;
          _entrada = '';
          _error = false;
        });
      }
    }
  }

  void _agregarDigito(String d) {
    if (_entrada.length >= 4) return;
    setState(() {
      _entrada += d;
      _error = false;
    });
    if (_entrada.length == 4) {
      _verificar();
    }
  }

  void _borrarDigito() {
    if (_entrada.isEmpty) return;
    setState(() {
      _entrada = _entrada.substring(0, _entrada.length - 1);
      _error = false;
    });
  }

  /// Compara contra `dashboard_pins`, que baja SOLO la fila propia (0202).
  /// Antes el PIN venía en el modelo del cobrador y viajaba tenant-wide.
  Future<void> _verificar() async {
    final cobrador = ref.read(cobradorActualProvider).valueOrNull;
    if (cobrador == null) return;
    final rows = await ps.db.getAll(
      'SELECT pin FROM dashboard_pins WHERE id = ?',
      [cobrador.id],
    );
    final pin = rows.isEmpty ? '' : (rows.first['pin'] as String? ?? '');
    if (!mounted) return;
    if (pin.isNotEmpty && _entrada == pin) {
      setState(() => _desbloqueado = true);
    } else {
      setState(() {
        _error = true;
        _entrada = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    if (cobrador == null) return const SizedBox.shrink();

    if (cobrador.esSuperAdmin) return const DashboardAdminScreen();
    // El PIN aplica a `admin` y a `lectura` (0198), los dos roles que abren el
    // resumen financiero como su vista principal. El resto entra sin gate.
    if (!cobrador.esAdmin && !cobrador.esLectura) {
      return const DashboardAdminScreen();
    }

    // `_desbloqueado` va PRIMERO: el PIN se guarda server-side (RPC), así que
    // `cobrador.dashboardPin` sigue vacío hasta que PowerSync lo baje. Con el
    // orden invertido, al guardarlo se volvía a entrar por la rama `isEmpty` y
    // reaparecía "Configurá tu PIN" con el snackbar de éxito encima.
    if (_desbloqueado) {
      return const DashboardAdminScreen();
    }

    if (!cobrador.dashboardPinConfigurado) {
      return _PinSetupScreen(
        onConfigurado: () => setState(() => _desbloqueado = true),
      );
    }

    return _PinEntryScreen(
      entrada: _entrada,
      error: _error,
      onDigit: _agregarDigito,
      onDelete: _borrarDigito,
    );
  }
}

class _PinSetupScreen extends ConsumerStatefulWidget {
  const _PinSetupScreen({required this.onConfigurado});

  /// Avisa al gate que el PIN quedó guardado, para entrar sin re-pedirlo.
  final VoidCallback onConfigurado;

  @override
  ConsumerState<_PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends ConsumerState<_PinSetupScreen> {
  final _ctrl = TextEditingController();
  bool _guardando = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    final pin = _ctrl.text.trim();
    if (pin.length != 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El PIN debe tener 4 dígitos')),
      );
      return;
    }
    setState(() => _guardando = true);
    try {
      final cobrador = ref.read(cobradorActualProvider).valueOrNull;
      if (cobrador == null) return;
      // El rol `lectura` descarta su cola de subida, así que para él un UPDATE
      // local nunca llegaría al server: SIEMPRE va por RPC, y si no hay red
      // falla con un mensaje (no hay forma honesta de guardárselo).
      //
      // El resto de los roles sí sube cola. Para ellos la RPC es preferible
      // (queda escrito al toque, sin depender del sync) pero NO puede ser
      // obligatoria: este gate es bloqueante — un admin sin PIN y sin internet
      // quedaría encerrado sin poder abrir su propio dashboard. Por eso, si la
      // RPC falla, cae al write local de siempre.
      if (cobrador.esLectura) {
        await Supabase.instance.client
            .rpc('set_mi_dashboard_pin', params: {'p_pin': pin});
      } else {
        try {
          await Supabase.instance.client
              .rpc('set_mi_dashboard_pin', params: {'p_pin': pin});
        } catch (_) {
          await ps.dbW.execute(
            'UPDATE cobradores SET dashboard_pin = ? WHERE id = ?',
            [pin, cobrador.id],
          );
        }
      }
      // op_log solo para roles que pueden escribir: el de `lectura` se
      // descartaría en la cola y quedaría solo en su SQLite local.
      if (!cobrador.esLectura) {
        final me = Supabase.instance.client.auth.currentUser;
        final actor = me != null
            ? await OpLog.actorDeUsuario(ps.db, me.id)
            : const OpLogActor.systemAdmin();
        final opId = OpLog.nuevoOpId();
        await ps.dbW.writeTransaction((tx) async {
          await OpLog.escribir(tx,
              tenantId: cobrador.tenantId,
              opId: opId,
              tipoOp: 'editar',
              entidad: 'cobradores',
              entidadId: cobrador.id,
              accion: 'update',
              diff: {
                'campos': [
                  {'campo': 'dashboard_pin', 'antes': '', 'despues': '****'},
                ]
              },
              actor: actor,
              ocurridoEn: DateTime.now().toUtc());
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN configurado')),
        );
        widget.onConfigurado();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${mensajeErrorHumano(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: scheme.tertiaryContainer,
              child: Icon(Icons.lock_open,
                  size: 36, color: scheme.onTertiaryContainer),
            ),
            const SizedBox(height: 20),
            Text(
              'Configurá tu PIN de acceso',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Elegí un código de 4 dígitos para proteger el '
              'acceso al resumen financiero.',
              style: TextStyle(color: scheme.outline),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 200,
              child: TextField(
                controller: _ctrl,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 12),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  counterText: '',
                  border: OutlineInputBorder(),
                  hintText: '••••',
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: _guardando
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check),
              label: const Text('Guardar PIN'),
              onPressed: _guardando ? null : _guardar,
            ),
          ],
        ),
      ),
    );
  }
}

class _PinEntryScreen extends StatelessWidget {
  const _PinEntryScreen({
    required this.entrada,
    required this.error,
    required this.onDigit,
    required this.onDelete,
  });

  final String entrada;
  final bool error;
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.lock_outline,
                  size: 32, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text('Ingresá tu PIN',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Para ver el resumen financiero',
                style: TextStyle(color: scheme.outline)),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) {
                final lleno = i < entrada.length;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: lleno ? scheme.primary : Colors.transparent,
                      border: Border.all(
                        color: error
                            ? scheme.error
                            : (lleno ? scheme.primary : scheme.outline),
                        width: 2,
                      ),
                    ),
                  ),
                );
              }),
            ),
            if (error) ...[
              const SizedBox(height: 12),
              Text('PIN incorrecto',
                  style: TextStyle(color: scheme.error, fontSize: 13)),
            ],
            const SizedBox(height: 32),
            SizedBox(
              width: 240,
              child: GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.4,
                children: [
                  for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
                    _NumKey(label: d, onTap: () => onDigit(d)),
                  const SizedBox.shrink(),
                  _NumKey(label: '0', onTap: () => onDigit('0')),
                  _NumKey(
                    icon: Icons.backspace_outlined,
                    onTap: onDelete,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumKey extends StatelessWidget {
  const _NumKey({this.label, this.icon, required this.onTap});
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Center(
          child: icon != null
              ? Icon(icon, size: 22, color: scheme.onSurface)
              : Text(label!,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

class DashboardAdminScreen extends ConsumerWidget {
  const DashboardAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    // Cada sección es toggleable por el super_admin por tenant (settings
    // 'dashboard.*_visible', grupo super-only en Avanzado, migración 0133).
    final s = ref.watch(appSettingsProvider);
    final esAdminCobranza =
        ref.watch(cobradorActualProvider).valueOrNull?.esAdminCobranza ?? false;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Resumen', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          '${Fmt.diaSemana(now)}, ${Fmt.fechaLarga(now)}',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 24),
        // El rol admin_cobranza NO ve montos recolectados, pero SÍ gestiona
        // mora y recuperación de cartera. Antes se le ocultaban estas tarjetas
        // ENTERAS para cumplir lo primero, y el resultado era que entraba al
        // Resumen y no veía nada — ni la mora, que es su trabajo. Ahora las ve
        // con el recorte ADENTRO: lo facturado y lo que falta, sin lo cobrado
        // ni la curva de cobrado acumulado.
        if (s.dashCobrosVisible) ...[
          TendenciaCobrosCard(ocultarRecaudado: esAdminCobranza),
          const SizedBox(height: 16),
        ],
        if (s.dashRecuperacionVisible) ...[
          TendenciaMoraCard(ocultarRecaudado: esAdminCobranza),
          const SizedBox(height: 16),
          // Va pegada a la de mora del ciclo y bajo el MISMO ajuste: son la
          // misma medida, una responde "cuánta hay" y la otra "vamos mejor o
          // peor". Separarlas en dos ajustes dejaría prender media respuesta.
          MoraHistoricaCard(ocultarRecaudado: esAdminCobranza),
          const SizedBox(height: 16),
        ],
        // Caja pura (lo que ENTRÓ, por fecha de pago): esto sí queda fuera.
        if (s.dashCobrosVisible && !esAdminCobranza) ...[
          const _CobrosKPIs(),
          const SizedBox(height: 16),
          const _ConsultarPeriodoCard(),
          const SizedBox(height: 24),
        ],
        // La proyección es lo ESPERADO a cobrar (cuotas que vencen), no lo
        // recolectado: es exactamente "lo pendiente por recolectar".
        if (s.dashProyeccionVisible) ...[
          const _ProyeccionCobrosCard(),
          const SizedBox(height: 24),
        ],
        if (s.dashTopCobradoresVisible && !esAdminCobranza)
          LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth >= 700) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _TopCobradoresCard(
                          titulo: 'Top cobradores (hoy)',
                          provider: topCobradoresHoyProvider,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _TopCobradoresCard(
                          titulo: 'Top cobradores (período)',
                          provider: topCobradoresProvider,
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TopCobradoresCard(
                      titulo: 'Top cobradores (hoy)',
                      provider: topCobradoresHoyProvider,
                    ),
                    const SizedBox(height: 16),
                    _TopCobradoresCard(
                      titulo: 'Top cobradores (período)',
                      provider: topCobradoresProvider,
                    ),
                  ],
                ),
              );
            },
          ),
        if (s.dashRecuperacionVisible) ...[
          const _RecuperacionCard(),
          const SizedBox(height: 24),
        ],
        if (s.dashSparklineVisible && !esAdminCobranza) ...[
          const _Sparkline7d(),
          const SizedBox(height: 24),
        ],
        if (s.dashOperativoVisible) ...[
          const _OperativoKPIs(),
          const SizedBox(height: 24),
        ],
        if (s.dashDistribucionVisible) ...[
          const _DistribucionCuotasCard(),
        ],
      ],
    );
  }
}

/// Encabezado con título + (i) para las filas de KPIs que no viven en un Card
/// con título propio (Cobros del período, Estado actual).
class _TituloConInfo extends StatelessWidget {
  const _TituloConInfo(this.titulo, this.info, {this.icon});
  final String titulo;
  final InfoGrafica info;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(titulo, style: Theme.of(context).textTheme.titleMedium),
        ),
        InfoGraficaBoton(info),
      ],
    );
  }
}

class _CobrosKPIs extends ConsumerWidget {
  const _CobrosKPIs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(cobrosKpisProvider);
    // El KPI grande acumula el PERÍODO (corte del 15), no el mes calendario.
    //
    // NO tiene por qué dar igual que el "Recuperado" de la gráfica de arriba,
    // aunque compartan ventana: este suma por `pagos.fecha_pago` (plata que
    // entró a caja en el período — invariante #4, caja bruta) y la gráfica
    // suma pagos filtrados por `cuotas.fecha_vencimiento` (cuánto se recuperó
    // de lo facturado en el período). Ejes distintos, los dos correctos.
    final v = ventanaPeriodoActual();
    final desdePeriodo =
        '${v.inicio.day} ${mesCortoPeriodo(v.inicio.month)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TituloConInfo('Cobros del período', kInfoCobrosKpis,
            icon: Icons.payments),
        const SizedBox(height: 8),
        async.when(
          data: (k) => _Kpis(items: [
            _KpiData(
                'Hoy', Fmt.cordobas(k.hoy), '${k.qtyHoy} cobros', Icons.today),
            _KpiData('Esta semana', Fmt.cordobas(k.semana),
                '${k.qtySemana} cobros · desde el domingo',
                Icons.calendar_view_week),
            _KpiData('Este período', Fmt.cordobas(k.periodo),
                '${k.qtyPeriodo} cobros · desde $desdePeriodo',
                Icons.calendar_month,
                primary: true),
          ]),
          loading: () => const SizedBox(
              height: 100, child: Center(child: CircularProgressIndicator())),
          // M13: antes el error desaparecía el KPI en silencio (parecía "en 0").
          error: (_, __) => Text('No se pudo calcular',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.error)),
        ),
        const SizedBox(height: 8),
        const _DesgloseCajaCard(),
      ],
    );
  }
}

/// "¿De qué cuotas era esta plata?" — descompone la caja del período según el
/// vencimiento de la cuota que pagó cada peso.
///
/// Es la tarjeta que responde el reclamo del dueño (2026-08-08): la caja del
/// período y el "Cobrado" de la gráfica NO tienen por qué coincidir, porque la
/// caja incluye atrasos de ciclos anteriores y adelantos, y en cambio deja
/// afuera lo que se cobró por adelantado ANTES de que el ciclo arrancara.
/// Los renglones CON PORCENTAJE suman exactamente el KPI de arriba, a
/// propósito: el dueño tiene que poder auditarlo con la calculadora. La
/// sub-línea de mora vieja va SIN % porque está contenida en "Atrasos", y
/// "Sin cuota asociada" es defensiva (`pagos.cuota_id` es NOT NULL con FK, así
/// que en régimen no se dibuja nunca).
class _DesgloseCajaCard extends ConsumerWidget {
  const _DesgloseCajaCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diasGracia =
        ref.watch(appSettingsProvider.select((s) => s.diasGracia));
    final async = ref.watch(desgloseCajaProvider(diasGracia));
    final scheme = Theme.of(context).colorScheme;

    return async.maybeWhen(
      data: (d) {
        if (d.total <= 0) return const SizedBox.shrink();
        double pct(num v) => d.total == 0 ? 0 : (v / d.total) * 100;

        Widget linea(String label, num monto,
            {bool conPct = true, bool sub = false}) {
          final estilo = TextStyle(
              fontSize: sub ? 11 : 12,
              color: sub ? scheme.outline : scheme.onSurface);
          return Padding(
            padding: EdgeInsets.only(left: sub ? 16 : 0, top: 3, bottom: 3),
            child: Row(
              children: [
                if (sub)
                  Icon(Icons.subdirectory_arrow_right,
                      size: 12, color: scheme.outline),
                if (sub) const SizedBox(width: 4),
                Expanded(
                    child: Text(label,
                        style: estilo, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(Fmt.cordobas(monto), style: estilo),
                ),
                SizedBox(
                  width: 40,
                  child: Text(conPct ? '${pct(monto).round()}%' : '',
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                      textAlign: TextAlign.right),
                ),
              ],
            ),
          );
        }

        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('¿De qué cuotas era esta plata?',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                // NO prometer un CONTEO de renglones: la sub-línea de mora
                // vieja está DENTRO de "Atrasos" y sumarla da +33% (justo el
                // error que originó el reclamo). El discriminador es la columna
                // de %, que la sub-línea deja en blanco a propósito.
                Text('por fecha de pago · los renglones con % suman el total',
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
                const SizedBox(height: 10),
                linea('De este ciclo', d.delCiclo),
                linea('Atrasos de ciclos anteriores', d.atrasos),
                if (d.moraVieja > 0.009)
                  linea('incluido en Atrasos — mora vieja recuperada',
                      d.moraVieja,
                      conPct: false, sub: true),
                linea('Adelantos a cuotas futuras', d.adelantos),
                if (d.sinCuota > 0.009) linea('Sin cuota asociada', d.sinCuota),
                Divider(height: 18, color: scheme.outlineVariant),
                Row(
                  children: [
                    const Expanded(
                        child: Text('Total que entró',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w500))),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(Fmt.cordobas(d.total),
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              ],
            ),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _ConsultarPeriodoCard extends ConsumerStatefulWidget {
  const _ConsultarPeriodoCard();
  @override
  ConsumerState<_ConsultarPeriodoCard> createState() =>
      _ConsultarPeriodoCardState();
}

class _ConsultarPeriodoCardState extends ConsumerState<_ConsultarPeriodoCard> {
  late DateTimeRange _rango;

  @override
  void initState() {
    super.initState();
    // Arranca IGUAL que el preset "Este período" (del 15 a HOY), no al 14 del
    // mes que viene: esos días futuros no tienen cobros y el "Hasta" en 14/08
    // confundía (parecía otro rango que el preset). Sigue siendo libre.
    final v = ventanaPeriodoActual();
    final hoy = Fmt.hoyNicaragua();
    _rango = DateTimeRange(
      start: v.inicio,
      end: hoy.isBefore(v.fin) ? hoy : v.fin.subtract(const Duration(days: 1)),
    );
  }

  Future<void> _elegirRango() async {
    // usarPeriodos: el dashboard lee KPIs y tendencias por el ciclo 15→14, así
    // que sus presets dicen "Este período/Período pasado" (los reportes NO).
    final r =
        await mostrarRangoFechas(context, inicial: _rango, usarPeriodos: true);
    if (r == null) return;
    if (!mounted) return;
    setState(() => _rango = r);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desde = isoDia(_rango.start);
    final hasta = isoDia(_rango.end);
    final async = ref.watch(cobrosRangoCustomProvider((desde, hasta)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.date_range, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${Fmt.fechaCorta(_rango.start)} — ${Fmt.fechaCorta(_rango.end)}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_calendar, size: 20),
                  tooltip: 'Cambiar rango',
                  onPressed: _elegirRango,
                  visualDensity: VisualDensity.compact,
                ),
                const InfoGraficaBoton(kInfoConsultarPeriodo),
              ],
            ),
            const SizedBox(height: 12),
            async.when(
              data: (k) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(Fmt.cordobas(k.total),
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text('${k.qty} cobros',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  // Aclara el EJE: esta tarjeta suma la plata que ENTRÓ (por
                  // fecha de pago). NO es lo mismo que el "Recuperado" de las
                  // gráficas de tendencia (que mide cobertura de lo que vence en
                  // el período) — por eso dan distinto para el mismo rango.
                  Text('Plata que entró por fecha de pago (caja)',
                      style: TextStyle(
                          fontSize: 11, color: scheme.outline, height: 1.3)),
                ],
              ),
              loading: () => const SizedBox(
                  height: 48,
                  child: Center(child: CircularProgressIndicator())),
              error: (_, __) => Text('No se pudo calcular',
                  style: TextStyle(fontSize: 12, color: scheme.error)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sparkline7d extends StatefulWidget {
  const _Sparkline7d();
  @override
  State<_Sparkline7d> createState() => _Sparkline7dState();
}

class _Sparkline7dState extends State<_Sparkline7d> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch('''
      SELECT date(fecha_pago) AS dia,
             COALESCE(SUM(monto_cordobas), 0) AS total
        FROM pagos
       WHERE COALESCE(anulado, 0) = 0 AND COALESCE(en_revision, 0) = 0
         AND date(fecha_pago) >= date('now', '-6 hours', '-6 days')
       GROUP BY date(fecha_pago)
       ORDER BY dia
    ''');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Cobros últimos 7 días',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
                const InfoGraficaBoton(kInfoSparkline7d),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _stream,
                initialData: const [],
                builder: (context, snap) {
                  if (snap.hasError || snap.data!.isEmpty) {
                    return Center(
                      child: Text('Sin datos',
                          style: TextStyle(color: scheme.outline, fontSize: 12)),
                    );
                  }
                  // Llenar los 7 días con 0 donde no hay cobros.
                  final map = <String, double>{};
                  for (final r in snap.data!) {
                    map[r['dia'] as String] = (r['total'] as num).toDouble();
                  }
                  final values = <double>[];
                  // Base Nicaragua (UTC-6, sin DST): las 7 claves se alinean con
                  // la ventana SQL (date('now','-6 hours')) y no se corren en un
                  // dispositivo fuera de UTC-6 (regla #1b; espeja _dashboardDates).
                  final baseNic =
                      DateTime.now().toUtc().subtract(const Duration(hours: 6));
                  for (var i = 6; i >= 0; i--) {
                    final d = baseNic.subtract(Duration(days: i));
                    final key = d.toIso8601String().substring(0, 10);
                    values.add(map[key] ?? 0);
                  }
                  return CustomPaint(
                    size: const Size(double.infinity, 48),
                    painter: _SparklinePainter(
                      values: values,
                      color: scheme.primary,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    if (maxV == 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.3), color.withValues(alpha: 0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path();
    final fillPath = Path();
    final stepX = size.width / (values.length - 1);

    for (var i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = size.height - (values[i] / maxV * size.height * 0.85);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    // Dots en cada punto.
    final dotPaint = Paint()..color = color;
    for (var i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = size.height - (values[i] / maxV * size.height * 0.85);
      canvas.drawCircle(Offset(x, y), 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color;
}

class _OperativoKPIs extends ConsumerWidget {
  const _OperativoKPIs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(operativoKpisProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TituloConInfo('Estado actual', kInfoOperativo,
            icon: Icons.donut_large),
        const SizedBox(height: 8),
        async.when(
          data: (k) => _Kpis(items: [
            _KpiData('Clientes activos', '${k.clientes}', null, Icons.people),
            _KpiData('Cuotas por cobrar', '${k.cuotasPend}',
                Fmt.cordobas(k.saldo), Icons.pending),
            _KpiData(
              'En mora',
              '${k.vencidas}',
              Fmt.cordobas(k.saldoVencido),
              Icons.warning,
              error: true,
            ),
            // Deuda de contratos suspendidos: fuera del titular "por cobrar" (no
            // está en rutas) pero visible porque sigue contando en contabilidad.
            if (k.cuotasSuspendidas > 0)
              _KpiData(
                'Suspendido (por reactivar)',
                '${k.cuotasSuspendidas}',
                Fmt.cordobas(k.saldoSuspendido),
                Icons.pause_circle_outline,
              ),
          ]),
          loading: () => const SizedBox.shrink(),
          // M13: antes el error desaparecía el KPI en silencio (parecía "en 0").
          error: (_, __) => Text('No se pudo calcular',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.error)),
        ),
      ],
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.items});
  final List<_KpiData> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 900 ? 3 : c.maxWidth >= 500 ? 2 : 1;
      return GridView.count(
        crossAxisCount: cols,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        // Mobile (1 col): ratio 2.3 — el contenido del card (icon+label
        // row + headlineMedium value + sub-label + 3 spacings + padding
        // 20×2) necesita ~132px de alto. Con viewport 375px y padding
        // del padre (~32px), el ancho del card es ~343px → ratio 2.3
        // da ~149px de alto, holgado. Probado: 4.0 → "BOTTOM OVERFLOWED
        // BY 18 PIXELS", 3.0 → "BY 23 PIXELS", 2.3 → entra OK.
        // 2 / 3 columnas (tablet/desktop) mantienen 2.2 — el ancho del
        // card es menor pero el contenido entra holgado.
        childAspectRatio: cols == 1 ? 2.3 : 2.2,
        children: items.map((k) => _KpiCard(data: k)).toList(),
      );
    });
  }
}

class _KpiData {
  const _KpiData(this.label, this.value, this.sub, this.icon,
      {this.primary = false, this.error = false});
  final String label;
  final String value;
  final String? sub;
  final IconData icon;
  final bool primary;
  final bool error;
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.data});
  final _KpiData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = data.error
        ? scheme.error
        : (data.primary ? scheme.primary : scheme.outline);
    return Card(
      color:
          data.primary ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(data.icon, size: 20, color: color),
                const SizedBox(width: 8),
                Text(data.label,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 12),
            Text(data.value,
                style: Theme.of(context).textTheme.headlineMedium),
            if (data.sub != null) ...[
              const SizedBox(height: 4),
              Text(data.sub!,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

class _TopCobradoresCard extends ConsumerWidget {
  const _TopCobradoresCard({
    required this.titulo,
    required this.provider,
  });
  final String titulo;
  final StreamProvider<List<TopCobrador>> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(titulo,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const InfoGraficaBoton(kInfoTopCobradores),
              ],
            ),
            const SizedBox(height: 16),
            async.when(
              data: (rows) {
                if (rows.isEmpty) {
                  return Text('Sin cobradores activos',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline));
                }
                final maxTotal = rows
                    .map((r) => r.total.toDouble())
                    .reduce((a, b) => a > b ? a : b);
                return Column(
                  children: rows.map((r) {
                    final total = r.total.toDouble();
                    final pct = maxTotal > 0 ? total / maxTotal : 0.0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(r.nombre)),
                              Text(Fmt.cordobas(total),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: pct,
                              minHeight: 6,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
              loading: () => const SizedBox.shrink(),
              // M13: antes el error dejaba el card vacío en silencio.
              error: (_, __) => Text('No se pudo calcular',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DistribucionCuotasCard extends ConsumerWidget {
  const _DistribucionCuotasCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(distribucionCuotasProvider);
    final pagoParcialOn = ref.watch(pagoParcialHabilitadoProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Distribución de cuotas',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const InfoGraficaBoton(kInfoDistribucion),
              ],
            ),
            const SizedBox(height: 16),
            async.when(
              data: (k) {
                final scheme = Theme.of(context).colorScheme;
                // Eje vigencia: distribución disjunta que suma al total.
                // 'Con pago parcial' es un overlay transversal (cruza los de
                // arriba); se muestra solo si la feature está ON o ya hay
                // parciales (si no, siempre sería 0 → solo haría ruido).
                final mostrarParcial = pagoParcialOn || k.parcial > 0;
                return Column(
                  children: [
                    _row('Al día', '${k.alDia}', scheme.primary, Icons.event),
                    _row('En gracia', '${k.enGracia}', Colors.amber.shade700,
                        Icons.schedule),
                    _row('Vencidas', '${k.vencida}', scheme.error,
                        Icons.warning),
                    _row('Pagadas', '${k.pagada}', scheme.outline, Icons.check),
                    if (mostrarParcial) ...[
                      const Divider(height: 20),
                      _row('Con pago parcial', '${k.parcial}',
                          Colors.teal.shade700, Icons.hourglass_bottom),
                      Padding(
                        padding: const EdgeInsets.only(left: 26, bottom: 4),
                        child: Text('incluidas en los buckets de arriba',
                            style: TextStyle(
                                fontSize: 11, color: scheme.outline)),
                      ),
                    ],
                  ],
                );
              },
              loading: () => const SizedBox.shrink(),
              // M13: antes el error dejaba el card vacío en silencio.
              error: (_, __) => Text('No se pudo calcular',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, Color color, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(value,
              style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

/// Proyección de cobros por cobrador (sección nueva). Por defecto muestra lo que
/// cada cobrador asignado debería cobrar HOY; el toggle suma las cuotas que
/// vencen dentro de los próximos `dias_cuotas_visibles` días.
class _ProyeccionCobrosCard extends ConsumerStatefulWidget {
  const _ProyeccionCobrosCard();
  @override
  ConsumerState<_ProyeccionCobrosCard> createState() =>
      _ProyeccionCobrosCardState();
}

class _ProyeccionCobrosCardState extends ConsumerState<_ProyeccionCobrosCard> {
  bool _incluirProximas = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(proyeccionCobrosProvider);
    final diasProx =
        ref.watch(appSettingsProvider.select((s) => s.diasCuotasVisibles));
    num montoDe(ProyeccionCobrador p) =>
        _incluirProximas ? p.montoHoy + p.montoProximas : p.montoHoy;
    int cuotasDe(ProyeccionCobrador p) =>
        _incluirProximas ? p.cuotasHoy + p.cuotasProximas : p.cuotasHoy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event_available, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Proyección de cobros por cobrador',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const InfoGraficaBoton(kInfoProyeccion),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _incluirProximas
                  ? 'Esperado a cobrar: vence hoy + próximos $diasProx días'
                  : 'Esperado a cobrar: cuotas que vencen hoy',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            Row(
              children: [
                Switch(
                  value: _incluirProximas,
                  onChanged: (v) => setState(() => _incluirProximas = v),
                ),
                Expanded(
                  child: Text('Incluir cuotas próximas ($diasProx días)',
                      style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            async.when(
              data: (rows) {
                final visibles = rows.where((p) => cuotasDe(p) > 0).toList()
                  ..sort((a, b) => montoDe(b).compareTo(montoDe(a)));
                if (visibles.isEmpty) {
                  return Text(
                    _incluirProximas
                        ? 'Nada por cobrar en el rango'
                        : 'Nada vence hoy',
                    style: TextStyle(color: scheme.outline),
                  );
                }
                final maxMonto = visibles
                    .map((p) => montoDe(p).toDouble())
                    .reduce((a, b) => a > b ? a : b);
                final total = visibles.fold<num>(0, (a, p) => a + montoDe(p));
                return Column(
                  children: [
                    ...visibles.map((p) {
                      final m = montoDe(p).toDouble();
                      final pct = maxMonto > 0 ? m / maxMonto : 0.0;
                      final esSin = p.cobradorId == null;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    esSin ? 'Sin cobrador asignado' : p.nombre,
                                    style: TextStyle(
                                        color: esSin ? scheme.outline : null),
                                  ),
                                ),
                                Text('${cuotasDe(p)} cuotas',
                                    style: TextStyle(
                                        fontSize: 12, color: scheme.outline)),
                                const SizedBox(width: 8),
                                Text(Fmt.cordobas(montoDe(p)),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: pct,
                                minHeight: 6,
                                backgroundColor: scheme.surfaceContainerHighest,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const Divider(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Total esperado',
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                        ),
                        Text(Fmt.cordobas(total),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => Text('No se pudo calcular',
                  style: TextStyle(fontSize: 12, color: scheme.error)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Recuperación por cobrador y comunidad: mora a recuperar (vencido pasada la
/// gracia), agrupada por cobrador asignado y comunidad. Colapsable para no
/// empujar las secciones de abajo fuera de vista.
class _RecuperacionCard extends ConsumerStatefulWidget {
  const _RecuperacionCard();
  @override
  ConsumerState<_RecuperacionCard> createState() => _RecuperacionCardState();
}

class _RecuperacionCardState extends ConsumerState<_RecuperacionCard> {
  bool _expandido = false;
  // Default = mora ACUMULADA (todo lo vencido, sin límite de fecha).
  //
  // OJO — no invertir este default: "vencidas del período" cruza dos
  // condiciones que casi no se solapan (vencer DENTRO del período en curso Y
  // haber pasado ya los días de gracia). Como el período arranca el 15, sus
  // cuotas todavía no tuvieron tiempo de entrar en mora: durante los primeros
  // ~15+gracia días da CERO, y después una fracción mínima. Medido contra
  // producción el 2026-07-26: C$89.315 de C$10.302.698 reales (0,87%).
  // La vista por período sirve para "cuánta mora generó este ciclo", no para
  // salir a cobrar — por eso es la secundaria.
  bool _soloPeriodo = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(recuperacionPorComunidadProvider(_soloPeriodo));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expandido = !_expandido),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(Icons.location_on, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Recuperación por cobrador y comunidad',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                            _soloPeriodo
                                ? 'Vencidas del período ${periodoLabelActual()} '
                                    '(las de ciclos anteriores no se cuentan)'
                                : 'Toda la mora acumulada (vencido pasada la gracia)',
                            style:
                                TextStyle(fontSize: 12, color: scheme.outline)),
                      ],
                    ),
                  ),
                  const InfoGraficaBoton(kInfoRecuperacion),
                  const SizedBox(width: 8),
                  async.when(
                    data: (rows) {
                      if (rows.isEmpty) return const SizedBox.shrink();
                      final total =
                          rows.fold<num>(0, (a, f) => a + f.porRecuperar);
                      return Text(Fmt.cordobas(total),
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: scheme.error));
                    },
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _expandido ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child:
                        Icon(Icons.expand_more, size: 24, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Toda la mora'),
                  selected: !_soloPeriodo,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) {
                    if (v) setState(() => _soloPeriodo = false);
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Vencidas del período'),
                  selected: _soloPeriodo,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) {
                    if (v) setState(() => _soloPeriodo = true);
                  },
                ),
              ],
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: async.when(
              data: (rows) {
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Text(
                        _soloPeriodo
                            ? 'Sin mora en este período'
                            : 'Sin mora para recuperar',
                        style: TextStyle(color: scheme.outline)),
                  );
                }
                final byCobrador = <String, List<RecuperacionFila>>{};
                final nombres = <String, String>{};
                final totales = <String, num>{};
                final cuotasTot = <String, int>{};
                for (final f in rows) {
                  final k = f.cobradorId ?? '__sin__';
                  byCobrador.putIfAbsent(k, () => []).add(f);
                  nombres[k] =
                      f.cobradorId == null ? 'Sin cobrador' : f.cobrador;
                  totales[k] = (totales[k] ?? 0) + f.porRecuperar;
                  cuotasTot[k] = (cuotasTot[k] ?? 0) + f.cuotas;
                }
                final orden = byCobrador.keys.toList()
                  ..sort((a, b) => totales[b]!.compareTo(totales[a]!));
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Column(
                    children: [
                      for (var gi = 0; gi < orden.length; gi++) ...[
                        if (gi > 0) const Divider(height: 20),
                        Builder(builder: (_) {
                          final k = orden[gi];
                          final filas = byCobrador[k]!
                            ..sort((a, b) =>
                                b.porRecuperar.compareTo(a.porRecuperar));
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(nombres[k]!,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600)),
                                  ),
                                  Text(
                                      '${Fmt.cordobas(totales[k]!)} · ${cuotasTot[k]} cuotas',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: scheme.error)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              ...filas.map((f) => _ComunidadRow(
                                    fila: f,
                                    soloPeriodo: _soloPeriodo,
                                  )),
                            ],
                          );
                        }),
                      ],
                    ],
                  ),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Text('No se pudo calcular',
                    style: TextStyle(fontSize: 12, color: scheme.error)),
              ),
            ),
            crossFadeState: _expandido
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}

/// Una fila de comunidad dentro de la card de recuperación. Toca para desplegar
/// el desglose por monto (cuántas cuotas de cada saldo), cuya suma cierra contra
/// el total de la fila. Colapsada por default: no se pide el desglose hasta que
/// alguien la abre (el provider es autoDispose → se descarta al colapsar).
class _ComunidadRow extends ConsumerStatefulWidget {
  const _ComunidadRow({required this.fila, required this.soloPeriodo});
  final RecuperacionFila fila;
  final bool soloPeriodo;

  @override
  ConsumerState<_ComunidadRow> createState() => _ComunidadRowState();
}

class _ComunidadRowState extends ConsumerState<_ComunidadRow> {
  bool _abierto = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = widget.fila;
    final nombre = f.comunidadId == null ? 'Sin comunidad' : f.comunidad;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _abierto = !_abierto),
          child: Padding(
            padding: const EdgeInsets.only(left: 6, top: 3, bottom: 3),
            child: Row(
              children: [
                Icon(_abierto ? Icons.expand_more : Icons.chevron_right,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(nombre,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
                Text('${Fmt.cordobas(f.porRecuperar)} · ${f.cuotas}',
                    style:
                        TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        if (_abierto) _Desglose(fila: f, soloPeriodo: widget.soloPeriodo),
      ],
    );
  }
}

/// El desglose por monto de una comunidad + la línea de verificación (suma y
/// conteo del desglose contra el total de la fila).
class _Desglose extends ConsumerWidget {
  const _Desglose({required this.fila, required this.soloPeriodo});
  final RecuperacionFila fila;
  final bool soloPeriodo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(recuperacionDesgloseProvider(RecuperacionDetalleKey(
      cobradorId: fila.cobradorId,
      comunidadId: fila.comunidadId,
      soloPeriodo: soloPeriodo,
    )));
    return Container(
      margin: const EdgeInsets.only(left: 22, top: 2, bottom: 6),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        border: Border(
            left: BorderSide(color: scheme.outlineVariant, width: 2)),
      ),
      child: async.when(
        loading: () => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('Cargando…',
              style: TextStyle(fontSize: 12, color: scheme.outline)),
        ),
        error: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('No se pudo desglosar',
              style: TextStyle(fontSize: 12, color: scheme.error)),
        ),
        data: (lineas) {
          final sumaMonto =
              lineas.fold<num>(0, (a, l) => a + l.subtotal);
          final sumaCuotas = lineas.fold<int>(0, (a, l) => a + l.cuotas);
          // Cuadra si la suma del desglose == el total de la fila (tolerancia
          // 1 centavo, igual que los invariantes). Si NO, se avisa en rojo: es
          // una señal de bug, no algo para esconder.
          final cuadra = (sumaMonto - fila.porRecuperar).abs() < 0.01 &&
              sumaCuotas == fila.cuotas;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final l in lineas)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                            '${Fmt.cordobas(l.monto)} × ${l.cuotas} '
                            '${l.cuotas == 1 ? 'cuota' : 'cuotas'}',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                      Text(Fmt.cordobas(l.subtotal),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  children: [
                    Icon(cuadra ? Icons.check_circle_outline : Icons.error_outline,
                        size: 14,
                        color: cuadra
                            ? scheme.primary
                            : scheme.error),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        cuadra
                            ? 'Coincide: $sumaCuotas cuotas · ${Fmt.cordobas(sumaMonto)}'
                            : 'No cuadra: desglose $sumaCuotas/${Fmt.cordobas(sumaMonto)} '
                                'vs fila ${fila.cuotas}/${Fmt.cordobas(fila.porRecuperar)}',
                        style: TextStyle(
                            fontSize: 11,
                            color: cuadra ? scheme.primary : scheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

