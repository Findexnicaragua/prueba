import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/conexion_real_provider.dart';
import '../../../powersync/db.dart' as ps;

/// Banner rojo persistente que aparece SOLO cuando el dispositivo está
/// realmente sin conexión. Envuelve el body de los shells (cobrador y admin).
///
/// **Fuente de verdad**: [conexionRealProvider] — sondeo TCP real al backend,
/// NO el `SyncStatus` de PowerSync. PowerSync no detecta caídas silenciosas de
/// red (la conexión TCP queda colgada sin error → `connected` queda en true) y
/// da falsos positivos en sus hipos (token/backoff con señal buena). Ver ese
/// provider para el detalle. (Decisión Rubén 2026-06-16: el rojo SOLO cuando de
/// verdad no hay conexión; nada más.)
///
/// El sondeo ya confirma una desconexión SOSTENIDA (2 fallos seguidos ≈ 15s),
/// así que el debounce de ENTRADA es corto (1s). Asimetría intencional: al
/// volver la conexión, oculta con 700ms de gracia para no parpadear si la red
/// vuelve a caer al instante.
///
/// **Patrón**: `ref.listen` (no `ref.watch` + setState) → reacciona solo a los
/// cambios del provider, sin races entre el estado del widget y el stream.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key, required this.child});
  final Widget child;

  static const _showDebounce = Duration(seconds: 1);
  // Debounce de SALIDA: al reconectar esperamos un toque antes de ocultar, así
  // una reconexión transitoria no hace parpadear el banner.
  static const _hideDebounce = Duration(milliseconds: 700);

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  Timer? _showTimer;
  Timer? _hideTimer;
  bool _show = false;

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  /// Reacciona a un cambio de conectividad. Idempotente.
  /// - `offline=true` con timer pending o banner visible → skip.
  /// - `offline=true` desde estado limpio → schedule timer corto.
  /// - `offline=false` con timer pending → cancela.
  /// - `offline=false` con banner visible → oculta con debounce de salida.
  void _onOffline(bool offline) {
    if (offline) {
      _hideTimer?.cancel();
      _hideTimer = null;
      if (_showTimer != null || _show) return;
      _showTimer = Timer(OfflineBanner._showDebounce, () {
        _showTimer = null;
        if (mounted) setState(() => _show = true);
      });
    } else {
      _showTimer?.cancel();
      _showTimer = null;
      if (_show && _hideTimer == null) {
        _hideTimer = Timer(OfflineBanner._hideDebounce, () {
          _hideTimer = null;
          if (mounted) setState(() => _show = false);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<bool>>(conexionRealProvider, (_, next) {
      final online = next.valueOrNull;
      if (online == null) return; // loading inicial: no decidir todavía
      _onOffline(!online);
    });

    return Column(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: _show ? const _Banner() : const SizedBox.shrink(),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

class _Banner extends StatefulWidget {
  const _Banner();

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  bool _retrying = false;

  /// Reintentar fuerza una reconexión de PowerSync. El banner en sí se oculta
  /// solo cuando el sondeo de conectividad vuelve a alcanzar el backend.
  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await ps.disconnectPowerSync();
      await ps.connectPowerSync();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sin conexión. Los cambios se guardan localmente y se '
                  'sincronizarán al volver la red.',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                icon: _retrying
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onErrorContainer,
                        ),
                      )
                    : const Icon(Icons.refresh, size: 16),
                label: Text(_retrying ? 'Reintentando…' : 'Reintentar'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onErrorContainer,
                ),
                onPressed: _retrying ? null : _retry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
