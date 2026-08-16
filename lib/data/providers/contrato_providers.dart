import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;

/// Providers del detalle de contrato (`ContratoDetailScreen`).
///
/// Antes los 4 streams (`contrato`, `cuotas`, `pagos`, `resumen`) vivían como
/// `late Stream` dentro del `State` de la pantalla, creados en `initState` con
/// `ps.db.watch(...)`. PowerSync cachea sus streams por query+params, así que
/// `watch(mismo SQL, mismos params)` devuelve la MISMA instancia de stream. Un
/// stream single-subscription sostenido en State, al re-entrar a la pantalla,
/// se re-subscribía sobre un stream ya cancelado → "Stream has already been
/// listened to" / la sección de pagos quedaba vacía.
///
/// La solución idiomática es `StreamProvider.autoDispose.family`: Riverpod
/// maneja UNA subscripción interna, cachea el último `AsyncValue` (replay para
/// nuevos watchers) y `autoDispose` limpia la subscripción al salir de la
/// pantalla, así re-entrar arranca limpio. Mismo patrón que
/// `dashboard_providers.dart`.
///
/// Los providers devuelven las filas crudas (`List<Map<String, dynamic>>`) —
/// los widgets leen los maps directamente, sin mapear a modelos.

final contratoDetalleProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT ct.id, ct.tenant_id, ct.codigo, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
           ct.estado, ct.cliente_id, ct.cobrador_id, ct.plan_id,
           ct.documento_path, ct.duracion_meses,
           ct.costo_instalacion, ct.notas,
           ct.cancelado_en, ct.motivo_cancelacion, ct.cancelacion_deuda_snapshot,
           p.nombre AS plan_nombre, p.precio_mensual,
           c.nombre AS cliente_nombre
      FROM contratos ct
      JOIN planes  p ON p.id = ct.plan_id
      JOIN clientes c ON c.id = ct.cliente_id
     WHERE ct.id = ?
     LIMIT 1
    ''',
    parameters: [contratoId],
  );
});

final contratoCuotasProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT cu.id, cu.monto, cu.monto_pagado, cu.cargos_neto,
           cu.fecha_vencimiento,
           cu.periodo, cu.estado, cu.contrato_id,
           cu.descripcion, cu.tipo_cargo_manual, ct.dia_pago,
           (SELECT COUNT(*) FROM cargos_extra ce
             WHERE ce.cuota_id = cu.id
           ) AS cargos_count,
           (SELECT COUNT(*) FROM cargos_extra ce
             WHERE ce.cuota_id = cu.id AND ce.tipo = 'credito_aplicado'
           ) AS credito_count,
           (SELECT MAX(p.fecha_pago) FROM pagos p
             WHERE p.cuota_id = cu.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
           ) AS fecha_cobro
      FROM cuotas cu
      LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     WHERE cu.contrato_id = ?
     ORDER BY cu.periodo ASC
    ''',
    parameters: [contratoId],
  );
});

/// Movimientos de saldo a favor (crédito por excedente, 0127) ligados a este
/// contrato: acreditado (origen) / aplicado (a una cuota suya) / devuelto /
/// condonado / revertido. Para la sección "Saldo a favor" del detalle.
final contratoSaldosFavorProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT sf.id, sf.tipo, sf.monto, sf.cuota_id, sf.motivo,
           sf.fecha_devolucion, sf.created_at, cu.periodo, ct.dia_pago
      FROM saldos_favor sf
      LEFT JOIN cuotas cu ON cu.id = sf.cuota_id
      LEFT JOIN contratos ct ON ct.id = sf.contrato_id
     WHERE sf.contrato_id = ?
     ORDER BY sf.created_at ASC
    ''',
    parameters: [contratoId],
  );
});

final contratoPagosProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT pa.id, pa.tenant_id, pa.cuota_id, pa.cobrador_id,
           pa.monto_cordobas, pa.vuelto_cordobas, pa.moneda,
           pa.monto_original, pa.tasa_conversion, pa.metodo,
           pa.referencia, pa.foto_comprobante_path,
           pa.lat, pa.lng, pa.notas, pa.fecha_pago,
           pa.anulado, pa.anulado_en, pa.anulado_por,
           pa.motivo_anulacion, pa.grupo_cobro, pa.client_local_id,
           cu.periodo, cu.tipo_cargo_manual, ct.dia_pago
      FROM pagos pa
      INNER JOIN cuotas cu ON cu.id = pa.cuota_id
      LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     WHERE cu.contrato_id = ?
     ORDER BY pa.fecha_pago DESC
     LIMIT 20
    ''',
    parameters: [contratoId],
  );
});

/// Historial de pagos de un CLIENTE (todos sus contratos), para la lista
/// READ-ONLY de la ficha (Feature 2). Mismo patrón que `contratoPagosProvider`
/// pero filtrado por `cu.cliente_id` y trayendo `plan_nombre`/`contrato_codigo`/
/// `contrato_id` para agrupar por contrato en la UI. SIN LIMIT: historial
/// completo del cliente (vida completa). Ordena por contrato (más nuevo) y, dentro,
/// por fecha de pago desc.
final clientePagosProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, clienteId) {
  return ps.db.watch(
    '''
    SELECT pa.id, pa.tenant_id, pa.cuota_id, pa.cobrador_id,
           pa.monto_cordobas, pa.vuelto_cordobas, pa.moneda,
           pa.monto_original, pa.tasa_conversion, pa.metodo,
           pa.referencia, pa.foto_comprobante_path,
           pa.lat, pa.lng, pa.notas, pa.fecha_pago,
           pa.anulado, pa.anulado_en, pa.anulado_por,
           pa.motivo_anulacion, pa.grupo_cobro, pa.client_local_id,
           cu.periodo, cu.tipo_cargo_manual, cu.contrato_id,
           ct.dia_pago, ct.codigo AS contrato_codigo, p.nombre AS plan_nombre
      FROM pagos pa
      INNER JOIN cuotas cu ON cu.id = pa.cuota_id
      LEFT JOIN contratos ct ON ct.id = cu.contrato_id
      LEFT JOIN planes p ON p.id = ct.plan_id
     WHERE cu.cliente_id = ?
     ORDER BY ct.created_at DESC, pa.fecha_pago DESC
    ''',
    parameters: [clienteId],
  );
});

// Resumen financiero del contrato: `recaudado` = SUM(pagos NO anulados, a cuotas
// regulares Y cargos manuales); `cobrable` = deuda viva = SUM(saldo canónico de
// cuotas pendiente/parcial), la misma fórmula que los reportes (consistencia #10).
final contratoRecaudadoProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT
      COALESCE((SELECT SUM(pa.monto_cordobas)
                  FROM pagos pa
                  JOIN cuotas cu ON cu.id = pa.cuota_id
                 WHERE cu.contrato_id = ? AND COALESCE(pa.anulado, 0) = 0 AND COALESCE(pa.en_revision, 0) = 0), 0) AS recaudado,
      COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                  FROM cuotas cu
                 WHERE cu.contrato_id = ?
                   AND cu.estado IN ('pendiente','parcial')), 0) AS cobrable,
      -- Conteo de cuotas vivas (no anuladas): un fijo intacto tiene tantas como
      -- su duración; si hay menos, hubo meses anulados (suspensión/cancelación).
      -- Señal del hint "ajustado" independiente del precio (robusta a cambio de
      -- plan, donde el nominal precio×meses ya no aplica).
      (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ? AND estado <> 'anulada') AS vivas,
      -- Avance en CONTEO de cuotas. Sale de `cuotas`, no de `pagos`, así que es
      -- exacto para el rol admin_usuarios, cuyo bucket NO sincroniza `pagos`
      -- (a ese rol se le muestra esto en vez de las 3 columnas de plata: su
      -- "Recaudado" daba 0 y arrastraba el Total a un número inventado).
      (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ? AND estado = 'pagada') AS pagadas
    ''',
    parameters: [contratoId, contratoId, contratoId, contratoId],
  );
});
