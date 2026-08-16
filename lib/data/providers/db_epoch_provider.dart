import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Contador que se incrementa cada vez que se abre una DB per-user nueva
/// (cambio de usuario). Los providers GLOBALES bound a `ps.db` lo observan con
/// `ref.watch(dbEpochProvider)` como trigger de recreación: al cambiar de DB,
/// Riverpod los recrea y re-suscribe sus streams a la DB nueva.
///
/// Resuelve el bug "data vieja / settings vacío al cambiar de usuario sin F5"
/// (#7): antes `main.dart` invalidaba a mano una lista hardcodeada e incompleta
/// de providers en `onDatabaseSwitched`; los que faltaban quedaban con el
/// stream de la DB anterior (ya cerrada) hasta un refresh manual del browser.
///
/// CONTRATO (importante para no re-introducir el bug): todo provider GLOBAL
/// (no `autoDispose`/`family`) que lea `ps.db` al crearse DEBE hacer
/// `ref.watch(dbEpochProvider);` como primera línea de su body. NO lo necesitan:
///   - Los providers DERIVADOS (que ya `ref.watch` otro provider db-bound que
///     sí observa el epoch) — se recrean en cascada.
///   - Los `autoDispose`/`family` — se recrean al re-navegar tras el switch.
///   - Los providers que no tocan `ps.db` (ej. el que escucha el controller
///     global de errores de upload).
final dbEpochProvider = StateProvider<int>((ref) => 0);
