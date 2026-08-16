import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import 'db_epoch_provider.dart';

/// Providers NUEVOS del Centro de cobranza (los otros 4 bloques reusan
/// `colas_servicio_provider` [cortes/reactivar] y `avisos_screen`
/// [gracia/mora]). Son QUERIES DERIVADAS sobre lo que el admin ya sincroniza —
/// no tocan dinero ni estado, solo le RECUERDAN al admin qué hacer.
///
/// Global que toca ps.db → primera línea `ref.watch(dbEpochProvider)` (regla #9):
/// se recrea al cambiar de DB (login/impersonación) y no queda leyendo una
/// conexión cerrada. Saldo canónico clampeado con `max(...,0)` (consistencia #10).

/// Contratos con una cuota que VENCE HOY (proactivo: cobrar antes de que se
/// atrase). Saldo canónico por cuota viva. 1 fila por contrato. `date('now',
/// '-6 hours')` = hoy en Nicaragua (UTC-6, regla #1b).
final vencenHoyProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  ref.watch(dbEpochProvider);
  return ps.db.watch('''
    SELECT ct.id AS contrato_id, ct.codigo AS contrato_codigo,
           cl.nombre AS cliente_nombre,
           SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0)
                   - COALESCE(cu.monto_pagado, 0), 0)) AS total
      FROM cuotas cu
      JOIN contratos ct ON ct.id = cu.contrato_id
 LEFT JOIN clientes cl ON cl.id = cu.cliente_id
     WHERE cu.estado IN ('pendiente', 'parcial')
       AND ct.estado = 'activo'
       AND cl.activo = 1
       AND date(cu.fecha_vencimiento) = date('now', '-6 hours')
       AND max(cu.monto + COALESCE(cu.cargos_neto, 0)
               - COALESCE(cu.monto_pagado, 0), 0) > 0.01
     GROUP BY ct.id, ct.codigo, cl.nombre
     ORDER BY total DESC
     LIMIT 50
  ''');
});

/// Agregado (TOTAL + cantidad, SIN LIMIT) de "Vencen hoy" para la MÉTRICA del
/// Centro. La lista de arriba tiene LIMIT 50; la métrica debe sumar TODO o
/// subestimaría en tenants grandes con día de pago concentrado (audit QA
/// 2026-06-30). Mismo filtro que la lista.
final vencenHoyTotalProvider =
    StreamProvider.autoDispose<({double total, int cant})>((ref) {
  ref.watch(dbEpochProvider);
  return ps.db.watch('''
    SELECT COALESCE(SUM(t.total), 0) AS suma, COUNT(*) AS cant FROM (
      SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0)
                     - COALESCE(cu.monto_pagado, 0), 0)) AS total
        FROM cuotas cu
        JOIN contratos ct ON ct.id = cu.contrato_id
   LEFT JOIN clientes cl ON cl.id = cu.cliente_id
       WHERE cu.estado IN ('pendiente', 'parcial')
         AND ct.estado = 'activo'
         AND cl.activo = 1
         AND date(cu.fecha_vencimiento) = date('now', '-6 hours')
         AND max(cu.monto + COALESCE(cu.cargos_neto, 0)
                 - COALESCE(cu.monto_pagado, 0), 0) > 0.01
       GROUP BY ct.id
    ) t
  ''').map(_aTotalCant);
});

/// CLIENTES con CRÉDITO A FAVOR sin aplicar (pagaron de más). El crédito es a
/// nivel CLIENTE — cruza sus contratos (un excedente acreditado en el contrato A
/// se puede aplicar a una cuota del B). Por eso se agrupa por CLIENTE, idéntico
/// a `contratos_repo.creditoDisponible` (libro append-only 0127): disponible =
/// SUM(+acreditado) − SUM(aplicado+devuelto+condonado+revertido). Agrupar por
/// contrato inflaría el A y ocultaría el B (audit 2026-06-29). Solo SUPERFICIE:
/// el bloque navega al cliente; el crédito se aplica en el próximo cobro/reactivar.
final creditosFavorProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  ref.watch(dbEpochProvider);
  return ps.db.watch('''
    SELECT cl.id AS cliente_id, cl.nombre AS cliente_nombre,
           SUM(CASE WHEN sf.tipo = 'acreditado' THEN sf.monto ELSE -sf.monto END)
             AS disponible
      FROM saldos_favor sf
      JOIN clientes cl ON cl.id = sf.cliente_id
     GROUP BY cl.id, cl.nombre
    HAVING SUM(CASE WHEN sf.tipo = 'acreditado' THEN sf.monto
                    ELSE -sf.monto END) > 0.01
     ORDER BY disponible DESC
     LIMIT 50
  ''');
});

/// Agregado (TOTAL + cantidad de clientes, SIN LIMIT) de "A favor" para la
/// MÉTRICA del Centro. Misma razón que `vencenHoyTotalProvider`.
final creditosFavorTotalProvider =
    StreamProvider.autoDispose<({double total, int cant})>((ref) {
  ref.watch(dbEpochProvider);
  return ps.db.watch('''
    SELECT COALESCE(SUM(t.disponible), 0) AS suma, COUNT(*) AS cant FROM (
      SELECT SUM(CASE WHEN sf.tipo = 'acreditado' THEN sf.monto ELSE -sf.monto END)
               AS disponible
        FROM saldos_favor sf
       GROUP BY sf.cliente_id
      HAVING SUM(CASE WHEN sf.tipo = 'acreditado' THEN sf.monto
                      ELSE -sf.monto END) > 0.01
    ) t
  ''').map(_aTotalCant);
});

/// Mapea la fila {suma, cant} de un agregado a un record tipado.
({double total, int cant}) _aTotalCant(List<Map<String, dynamic>> rows) {
  final r = rows.isNotEmpty ? rows.first : const <String, dynamic>{};
  return (
    total: (r['suma'] as num?)?.toDouble() ?? 0,
    cant: (r['cant'] as num?)?.toInt() ?? 0,
  );
}
