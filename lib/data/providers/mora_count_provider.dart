import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../powersync/db.dart' as ps;
import 'db_epoch_provider.dart';

/// Count de notificaciones de mora sin ver DEL PROPIO cobrador.
/// Usado para el Badge del bottom-nav del cobrador (app_shell).
///
/// Scoped a `cobrador_id = uid` (audit 2026-07-03): es la única mora que él
/// puede marcar como vista (RLS `notif_update_marca` exige
/// `cobrador_id = auth.uid()` para el cobrador puro) y la única accionable en
/// su lista. La mora de clientes SIN cobrador (admin-managed, P3b) es del
/// admin — contarla acá dejaba un badge imposible de limpiar: el UPDATE local
/// se revertía al sincronizar (server rechaza) y el número quedaba pegado.
final moraCountProvider = StreamProvider<int>((ref) async* {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) {
    yield 0;
    return;
  }
  yield* ps.db
      .watch('''
        SELECT COUNT(*) AS cnt FROM notificaciones_mora
        WHERE resuelta_en IS NULL AND vista_en IS NULL
          AND cobrador_id = ?
      ''', parameters: [uid])
      .map((rows) => rows.isEmpty ? 0 : (rows.first['cnt'] as int? ?? 0));
});
