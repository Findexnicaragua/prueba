import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@pragma('vm:entry-point')
void _syncForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_SyncTaskHandler());
}

class _SyncTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Administrador de Foreground Service y WakeLock para sincronizaciones
/// críticas (primer login, cambio de tenant por impersonación).
///
/// En Android:
///   - Levanta un Foreground Service con tipo `dataSync` y notificación persistente
///     para que el SO no suspenda los sockets de red ni mate el proceso si el
///     usuario cambia a WhatsApp o minimiza.
///   - Activa WakeLock para evitar que la pantalla se apague por inactividad.
///
/// En Windows / Web:
///   - El Foreground Service es no-op (los procesos de Windows no se suspenden
///     al cambiar de app).
///   - WakeLock se aplica de forma segura si la plataforma lo soporta.
class SyncForegroundService {
  SyncForegroundService._();
  static final SyncForegroundService instance = SyncForegroundService._();

  bool _activo = false;
  int _ultimoReportado = -1;

  /// Inicia el servicio en primer plano y mantiene la pantalla encendida.
  Future<void> iniciar() async {
    if (_activo) return;
    _activo = true;
    _ultimoReportado = -1;

    // 1. WakeLock en todas las plataformas soportadas
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('[SYNC-FG] Error al activar WakelockPlus: $e');
    }

    // 2. Foreground Task solo en Android
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      // Verificar permisos de notificación (Android 13+)
      final notifPerm =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notifPerm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'sitecsa_sync_channel',
          channelName: 'Sincronización de Cartera',
          channelDescription:
              'Mantiene activa la sincronización con el servidor en segundo plano.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );

      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: 'Sincronizando cartera...',
          notificationText: 'Sincronizando datos con el servidor...',
          callback: _syncForegroundTaskCallback,
        );
      }
      debugPrint('[SYNC-FG] Foreground service iniciado correctamente');
    } catch (e, stack) {
      debugPrint('[SYNC-FG] Error al iniciar Foreground Service: $e\n$stack');
    }
  }

  /// Actualiza el texto de la notificación con el progreso de descarga.
  void actualizarProgreso(int descargados, int total) {
    if (!_activo || kIsWeb || !Platform.isAndroid) return;
    if (total <= 0) return;

    // Evitar llamadas excesivas por cada registro individual
    if ((descargados - _ultimoReportado).abs() < 50 && descargados < total) {
      return;
    }
    _ultimoReportado = descargados;

    try {
      final porcentaje = (descargados / total * 100).clamp(0, 100).toStringAsFixed(0);
      FlutterForegroundTask.updateService(
        notificationTitle: 'Sincronizando cartera ($porcentaje%)',
        notificationText: 'Descargando: $descargados / $total registros',
      );
    } catch (_) {
      // No bloquear si la notificación no puede actualizarse
    }
  }

  /// Detiene el servicio y libera la pantalla.
  Future<void> detener() async {
    if (!_activo) return;
    _activo = false;

    // 1. Liberar WakeLock
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('[SYNC-FG] Error al desactivar WakelockPlus: $e');
    }

    // 2. Detener Foreground Service en Android
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        await FlutterForegroundTask.stopService();
        debugPrint('[SYNC-FG] Foreground service detenido');
      }
    } catch (e) {
      debugPrint('[SYNC-FG] Error al detener Foreground Service: $e');
    }
  }
}
