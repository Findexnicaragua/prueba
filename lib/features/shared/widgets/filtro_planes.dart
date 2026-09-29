/// El filtro **Plan** — la consulta y el armado de opciones, en un solo lugar.
///
/// Lo usan las TRES pantallas que lo tienen (Clientes, Cuotas a cobrar y Mapa).
/// Ojo: esas tres NO comparten barra de filtros —cada una tiene la suya hecha a
/// mano y la única que usa `FiltrosBar` es Inventario— así que lo compartible
/// es esto: el SQL de las opciones y su traducción a [FiltroOpcion]. El chip se
/// arma en cada pantalla con su propio patrón.
library;

import 'package:flutter/material.dart';

import '../../../data/utils/formatters.dart';
import '../../../data/utils/plan_tipo.dart';
export '../../../data/utils/plan_tipo.dart' show kPlanSinPlan;
import 'filtro_multi_dropdown.dart';


/// Los planes que ALGÚN contrato está usando, con su precio y su conteo.
///
/// ## Las dos reglas que decidió el dueño y que este SQL implementa
///
/// 1. **Un plan aparece si algún contrato lo usa** — el `activo` del plan NO
///    participa. Desactivarlo sólo saca la opción del formulario de contratos
///    nuevos; no borra a los clientes que ya lo tienen.
///
/// 2. **Cuenta contratos de CUALQUIER estado, no sólo activos.** Es
///    consecuencia de que el filtro también aplique a "Fuera de ruta"
///    (cancelados y suspendidos con deuda): si un plan sólo apareciera cuando
///    tiene contratos vivos, el día que se cancele el último sus filas de esa
///    sección quedarían **inalcanzables** — visibles en la lista pero
///    imposibles de filtrar. Hoy ese caso no existe en ninguno de los tres
///    tenants (todo plan o tiene activos o no tiene ninguno), pero nace en
///    cuanto alguien cancela el último contrato de un plan.
///
/// El conteo del subtítulo, en cambio, es de contratos **activos**: es lo que
/// una persona entiende por "clientes".
///
/// 🔴 **Lleva `?` de tenant a propósito.** El SQLite del super_admin NO es
/// mono-tenant (conserva la empresa anterior hasta que cierra el sync, AGENTS
/// §1), así que sin este filtro el chip listaría planes de otro ISP. Es el
/// mismo cuidado que ya tiene la consulta de cobradores.
const kPlanesFiltroSql = '''
  SELECT p.id, p.nombre, p.tipo, p.precio_mensual,
         COUNT(ct.id)                                     AS contratos,
         SUM(CASE WHEN ct.estado = 'activo' THEN 1 ELSE 0 END) AS activos
    FROM planes p
    JOIN contratos ct ON ct.plan_id = p.id
   WHERE p.tenant_id = ?
   GROUP BY p.id, p.nombre, p.tipo, p.precio_mensual
''';

/// Convierte las filas de [kPlanesFiltroSql] en opciones agrupadas por tipo,
/// con la opción "Sin plan" adelante.
///
/// ## Por qué el subtítulo NO es decorativo
///
/// Los nombres de plan **se repiten**: en Telecable Mairena hay SIETE planes
/// llamados "CATV" con precios distintos — uno tiene 2.113 contratos y otro
/// tiene 6. Sin el precio y el conteo serían siete filas idénticas, y tocar la
/// equivocada devuelve 6 clientes en vez de 2.113.
///
/// ⚠️ El buscador del panel mira `label` y `grupo`, **no el subtítulo**
/// (`filtro_multi_dropdown`): tipear un precio no encuentra nada. Por eso el
/// orden importa tanto como la búsqueda.
///
/// ## El orden
///
/// Por tipo ([kPlanTiposOrden]: TV → Internet → Combo) y adentro de cada grupo
/// del más usado al menos usado, para que el plan que cubre media cartera quede
/// primero. **El orden de los GRUPOS sale del orden de esta lista**, no de un
/// sort del widget: el panel los agrupa con un Map en orden de inserción.
List<FiltroOpcion> opcionesDePlanes(
  List<Map<String, dynamic>> rows, {
  bool conSinPlan = true,
}) {
  int activosDe(Map<String, dynamic> r) =>
      ((r['activos'] as num?) ?? 0).toInt();

  // Se ordenan las FILAS —que traen `tipo` y los conteos— y recién después se
  // mapean: ordenar las opciones ya construidas obligaría a volver a buscar el
  // tipo de cada una dentro del comparador.
  final ordenadas = rows.where((r) => r['id'] is String).toList()
    ..sort((a, b) {
      final ta = planTipoOrden(a['tipo'] as String?);
      final tb = planTipoOrden(b['tipo'] as String?);
      if (ta != tb) return ta.compareTo(tb);
      final k = activosDe(b).compareTo(activosDe(a));
      if (k != 0) return k;
      // Desempate estable: los siete "CATV" de Mairena con el mismo conteo
      // saldrían en un orden distinto en cada build sin esto.
      return ((a['precio_mensual'] as num?) ?? 0)
          .compareTo((b['precio_mensual'] as num?) ?? 0);
    });

  String subtitulo(Map<String, dynamic> r) {
    final n = activosDe(r);
    final precio = Fmt.cordobas((r['precio_mensual'] as num?) ?? 0);
    // Un plan que sólo tiene contratos cancelados/suspendidos existe como
    // opción (para que "Fuera de ruta" sea filtrable) pero decir "0 clientes"
    // se leería como un error. Se dice lo que es.
    if (n == 0) return '$precio · sin clientes activos';
    return '$precio · $n ${n == 1 ? 'cliente' : 'clientes'}';
  }

  return [
    if (conSinPlan)
      const FiltroOpcion(
        id: kPlanSinPlan,
        label: 'Sin plan',
        subtitulo: 'clientes sin contrato activo',
      ),
    for (final r in ordenadas)
      FiltroOpcion(
        id: r['id'] as String,
        label: (r['nombre'] as String?) ?? r['id'] as String,
        grupo: planTipoLabel(r['tipo'] as String?),
        subtitulo: subtitulo(r),
      ),
  ];
}

/// El ícono del chip. Uno solo para las tres pantallas.
const kPlanFiltroIcono = Icons.wifi_tethering;
