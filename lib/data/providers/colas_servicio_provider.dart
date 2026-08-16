import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import 'db_epoch_provider.dart';

/// Colas de la integración órdenes-de-trabajo ↔ facturación (Fase 1, 0172).
///
/// Son QUERIES DERIVADAS (no tablas) sobre lo que el admin YA sincroniza
/// (contratos/cuotas/tickets/ticket_tipos): le recuerdan la acción de
/// facturación MANUAL que sigue a un trabajo de campo. El cobro y el estado de
/// servicio NO se tocan acá — el panel solo navega al contrato para que el admin
/// dispare suspender/reactivar con su identidad (gateado + bloqueado al
/// impersonar). Cero trigger de plata: el automatismo es Fase 2 (diferido).
///
/// Global que toca ps.db → primera línea ref.watch(dbEpochProvider) (regla #9):
/// se recrea al cambiar de DB (login/impersonación) y no queda leyendo una
/// conexión cerrada.

/// Cortes ejecutados (ticket efecto='corte' resuelto/cerrado) sobre un contrato
/// que SIGUE activo → el admin debería SUSPENDERLO (para que deje de facturarse
/// el servicio que ya se cortó físicamente).
final colaCortesPendientesProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  ref.watch(dbEpochProvider);
  // 1 fila por CONTRATO (GROUP BY), no por ticket: un contrato con varias
  // órdenes de corte resueltas aparece UNA sola vez (audit 2026-06-29). LIMIT
  // defensivo — el panel igual acota su alto y scrollea.
  // Enriquecido (Fase 2): + código de cliente/plan/precio (para mostrar y para
  // el batch que prorratea) + "días en mora" (subquery sobre la cuota impaga más
  // vieja) para el badge de antigüedad y el ORDER por urgencia.
  return ps.db.watch('''
    SELECT ct.id AS contrato_id, ct.codigo AS contrato_codigo, ct.dia_pago AS dia_pago,
           cl.codigo AS cliente_codigo, cl.nombre AS cliente_nombre,
           p.nombre AS plan_nombre, COALESCE(p.precio_mensual, 0) AS precio_mensual,
           MAX(t.resuelto_en) AS resuelto_en,
           (SELECT CAST(julianday('now', '-6 hours')
                        - julianday(MIN(cu.fecha_vencimiento)) AS int)
              FROM cuotas cu
             WHERE cu.contrato_id = ct.id
               AND cu.estado IN ('pendiente', 'parcial')
               AND (cu.monto + COALESCE(cu.cargos_neto, 0)
                    - COALESCE(cu.monto_pagado, 0)) > 0.01) AS dias_mora
      FROM tickets t
      JOIN ticket_tipos tt ON tt.id = t.tipo_id
      JOIN contratos ct ON ct.id = t.contrato_id
 LEFT JOIN clientes cl ON cl.id = t.cliente_id
 LEFT JOIN planes p ON p.id = ct.plan_id
     WHERE tt.efecto = 'corte'
       AND t.estado IN ('resuelto', 'cerrado')
       AND ct.estado = 'activo'
     GROUP BY ct.id, ct.codigo, ct.dia_pago, cl.codigo, cl.nombre,
              p.nombre, p.precio_mensual
     ORDER BY dias_mora DESC, MAX(t.resuelto_en) DESC
     LIMIT 50
  ''');
});

/// COUNT total (SIN LIMIT) de contratos a suspender — para la MÉTRICA del Centro.
/// La lista de arriba tiene LIMIT 50; la métrica debe contar TODO o subestima en
/// un corte masivo (>50 contratos) — audit 2026-06-30. Mismo filtro que la lista.
final colaCortesTotalProvider = StreamProvider.autoDispose<int>((ref) {
  ref.watch(dbEpochProvider);
  return ps.db.watch('''
    SELECT COUNT(*) AS n FROM (
      SELECT ct.id
        FROM tickets t
        JOIN ticket_tipos tt ON tt.id = t.tipo_id
        JOIN contratos ct ON ct.id = t.contrato_id
       WHERE tt.efecto = 'corte'
         AND t.estado IN ('resuelto', 'cerrado')
         AND ct.estado = 'activo'
       GROUP BY ct.id
    )
  ''').map((rows) => rows.isEmpty ? 0 : (rows.first['n'] as int? ?? 0));
});

/// Contratos SUSPENDIDOS cuya deuda viva quedó en 0 → el cliente pagó y el admin
/// debería REACTIVARLOS (si usa el flujo de 2 visitas, antes genera la orden de
/// reconexión para el técnico). Saldo canónico por cuota viva (no anulada):
/// monto + cargos_neto − monto_pagado (invariante #10).
final colaReactivarPendientesProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  ref.watch(dbEpochProvider);
  // Enriquecido (Fase 2): + código de cliente/plan/precio + "días suspendido"
  // (desde el último contrato_suspensiones sin reactivar) para el badge y el
  // ORDER por antigüedad.
  return ps.db.watch('''
    SELECT ct.id AS contrato_id, ct.codigo AS contrato_codigo, ct.dia_pago AS dia_pago,
           cl.codigo AS cliente_codigo, cl.nombre AS cliente_nombre,
           p.nombre AS plan_nombre, COALESCE(p.precio_mensual, 0) AS precio_mensual,
           (SELECT CAST(julianday('now', '-6 hours')
                        - julianday(MAX(s.suspendido_en)) AS int)
              FROM contrato_suspensiones s
             WHERE s.contrato_id = ct.id AND s.reactivado_en IS NULL) AS dias_suspendido
      FROM contratos ct
 LEFT JOIN clientes cl ON cl.id = ct.cliente_id
 LEFT JOIN planes p ON p.id = ct.plan_id
     WHERE ct.estado = 'suspendido'
       AND COALESCE((
             SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0)
                        - COALESCE(cu.monto_pagado, 0), 0))
               FROM cuotas cu
              WHERE cu.contrato_id = ct.id AND cu.estado <> 'anulada'
           ), 0) <= 0.01
     ORDER BY dias_suspendido DESC
     LIMIT 50
  ''');
});
