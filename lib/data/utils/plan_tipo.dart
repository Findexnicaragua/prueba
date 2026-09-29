/// El TIPO DE SERVICIO de un plan — `planes.tipo` — en un solo lugar.
///
/// ## Por qué existe
///
/// La columna guarda `'internet' | 'tv' | 'combo'` (NOT NULL + CHECK desde el
/// día uno). Ese valor crudo se venía mostrando tal cual en la tarjeta del
/// catálogo ("tv · 2113 contrato(s)"), y desde 2026-09-03 el filtro por plan lo
/// usa para AGRUPAR — o sea que el mismo dato aparece rotulado en dos lugares.
/// Con dos copias del mapa, el día que se agregue un tipo nuevo una de las dos
/// se va a olvidar. Acá está una sola vez.
///
/// El ícono vive en la pantalla que lo dibuja: este archivo no depende de
/// Flutter para que lo pueda importar la capa de queries.
///
/// ## El orden importa
///
/// [kPlanTiposOrden] es el orden en que se muestran los grupos del filtro. No
/// es alfabético ni por cantidad: va del servicio más simple al más completo
/// (TV → Internet → Combo), que es como los nombra el negocio.
library;

/// Id centinela de la opción **"Sin plan"** del filtro.
///
/// Vive acá y no con el widget porque `cobros_query.dart` —que es SIN Flutter a
/// propósito, para que los tests corran el MISMO SQL que la app— también lo
/// necesita. Definirlo dos veces sería garantizar que un día diverjan.
const kPlanSinPlan = '__sin_plan__';

/// Los tres valores válidos, en el orden en que se muestran.
const kPlanTiposOrden = <String>['tv', 'internet', 'combo'];

/// `'tv'` → `'TV'`. Un valor desconocido se devuelve tal cual: si mañana la
/// base admite un tipo nuevo, la pantalla lo muestra crudo en vez de esconderlo.
String planTipoLabel(String? tipo) => switch (tipo) {
      'internet' => 'Internet',
      'tv' => 'TV',
      'combo' => 'Combo',
      null => '—',
      _ => tipo,
    };

/// Para ordenar una lista de planes por su tipo siguiendo [kPlanTiposOrden].
/// Un tipo desconocido va al final.
int planTipoOrden(String? tipo) {
  final i = kPlanTiposOrden.indexOf(tipo ?? '');
  return i < 0 ? kPlanTiposOrden.length : i;
}
