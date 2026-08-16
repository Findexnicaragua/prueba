import 'package:shared_preferences/shared_preferences.dart';

/// High-water mark LOCAL del correlativo de recibos, por (cobrador, prefijo).
///
/// Por qué existe (audit 2026-06-11, finding #2): el `MAX(correlativo)` del
/// SQLite local PIERDE los recibos anulados — las sync rules filtran
/// `anulado = false`, así que cuando el admin anula el último recibo del
/// cobrador, PowerSync BORRA esa fila local y el MAX baja. Si encima no hay
/// señal (el piso server es best-effort con catch), el próximo cobro REUSA
/// un número ya impreso → 23505 al subir → recibo descartado y un cliente
/// del ISP con un recibo cuyo número pertenece a otro cobro.
///
/// Este store recuerda el último correlativo EMITIDO/VISTO por este
/// dispositivo y NUNCA decrece. Se actualiza en cada emisión y con el MAX
/// del server cuando hay red (cubre lo emitido desde otros dispositivos).
///
/// Best-effort A PROPÓSITO: cualquier fallo de SharedPreferences degrada a 0
/// y JAMÁS bloquea un cobro (offline-first). En los tests de repo (Dart VM
/// sin plugins) cae en el catch y el flujo sigue solo con el MAX local.
/// Límite conocido: desinstalar la app borra el hwm (como borra la DB); la
/// primera consulta online al piso server lo reconstruye.
class CorrelativoStore {
  CorrelativoStore._();

  static String _key(String cobradorId, String prefijo) =>
      'correlativo_hwm_${cobradorId}_$prefijo';

  /// Último correlativo conocido para (cobrador, prefijo); 0 si no hay.
  static Future<int> leer(String cobradorId, String prefijo) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_key(cobradorId, prefijo)) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Sube el high-water mark a [valor] solo si es mayor (monotónico).
  static Future<void> subirA(
      String cobradorId, String prefijo, int valor) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final k = _key(cobradorId, prefijo);
      if (valor > (prefs.getInt(k) ?? 0)) {
        await prefs.setInt(k, valor);
      }
    } catch (_) {}
  }
}
