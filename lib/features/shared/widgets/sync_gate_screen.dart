import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/providers/sync_status_provider.dart';
import '../../../powersync/db.dart' as ps;
import '../utils/sign_out_helper.dart';

/// Pantalla intermedia mostrada por el router mientras PowerSync confirma
/// un sync tras cambio de identidad (login después de signOut, o switch
/// de user en el mismo browser).
///
/// Cuando `syncReadyProvider` flippa a `true`, el redirect del router
/// vuelve a evaluarse y manda al user a su pantalla por rol.
///
/// **Feedback de progreso**: si PowerSync expone `downloadProgress`
/// (operaciones descargadas / total), mostramos un `LinearProgressIndicator`
/// con el avance real y el conteo de registros. Sin progress (handshake
/// inicial, errores), caemos al `CircularProgressIndicator` clásico.
///
/// **Detección de estados anómalos**:
///   - `status.connected == false`: mostramos "Esperando conexión…" en
///     lugar del mensaje de sync activo, así el user sabe que el
///     bloqueo es de red, no del servidor.
///   - `status.anyError != null`: mostramos el mensaje + botón
///     reintentar inmediato (sin esperar el timer de 120s) porque el
///     spinner girando sin causa visible es peor UX que un error claro.
///
/// **Manejo de gates largos**: el sync inicial de un user con muchos
/// buckets (típicamente super_admin que ve todos los tenants) puede
/// tardar minutos legítimamente. Timeouts realistas:
///   - 30s: mensaje secundario explicando que el primer sync es lento.
///   - 120s (2 min): botón "Reintentar conexión" (disconnect + connect,
///     útil si el problema fue conectividad — el sync resume desde
///     donde iba, no se pierde el progreso parcial).
///   - 180s (3 min): botón "Volver al login" como escape final
///     (signOut + confirmación porque re-loguearse reinicia el sync
///     desde cero, costo real que el user debe conocer).
///
/// Post-reintento manual, los timers usan ventanas más cortas (15s/60s/120s)
/// porque el user ya esperó 2 min — no tiene sentido hacerlo esperar
/// otros 2 min para volver a ver el botón.
class SyncGateScreen extends ConsumerStatefulWidget {
  const SyncGateScreen({super.key});

  @override
  ConsumerState<SyncGateScreen> createState() => _SyncGateScreenState();
}

class _SyncGateScreenState extends ConsumerState<SyncGateScreen> {
  Timer? _slowHintTimer;
  Timer? _retryButtonTimer;
  Timer? _escapeHatchTimer;
  bool _showSlowHint = false;
  bool _showRetryButton = false;
  bool _showEscapeHatch = false;
  bool _reconnecting = false;
  // Si el último reintento manual falló (excepción durante disconnect/
  // connect/timeout), guardamos un flag para mostrar feedback debajo
  // del botón. Sin esto, el catch silencioso del _reintentar dejaba al
  // user sin saber que el problema persistía.
  bool _lastRetryFailed = false;
  // El primer set de timers usa ventanas largas (30/120/180s). Después
  // de un reintento manual, las usamos cortas (15/60/120s).
  bool _hasRetriedOnce = false;

  @override
  void initState() {
    super.initState();
    _scheduleTimers();
  }

  void _scheduleTimers() {
    final slowHintAfter = _hasRetriedOnce ? 15 : 30;
    final retryAfter = _hasRetriedOnce ? 60 : 120;
    final escapeAfter = _hasRetriedOnce ? 120 : 180;
    _slowHintTimer = Timer(Duration(seconds: slowHintAfter), () {
      if (mounted) setState(() => _showSlowHint = true);
    });
    _retryButtonTimer = Timer(Duration(seconds: retryAfter), () {
      if (mounted) setState(() => _showRetryButton = true);
    });
    _escapeHatchTimer = Timer(Duration(seconds: escapeAfter), () {
      if (mounted) setState(() => _showEscapeHatch = true);
    });
  }

  void _cancelTimers() {
    _slowHintTimer?.cancel();
    _retryButtonTimer?.cancel();
    _escapeHatchTimer?.cancel();
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  Future<void> _reintentar() async {
    // Guard contra setState post-dispose: el callback del onPressed
    // puede colarse en el mismo frame que el screen se desmonta cuando
    // sync completa.
    if (!mounted || _reconnecting) return;
    setState(() {
      _reconnecting = true;
      _lastRetryFailed = false;
    });
    var failed = false;
    try {
      await ps.disconnectPowerSync();
      // Timeout defensivo: si el connect cuelga (network blip durante
      // handshake), no dejamos al user con `_reconnecting=true`
      // permanente y el botón disabled para siempre.
      await ps.connectPowerSync().timeout(const Duration(seconds: 30));
    } catch (_) {
      // El escape final ("Volver al login") sigue disponible y
      // PowerSync reintenta solo en background. Capturamos el fail
      // para mostrar feedback al user.
      failed = true;
    }
    if (!mounted) return;
    _cancelTimers();
    setState(() {
      _reconnecting = false;
      _lastRetryFailed = failed;
      _hasRetriedOnce = true;
      _showSlowHint = false;
      _showRetryButton = false;
      _showEscapeHatch = false;
    });
    _scheduleTimers();
  }

  Future<void> _volverAlLogin() async {
    final confirmar = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Volver al login'),
        content: const Text(
          'Vas a cerrar sesión. Al volver a entrar, el sync se va a '
          'reiniciar desde cero y el progreso descargado hasta ahora '
          'se va a tener que volver a descargar.\n\n'
          '¿Querés continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (confirmar != true) return;
    try {
      // Limpiar impersonación activa (#9) ANTES del signOut: requiere el JWT
      // vivo para autorizar el DELETE server-side. Si el super_admin estaba
      // impersonando un tenant y el sync gate se colgó, esto evita que la fila
      // quede "pegajosa" y re-loguee impersonando el tenant viejo.
      await limpiarImpersonacionSiActiva();
      await Supabase.instance.client.auth.signOut();
      // El listener de main.dart dispara onSignOut → el redirect del
      // router lleva a /login. No hace falta navegación manual.
    } catch (_) {
      // Si signOut falla por red, no podemos llevarlo al login.
      // Mostramos SnackBar para que el user sepa y pueda reintentar.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No pudimos cerrar la sesión. '
              'Revisá tu conexión y probá de nuevo.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = ref.watch(syncStatusProvider).valueOrNull;
    final progress = status?.downloadProgress;
    final connected = status?.connected ?? true;
    final hasError = status?.anyError != null;

    // Mensaje principal varía según el estado más prominente.
    final tituloPrincipal = hasError
        ? 'No se pudo sincronizar'
        : !connected
            ? 'Esperando conexión…'
            : 'Sincronizando datos…';

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Indicador: barra con progreso real si está disponible y
              // hay conexión activa, sino spinner clásico.
              if (progress != null &&
                  progress.totalOperations > 0 &&
                  connected &&
                  !hasError)
                _ProgressBar(
                  downloaded: progress.downloadedOperations,
                  total: progress.totalOperations,
                  fraction: progress.downloadedFraction,
                )
              else if (hasError)
                Icon(Icons.cloud_off,
                    size: 48, color: scheme.error)
              else
                const SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                child: Text(
                  tituloPrincipal,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasError) ...[
                      const SizedBox(height: 12),
                      Text(
                        _humanizeError(status!.anyError!),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.tonalIcon(
                        icon: _reconnecting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(_reconnecting
                            ? 'Reconectando…'
                            : 'Reintentar'),
                        onPressed: _reconnecting ? null : _reintentar,
                      ),
                    ] else if (_showSlowHint) ...[
                      const SizedBox(height: 12),
                      Text(
                        connected
                            ? 'El primer sync de una cuenta con varios '
                                'tenants o mucha data puede tardar varios '
                                'minutos. Estamos descargando todo — no '
                                'hace falta reintentar.'
                            : 'Estás sin internet. Vamos a retomar la '
                                'descarga apenas vuelva la conexión.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                    ],
                    if (!hasError && _showRetryButton) ...[
                      const SizedBox(height: 24),
                      FilledButton.tonalIcon(
                        icon: _reconnecting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(_reconnecting
                            ? 'Reconectando…'
                            : 'Reintentar conexión'),
                        onPressed: _reconnecting ? null : _reintentar,
                      ),
                      if (_lastRetryFailed && !_reconnecting) ...[
                        const SizedBox(height: 8),
                        Text(
                          'No se pudo reconectar. Revisá tu internet.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12, color: scheme.error),
                        ),
                      ],
                    ],
                    if (_showEscapeHatch) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _volverAlLogin,
                        child: const Text('Volver al login'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Barra de progreso con conteo "X / Y registros". Solo se muestra
/// cuando PowerSync expone downloadProgress con totalOperations > 0.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.downloaded,
    required this.total,
    required this.fraction,
  });

  final int downloaded;
  final int total;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, minWidth: 200),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$downloaded / $total registros',
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Mapea el error opaco de PowerSync a un mensaje legible en español.
/// PowerSync emite Exception/String según el origen del fallo; usamos
/// substring matching defensivo y caemos a un mensaje genérico si no
/// reconocemos el patrón.
String _humanizeError(Object error) {
  final raw = error.toString().toLowerCase();
  if (raw.contains('jwt') ||
      raw.contains('token') ||
      raw.contains('unauthorized') ||
      raw.contains('401')) {
    return 'Tu sesión expiró. Volvé al login para continuar.';
  }
  if (raw.contains('network') ||
      raw.contains('socket') ||
      raw.contains('failed host lookup') ||
      raw.contains('connection')) {
    return 'No pudimos conectarnos al servidor. Revisá tu internet '
        'y dale a Reintentar.';
  }
  if (raw.contains('500') ||
      raw.contains('502') ||
      raw.contains('503') ||
      raw.contains('504')) {
    return 'El servidor está teniendo problemas. Probá en unos '
        'minutos.';
  }
  return 'Hubo un problema con la sincronización. Probá reintentar o '
      'volver al login.';
}
