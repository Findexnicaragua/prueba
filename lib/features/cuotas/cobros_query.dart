/// Builders del SQL de la lista de Cobros, en un archivo aparte y SIN
/// dependencia de Flutter, para que los tests ejerciten EXACTAMENTE el mismo
/// SQL que la app (consistencia de dinero #10 — el total del resumen DEBE dar
/// igual que la suma del detalle). La UI vive en `cuotas_list_screen.dart`.
library;

/// Filtro de estado de la lista de Cobros (los chips de la pantalla).
enum CobrosFiltro { todas, mora, gracia, parciales, hoy, proxima, verTodo }

/// Centinela del filtro de cobrador para "Sin cobrador" (P3b) → mapea a
/// `cobrador_id IS NULL`.
const kSinCobradorFiltro = '__sin_cobrador__';

/// (SQL, params) del filtro de estado, sobre el alias `cu` de cuotas.
///
/// Día de HOY en hora de Nicaragua (UTC-6, sin DST): `date('now','-6 hours')`.
/// NUNCA `date('now')` pelado (es UTC → corre 1 día de noche). Norma general de
/// la app para lógica de límite de día — ver CLAUDE.md.
(String, List<Object?>) cobrosEstadoFilterSql(
  CobrosFiltro filtro, {
  required int diasGracia,
  required int diasVisibles,
}) {
  final rangoFilter = filtro == CobrosFiltro.todas
      ? "AND cu.estado IN ('pendiente','parcial') "
          "AND date(cu.fecha_vencimiento) <= date('now', '-6 hours', '+$diasVisibles days')"
      : '';
  return switch (filtro) {
    CobrosFiltro.todas => (rangoFilter, <Object?>[]),
    CobrosFiltro.mora => (
        "AND cu.estado IN ('pendiente','parcial') "
            "AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')",
        <Object?>[diasGracia],
      ),
    CobrosFiltro.gracia => (
        "AND cu.estado IN ('pendiente','parcial') "
            "AND date(cu.fecha_vencimiento) < date('now', '-6 hours') "
            "AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now', '-6 hours')",
        <Object?>[diasGracia],
      ),
    CobrosFiltro.parciales => ("AND cu.estado = 'parcial'", <Object?>[]),
    CobrosFiltro.hoy => (
        "AND cu.estado IN ('pendiente','parcial') "
            "AND date(cu.fecha_vencimiento) = date('now', '-6 hours')",
        <Object?>[],
      ),
    // Próximas: vencen DESPUÉS de hoy pero dentro del rango visible.
    CobrosFiltro.proxima => (
        "AND cu.estado IN ('pendiente','parcial') "
            "AND date(cu.fecha_vencimiento) > date('now', '-6 hours') "
            "AND date(cu.fecha_vencimiento) <= date('now', '-6 hours', '+$diasVisibles days')",
        <Object?>[],
      ),
    // Ver todo (solo admin): TODO lo pendiente, SIN el límite de rango.
    CobrosFiltro.verTodo =>
      ("AND cu.estado IN ('pendiente','parcial')", <Object?>[]),
  };
}

/// (SQL, params) del filtro admin (cobrador / zona), sobre el alias `c` de
/// clientes. En la vista del cobrador siempre es vacío.
/// Multi-selección: `null` = sin filtrar (todos); un `Set` = solo esos. El
/// centinela `kSinCobradorFiltro` mapea a `cobrador_id IS NULL`. Un set VACÍO
/// (todo deseleccionado) = **sin filtrar** (nunca produce lista vacía por
/// accidente — rework 2026-06-21; la UI además coacciona vacío→null).
(String, List<Object?>) cobrosAdminFilterSql({
  Set<String>? cobradorIds,
  Set<String>? comunidadIds,
}) {
  var sql = '';
  final params = <Object?>[];
  if (cobradorIds != null && cobradorIds.isNotEmpty) {
    final sinCobrador = cobradorIds.contains(kSinCobradorFiltro);
    final reales = cobradorIds.where((id) => id != kSinCobradorFiltro).toList();
    final conds = <String>[];
    if (sinCobrador) conds.add('c.cobrador_id IS NULL');
    if (reales.isNotEmpty) {
      conds.add('c.cobrador_id IN (${List.filled(reales.length, '?').join(', ')})');
      params.addAll(reales);
    }
    if (conds.isNotEmpty) sql += 'AND (${conds.join(' OR ')}) ';
  }
  if (comunidadIds != null && comunidadIds.isNotEmpty) {
    sql +=
        'AND c.comunidad_id IN (${List.filled(comunidadIds.length, '?').join(', ')}) ';
    params.addAll(comunidadIds);
  }
  return (sql, params);
}

/// Resumen por CLIENTE (Opción 2): una fila por cliente con el total cobrable
/// AHORA (Σ saldo canónico de la cuota más antigua de CADA contrato que matchea
/// el filtro), nº de líneas, vencimiento más urgente y el id de la cuota más
/// vieja del cliente (para el "Pagar" colapsado).
///
/// Cómo: el CTE `lineas` usa `ROW_NUMBER()` particionado por contrato (cargos
/// manuales sueltos = su propia partición) ordenado por antigüedad → `rn=1` es
/// la cuota más vieja de cada contrato. El CTE `mas_viejas` toma esas (`rn=1`) y
/// con un segundo `ROW_NUMBER()` por CLIENTE marca la global más vieja
/// (`rn_cli=1`, desempate explícito por `periodo`) → `oldest_cuota_id` es
/// DETERMINISTA (no depende del truco de columna desnuda junto a MIN, que en
/// empate de vencimiento entre contratos elegiría una fila arbitraria). El saldo
/// usa la fórmula canónica `monto + cargos_neto - pagado` clampeada a ≥0
/// (idéntica a `_saldoCanonico`/cobro/recibo/mapa → consistencia #10).
///
/// Performance: hace SCAN de cuotas + sort en temp (la partición es sobre una
/// EXPRESIÓN, no matchea el índice). Aceptable: dataset offline por-tenant
/// (cientos/bajos miles), con debounce, sólo al cambiar filtro/expandir.
(String, List<Object?>) cobrosResumenQuery({
  required CobrosFiltro filtro,
  required int diasGracia,
  required int diasVisibles,
  Set<String>? cobradorIds,
  Set<String>? comunidadIds,
}) {
  final (estadoSql, estadoParams) = cobrosEstadoFilterSql(filtro,
      diasGracia: diasGracia, diasVisibles: diasVisibles);
  final (adminSql, adminParams) =
      cobrosAdminFilterSql(cobradorIds: cobradorIds, comunidadIds: comunidadIds);
  final sql = '''
    WITH lineas AS (
      SELECT cu.id AS cuota_id, cu.cliente_id AS cliente_id,
             cu.fecha_vencimiento AS fecha_vencimiento, cu.periodo AS periodo,
             max(0.0, cu.monto + COALESCE(cu.cargos_neto, 0)
                      - COALESCE(cu.monto_pagado, 0)) AS saldo,
             ROW_NUMBER() OVER (
               PARTITION BY COALESCE(cu.contrato_id, 'm:' || cu.id)
               ORDER BY cu.fecha_vencimiento ASC, cu.periodo ASC
             ) AS rn
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN contratos ct ON ct.id = cu.contrato_id
       WHERE c.activo = 1
         AND COALESCE(ct.estado, 'activo') = 'activo'
         $estadoSql
         $adminSql
    ),
    mas_viejas AS (
      SELECT cuota_id, cliente_id, fecha_vencimiento, saldo,
             ROW_NUMBER() OVER (
               PARTITION BY cliente_id
               ORDER BY fecha_vencimiento ASC, periodo ASC
             ) AS rn_cli
        FROM lineas
       WHERE rn = 1
    ),
    -- Deuda VENCIDA del cliente: TODAS sus cuotas ya pasadas de fecha (no solo
    -- la más vieja por contrato) → para avisar "debe más de lo que ves cobrable
    -- ahora". Día local Nicaragua (UTC-6), igual que el resto.
    venc AS (
      SELECT cliente_id,
             COUNT(*) AS vencidas_count,
             SUM(saldo) AS vencido_total
        FROM lineas
       WHERE date(fecha_vencimiento) < date('now', '-6 hours')
       GROUP BY cliente_id
    )
    SELECT l.cliente_id AS cliente_id,
           c.codigo AS cliente_codigo, c.nombre AS cliente_nombre,
           c.cedula AS cliente_cedula, c.telefono AS cliente_telefono,
           c.cobrador_id AS cobrador_id,
           co.nombre AS comunidad, mu.nombre AS municipio,
           SUM(l.saldo) AS total_cobrable,
           COUNT(*) AS n_lineas,
           MIN(l.fecha_vencimiento) AS peor_vence,
           MAX(CASE WHEN l.rn_cli = 1 THEN l.cuota_id END) AS oldest_cuota_id,
           MAX(COALESCE(v.vencidas_count, 0)) AS vencidas_count,
           MAX(COALESCE(v.vencido_total, 0)) AS vencido_total,
           (SELECT GROUP_CONCAT(e.nombre || char(31) || e.color || char(31) || e.icono, char(30))
              FROM cliente_etiquetas ce JOIN etiquetas e ON e.id = ce.etiqueta_id
             WHERE ce.cliente_id = l.cliente_id) AS etiquetas_concat
      FROM mas_viejas l
      JOIN clientes c ON c.id = l.cliente_id
 LEFT JOIN comunidades co ON co.id = c.comunidad_id
 LEFT JOIN municipios mu ON mu.id = co.municipio_id
 LEFT JOIN venc v ON v.cliente_id = l.cliente_id
     GROUP BY l.cliente_id
     ORDER BY MIN(l.fecha_vencimiento) ASC, c.nombre
  ''';
  return (sql, [...estadoParams, ...adminParams]);
}

/// Lista PLANA (Feature 1, 2026-06-20): UNA fila por CONTRATO = su cuota más
/// antigua que matchea el filtro (no una fila-resumen por cliente). Reusa el
/// MISMO CTE `lineas` que `cobrosResumenQuery` (rn=1 = cuota más vieja por
/// contrato, oldest-first) → el saldo de cada fila es el canónico
/// (`monto + cargos_neto - pagado` clamp ≥0) y la suma de las filas de un
/// cliente da IDÉNTICA al `total_cobrable` del resumen (consistencia #10).
///
/// Trae todo lo que la fila muestra inline sin desplegar: plan, mes (periodo +
/// dia_pago), fecha, estado, saldo, y `dia_pago`/`precio_mensual`/`contrato_id`
/// para "Cambiar fecha". Además, por grupo (contrato o cargo manual suelto):
/// `grupo_count` (cuántas cuotas matchean) y `grupo_saldo` (Σ saldos del grupo)
/// para avisar "debe N cuotas · C$X" cuando el contrato arrastra más de una.
(String, List<Object?>) cobrosFlatQuery({
  required CobrosFiltro filtro,
  required int diasGracia,
  required int diasVisibles,
  Set<String>? cobradorIds,
  Set<String>? comunidadIds,
}) {
  final (estadoSql, estadoParams) = cobrosEstadoFilterSql(filtro,
      diasGracia: diasGracia, diasVisibles: diasVisibles);
  final (adminSql, adminParams) =
      cobrosAdminFilterSql(cobradorIds: cobradorIds, comunidadIds: comunidadIds);
  final sql = '''
    WITH lineas AS (
      SELECT cu.id AS cuota_id, cu.cliente_id AS cliente_id,
             cu.contrato_id AS contrato_id,
             COALESCE(cu.contrato_id, 'm:' || cu.id) AS grupo_key,
             cu.fecha_vencimiento AS fecha_vencimiento, cu.periodo AS periodo,
             cu.estado AS estado, cu.monto AS monto,
             COALESCE(cu.cargos_neto, 0) AS cargos_neto,
             COALESCE(cu.monto_pagado, 0) AS monto_pagado,
             cu.tipo_cargo_manual AS tipo_cargo_manual,
             cu.descripcion AS descripcion,
             max(0.0, cu.monto + COALESCE(cu.cargos_neto, 0)
                      - COALESCE(cu.monto_pagado, 0)) AS saldo,
             ROW_NUMBER() OVER (
               PARTITION BY COALESCE(cu.contrato_id, 'm:' || cu.id)
               ORDER BY cu.fecha_vencimiento ASC, cu.periodo ASC
             ) AS rn
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN contratos ct ON ct.id = cu.contrato_id
       WHERE c.activo = 1
         AND COALESCE(ct.estado, 'activo') = 'activo'
         $estadoSql
         $adminSql
    ),
    -- Agregado por grupo (contrato o cargo manual suelto) para el aviso
    -- "debe N cuotas": cuántas matchean y su saldo total.
    grupos AS (
      SELECT grupo_key, COUNT(*) AS grupo_count, SUM(saldo) AS grupo_saldo
        FROM lineas GROUP BY grupo_key
    )
    SELECT l.cuota_id AS id, l.cliente_id AS cliente_id,
           l.contrato_id AS contrato_id,
           l.fecha_vencimiento AS fecha_vencimiento, l.periodo AS periodo,
           l.estado AS estado, l.monto AS monto, l.cargos_neto AS cargos_neto,
           l.monto_pagado AS monto_pagado,
           l.tipo_cargo_manual AS tipo_cargo_manual,
           l.descripcion AS descripcion, l.saldo AS saldo,
           g.grupo_count AS grupo_count, g.grupo_saldo AS grupo_saldo,
           c.codigo AS cliente_codigo, c.nombre AS cliente_nombre,
           c.cedula AS cliente_cedula, c.telefono AS cliente_telefono,
           c.cobrador_id AS cobrador_id,
           co.nombre AS comunidad, mu.nombre AS municipio,
           p.nombre AS plan_nombre, p.precio_mensual AS precio_mensual,
           ct.dia_pago AS dia_pago,
           (SELECT GROUP_CONCAT(ctc.codigo, char(30))
              FROM contratos ctc
             WHERE ctc.cliente_id = l.cliente_id
               AND ctc.codigo IS NOT NULL) AS contrato_codigos,
           (SELECT GROUP_CONCAT(e.nombre || char(31) || e.color || char(31) || e.icono, char(30))
              FROM cliente_etiquetas ce JOIN etiquetas e ON e.id = ce.etiqueta_id
             WHERE ce.cliente_id = l.cliente_id) AS etiquetas_concat
      FROM lineas l
      JOIN grupos g ON g.grupo_key = l.grupo_key
      JOIN clientes c ON c.id = l.cliente_id
 LEFT JOIN contratos ct ON ct.id = l.contrato_id
 LEFT JOIN planes p ON p.id = ct.plan_id
 LEFT JOIN comunidades co ON co.id = c.comunidad_id
 LEFT JOIN municipios mu ON mu.id = co.municipio_id
     WHERE l.rn = 1
     ORDER BY l.fecha_vencimiento ASC, c.nombre
  ''';
  return (sql, [...estadoParams, ...adminParams]);
}

/// Lista de deuda FUERA DE RUTA (recuperación, toggle "Ver fuera de ruta",
/// 2026-07-01): UNA fila por CONTRATO con estado `cancelado` o `suspendido` =
/// su cuota más antigua pendiente/parcial. Misma forma de salida que
/// [cobrosFlatQuery] (el row widget `_CobroFilaCard` la reusa tal cual) MÁS la
/// columna `estado_contrato` — que es a la vez el badge (Cancelado/Suspendido)
/// y el discriminador de sección (las filas de la lista activa la traen NULL).
///
/// A diferencia de la lista activa, NO aplica los chips de fecha (mora/gracia/
/// hoy/próximas): la recuperación muestra TODA la deuda viva del contrato
/// (pendiente/parcial), oldest-first por contrato — es cobro de una deuda que
/// ya no está en el ciclo activo, no una ventana de vencimiento. Respeta el
/// filtro admin (cobrador/zona). Los cargos manuales (sin contrato) NO entran
/// acá (no tienen estado de contrato → viven en la lista activa, sin doble
/// conteo). El saldo usa la MISMA fórmula canónica clamp ≥0 (consistencia #10).
(String, List<Object?>) cobrosFueraDeRutaQuery({
  Set<String>? cobradorIds,
  Set<String>? comunidadIds,
}) {
  final (adminSql, adminParams) =
      cobrosAdminFilterSql(cobradorIds: cobradorIds, comunidadIds: comunidadIds);
  final sql = '''
    WITH lineas AS (
      SELECT cu.id AS cuota_id, cu.cliente_id AS cliente_id,
             cu.contrato_id AS contrato_id,
             cu.fecha_vencimiento AS fecha_vencimiento, cu.periodo AS periodo,
             cu.estado AS estado, cu.monto AS monto,
             COALESCE(cu.cargos_neto, 0) AS cargos_neto,
             COALESCE(cu.monto_pagado, 0) AS monto_pagado,
             cu.tipo_cargo_manual AS tipo_cargo_manual,
             cu.descripcion AS descripcion,
             ct.estado AS estado_contrato,
             max(0.0, cu.monto + COALESCE(cu.cargos_neto, 0)
                      - COALESCE(cu.monto_pagado, 0)) AS saldo,
             ROW_NUMBER() OVER (
               PARTITION BY cu.contrato_id
               ORDER BY cu.fecha_vencimiento ASC, cu.periodo ASC
             ) AS rn
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
        JOIN contratos ct ON ct.id = cu.contrato_id
       WHERE c.activo = 1
         AND ct.estado IN ('cancelado', 'suspendido')
         AND cu.estado IN ('pendiente', 'parcial')
         $adminSql
    ),
    grupos AS (
      SELECT contrato_id, COUNT(*) AS grupo_count, SUM(saldo) AS grupo_saldo
        FROM lineas GROUP BY contrato_id
    )
    SELECT l.cuota_id AS id, l.cliente_id AS cliente_id,
           l.contrato_id AS contrato_id,
           l.fecha_vencimiento AS fecha_vencimiento, l.periodo AS periodo,
           l.estado AS estado, l.monto AS monto, l.cargos_neto AS cargos_neto,
           l.monto_pagado AS monto_pagado,
           l.tipo_cargo_manual AS tipo_cargo_manual,
           l.descripcion AS descripcion, l.saldo AS saldo,
           l.estado_contrato AS estado_contrato,
           g.grupo_count AS grupo_count, g.grupo_saldo AS grupo_saldo,
           c.codigo AS cliente_codigo, c.nombre AS cliente_nombre,
           c.cedula AS cliente_cedula, c.telefono AS cliente_telefono,
           c.cobrador_id AS cobrador_id,
           co.nombre AS comunidad, mu.nombre AS municipio,
           p.nombre AS plan_nombre, p.precio_mensual AS precio_mensual,
           ct.dia_pago AS dia_pago,
           (SELECT GROUP_CONCAT(ctc.codigo, char(30))
              FROM contratos ctc
             WHERE ctc.cliente_id = l.cliente_id
               AND ctc.codigo IS NOT NULL) AS contrato_codigos,
           (SELECT GROUP_CONCAT(e.nombre || char(31) || e.color || char(31) || e.icono, char(30))
              FROM cliente_etiquetas ce JOIN etiquetas e ON e.id = ce.etiqueta_id
             WHERE ce.cliente_id = l.cliente_id) AS etiquetas_concat
      FROM lineas l
      JOIN grupos g ON g.contrato_id = l.contrato_id
      JOIN clientes c ON c.id = l.cliente_id
      JOIN contratos ct ON ct.id = l.contrato_id
 LEFT JOIN planes p ON p.id = ct.plan_id
 LEFT JOIN comunidades co ON co.id = c.comunidad_id
 LEFT JOIN municipios mu ON mu.id = co.municipio_id
     WHERE l.rn = 1
     ORDER BY l.fecha_vencimiento ASC, c.nombre
  ''';
  return (sql, adminParams);
}

/// Detalle de un cliente al expandir su tarjeta: sus cuotas que matchean el
/// filtro (mismo alias `cu`), para agrupar client-side por contrato (cuota más
/// antigua) y renderizar un renglón por contrato. NO aplica el filtro admin: el
/// cliente ya pasó ese filtro en el resumen (es por cliente, no por cuota).
(String, List<Object?>) cobrosDetalleQuery(
  String clienteId, {
  required CobrosFiltro filtro,
  required int diasGracia,
  required int diasVisibles,
}) {
  final (estadoSql, estadoParams) = cobrosEstadoFilterSql(filtro,
      diasGracia: diasGracia, diasVisibles: diasVisibles);
  final sql = '''
    SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
           cu.periodo, cu.estado, cu.contrato_id,
           cu.descripcion, cu.tipo_cargo_manual,
           COALESCE(cu.cargos_neto, 0) AS cargos_neto,
           c.id AS cliente_id, c.nombre AS cliente_nombre,
           p.nombre AS plan_nombre, p.precio_mensual, ct.dia_pago
      FROM cuotas cu
      JOIN clientes c ON c.id = cu.cliente_id
 LEFT JOIN contratos ct ON ct.id = cu.contrato_id
 LEFT JOIN planes p ON p.id = ct.plan_id
     WHERE cu.cliente_id = ?
       AND COALESCE(ct.estado, 'activo') = 'activo'
       $estadoSql
     ORDER BY cu.fecha_vencimiento ASC, cu.periodo ASC
  ''';
  return (sql, [clienteId, ...estadoParams]);
}
