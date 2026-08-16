import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import 'db_epoch_provider.dart';

/// Cuenta de productos GRANEL por debajo de su stock mínimo (>0) — alimenta el
/// badge del item "Inventario" del menú admin. Solo granel: es la única vista de
/// "Bajo mínimo" accionable (la tab Existencias filtra es_serializado=0); contar
/// serializados bajo mínimo apuntaba a algo sin superficie para llegar (audit
/// 2026-06-30). Stock granel = Σdestino − Σorigen del ledger. Derivado/offline;
/// recomputa cuando cambian productos/movimientos (no necesita ticker).
final inventarioStockBajoCountProvider = StreamProvider.autoDispose<int>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (per-user)
  return ps.db
      .watch('''
        SELECT COUNT(*) AS n FROM (
          SELECT p.stock_minimo AS smin,
                 COALESCE((SELECT SUM(CASE WHEN m.ubicacion_destino_id IS NOT NULL THEN m.cantidad ELSE 0 END)
                                - SUM(CASE WHEN m.ubicacion_origen_id IS NOT NULL THEN m.cantidad ELSE 0 END)
                             FROM inv_movimientos m WHERE m.producto_id = p.id), 0) AS stock
            FROM inv_productos p WHERE p.activo = 1 AND p.es_serializado = 0
        ) WHERE smin > 0 AND stock < smin
      ''')
      .map((rows) => rows.isEmpty ? 0 : (rows.first['n'] as int? ?? 0));
});
