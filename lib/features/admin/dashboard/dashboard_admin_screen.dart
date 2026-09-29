import 'dart:async';
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
import 'estado_actual_card.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';
import 'recaudo_mora_card.dart';
import 'mora_zona_card.dart';
import 'caja_ciclo_card.dart';
import 'dashboard_tarjetas.dart';
import 'distribucion_cuotas_card.dart';
import 'mora_ciclos_card.dart';
import 'proyeccion_cobros_card.dart';
import 'quien_cobro_card.dart';
import 'tendencia_cobros_card.dart';
import 'resumen_watch.dart';

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

/// Borde de las tarjetas del RESUMEN, más marcado que el del tema.
///
/// El tema global pinta las Card blancas (`#FFFFFF`) con un filete de 0,5px en
/// `#E5E5EA`, sobre un fondo de página `#FAFAFC`. En una pantalla de lista eso
/// alcanza, porque las filas se separan por su contenido. Acá no: el Resumen es
/// una PILA de siete tarjetas grandes, y con 0,4% de diferencia entre la tarjeta
/// y el fondo más un filete que a escala normal casi no se ve, las siete se
/// leen como una sola masa continua. Reporte del dueño (2026-09-01): *"me
/// gustaría una separación clara entre cada gráfico"*.
///
/// 1px de `#D1D1D6` (el gris 4 de la paleta iOS que la app ya imita) dibuja
/// cada tarjeta sin cambiarle el color a nada. Se descartó oscurecer el FONDO
/// del Resumen a `#F2F2F7` —más efectivo, pero dejaba esta pantalla de otro
/// color que el resto de la app— y se descartó tocar el `cardTheme` global,
/// que le cambiaría el borde a toda Card de la app (clientes, contratos,
/// tickets). Por eso el override va en un `Theme` que envuelve SOLO esta
/// pantalla.
const _bordeTarjetaResumen = Color(0xFFD1D1D6);

/// Aire entre tarjetas. Era 16 y subía a 28 en el mismo pedido: el borde
/// separa cada objeto, el aire dice cuánto respiran entre sí. Uno sin el otro
/// deja la pila igual de apretada o igual de indistinta.
const _aireEntreTarjetas = 28.0;

class DashboardAdminScreen extends ConsumerStatefulWidget {
  const DashboardAdminScreen({super.key});

  @override
  ConsumerState<DashboardAdminScreen> createState() =>
      _DashboardAdminScreenState();
}

class _DashboardAdminScreenState extends ConsumerState<DashboardAdminScreen> {
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    // 1) Refrescar de inmediato al abrir el dashboard resumen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refrescar();
    });
    // 2) Auto-refresco cada 10 minutos mientras la pantalla permanezca abierta
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (!mounted) return;
      _refrescar();
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  void _refrescar() {
    ref.read(dashboardRefreshEpochProvider.notifier).state++;
    ref.read(dashboardUltimaActualizacionProvider.notifier).state =
        DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // Cada sección es toggleable por el super_admin por tenant (settings
    // 'dashboard.*_visible', grupo super-only en Avanzado, migración 0133).
    final s = ref.watch(appSettingsProvider);
    final esAdminCobranza =
        ref.watch(cobradorActualProvider).valueOrNull?.esAdminCobranza ?? false;

    // El override vive ACÁ y no en `theme.dart` a propósito: las Card de los
    // diálogos y las hojas que se abren DESDE el Resumen (el (i) de cada
    // gráfica, los selectores) viven en el overlay, o sea en otro subtree, y
    // siguen con el borde del tema. Cambia la pila del Resumen, nada más.
    final tema = Theme.of(context);
    return Theme(
      data: tema.copyWith(
        cardTheme: tema.cardTheme.copyWith(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: _bordeTarjetaResumen, width: 1),
          ),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Resumen',
                          style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: 4),
                      Text(
                        '${Fmt.diaSemana(now)}, ${Fmt.fechaLarga(now)}',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline),
                      ),
                    ],
                  ),
                ),
                _BotonActualizarResumen(onActualizar: _refrescar),
              ],
            ),
            const SizedBox(height: 24),
            // El rol admin_cobranza NO ve montos recolectados, pero SÍ gestiona
            // mora y recuperación de cartera. Antes se le ocultaban estas tarjetas
            // ENTERAS para cumplir lo primero, y el resultado era que entraba al
            // Resumen y no veía nada — ni la mora, que es su trabajo. Ahora las ve
            // con el recorte ADENTRO: lo facturado y lo que falta, sin lo cobrado
            // ni la curva de cobrado acumulado.
            // La tarjeta de 4 líneas (recaudo vs meta, mora vs límite) es 100%
            // montos: el rol que no ve montos recolectados no la monta.
            // ── EL ORDEN Y EL ENCENDIDO LOS DECIDE EL AJUSTE, NO ESTE ARCHIVO ──
            //
            // Hasta el 2026-08-29 la lista estaba escrita aca y cada tarjeta tenia
            // su propio `dashboard.*_visible`. Ahora vive en `dashboard.tarjetas`
            // (migracion 0263), que guarda ORDEN y encendido juntos y se edita en
            // Ajustes > Avanzado > Tarjetas del Resumen, por empresa.
            //
            // Este archivo aporta el MAPA id -> widget. Si un id del ajuste no esta
            // en el mapa se ignora; si una tarjeta del mapa no esta en el ajuste,
            // `leerOrdenTarjetas` la agrega al final encendida. Asi una tarjeta
            // nueva nunca nace invisible en un tenant con ajuste viejo.
            //
            // El GATE DE ROL manda sobre el ajuste: `admin_cobranza` no ve montos
            // cobrados, asi que encender "Caja del ciclo" para su empresa igual no
            // se la muestra a el.
            ..._tarjetasOrdenadas(s, esAdminCobranza),
          ],
        ),
      ),
    );
  }

  /// Arma las tarjetas en el orden del ajuste, con su separacion.
  List<Widget> _tarjetasOrdenadas(AppSettings s, bool esAdminCobranza) {
    // El mapa id -> widget. Una tarjeta que no este aca simplemente no se
    // dibuja aunque el ajuste la nombre.
    Widget? construir(String id) {
      switch (id) {
        case 'caja':
          return esAdminCobranza ? null : const CajaCicloCard();
        case 'cobertura':
          return TendenciaCobrosCard(ocultarRecaudado: esAdminCobranza);
        case 'mora_ciclo':
          return MoraCiclosCard(ocultarRecaudado: esAdminCobranza);
        case 'proyeccion':
          return const ProyeccionCobrosCard();
        case 'mora_zona':
          return const MoraZonaCard();
        case 'quien_cobro':
          return esAdminCobranza ? null : const QuienCobroCard();
        // ── Las que quedaron fuera del Resumen de 2026-08-27 ──
        // Se conservan enteras: apagadas por defecto, pero prendibles desde el
        // ajuste sin tocar codigo.
        case 'recaudo_mora':
          return esAdminCobranza ? null : const RecaudoMoraCard();
        case 'consultar_periodo':
          return esAdminCobranza ? null : const _ConsultarPeriodoCard();
        case 'sparkline':
          return esAdminCobranza ? null : const _Sparkline7d();
        case 'operativo':
          return const EstadoActualCard();
        case 'distribucion':
          return const DistribucionCuotasCard();
      }
      return null;
    }

    final out = <Widget>[];
    for (final f in leerOrdenTarjetas(s.dashTarjetasOrden)) {
      if (!f.encendida) continue;
      final w = construir(f.id);
      if (w == null) continue;
      // Separacion UNIFORME. Habia 16 y 24 mezclados, y un 16+16 seguido que
      // abria un hueco de 32 sin motivo; despues quedo en 16 para todas y el
      // 2026-09-01 subio a 28 (ver `_aireEntreTarjetas`).
      if (out.isNotEmpty) {
        out.add(const SizedBox(height: _aireEntreTarjetas));
      }
      out.add(w);
    }
    return out;
  }
}

// `_TituloConInfo` se fue con `_OperativoKPIs` (2026-09-01): era el encabezado
// de las filas de KPIs que NO vivían en un Card con título propio, y ya no
// queda ninguna — todas las tarjetas del Resumen son Cards autocontenidas.

// `_CobrosKPIs` y `_DesgloseCajaCard` se mudaron a `caja_ciclo_card.dart`
// (2026-08-28): la tarjeta pasa a tener retroceso propio por bloque y, como
// el resto del Resumen, vive en su propio archivo sin compartir nada.

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
    _stream = watchResumen('''
      SELECT fecha_cobro AS dia,
             COALESCE(SUM(monto_cordobas), 0) AS total
        FROM pagos
       WHERE COALESCE(anulado, 0) = 0 AND COALESCE(en_revision, 0) = 0
         AND fecha_cobro >= date('now', '-6 hours', '-6 days')
       GROUP BY fecha_cobro
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

class _BotonActualizarResumen extends ConsumerWidget {
  const _BotonActualizarResumen({required this.onActualizar});
  final VoidCallback onActualizar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ultima = ref.watch(dashboardUltimaActualizacionProvider);
    final horaStr = Fmt.hora(ultima);
    return Tooltip(
      message: 'Actualizar datos del Resumen (última: $horaStr)',
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        onPressed: onActualizar,
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(
          'Actualizar · $horaStr',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}


// `_OperativoKPIs` (+ `_Kpis`, `_KpiData`, `_KpiCard`) se mudaron a
// `estado_actual_card.dart`, y `_DistribucionCuotasCard` a
// `distribucion_cuotas_card.dart` (2026-09-02).
//
// Las dos habian quedado FUSIONADAS el 2026-09-01 con el argumento de que
// contaban la misma particion —"Cuotas por cobrar" es exactamente al dia + en
// gracia + vencidas, y "En mora" salia repetido en las dos—. El argumento
// sigue siendo cierto; el dueño lo escucho con sus propios numeros y pidio las
// dos igual, separadas y en el estilo de produccion (ver ARQUITECTURA,
// §Dashboard admin, "Las cuatro tarjetas que volvieron"). Cada una en su
// archivo, como el resto: la pantalla solo las instancia.

/// Proyección de cobros por cobrador (sección nueva). Por defecto muestra lo que
/// cada cobrador asignado debería cobrar HOY; el toggle suma las cuotas que
/// vencen dentro de los próximos `dias_cuotas_visibles` días.
// Aca vivian `_ComunidadRow` y `_Desglose`, el detalle de la tarjeta vieja de
// Recuperacion. Se fueron con ella el 2026-08-28: la reemplazo
// `DeudaZonaCard`, que trae su propio desglose por comunidad.
