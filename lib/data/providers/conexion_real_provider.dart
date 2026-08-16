import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/env.dart';
import 'db_epoch_provider.dart';

/// Conectividad REAL del dispositivo, sondeada con `dart:io` (sin paquetes
/// nuevos).
///
/// **Por qué no alcanza PowerSync** (feedback Rubén 2026-06-16): el banner
/// dependía de `SyncStatus.connected`, pero ese flag dice cuándo el sync se
/// ESTABLECE — no si hay internet. Cuando el wifi se cae en silencio, la
/// conexión TCP de PowerSync queda colgada sin error y `connected` puede
/// quedar en `true`, así que el banner NUNCA se enteraba de la caída. Y al
/// revés, PowerSync baja `connected` por hipos (refresh del token, backoff)
/// con señal buena → falsos positivos. Ninguno de los dos es "hay internet".
///
/// **Cómo funciona**: cada [_intervalo] intenta un TCP connect corto al host
/// del backend (Supabase). Tras 2 fallos seguidos declara OFFLINE; un solo
/// éxito vuelve a ONLINE. Emite `true`=online / `false`=offline. `autoDispose`:
/// deja de sondear cuando no hay shell montado (ej. pantalla de login). Un
/// connect crudo a :443 NO hace TLS — solo verifica alcance real (no es
/// cacheable como un DNS lookup) y se cierra al instante. Tiempos ajustables.
final conexionRealProvider = StreamProvider.autoDispose<bool>((ref) async* {
  // Recrea al cambiar de DB (#7). En el cold-start de un cambio de schema la DB
  // se recrea (isolate ocupado en I/O + DNS lento) → sondeos pueden fallar y
  // dejar el provider "latcheado" en offline aunque haya red. Observar el epoch
  // reinicia el generador → vuelve a arrancar OPTIMISTA (yield true) en vez de
  // heredar ese falso offline.
  ref.watch(dbEpochProvider);
  const intervalo = Duration(seconds: 7);
  const timeout = Duration(seconds: 4);
  const fallosOffline = 2; // ~2 ciclos sin alcance = offline real (~15s)

  final host = Uri.tryParse(Env.supabaseUrl)?.host ?? '';
  if (host.isEmpty) {
    // Sin backend configurado no podemos sondear → no molestamos con el banner.
    yield true;
    return;
  }

  Future<bool> alcanzable() async {
    try {
      final s = await Socket.connect(host, 443, timeout: timeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  var online = true;
  var fallos = 0;
  yield true; // optimista al arrancar: no mostramos rojo hasta CONFIRMAR offline
  while (true) {
    final ok = await alcanzable();
    if (ok) {
      fallos = 0;
      if (!online) {
        online = true;
        yield true;
      }
    } else {
      fallos++;
      if (online && fallos >= fallosOffline) {
        online = false;
        yield false;
      }
    }
    await Future<void>.delayed(intervalo);
  }
});
