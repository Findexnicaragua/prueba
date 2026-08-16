import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/update_service.dart';

/// Checa si hay actualización disponible al arrancar la app.
/// FutureProvider porque es un one-shot check, no un stream.
/// autoDispose para que re-chequee si el provider es invalidado.
final updateAvailableProvider = FutureProvider.autoDispose<AppUpdate?>((ref) {
  return UpdateService.checkForUpdate();
});
