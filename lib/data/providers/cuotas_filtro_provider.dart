import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import 'db_epoch_provider.dart';

/// `true` si existe al menos una cuota en estado `parcial` en la DB local.
///
/// Se usa para decidir si mostrar el filtro "Parcial/Parciales" en las
/// pantallas de cuotas (admin y cobrador): el chip aparece si el tenant permite
/// pago parcial O si ya hay cuotas parciales (históricas), aunque el setting
/// esté en OFF. Así un filtro sin uso no ensucia la UI, pero las parciales
/// existentes siempre se pueden ver.
final hayCuotasParcialesProvider = StreamProvider.autoDispose<bool>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB
  return ps.db
      .watch("SELECT EXISTS(SELECT 1 FROM cuotas WHERE estado='parcial') AS hay")
      .map((rows) => ((rows.first['hay'] as num?) ?? 0) != 0);
});
