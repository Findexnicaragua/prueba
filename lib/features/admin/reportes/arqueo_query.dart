/// SQL del arqueo, fuera de la pantalla.
///
/// Vive acá por el mismo motivo que `dashboard_query.dart`: así el test puede
/// correr la consulta de PRODUCCIÓN y compararla contra la caja del dashboard.
/// Las dos miden lo mismo —plata que entró, por `fecha_pago`, de pagos vivos—
/// y tienen que dar idéntico sobre la misma ventana. Si divergen, una está mal.
///
/// La tarjeta de tendencia del dashboard NO entra en esa comparación: mide por
/// `fecha_vencimiento` de la cuota (cobertura), que es otra pregunta.
library;

/// Query del arqueo / cierre por cobrador. Una fila por cobrador con los
/// efectivos separados por moneda (US$/C$, montos en `monto_original`), el
/// vuelto total, los electrónicos por método, y el recaudado contable
/// (`monto_cordobas`). Params: [desde, hasta] (date-only, inclusive).
/// SQLite-válida: usa SUM(CASE WHEN…), NO FILTER. Compartida por PDF y Excel.
/// [filtroCbWhere] = '' (todos) o 'WHERE cb.id IN (?,?,…)' del filtro de
/// cobradores; sus params van DESPUÉS de los 4 de fechas (orden posicional).
String arqueoSql(String filtroCbWhere) => '''
  SELECT cb.nombre AS cobrador_nombre,
         COUNT(p.id) AS total_cobros,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='USD' THEN p.monto_original ELSE 0 END),0) AS efectivo_usd,
         SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='USD' THEN 1 ELSE 0 END) AS efectivo_usd_qty,
         -- Equivalente en córdobas del efectivo USD, a la tasa de CADA cobro
         -- (monto_cordobas + vuelto_cordobas = monto_original × tasa_conversion,
         -- invariante #3). NO usar la tasa de hoy: rompería la reconciliación.
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='USD' THEN COALESCE(p.monto_cordobas,0) + COALESCE(p.vuelto_cordobas,0) ELSE 0 END),0) AS efectivo_usd_equiv,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='NIO' THEN p.monto_original ELSE 0 END),0) AS efectivo_nio,
         SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='NIO' THEN 1 ELSE 0 END) AS efectivo_nio_qty,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' THEN p.vuelto_cordobas ELSE 0 END),0) AS efectivo_vuelto,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' THEN p.monto_cordobas ELSE 0 END),0) AS efectivo_ingreso,
         COALESCE(SUM(CASE WHEN p.metodo='transferencia' THEN p.monto_cordobas ELSE 0 END),0) AS transferencia,
         SUM(CASE WHEN p.metodo='transferencia' THEN 1 ELSE 0 END) AS transferencia_qty,
         COALESCE(SUM(CASE WHEN p.metodo='deposito' THEN p.monto_cordobas ELSE 0 END),0) AS deposito,
         SUM(CASE WHEN p.metodo='deposito' THEN 1 ELSE 0 END) AS deposito_qty,
         COALESCE(SUM(CASE WHEN p.metodo='tarjeta' THEN p.monto_cordobas ELSE 0 END),0) AS tarjeta,
         SUM(CASE WHEN p.metodo='tarjeta' THEN 1 ELSE 0 END) AS tarjeta_qty,
         COALESCE(SUM(p.monto_cordobas),0) AS ingreso_total,
         -- Devoluciones de saldo a favor pagadas en efectivo (0127): salen de la
         -- caja de ESTE cobrador en el rango (bucket por fecha_devolucion LOCAL).
         -- Tabla derivada con LEFT JOIN (no subquery correlacionada) → un cobrador
         -- que SOLO hizo devoluciones (sin pagos en el rango) igual aparece.
         COALESCE(d.dev, 0) AS devoluciones
    FROM cobradores cb
    LEFT JOIN pagos p ON p.cobrador_id = cb.id AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
                     AND date(p.fecha_pago) BETWEEN ? AND ?
    LEFT JOIN (SELECT cobrador_id, SUM(monto) AS dev
                 FROM saldos_favor
                WHERE tipo = 'devuelto'
                  AND date(fecha_devolucion) BETWEEN ? AND ?
                GROUP BY cobrador_id) d ON d.cobrador_id = cb.id
   $filtroCbWhere
   GROUP BY cb.id, cb.nombre, d.dev
  HAVING COUNT(p.id) > 0 OR COALESCE(d.dev, 0) > 0
   ORDER BY ingreso_total DESC
''';
