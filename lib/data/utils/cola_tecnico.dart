/// Cola de trabajo del técnico: una orden a la vez (0206).
///
/// Pedido del nuevo dueño (audio 6): *"quiero que el técnico pueda ver la
/// siguiente orden, pero no la pueda manipular hasta que haya terminado la
/// primera. Es como el mismo caso de los meses"*. Esa analogía es literal — es
/// el mismo **oldest-first** que ya rige la cobranza (invariante #11): las
/// siguientes se ven, pero no se tocan.
///
/// **Se libera con `resuelto`, no con `cerrado`.** Cerrar es del call center y
/// depende de que logre hablar con el cliente; si la cola esperara al cierre, un
/// cliente que no contesta le paralizaría el día entero al técnico por algo que
/// no controla. `resuelto` sí depende de él.
///
/// Funciones puras, sin DB ni widgets, para poder testearlas.
library;

/// Estados en los que una orden OCUPA al técnico y participa de la cola.
///
/// `en_espera` queda AFUERA a propósito: es el estado de "parada esperando algo"
/// (un repuesto, una autorización). Si bloqueara, un técnico con una orden en
/// espera no podría trabajar en nada más — justo lo contrario de para qué existe
/// ese estado. Las órdenes en espera quedan siempre accesibles para retomarlas.
const kEstadosOcupanTecnico = {
  'abierto',
  'asignado',
  'en_progreso',
  'reabierto',
};

/// Compara dos órdenes por su posición en la cola.
///
/// Primero las que tienen posición explícita (`orden_cola`, la que setea el
/// coordinador), en orden ascendente; después las que no la tienen, por
/// antigüedad. Así una migración que agrega la columna en NULL no reordena nada.
int compararEnCola(Map<String, dynamic> a, Map<String, dynamic> b) {
  final oa = a['orden_cola'] as int?;
  final ob = b['orden_cola'] as int?;
  if (oa != null && ob != null) {
    final c = oa.compareTo(ob);
    if (c != 0) return c;
  } else if (oa != null) {
    return -1;
  } else if (ob != null) {
    return 1;
  }
  // Desempate estable por antigüedad: la más vieja primero (oldest-first).
  final ca = (a['created_at'] as String?) ?? '';
  final cb = (b['created_at'] as String?) ?? '';
  return ca.compareTo(cb);
}

/// Id de la orden ACTIVA: la primera de la cola que ocupa al técnico.
///
/// `null` si no tiene ninguna en curso (todas resueltas, en espera o cerradas).
/// No asume que [ordenes] venga ordenada — ordena por su cuenta.
String? ordenActiva(List<Map<String, dynamic>> ordenes) {
  final enCurso = ordenes
      .where((t) => kEstadosOcupanTecnico.contains(t['estado'] as String?))
      .toList()
    ..sort(compararEnCola);
  return enCurso.isEmpty ? null : enCurso.first['id'] as String?;
}

/// ¿Esta orden está bloqueada para el técnico?
///
/// Lo está si ocupa la cola pero no es la activa. Todo lo demás —la activa, las
/// que están en espera, las ya resueltas— se puede abrir.
bool ordenBloqueada(Map<String, dynamic> orden, String? idActiva) {
  if (!kEstadosOcupanTecnico.contains(orden['estado'] as String?)) return false;
  return orden['id'] != idActiva;
}
