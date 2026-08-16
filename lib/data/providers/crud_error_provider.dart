import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/connector.dart';
import '../../powersync/db.dart' as ps;
import '../services/rechazos_sync_service.dart';

/// Stream de errores de CRUD upload. Cuando PowerSync intenta subir
/// un write local y Postgres lo rechaza (constraint, trigger, RLS),
/// el error llega acá para que los shells lo muestren como SnackBar.
final crudUploadErrorProvider = StreamProvider<CrudUploadError>((ref) {
  return ps.uploadErrorsController.stream;
});

/// Rechazos de sync PERSISTIDOS (el rastro que queda después del SnackBar).
/// Los muestra el Perfil en "Cambios sin sincronizar". No toca ps.db (lee
/// SharedPreferences), así que no necesita dbEpochProvider.
final rechazosSyncProvider = StreamProvider<List<RechazoSync>>((ref) {
  return RechazosSyncService.instance.watch();
});
