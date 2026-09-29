/// SQL del Resumen del dashboard, fuera del widget.
///
/// Por qué vive acá y no inline en `tendencia_cobros_card.dart`: así el test
/// (`test/features/admin/dashboard/dashboard_numeros_test.dart`) corre
/// EXACTAMENTE la consulta de producción contra el SQLite real de PowerSync, y
/// no una copia que se despegue con el tiempo. Es el mismo patrón que
/// `features/cuotas/cobros_query.dart`.
///
/// Todas las consultas comparten dos definiciones que conviene tener a mano:
///
///  - UNIVERSO DEL PERÍODO: una cuota entra por su `fecha_vencimiento`, nunca
///    por la fecha del pago. Cobrar hoy una cuota de junio no mueve ningún
///    número del ciclo de agosto.
///  - PAGO VIVO: `anulado = 0 AND en_revision = 0`. Las dos condiciones. Es el
///    mismo predicado que usa el trigger del server para mantener
///    `cuotas.monto_pagado`, así que el saldo canónico y la suma de pagos
///    hablan de las mismas filas.
library;

/// Una consulta lista para `db.watch` / `db.getAll`: el SQL y sus parámetros
/// posicionales en orden. Van juntos a propósito — separarlos es exactamente
/// como se corren los parámetros de lugar sin que nada falle a la vista.
class ConsultaSql {
  const ConsultaSql(this.sql, this.parametros);

  final String sql;
  final List<Object?> parametros;
}

/// Saldo canónico de una cuota (invariante de dinero #10), clampeado a 0 para
/// que una cuota sobre-cubierta no le reste deuda a las demás.
const String saldoCanonico =
    'max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)';

/// Igual que [saldoCanonico] pero sobre el alias `cu2` de las subconsultas.
const String saldoCanonico2 =
    'max(cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0), 0)';

const String _pagoVivo =
    'COALESCE(p2.anulado, 0) = 0 AND COALESCE(p2.en_revision, 0) = 0';

/// El MISMO predicado con el alias `p`. Invariante #7: pago vivo son las DOS
/// condiciones, no solo `anulado`.
const String _pagoVivoP =
    'COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0';

/// Resumen de la tarjeta "Cobros del mes".
///
/// El universo son las cuotas que VENCEN dentro del período. `rec_*` cuenta
/// exclusivamente pagos aplicados a esas mismas cuotas.
ConsultaSql resumenCobros({
  required String inicio,
  required String fin,
  required int diasGracia,
}) {
  const facturado = 'cu.monto + COALESCE(cu.cargos_neto, 0)';
  const entro = 'COALESCE(cu.monto_pagado, 0)';
  const saldo = '$facturado - $entro';
  const sql = '''
      SELECT
        -- "Usuarios" cuenta PERSONAS. Y esto se decidio DOS VECES, en
        -- sentidos opuestos: leer la historia antes de volver a darla vuelta.
        --
        -- 2026-08-24: contaba personas, el dueño vio "mas cuotas que usuarios"
        -- y reporto que no le cerraba. Se cambio a contar CONTRATOS para que
        -- las dos columnas cuadraran, y el 2026-08-27 se le cambio la etiqueta
        -- a "Servicios" para que dijera lo que contaba. Esa etiqueta se perdio
        -- al volver al Resumen anterior en v0.37.1.
        --
        -- 2026-09-02: el dueño del tenant explico PARA QUE la usa —"si veo mas
        -- cuotas que usuarios, reviso si por accidente alguien tiene dos
        -- contratos"— y contando contratos eso es IMPOSIBLE de ver: da 1:1
        -- siempre, por construccion. Medido en los tres tenants antes de
        -- cambiarlo: con contratos, 4.414 = 4.414 en Mairena; contando
        -- personas, 4.409 contra 4.414 = cinco clientes con dos servicios
        -- (CATV + COMBO), todos legitimos. En Telenet la diferencia es 1 y en
        -- el Test Tenant 4.
        --
        -- O sea: la diferencia NO es un descuadre, es EL DATO. Las dos
        -- columnas no tienen por que cuadrar, y cuando no cuadran es que hay
        -- alguien con mas de un contrato — que es justo lo que se quiere ver.
        --
        -- Sin COALESCE, a diferencia de la version de contratos: `cliente_id`
        -- es NOT NULL en las 61.059 cuotas vivas de produccion (una cuota
        -- siempre pertenece a alguien, incluso un cargo manual, que tiene
        -- `contrato_id` NULL pero cliente si). Verificado antes de sacarlo.
        --
        -- El WHERE es IDENTICO al de `meta_c`, y eso no es casualidad: es lo
        -- que garantiza que el conteo cierre contra el desglose del Excel, que
        -- recorre exactamente ese mismo universo.
        COUNT(DISTINCT cu.cliente_id) AS meta_u,
        COUNT(*) AS meta_c,
        COALESCE(SUM($facturado), 0) AS meta_m,
        -- PARTICIÓN por estado de cobro: cada cuota cae en UNO solo de los tres
        -- grupos, así las columnas SUMAN el total. Antes "Recuperado — Cuotas"
        -- contaba las que recibieron ALGÚN pago y "Por recuperar" las que
        -- quedaban con saldo: la cuota con abono parcial caía en las dos y
        -- 8 + 8 daba 16 sobre 15.
        --
        -- Hacen falta DOS columnas de plata porque la cuota a medias tiene la
        -- suya partida: parte entró y parte falta. Con una sola no hay forma de
        -- que cierre — poner "7 cuotas" al lado de C\$5.800 volvería a mentir,
        -- porque esas 7 solo facturan C\$4.700.
        SUM(CASE WHEN $saldo <= 0.009 THEN 1 ELSE 0 END) AS comp_c,
        COALESCE(SUM(CASE WHEN $saldo <= 0.009 THEN $facturado ELSE 0 END), 0) AS comp_f,
        COALESCE(SUM(CASE WHEN $saldo <= 0.009 THEN $entro ELSE 0 END), 0) AS comp_e,
        SUM(CASE WHEN $saldo > 0.009 AND $entro > 0.009 THEN 1 ELSE 0 END) AS med_c,
        COALESCE(SUM(CASE WHEN $saldo > 0.009 AND $entro > 0.009 THEN $facturado ELSE 0 END), 0) AS med_f,
        COALESCE(SUM(CASE WHEN $saldo > 0.009 AND $entro > 0.009 THEN $entro ELSE 0 END), 0) AS med_e,
        COALESCE(SUM(CASE WHEN $saldo > 0.009 AND $entro > 0.009 THEN $saldo ELSE 0 END), 0) AS med_s,
        SUM(CASE WHEN $saldo > 0.009 AND $entro <= 0.009 THEN 1 ELSE 0 END) AS nada_c,
        COALESCE(SUM(CASE WHEN $saldo > 0.009 AND $entro <= 0.009 THEN $facturado ELSE 0 END), 0) AS nada_f,
        -- Mismo universo EXACTO que `rec_c` (la de abajo), solo cambia que
        -- cuenta personas en vez de cuotas: por eso las dos columnas de la
        -- fila "Recuperado" se pueden comparar entre si y contra el Excel.
        (SELECT COUNT(DISTINCT cu2.cliente_id) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE $_pagoVivo
             AND cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
        ) AS rec_u,
        (SELECT COUNT(DISTINCT p2.cuota_id) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE $_pagoVivo
             AND cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
        ) AS rec_c,
        (SELECT COALESCE(SUM(p2.monto_cordobas), 0) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE $_pagoVivo
             AND cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
        ) AS rec_m,
        -- Porción de rec_m cobrada DESPUÉS de la gracia. Es EXACTAMENTE el
        -- "Recuperado" de la tarjeta de Mora (mismo universo + el corte de
        -- gracia), o sea un SUBCONJUNTO de rec_m. Se muestra como sub-fila para
        -- que no se pueda volver a sumar aparte (reclamo del dueño 2026-08-08).
        (SELECT COALESCE(SUM(p2.monto_cordobas), 0) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE $_pagoVivo
             AND cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < p2.fecha_cobro
        ) AS rec_m_tarde,
        -- Lo que FALTA cobrar, CONSULTADO (no por resta): el cliente que pagó
        -- una cuota del ciclo y debe otra tiene que contar en las dos filas, y
        -- el monto tiene que salir del mismo universo que sus conteos.
        (SELECT COUNT(DISTINCT cu2.cliente_id) FROM cuotas cu2
           WHERE cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
             AND (cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0)) > 0.009
        ) AS porrec_u,
        (SELECT COUNT(*) FROM cuotas cu2
           WHERE cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
             AND (cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0)) > 0.009
        ) AS porrec_c,
        (SELECT COALESCE(SUM($saldoCanonico2), 0) FROM cuotas cu2
           WHERE cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
        ) AS porrec_m
      FROM cuotas cu
      WHERE cu.estado != 'anulada'
        AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
    ''';
  return ConsultaSql(sql, [
    inicio, fin, // rec_u
    inicio, fin, // rec_c
    inicio, fin, // rec_m
    inicio, fin, diasGracia, // rec_m_tarde
    inicio, fin, // porrec_u
    inicio, fin, // porrec_c
    inicio, fin, // porrec_m
    inicio, fin, // WHERE externo (meta_u / meta_c / meta_m)
  ]);
}

/// Los otros DOS cortes del mismo 100% del ciclo: por ORIGEN de la cuota
/// (contrato vs servicio) y por MORA (cuándo entró o dejó de entrar la plata).
///
/// Van en su propia consulta y no adentro de [resumenCobros] a propósito: ésa ya
/// tiene 10 subconsultas y 38 parámetros posicionales, y meterle un `WITH` la
/// obligaba a reordenar todos. Acá el orden de los `?` es corto y verificable.
///
/// **Los tres cortes cierran en los MISMOS totales** (facturado / entró / falta)
/// porque los tres reparten las mismas cuotas del ciclo:
///  - por origen: `contrato_id IS NULL` separa la cuota de servicio (cobro
///    puntual y, cuando se habilite el módulo, el cobro nacido de un ticket —
///    ver ARQUITECTURA §3.5 (6)) de la mensualidad.
///  - por mora: `util` está CLAMPEADO a lo facturado (`min`), que es lo que
///    vuelve la identidad `a_tiempo + cobrado + impago + en_fecha = facturado`
///    cierta para cualquier dato. Sin ese clamp, una cuota sobrepagada hacía que
///    el ciclo mostrara más de 100% (audit 2026-08-13).
///
/// [hoy] es el día de corte (ISO, hora de Nicaragua) y tiene que ser EL MISMO
/// que se le pasa a [resumenMora] y a los export — ver la nota de [detalleMora].
ConsultaSql cortesDelCiclo({
  required String inicio,
  required String fin,
  required int diasGracia,
  required String hoy,
}) {
  const sql = '''
      WITH c AS (
        SELECT cu.contrato_id AS contrato_id,
               cu.estado AS estado,
               cu.monto + COALESCE(cu.cargos_neto, 0) AS fact,
               min(COALESCE(cu.monto_pagado, 0),
                   cu.monto + COALESCE(cu.cargos_neto, 0)) AS util,
               max(cu.monto + COALESCE(cu.cargos_neto, 0)
                   - COALESCE(cu.monto_pagado, 0), 0) AS saldo,
               (date(cu.fecha_vencimiento, '+' || ? || ' days') < ?) AS vencida,
               -- Lo que ENTRO a la cuota. Se usa para partir la mora de "Por
               -- recuperar" entre las que ya recibieron algo y las que no: es
               -- el MISMO criterio que `resumenCobros` usa para dibujar esas
               -- dos filas (`med_c` / `nada_c`), asi que los conteos se pueden
               -- confrontar renglon contra renglon.
               COALESCE(cu.monto_pagado, 0) AS entro,
               (SELECT COALESCE(SUM(p.monto_cordobas), 0) FROM pagos p
                 WHERE p.cuota_id = cu.id
                   AND COALESCE(p.anulado, 0) = 0
                   AND COALESCE(p.en_revision, 0) = 0
                   AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                       < p.fecha_cobro
                   AND date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
               ) AS tarde
          FROM cuotas cu
         WHERE cu.estado != 'anulada'
           AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
      ),
      b AS (
        SELECT contrato_id, fact, util, saldo, entro,
               -- Una cuota esta EN MORA si cruzo la gracia debiendo, o si la
               -- saldo con un pago posterior a la gracia. Mismo universo que
               -- `resumenMora`.
               (vencida = 1
                AND (estado IN ('pendiente','parcial')
                     OR max(min(tarde, util), 0) > 0.009)) AS en_mora,
               max(min(tarde, util), 0) AS cobrado_tarde
          FROM c
      )
      SELECT
        SUM(CASE WHEN contrato_id IS NOT NULL THEN 1 ELSE 0 END) AS ctr_c,
        COALESCE(SUM(CASE WHEN contrato_id IS NOT NULL THEN fact ELSE 0 END), 0) AS ctr_f,
        COALESCE(SUM(CASE WHEN contrato_id IS NOT NULL THEN util ELSE 0 END), 0) AS ctr_e,
        COALESCE(SUM(CASE WHEN contrato_id IS NOT NULL THEN saldo ELSE 0 END), 0) AS ctr_s,
        SUM(CASE WHEN contrato_id IS NULL THEN 1 ELSE 0 END) AS srv_c,
        COALESCE(SUM(CASE WHEN contrato_id IS NULL THEN fact ELSE 0 END), 0) AS srv_f,
        COALESCE(SUM(CASE WHEN contrato_id IS NULL THEN util ELSE 0 END), 0) AS srv_e,
        COALESCE(SUM(CASE WHEN contrato_id IS NULL THEN saldo ELSE 0 END), 0) AS srv_s,
        -- El corte por mora reparte CUOTAS, no cordobas: cada cuota cae en UNA
        -- de las cuatro por su estado final, asi que los conteos suman las del
        -- ciclo y responden "de las 15, cuantas se cobraron estando en mora y
        -- cuantas siguen debiendo". Las tres columnas de plata cierran igual.
        SUM(CASE WHEN saldo <= 0.009 AND NOT en_mora THEN 1 ELSE 0 END) AS at_c,
        COALESCE(SUM(CASE WHEN saldo <= 0.009 AND NOT en_mora THEN fact ELSE 0 END), 0) AS at_f,
        SUM(CASE WHEN saldo <= 0.009 AND en_mora THEN 1 ELSE 0 END) AS cm_c,
        COALESCE(SUM(CASE WHEN saldo <= 0.009 AND en_mora THEN fact ELSE 0 END), 0) AS cm_f,
        SUM(CASE WHEN saldo > 0.009 AND en_mora THEN 1 ELSE 0 END) AS sm_c,
        COALESCE(SUM(CASE WHEN saldo > 0.009 AND en_mora THEN fact ELSE 0 END), 0) AS sm_f,
        COALESCE(SUM(CASE WHEN saldo > 0.009 AND en_mora THEN util ELSE 0 END), 0) AS sm_e,
        COALESCE(SUM(CASE WHEN saldo > 0.009 AND en_mora THEN saldo ELSE 0 END), 0) AS sm_s,
        SUM(CASE WHEN saldo > 0.009 AND NOT en_mora THEN 1 ELSE 0 END) AS ef_c,
        COALESCE(SUM(CASE WHEN saldo > 0.009 AND NOT en_mora THEN fact ELSE 0 END), 0) AS ef_f,
        COALESCE(SUM(CASE WHEN saldo > 0.009 AND NOT en_mora THEN util ELSE 0 END), 0) AS ef_e,
        COALESCE(SUM(CASE WHEN saldo > 0.009 AND NOT en_mora THEN saldo ELSE 0 END), 0) AS ef_s,
        -- Lo que la tarjeta de Mora llama "Recuperado": pagos posteriores a la
        -- gracia. Es la suma de la curva roja y le da su techo al grafico.
        COALESCE(SUM(cobrado_tarde), 0) AS m_cobrado,
        -- LA MORA DE "POR RECUPERAR", PARTIDA EN SUS DOS FILAS (2026-09-01).
        --
        -- `sm_c` ya decia cuantas siguen en mora; esto dice cuantas de esas
        -- tienen un abono y cuantas ni eso, para poder colgarlas DENTRO de
        -- "con abono parcial" y "sin ningun pago" en vez de al lado. Por
        -- construccion `sm_med_c + sm_nada_c = sm_c` y lo mismo con el saldo.
        --
        -- El monto es el SALDO —lo que todavia se debe—, igual que la fila
        -- madre. Poner el facturado la haria leer como si fuera plata distinta.
        SUM(CASE WHEN saldo > 0.009 AND en_mora AND entro > 0.009
                 THEN 1 ELSE 0 END) AS sm_med_c,
        COALESCE(SUM(CASE WHEN saldo > 0.009 AND en_mora AND entro > 0.009
                          THEN saldo ELSE 0 END), 0) AS sm_med_s,
        SUM(CASE WHEN saldo > 0.009 AND en_mora AND entro <= 0.009
                 THEN 1 ELSE 0 END) AS sm_nada_c,
        COALESCE(SUM(CASE WHEN saldo > 0.009 AND en_mora AND entro <= 0.009
                          THEN saldo ELSE 0 END), 0) AS sm_nada_s
      FROM b
    ''';
  final g = diasGracia;
  return ConsultaSql(sql, [
    g, hoy, // vencida
    g, g, hoy, // tarde
    inicio, fin, // la ventana del ciclo
  ]);
}

/// Quién es la cuota: las columnas que no hablan de plata.
///
/// `contrato` es el CÓDIGO del contrato, no su uuid: es lo que sirve para
/// buscarlo en la app. Los cobros puntuales no cuelgan de ningún contrato —por
/// eso no aparecen en su pantalla— y quedan en NULL.
const String _colsIdentidad = '''
        -- `cliente_id` NO sale como columna del Excel: `_fila` arma por clave
        -- y solo escribe las que lista. Viaja para que el export pueda contar
        -- PERSONAS con el mismo criterio que la tarjeta (`COUNT(DISTINCT
        -- cliente_id)`). Se podría contar por `cliente_codigo` —hoy es único
        -- en los tres tenants, verificado— pero eso apoya el conteo en un dato
        -- que un ISP puede repetir sin saberlo.
        cu.cliente_id AS cliente_id,
        c.codigo AS cliente_codigo,
        c.nombre AS cliente_nombre,
        -- Si el contrato no tiene codigo cargado, va un fragmento de su id:
        -- sin esto quedaba vacio, indistinguible de un cobro puntual, y en un
        -- tenant sin codigos TODAS las filas parecian cargos manuales.
        CASE WHEN cu.contrato_id IS NULL THEN NULL
             ELSE COALESCE(NULLIF(TRIM(ct.codigo), ''), substr(ct.id, 1, 8))
        END AS contrato,
        CASE WHEN cu.contrato_id IS NULL THEN 'cobro puntual'
             ELSE 'mensualidad' END AS tipo,
        cu.fecha_vencimiento AS vence''';

/// El cierre de cada fila, igual en los dos detalles.
///
/// **`fecha_cobro` se llamaba `ultimo_pago`** hasta el 2026-09-01. El nombre
/// venía de que una cuota PUEDE recibir varios abonos y entonces habría que
/// quedarse con el último. Medido contra producción ese día: de **32.609
/// cuotas cobradas** en los tres tenants, **ninguna** tiene más de un pago.
/// O sea que siempre fue la fecha de cobro, y el nombre sólo hacía dudar —
/// el dueño preguntó textualmente qué significaba la columna.
///
/// El `max()` se conserva igual: si algún día aparece una cuota con dos
/// abonos, la fila muestra el último, que es cuando terminó de pagarse.
///
/// **`recibo`** es el identificador del cobro para el negocio, mucho más útil
/// que el uuid del pago. Verificado el 2026-09-01: los 32.609 pagos vivos
/// tienen uno, así que la columna sólo queda vacía en cuotas sin cobrar.
const String _colsCierre = '''
        cu.estado AS estado,
        (SELECT max(p.fecha_cobro) FROM pagos p
          WHERE p.cuota_id = cu.id
            AND COALESCE(p.anulado, 0) = 0
            AND COALESCE(p.en_revision, 0) = 0) AS fecha_cobro,
        (SELECT r.numero_completo FROM recibos r
           JOIN pagos p ON p.id = r.pago_id
          WHERE p.cuota_id = cu.id
            AND COALESCE(p.anulado, 0) = 0
            AND COALESCE(p.en_revision, 0) = 0
            AND COALESCE(r.anulado, 0) = 0
          ORDER BY p.fecha_cobro DESC LIMIT 1) AS recibo''';

/// Columnas del detalle de COBERTURA: lo facturado del ciclo y cuánto de eso
/// entró. Es la pregunta que responde esa tarjeta.
const String _colsDetalle = '''$_colsIdentidad,
        cu.monto + COALESCE(cu.cargos_neto, 0) AS facturado,
        COALESCE(cu.monto_pagado, 0) AS pagado,
        max(cu.monto + COALESCE(cu.cargos_neto, 0)
            - COALESCE(cu.monto_pagado, 0), 0) AS falta,
$_colsCierre''';

/// Pagos vivos de la cuota POSTERIORES a la gracia: lo que la tarjeta llama
/// "Recuperado". Lleva un `?` (los días de gracia).
const String _sqlRecuperadoTarde = '''
          (SELECT COALESCE(SUM(p.monto_cordobas), 0) FROM pagos p
            WHERE p.cuota_id = cu.id
              AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
              AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                  < p.fecha_cobro)''';

/// El complemento EXACTO del anterior: lo que se pagó DENTRO de la gracia y por
/// eso nunca cayó en mora. Lleva un `?`.
///
/// Los dos lados van envueltos en `date(...)` a propósito: `fecha_pago` guarda
/// la hora ('2026-08-09T15:01:00'), así que compararla pelada contra el día
/// ('2026-08-09') es una comparación de TEXTO y el prefijo más corto ordena
/// primero — un pago del último día de gracia se clasificaría como tardío.
const String _sqlPagadoATiempo = '''
          (SELECT COALESCE(SUM(p.monto_cordobas), 0) FROM pagos p
            WHERE p.cuota_id = cu.id
              AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
              AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                  >= p.fecha_cobro)''';

/// Lo que la tarjeta llama "Por recuperar", por fila. El filtro de estado NO es
/// decorativo: `resumenMora` suma el saldo solo de las pendiente/parcial, así
/// que sin él una cuota 'pagada' a la que le agregaron un cargo después sumaría
/// acá y no allá.
const String _sqlSigueImpago =
    "CASE WHEN cu.estado IN ('pendiente','parcial') THEN $saldoCanonico "
    'ELSE 0 END';

/// Columnas del detalle de MORA.
///
/// Las tres de la derecha son, expresión por expresión, las de [resumenMora]:
/// `en_mora` ≡ meta_m, `recuperado_tarde` ≡ rec_m, `sigue_impago` ≡ porrec_m.
/// Por eso el subtotal del Excel da igual que la tarjeta POR CONSTRUCCIÓN y no
/// por casualidad.
///
/// `facturado` y `pagado_a_tiempo` van al lado como CONTEXTO, no como parte de
/// la mora: son los que explican la diferencia. El caso que lo motivó —un
/// abono dentro de la gracia sobre una cuota que igual cayó en mora— hacía que
/// el Excel dijera 22.150/18.265 donde la tarjeta decía 21.950/18.065, y no
/// había forma de ver de dónde salían los C$200.
const String _colsDetalleMora = '''$_colsIdentidad,
        cu.monto + COALESCE(cu.cargos_neto, 0) AS facturado,
        $_sqlPagadoATiempo AS pagado_a_tiempo,
        $_sqlSigueImpago + $_sqlRecuperadoTarde AS en_mora,
        $_sqlRecuperadoTarde AS recuperado_tarde,
        $_sqlSigueImpago AS sigue_impago,
$_colsCierre''';

/// Detalle exportable de "Cobertura del ciclo": una fila por cuota que la
/// tarjeta CUENTA. Mismo universo que [resumenCobros] — si divergiera, el
/// Excel y la pantalla dirían cosas distintas y no habría forma de saber cuál
/// creer. Hay un test que suma este detalle y lo compara contra la tarjeta.
/// [hoy] y [diasGracia] agregan el corte por mora POR FILA, con las mismas
/// expresiones de [cortesDelCiclo]: así el subtotal de cada columna del Excel
/// da igual que su fila de la tarjeta. `origen` separa la cuota de servicio
/// (cobro puntual / ticket) de la mensualidad, que es como se agrupa el archivo.
ConsultaSql detalleCobertura({
  required String inicio,
  required String fin,
  required int diasGracia,
  required String hoy,
}) {
  const sql = '''
      SELECT $_colsDetalle,
        CASE WHEN cu.contrato_id IS NULL THEN 'Servicio' ELSE 'Contrato' END
          AS origen,
        date(cu.fecha_vencimiento, '+' || ? || ' days') AS limite,
        min(COALESCE(cu.monto_pagado, 0),
            cu.monto + COALESCE(cu.cargos_neto, 0))
          - max(min($_sqlTardeCu, min(COALESCE(cu.monto_pagado, 0),
                cu.monto + COALESCE(cu.cargos_neto, 0))), 0) AS cobrado_a_tiempo,
        max(min($_sqlTardeCu, min(COALESCE(cu.monto_pagado, 0),
              cu.monto + COALESCE(cu.cargos_neto, 0))), 0) AS cobrado_en_mora,
        CASE WHEN date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
                  AND cu.estado IN ('pendiente','parcial')
             THEN $saldoCanonico ELSE 0 END AS impago_en_mora,
        $saldoCanonico
          - CASE WHEN date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
                      AND cu.estado IN ('pendiente','parcial')
                 THEN $saldoCanonico ELSE 0 END AS en_fecha
      FROM cuotas cu
      JOIN clientes c ON c.id = cu.cliente_id
      LEFT JOIN contratos ct ON ct.id = cu.contrato_id
      WHERE cu.estado != 'anulada'
        AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
      ORDER BY (cu.contrato_id IS NULL), c.codigo, cu.fecha_vencimiento
    ''';
  final g = diasGracia;
  return ConsultaSql(sql, [
    g, // limite
    g, g, hoy, // cobrado_a_tiempo (su mitad tardía)
    g, g, hoy, // cobrado_en_mora
    g, hoy, // impago_en_mora
    g, hoy, // en_fecha
    inicio, fin,
  ]);
}

/// Los pagos vivos de `cu` posteriores a la gracia Y con la gracia ya vencida
/// contra hoy. Lleva TRES `?`: gracia, gracia, hoy.
const String _sqlTardeCu = '''
          (SELECT COALESCE(SUM(p.monto_cordobas), 0) FROM pagos p
            WHERE p.cuota_id = cu.id
              AND COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
              AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                  < p.fecha_cobro
              AND date(cu.fecha_vencimiento, '+' || ? || ' days') < ?)''';

/// Detalle exportable de la tarjeta de Mora: las cuotas que cruzaron la gracia
/// estando vencidas. Mismo universo que [resumenMora].
///
/// [hoy] es el día de corte (ISO `yyyy-MM-dd`, hora de Nicaragua) y tiene que
/// ser EL MISMO que se le pasó a [resumenMora] para armar la tarjeta. Antes se
/// resolvía adentro del SQL con `date('now','-6 hours')`, y eso alcanzaba para
/// que las dos consultas dijeran lo mismo... solo si corrían el mismo día: la
/// tarjeta es un `watch` que PowerSync re-ejecuta únicamente cuando cambian
/// `cuotas`/`pagos`, así que si el dashboard queda abierto cruzando la
/// medianoche se queda con el universo de AYER mientras el Excel —un `getAll`
/// al hacer clic— sale con el de HOY. En Mairena esa deriva medía C$42.680.
ConsultaSql detalleMora({
  required String inicio,
  required String fin,
  required int diasGracia,
  required String hoy,
}) {
  const sql = '''
      SELECT $_colsDetalleMora
      FROM cuotas cu
      JOIN clientes c ON c.id = cu.cliente_id
      LEFT JOIN contratos ct ON ct.id = cu.contrato_id
      WHERE cu.estado != 'anulada'
        AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
        AND date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
        AND (cu.estado IN ('pendiente','parcial')
             OR EXISTS (SELECT 1 FROM pagos p3
                         WHERE p3.cuota_id = cu.id
                           AND COALESCE(p3.anulado, 0) = 0
                           AND COALESCE(p3.en_revision, 0) = 0
                           AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                               < p3.fecha_cobro))
      ORDER BY c.codigo, cu.fecha_vencimiento
    ''';
  final g = diasGracia;
  return ConsultaSql(sql, [
    g, // pagado_a_tiempo
    g, // en_mora — su mitad de recuperado tarde
    g, // recuperado_tarde
    inicio, fin, g, hoy, g, // el universo de filas
  ]);
}

/// Las cuotas ANULADAS del período. Van en su propia hoja del Excel: hoy no
/// aparecen en ningún lado, así que quien busque una no encuentra ni rastro.
/// Listadas con su motivo, la diferencia entre las cuotas que hay en la ventana
/// y las que la tarjeta cuenta queda explicada dentro del propio archivo.
ConsultaSql anuladasDelPeriodo({required String inicio, required String fin}) {
  const sql = '''
      SELECT $_colsDetalle,
             COALESCE(cu.motivo_anulacion, '') AS motivo
      FROM cuotas cu
      JOIN clientes c ON c.id = cu.cliente_id
      LEFT JOIN contratos ct ON ct.id = cu.contrato_id
      WHERE cu.estado = 'anulada'
        AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
      ORDER BY c.codigo, cu.fecha_vencimiento
    ''';
  return ConsultaSql(sql, [inicio, fin]);
}

/// Desglose de la fila "Recuperado" por CUANDO entro la plata de cada cuota.
///
/// Devuelve una fila por momento (`antes` / `dentro` / `despues` / `sin`) con:
///   `saldadas`  cuotas del ciclo que quedaron SIN saldo y cuyo momento es ese
///   `monto`     TODA la plata que entro en ese momento — incluida la de cuotas
///               que siguen debiendo, porque esa plata entro igual
///   `parciales` / `parciales_monto`  de esas, las que recibieron algo y AUN
///               DEBEN. Se cuentan en "Por recuperar", asi que su conteo NO
///               suma aca; su plata SI, porque esta adentro de `monto`
///   `credito`   cuotas saldadas SIN un peso de por medio (credito a favor
///               aplicado). Su momento sale de la fecha del cargo, no de un
///               pago que no existe
///
/// Los `saldadas` de los cuatro momentos suman la fila "Recuperado", y los
/// `monto` suman su monto. Cada numero se cuenta o se suma DIRECTO: ninguno
/// sale de restar dos totales (pedido explicito del dueno 2026-08-27, despues
/// de que una propuesta anterior fabricara un residuo).
ConsultaSql desgloseRecuperado(
    {required String inicio, required String fin, required int diasGracia}) {
  const sql = '''
      SELECT
        CASE
          WHEN COALESCE(q.ultimo, q.credito_el) IS NULL THEN 'sin'
          WHEN COALESCE(q.ultimo, q.credito_el) < ? THEN 'antes'
          WHEN COALESCE(q.ultimo, q.credito_el) >= ? THEN 'despues'
          ELSE 'dentro'
        END AS momento,
        SUM(CASE WHEN q.saldo <= 0.009 THEN 1 ELSE 0 END) AS saldadas,
        COALESCE(SUM(q.entro), 0) AS monto,
        SUM(CASE WHEN q.saldo > 0.009 AND q.entro > 0.009 THEN 1 ELSE 0 END)
          AS parciales,
        COALESCE(SUM(CASE WHEN q.saldo > 0.009 AND q.entro > 0.009
                          THEN q.entro ELSE 0 END), 0) AS parciales_monto,
        SUM(CASE WHEN q.saldo <= 0.009 AND q.entro <= 0.009 THEN 1 ELSE 0 END)
          AS credito,
        -- DE ESAS SALDADAS, LAS QUE PAGARON PASADA LA GRACIA (2026-09-01).
        --
        -- El momento dice CUANDO entro la plata; esto dice si llego dentro del
        -- plazo. Antes la mora colgaba de la fila madre, hermana de los tres
        -- momentos; el dueno pidio que se reparta ADENTRO de cada uno porque
        -- *"los momentos son la jerarquia principal"*.
        --
        -- El monto es el FACTURADO de esas cuotas, no lo cobrado tarde: es
        -- exactamente lo que mostraba la fila unica (`cm_f` de
        -- [cortesDelCiclo]), asi que al mudarla el numero no se mueve. Y la
        -- SUMA de los momentos tiene que dar ese mismo `cm_f` — hay un test.
        SUM(CASE WHEN q.saldo <= 0.009 AND q.tarde > 0.009 THEN 1 ELSE 0 END)
          AS mora,
        COALESCE(SUM(CASE WHEN q.saldo <= 0.009 AND q.tarde > 0.009
                          THEN q.fact ELSE 0 END), 0) AS mora_monto
      FROM (
        SELECT
          cu.monto + COALESCE(cu.cargos_neto, 0)
            - COALESCE(cu.monto_pagado, 0) AS saldo,
          cu.monto + COALESCE(cu.cargos_neto, 0) AS fact,
          -- Mismo predicado que `cortesDelCiclo` y que `serieMoraDiaria`: pago
          -- VIVO cuya fecha cae despues del vencimiento mas la gracia. Si estos
          -- tres se separan, la tabla, la curva y la tarjeta de Mora empiezan a
          -- decir numeros distintos de la misma plata.
          (SELECT COALESCE(SUM(p.monto_cordobas), 0) FROM pagos p
             WHERE p.cuota_id = cu.id AND $_pagoVivoP
               AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                   < p.fecha_cobro) AS tarde,
          (SELECT COALESCE(SUM(p.monto_cordobas), 0) FROM pagos p
             WHERE p.cuota_id = cu.id AND $_pagoVivoP) AS entro,
          (SELECT MAX(p.fecha_cobro) FROM pagos p
             WHERE p.cuota_id = cu.id AND $_pagoVivoP) AS ultimo,
          -- Una cuota saldada con credito no tiene fecha de pago: su momento
          -- es el dia en que el credito se APLICO.
          (SELECT MAX(date(ce.aplicado_en)) FROM cargos_extra ce
             WHERE ce.cuota_id = cu.id
               AND ce.tipo = 'credito_aplicado') AS credito_el
        FROM cuotas cu
        WHERE cu.estado != 'anulada'
          AND cu.fecha_vencimiento >= ?
          AND cu.fecha_vencimiento < ?
      ) q
      GROUP BY momento
    ''';
  // El `?` de la gracia va en el subselect `tarde`, que en el texto del SQL
  // aparece DESPUES de los dos `?` del CASE de momento y ANTES de los dos de
  // la ventana. El orden de esta lista es el orden en que salen en el texto.
  return ConsultaSql(sql, [inicio, fin, diasGracia, inicio, fin]);
}

/// Lo que entró CADA DÍA de la ventana pero pertenece a OTRO ciclo.
///
/// ## El caso que la trajo
///
/// El dueño abrió el ciclo de septiembre, pasó el mouse por el 16 de agosto y
/// el globo le dijo **"Sin cobros este día"**. Ese día habían entrado C$1.000:
/// dos cuotas que vencían el 10 y el 14 de agosto, o sea del ciclo anterior,
/// cobradas dentro de la ventana de septiembre.
///
/// La afirmación era cierta para la COBERTURA de septiembre —esas cuotas no
/// vencen ahí, así que la curva no las cuenta— y falsa para cualquiera que lea
/// "no entró plata ese día".
///
/// ## Los dos ejes, que es lo que hay debajo
///
/// El Resumen mide el tiempo de dos maneras y hasta ahora ninguna pantalla lo
/// decía: **Cobertura y Mora** cuentan por el VENCIMIENTO de la cuota (qué se
/// facturó en el ciclo) y **Caja y Quién cobró** por la FECHA DE PAGO (qué
/// plata entró por la ventanilla). Esta consulta es el puente: le da a la
/// primera el dato de la segunda, sin mezclarlos en la misma curva.
///
/// La ventana es la MISMA que la de la curva —`inicio`/`fin`— pero aplicada a
/// `fecha_pago` en vez de a `fecha_vencimiento`, y se queda con las cuotas cuyo
/// vencimiento cae FUERA. Por eso los dos pares de `?`.
///
/// **No alimenta ninguna curva ni ningún total**: sólo el renglón del globo del
/// día que corresponda. Sumarla a la cobertura sería contar en septiembre una
/// cuota de agosto, que es exactamente lo que la tarjeta NO hace.
ConsultaSql cobrosDeOtrosCiclosDiaria(
    {required String inicio, required String fin, required int diasGracia}) {
  // Las dos columnas `mora_*` (2026-09-02) son un SUBCONJUNTO de las de
  // arriba: mismas filas con una condición más —haber entrado pasada la
  // gracia—, igual que la curva roja respecto de la verde. NO se suman entre
  // sí; el globo las muestra sangradas como "de eso, de mora".
  //
  // El `WHERE` de las columnas originales NO se toca: este cambio sólo agrega
  // columnas. La plata que devuelve la consulta es exactamente la misma.
  const sql = '''
      SELECT p.fecha_cobro AS dia,
             COALESCE(SUM(p.monto_cordobas), 0) AS monto,
             -- CUOTAS, no filas de pago: el renglón dice "2 cuotas".
             COUNT(DISTINCT p.cuota_id) AS qty,
             COALESCE(SUM(CASE
               WHEN p.fecha_cobro
                    > date(cu.fecha_vencimiento, '+' || ? || ' days')
               THEN p.monto_cordobas ELSE 0 END), 0) AS mora_monto,
             COUNT(DISTINCT CASE
               WHEN p.fecha_cobro
                    > date(cu.fecha_vencimiento, '+' || ? || ' days')
               THEN p.cuota_id END) AS mora_qty
      FROM pagos p
      JOIN cuotas cu ON cu.id = p.cuota_id
      WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
        AND cu.estado != 'anulada'
        AND p.fecha_cobro >= ? AND p.fecha_cobro < ?
        AND (cu.fecha_vencimiento < ?
             OR cu.fecha_vencimiento >= ?)
      GROUP BY p.fecha_cobro
      ORDER BY dia
    ''';
  // Orden de los `?`: los dos de gracia van PRIMERO porque aparecen en el
  // SELECT, que se lee antes que el WHERE.
  return ConsultaSql(
      sql, [diasGracia, diasGracia, inicio, fin, inicio, fin]);
}

/// El vencimiento MÁS NUEVO que ya recibió algún pago vivo.
///
/// Sirve para decidir hasta qué ciclo deja avanzar el selector de Cobertura.
/// Hasta el 2026-09-02 la regla era "nunca un ciclo futuro", y eso dejaba
/// invisible un caso real: **un cliente que paga por adelantado**. Rubén lo
/// encontró probando — cobró una cuota que vence el 28/09 el día 02/09, y no
/// podía abrir Octubre para verla.
///
/// **Por qué el criterio es "tiene PAGOS" y no "tiene cuotas".** Las cuotas se
/// generan meses por adelantado: en el Test Tenant hay cuotas hasta Ago 2027
/// (18 ciclos) pero sólo 8 ciclos tienen algún pago. Con "tiene cuotas" el
/// selector dejaría recorrer once ciclos vacíos; con "tiene pagos" se detiene
/// exactamente donde hay algo que mirar.
/// Devuelve `vence` (el más nuevo CON PAGO, para el tope hacia adelante de
/// Cobertura) y `primero` (el más viejo que exista, para el tope hacia atrás
/// del selector de Mora). Los dos en una consulta: son los dos extremos de lo
/// mismo y separarlos sería pedirle dos veces al disco por el mismo escaneo.
ConsultaSql ultimoVencimientoConPago() {
  const sql = '''
      SELECT (
        SELECT MAX(cu.fecha_vencimiento)
          FROM pagos p
          JOIN cuotas cu ON cu.id = p.cuota_id
         WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
           AND cu.estado != 'anulada'
      ) AS vence,
      (
        SELECT MIN(cu.fecha_vencimiento)
          FROM cuotas cu
         WHERE cu.estado != 'anulada'
      ) AS primero
    ''';
  return const ConsultaSql(sql, []);
}
/// Serie diaria de la curva verde: lo cobrado del período, por día de pago.
ConsultaSql serieCobrosDiaria({required String inicio, required String fin}) {
  const sql = '''
      SELECT p.fecha_cobro AS dia,
             COALESCE(SUM(p.monto_cordobas), 0) AS monto,
             -- CUOTAS, no filas de pago: el tooltip lo rotula "Cuotas
             -- cobradas". Con COUNT(*) una cuota con dos pagos el mismo dia
             -- contaba dos veces. Hoy no pasa —medido: 685 dias con cobro en
             -- los 3 tenants, cero diferencias— pero el rotulo no puede
             -- depender de que nunca pase.
             COUNT(DISTINCT p.cuota_id) AS qty
      FROM pagos p
      JOIN cuotas cu ON cu.id = p.cuota_id
      WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
        AND cu.estado != 'anulada'
        AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
      GROUP BY p.fecha_cobro
      ORDER BY dia
    ''';
  return ConsultaSql(sql, [inicio, fin]);
}

/// Serie diaria de la curva roja: de lo cobrado del período, la parte que entró
/// TARDE (pasada la gracia). Mismo universo que [serieCobrosDiaria] con una
/// condición más, así que es un SUBCONJUNTO: la curva roja queda siempre por
/// debajo de la verde. No son dos cosas que se suman.
ConsultaSql serieMoraDiaria({
  required String inicio,
  required String fin,
  required int diasGracia,
}) {
  const sql = '''
      SELECT p.fecha_cobro AS dia,
             COALESCE(SUM(p.monto_cordobas), 0) AS monto,
             -- CUOTAS, no filas de pago: el tooltip lo rotula "Cuotas
             -- cobradas". Con COUNT(*) una cuota con dos pagos el mismo dia
             -- contaba dos veces. Hoy no pasa —medido: 685 dias con cobro en
             -- los 3 tenants, cero diferencias— pero el rotulo no puede
             -- depender de que nunca pase.
             COUNT(DISTINCT p.cuota_id) AS qty
      FROM pagos p
      JOIN cuotas cu ON cu.id = p.cuota_id
      WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
        AND cu.estado != 'anulada'
        AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
        AND date(cu.fecha_vencimiento, '+' || ? || ' days') < p.fecha_cobro
      GROUP BY p.fecha_cobro
      ORDER BY dia
    ''';
  return ConsultaSql(sql, [inicio, fin, diasGracia]);
}

/// Las barras de "Mora — últimos N ciclos": un renglón por ciclo con lo que
/// sigue impago y lo que se recuperó tarde.
///
/// La definición de mora es la MISMA que la de [resumenMora] — incluida la
/// condición de que la gracia ya haya vencido contra hoy — para que la barra
/// del ciclo en curso dé idéntica a la de esa tarjeta. Si divergen, el dueño ve
/// dos números distintos para lo mismo en la misma pantalla.
///
/// [ciclos] son los bordes `(inicio, fin)` de cada ciclo, del más viejo al más
/// nuevo, y [hoy] el día de corte en hora de Nicaragua.
///
/// El corte va como PARÁMETRO, no como `date('now','-6 hours')` adentro del SQL.
/// El comentario que estaba acá decía lo contrario —"así no queda congelado en
/// el arranque"— y era falso: bajo `db.watch` resolver `now()` en SQL no
/// descongela nada, porque la consulta solo se re-ejecuta cuando cambian las
/// tablas fuente. El corte quedaba clavado en la última escritura, y encima
/// distinto del que usaba el Excel.
ConsultaSql moraHistorica({
  required List<(String, String)> ciclos,
  required int diasGracia,
  required String hoy,
}) {
  final valores = List.generate(ciclos.length, (_) => '(?,?,?)').join(',');
  final sql = '''
      WITH ciclos(idx, ini, fin) AS (VALUES $valores)
      SELECT
        c.idx AS idx,
        COALESCE((
          SELECT SUM($saldoCanonico) FROM cuotas cu
           WHERE cu.estado IN ('pendiente','parcial')
             AND cu.fecha_vencimiento >= c.ini
             AND cu.fecha_vencimiento <  c.fin
             AND date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
        ), 0) AS impago,
        COALESCE((
          SELECT SUM(p2.monto_cordobas) FROM pagos p2
            JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE $_pagoVivo
             AND cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= c.ini
             AND cu2.fecha_vencimiento <  c.fin
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days')
                 < p2.fecha_cobro
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < ?
        ), 0) AS recuperado
        FROM ciclos c
       ORDER BY c.idx
    ''';
  return ConsultaSql(sql, [
    // 3 por ciclo (idx, ini, fin): van primero porque el CTE aparece primero
    // en el texto del SQL, y `?` es posicional.
    for (var i = 0; i < ciclos.length; i++) ...[
      i,
      ciclos[i].$1,
      ciclos[i].$2,
    ],
    diasGracia, hoy, // impago
    diasGracia, // recuperado — pagado después de la gracia
    diasGracia, hoy, // recuperado — gracia ya vencida contra hoy
  ]);
}

/// Resumen de la tarjeta "Mora del ciclo".
///
/// META es el universo BRUTO: cuotas del período que cruzaron la gracia estando
/// vencidas — las que SIGUEN impagas Y las que se recuperaron tarde. Con el
/// universo bruto, REC siempre es un subconjunto de META (antes META era solo
/// lo impago, que se achica a medida que se cobra mientras REC crece, y
/// "Cumplimiento" llegaba a 1500% en meses cerrados — audit 2026-08-01).
///
/// Una cuota pagada a tiempo cuya gracia ya venció NO entra: nunca estuvo en
/// mora.
ConsultaSql resumenMora({
  required String inicio,
  required String fin,
  required int diasGracia,
  required String hoy,
}) {
  const universo = '''
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < ?
             AND cu2.estado != 'anulada'
             AND (cu2.estado IN ('pendiente','parcial')
                  OR EXISTS (SELECT 1 FROM pagos p3 WHERE p3.cuota_id = cu2.id AND COALESCE(p3.anulado, 0) = 0 AND COALESCE(p3.en_revision, 0) = 0
                               AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < p3.fecha_cobro))''';
  const sql = '''
      SELECT
        -- Cuenta CONTRATOS, no personas: misma regla que la tabla de
        -- "Cobros del mes" (ver el comentario largo alla). Si las dos tarjetas
        -- no usaran el mismo criterio, mostrarian universos distintos.
        (SELECT COUNT(DISTINCT COALESCE(cu2.contrato_id, cu2.id)) FROM cuotas cu2
           WHERE 1=1 $universo) AS meta_u,
        (SELECT COUNT(*) FROM cuotas cu2
           WHERE 1=1 $universo) AS meta_c,
        -- META monto bruto = saldo aún impago + pagos recuperados tarde.
        ( (SELECT COALESCE(SUM($saldoCanonico), 0) FROM cuotas cu
             WHERE cu.estado IN ('pendiente','parcial')
               AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
               AND date(cu.fecha_vencimiento, '+' || ? || ' days') < ?)
        + (SELECT COALESCE(SUM(p2.monto_cordobas), 0) FROM pagos p2
             JOIN cuotas cu2 ON cu2.id = p2.cuota_id
             WHERE $_pagoVivo
               AND cu2.estado != 'anulada'
               AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
               AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < p2.fecha_cobro
               -- Este guard faltaba. Sin él este término no era IDÉNTICO a
               -- `rec_m`, así que `meta_m = rec_m + porrec_m` dependía de que
               -- ningún pago tuviera fecha futura en vez de ser una identidad.
               -- Hoy no cambia un centavo en ninguno de los 3 tenants; con el
               -- guard, el Excel puede prometer que reconcilia por
               -- construcción.
               AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < ?)
        ) AS meta_m,
        (SELECT COUNT(DISTINCT COALESCE(cu2.contrato_id, cu2.id)) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE $_pagoVivo
             AND cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < p2.fecha_cobro
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < ?
        ) AS rec_u,
        (SELECT COUNT(DISTINCT p2.cuota_id) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE $_pagoVivo
             AND cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < p2.fecha_cobro
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < ?
        ) AS rec_c,
        (SELECT COALESCE(SUM(p2.monto_cordobas), 0) FROM pagos p2
           JOIN cuotas cu2 ON cu2.id = p2.cuota_id
           WHERE $_pagoVivo
             AND cu2.estado != 'anulada'
             AND cu2.fecha_vencimiento >= ? AND cu2.fecha_vencimiento < ?
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < p2.fecha_cobro
             AND date(cu2.fecha_vencimiento, '+' || ? || ' days') < ?
        ) AS rec_m,
        -- "Sigue impago": consultado dentro del universo de mora, no por resta
        -- (una cuota parcial cuenta en las dos filas).
        (SELECT COUNT(DISTINCT COALESCE(cu2.contrato_id, cu2.id)) FROM cuotas cu2
           WHERE cu2.estado IN ('pendiente','parcial') $universo
             AND (cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0)) > 0.009
        ) AS porrec_u,
        (SELECT COUNT(*) FROM cuotas cu2
           WHERE cu2.estado IN ('pendiente','parcial') $universo
             AND (cu2.monto + COALESCE(cu2.cargos_neto, 0) - COALESCE(cu2.monto_pagado, 0)) > 0.009
        ) AS porrec_c,
        (SELECT COALESCE(SUM($saldoCanonico2), 0) FROM cuotas cu2
           WHERE cu2.estado IN ('pendiente','parcial') $universo
        ) AS porrec_m
    ''';
  final g = diasGracia;
  final h = hoy;
  return ConsultaSql(sql, [
    // El `universo` pone sus `?` en este orden: inicio, fin, gracia, hoy, gracia.
    inicio, fin, g, h, g, // meta_u
    inicio, fin, g, h, g, // meta_c
    inicio, fin, g, h, // meta_m — saldo impago
    inicio, fin, g, g, h, // meta_m — pagos tardíos (ahora igual que rec_m)
    inicio, fin, g, g, h, // rec_u
    inicio, fin, g, g, h, // rec_c
    inicio, fin, g, g, h, // rec_m
    inicio, fin, g, h, g, // porrec_u
    inicio, fin, g, h, g, // porrec_c
    inicio, fin, g, h, g, // porrec_m
  ]);
}

/// Serie por CICLO de la tarjeta "Recaudo y mora" (formato de 4 líneas que
/// pidió el dueño, 2026-08-24): una fila por período 15→14 dentro de la
/// ventana, con la PARTICIÓN completa de lo facturado.
///
///  - `fact`   = lo facturado del ciclo (cuotas que VENCEN en él).
///  - `rec`    = lo que entró a esas cuotas (`monto_pagado`, mantenido por el
///               trigger del server con el predicado de pago vivo).
///  - `mora`   = el saldo canónico de las cuotas del ciclo que YA cruzaron la
///               gracia (mismo corte que la tarjeta de Mora).
///  - `porrec` = el saldo que todavía está en plazo o en gracia.
///
/// IDENTIDAD por construcción: `fact = rec + porrec + mora` por ciclo — los
/// tres sumandos parten el mismo saldo y el saldo parte lo facturado. La única
/// forma de romperla es un sobrepago (saldo clampeado a 0), que el guard del
/// server (0214/0218) impide: INV4 = 0 en toda la base. El test la verifica
/// contra el escenario completo.
///
/// La clave `ciclo` es 'YYYY-MM' del PERÍODO (día >= 15 → cuenta contra el mes
/// siguiente), calcada de `periodoDe` en `periodo_dashboard.dart`. La tarjeta
/// rellena con ceros los ciclos sin filas.
ConsultaSql serieRecaudoMora({
  required String inicio,
  required String fin,
  required int diasGracia,
  required String hoy,
}) {
  const sql = '''
      SELECT ciclo,
        COALESCE(SUM(fact), 0) AS fact,
        COALESCE(SUM(entro), 0) AS rec,
        COALESCE(SUM(CASE WHEN en_mora = 1 THEN saldo ELSE 0 END), 0) AS mora,
        COALESCE(SUM(CASE WHEN en_mora = 0 THEN saldo ELSE 0 END), 0) AS porrec
      FROM (
        SELECT
          CASE WHEN CAST(strftime('%d', cu.fecha_vencimiento) AS INTEGER) >= 15
               THEN strftime('%Y-%m', date(cu.fecha_vencimiento, 'start of month', '+1 month'))
               ELSE strftime('%Y-%m', cu.fecha_vencimiento) END AS ciclo,
          cu.monto + COALESCE(cu.cargos_neto, 0) AS fact,
          COALESCE(cu.monto_pagado, 0) AS entro,
          $saldoCanonico AS saldo,
          CASE WHEN date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
               THEN 1 ELSE 0 END AS en_mora
        FROM cuotas cu
        WHERE cu.estado != 'anulada'
          AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
      ) t
      GROUP BY ciclo
      ORDER BY ciclo
    ''';
  return ConsultaSql(sql, [diasGracia, hoy, inicio, fin]);
}

/// El ciclo administrativo (15→14) al que pertenece una cuota, como el primer
/// día del mes de período. Es el espejo SQL de `periodoDe`: del 15 en adelante
/// la cuota ya cuenta contra el período del mes siguiente.
///
/// Se escribe una vez acá porque las dos consultas de Mora tienen que agrupar
/// EXACTAMENTE igual; si una usara el mes calendario, la barra y la tabla
/// hablarían de ciclos distintos.
const String _cicloDeVencimiento = '''
    CASE WHEN CAST(strftime('%d', cu.fecha_vencimiento) AS INTEGER) >= 15
         THEN date(cu.fecha_vencimiento, 'start of month', '+1 month')
         ELSE date(cu.fecha_vencimiento, 'start of month') END''';

/// El universo de mora de una cuota, en forma de sub-SELECT reusable.
///
/// Mismo criterio que [resumenMora] —cuotas que cruzaron la gracia estando
/// vencidas: las que SIGUEN impagas y las que se recuperaron tarde—, pero
/// dejando una fila por cuota para poder agrupar por ciclo después.
///
/// Parámetros, en orden: gracia · inicio · fin · hoy · gracia.
const String _cuotasEnMora = '''
      SELECT
        $_cicloDeVencimiento AS ciclo,
        cu.id AS cuota_id,
        -- Para el conteo de USUARIOS de la tabla (2026-09-02). Sale de aca y no
        -- de una consulta aparte para que las tres filas se cuenten sobre EL
        -- MISMO universo que sus cuotas y sus montos.
        cu.cliente_id AS cliente_id,
        cu.estado AS estado,
        COALESCE(cu.monto_pagado, 0) AS pagado,
        CASE WHEN cu.estado IN ('pendiente','parcial')
             THEN $saldoCanonico ELSE 0 END AS saldo,
        (SELECT COALESCE(SUM(p.monto_cordobas), 0) FROM pagos p
           WHERE p.cuota_id = cu.id AND $_pagoVivoP
             AND p.fecha_cobro
                 > date(cu.fecha_vencimiento, '+' || ? || ' days')) AS rec_m
      FROM cuotas cu
      WHERE cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
        AND date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
        AND cu.estado != 'anulada' ''';

/// Una fila POR CICLO con las tres cifras de la tarjeta de Mora.
///
/// Alimenta las barras apiladas: la barra entera es `mora_m` y el verde es
/// `rec_m`. Por construcción `rec_m + pend_m = mora_m` — la misma identidad
/// que [resumenMora] garantiza para un ciclo suelto, ahora por ciclo.
///
/// Los ciclos SIN cuotas en mora no vuelven en el resultado (no hay filas que
/// agrupar); los rellena el widget para que la ventana siempre muestre las 6
/// barras y no se corra el eje.
ConsultaSql serieMoraPorCiclo({
  required String inicio,
  required String fin,
  required int diasGracia,
  required String hoy,
}) {
  const sql = '''
      SELECT ciclo,
        SUM(CASE WHEN estado IN ('pendiente','parcial') OR rec_m > 0.009
                 THEN 1 ELSE 0 END) AS mora_c,
        COALESCE(SUM(saldo), 0) + COALESCE(SUM(rec_m), 0) AS mora_m,
        SUM(CASE WHEN rec_m > 0.009 THEN 1 ELSE 0 END) AS rec_c,
        COALESCE(SUM(rec_m), 0) AS rec_m,
        SUM(CASE WHEN estado IN ('pendiente','parcial') AND saldo > 0.009
                 THEN 1 ELSE 0 END) AS pend_c,
        COALESCE(SUM(saldo), 0) AS pend_m,
        -- USUARIOS (2026-09-02): el MISMO predicado que su fila de cuotas, con
        -- COUNT(DISTINCT) sobre el cliente en vez de SUM(1). Copiar el
        -- predicado y no aproximarlo es lo que hace que las dos columnas de
        -- una fila hablen del mismo conjunto y cierren contra el Excel.
        COUNT(DISTINCT CASE WHEN estado IN ('pendiente','parcial') OR rec_m > 0.009
                 THEN cliente_id END) AS mora_u,
        COUNT(DISTINCT CASE WHEN rec_m > 0.009 THEN cliente_id END) AS rec_u,
        COUNT(DISTINCT CASE WHEN estado IN ('pendiente','parcial') AND saldo > 0.009
                 THEN cliente_id END) AS pend_u
      FROM ($_cuotasEnMora)
      GROUP BY ciclo
      ORDER BY ciclo
    ''';
  return ConsultaSql(sql, [diasGracia, inicio, fin, diasGracia, hoy]);
}

/// El desglose de las dos filas desplegables de UN ciclo.
///
/// Devuelve filas `(fila, clave, cuotas, monto)`:
///   `rec` · `dentro`  — cobradas dentro del mismo ciclo, pasada la gracia
///   `rec` · `despues` — cobradas en un ciclo posterior
///   `pend` · `parcial` — siguen debiendo pero tienen un abono
///   `pend` · `nada`    — sin ningún pago
///
/// El lado de `rec` se agrupa **por PAGO**, no por cuota: una cuota con un
/// pago tardío dentro del ciclo y otro después reparte su plata donde
/// corresponde en vez de mandarla entera al último. Así el monto cierra contra
/// `rec_m` por construcción. El conteo usa `COUNT(DISTINCT cuota_id)`, que en
/// ese caso (hoy inexistente en los tres tenants) contaría la cuota en las dos
/// líneas — la plata es la que tiene que cerrar, no el conteo.
ConsultaSql desgloseMora({
  required String inicio,
  required String fin,
  required int diasGracia,
  required String hoy,
}) {
  const sql = '''
      SELECT 'rec' AS fila,
        CASE WHEN p.fecha_cobro < ? THEN 'dentro' ELSE 'despues' END AS clave,
        COUNT(DISTINCT p.cuota_id) AS cuotas,
        COALESCE(SUM(p.monto_cordobas), 0) AS monto
      FROM pagos p JOIN cuotas cu ON cu.id = p.cuota_id
      WHERE $_pagoVivoP
        AND cu.estado != 'anulada'
        AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
        AND date(cu.fecha_vencimiento, '+' || ? || ' days') < p.fecha_cobro
        AND date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
      GROUP BY clave
      UNION ALL
      SELECT 'pend' AS fila,
        CASE WHEN COALESCE(cu.monto_pagado, 0) > 0.009 THEN 'parcial'
             ELSE 'nada' END AS clave,
        COUNT(*) AS cuotas,
        COALESCE(SUM($saldoCanonico), 0) AS monto
      FROM cuotas cu
      WHERE cu.estado IN ('pendiente','parcial')
        AND cu.fecha_vencimiento >= ? AND cu.fecha_vencimiento < ?
        AND date(cu.fecha_vencimiento, '+' || ? || ' days') < ?
        AND $saldoCanonico > 0.009
      GROUP BY clave
    ''';
  return ConsultaSql(sql, [
    fin, inicio, fin, diasGracia, diasGracia, hoy, // rec
    inicio, fin, diasGracia, hoy, // pend
  ]);
}

/// La FOTO de la cartera viva: el titular "Por cobrar" y sus tres partes.
///
/// Vive acá y no adentro del provider por una razón concreta: así el test
/// corre ESTA consulta y no una copia parecida. Un test que reescribe el SQL
/// prueba que el autor del test sabe sumar, no que la pantalla dice la verdad
/// — y las dos versiones se separan en cuanto alguien toca una.
///
/// **Las tres ramas parten lo vivo**: `al_dia` (todavía no vence), en gracia
/// (venció, sin pasar la gracia) y `vencidas` (pasó la gracia) se excluyen
/// entre sí y cubren todo, así que `al_dia + en_gracia + vencidas =
/// cuotas_pend`, en cuotas y en córdobas. El test lo verifica; no es una
/// promesa del comentario.
///
/// `cuotas_susp` y `parciales` NO son ramas: atraviesan las tres. Sumarlos
/// duplica.
ConsultaSql estadoActual({required int diasGracia}) {
  const sql = '''
    WITH c AS (
      SELECT
        cu.estado AS estado,
        max(cu.monto + COALESCE(cu.cargos_neto, 0)
            - COALESCE(cu.monto_pagado, 0), 0) AS saldo,
        (cu.estado IN ('pendiente','parcial')) AS viva,
        (cu.fecha_vencimiento >= date('now', '-6 hours')) AS futura,
        (date(cu.fecha_vencimiento, '+' || ? || ' days')
           < date('now', '-6 hours')) AS paso_gracia,
        CASE WHEN cu.estado IN ('pendiente','parcial')
             THEN COALESCE((SELECT ct.estado FROM contratos ct
                             WHERE ct.id = cu.contrato_id), 'activo')
                  = 'suspendido'
             ELSE 0 END AS susp
      FROM cuotas cu
      WHERE cu.estado != 'anulada'
    )
    SELECT
      (SELECT COUNT(*) FROM clientes WHERE activo = 1) AS clientes,
      COALESCE(SUM(CASE WHEN viva THEN 1 ELSE 0 END), 0) AS cuotas_pend,
      COALESCE(SUM(CASE WHEN viva THEN saldo ELSE 0 END), 0) AS saldo,
      COALESCE(SUM(CASE WHEN viva AND futura THEN 1 ELSE 0 END), 0) AS al_dia,
      COALESCE(SUM(CASE WHEN viva AND futura THEN saldo ELSE 0 END), 0)
        AS saldo_al_dia,
      COALESCE(SUM(CASE WHEN viva AND NOT futura AND NOT paso_gracia
                        THEN 1 ELSE 0 END), 0) AS en_gracia,
      COALESCE(SUM(CASE WHEN viva AND NOT futura AND NOT paso_gracia
                        THEN saldo ELSE 0 END), 0) AS saldo_en_gracia,
      COALESCE(SUM(CASE WHEN viva AND paso_gracia THEN 1 ELSE 0 END), 0)
        AS vencidas,
      COALESCE(SUM(CASE WHEN viva AND paso_gracia THEN saldo ELSE 0 END), 0)
        AS saldo_vencido,
      COALESCE(SUM(CASE WHEN viva AND susp THEN 1 ELSE 0 END), 0) AS cuotas_susp,
      COALESCE(SUM(CASE WHEN viva AND susp THEN saldo ELSE 0 END), 0)
        AS saldo_susp,
      COALESCE(SUM(CASE WHEN estado = 'pagada' THEN 1 ELSE 0 END), 0) AS pagadas,
      COALESCE(SUM(CASE WHEN estado = 'parcial' THEN 1 ELSE 0 END), 0)
        AS parciales
    FROM c
    ''';
  return ConsultaSql(sql, [diasGracia]);
}
