import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/db_epoch_provider.dart';
import '../../powersync/db.dart' as ps;

/// SQL de las cuotas en mora del contrato (pendiente/parcial pasadas de gracia).
/// Cada fila: cuota_id, periodo, fecha_vencimiento, dia_pago, saldo. Ordenadas
/// cronológicamente. Fórmula canónica (invariante de consistencia #10): estado
/// IN ('pendiente','parcial') AND venc + diasGracia ya pasó AND saldo > 0.01,
/// donde saldo = monto + cargos_neto - monto_pagado. Una cuota PAGADA (estado
/// 'pagada' o saldo 0) queda EXCLUIDA. Placeholders: [contratoId, diasGracia].
const String _kMoraSql = '''
  SELECT cu.id AS cuota_id, cu.periodo, cu.fecha_vencimiento, ct.dia_pago AS dia_pago,
         max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0) AS saldo
    FROM cuotas cu
    LEFT JOIN contratos ct ON ct.id = cu.contrato_id
   WHERE cu.contrato_id = ?
     AND cu.estado IN ('pendiente','parcial')
     AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
     AND max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0) > 0.01
   ORDER BY cu.periodo ASC
''';

/// Cuotas en mora del contrato — fetch ONE-SHOT (para el path de IMPRESIÓN/PDF,
/// que await-ea afuera del widget y no tiene `ref`). Mismo SQL que el stream del
/// preview (`watchMoraContrato`) → ambos paths dan idéntico (consistencia #10).
Future<List<Map<String, dynamic>>> fetchMoraContrato(
        String contratoId, int diasGracia) =>
    ps.db.getAll(_kMoraSql, [contratoId, diasGracia]);

/// Cuotas en mora del contrato — STREAM VIVO (para el PREVIEW en pantalla).
/// `ps.db.watch` se re-emite cuando cambian las cuotas → tras un cobro que salda
/// una cuota, el recibo deja de listarla en "EN MORA" al instante. (Antes el
/// preview leía un `FutureProvider` cacheado y mostraba cuotas YA pagadas —
/// bug 2026-06-29; los datos y cargos del recibo ya eran streams, la mora no.)
Stream<List<Map<String, dynamic>>> watchMoraContrato(
        String contratoId, int diasGracia) =>
    ps.db.watch(_kMoraSql, parameters: [contratoId, diasGracia]);

/// Provider del preview: STREAM (vivo) memoizado por (contrato, gracia) — así no
/// se crea un `ps.db.watch` inline en el build (regla #2) y a la vez SIEMPRE
/// refleja el estado actual. `autoDispose`: al cerrar el recibo se libera y el
/// próximo recibo recalcula desde cero. `dbEpochProvider`: recrea al cambiar de
/// DB (login/impersonación). El path de impresión NO usa este provider (usa
/// `fetchMoraContrato`, one-shot fresco).
final moraContratoProvider = StreamProvider.autoDispose.family<
    List<Map<String, dynamic>>, ({String contratoId, int diasGracia})>(
  (ref, args) {
    ref.watch(dbEpochProvider);
    return watchMoraContrato(args.contratoId, args.diasGracia);
  },
);
