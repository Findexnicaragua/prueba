import 'dart:convert';

import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;

/// El bloque "CAMBIO DE PLAN" del recibo: la explicación de por qué esta cuota
/// vale distinto que las demás.
///
/// **Por qué existe** (pedido de Rubén, 2026-09-02): cuando un contrato cambia
/// de plan a mitad de ciclo, la cuota en curso queda con un cargo por la
/// diferencia de los días que faltan. Hasta hoy el cliente recibía un papel que
/// decía "Monto: 745,16 C$" y nada más — el único lugar donde el cargo podía
/// aparecer era el bloque "Montos de la cuota", que los tres ISPs tienen
/// apagado, y aun prendido decía apenas "Cargo: Diferencia por cambio de plan".
/// Ni de qué plan a cuál, ni cuántos días, ni a qué precio.
///
/// **Mismo patrón que `recibo_cargos.dart`**: acá viven la consulta y el
/// armado de líneas; los renderers (ticket / PDF / ESC-POS) solo maquetan. Así
/// los tres imprimen exactamente lo mismo y no se pueden desincronizar.
///
/// **100% offline**: todo sale de `cargos_extra.detalle` / `saldos_favor.detalle`
/// (0267), que se sincronizan al device. NO se recalcula nada: el papel tiene
/// que seguir diciendo lo mismo dentro de dos años, aunque la fórmula del
/// prorrateo cambie. Es la lección de 0262 con el mes.
///
/// **El desglose día por día NO va en el papel** (decisión de Rubén,
/// 2026-09-02). Quien tiene que poder rehacer la multiplicación es el que
/// AUTORIZA el cambio, y para eso está la pantalla; el cliente necesita saber
/// de qué plan a cuál pasó, cuánto paga este mes y cuánto va a pagar desde el
/// siguiente. Los tramos **se siguen guardando** en `detalle`: sacarlos del
/// papel es una decisión de impresión, no de datos. Lo que no se guarda no se
/// recupera; lo que no se imprime, sí.

/// Un renglón del bloque. [valor] null = línea de texto a todo el ancho.
class LineaCambioPlan {
  const LineaCambioPlan(this.texto, [this.valor, this.destacada = false]);

  /// Lo que va a la izquierda.
  final String texto;

  /// Lo que va a la derecha, ya formateado. Null = sin columna derecha.
  final String? valor;

  /// La línea del total: los renderers la ponen en negrita / doble alto.
  final bool destacada;
}

/// Trae las transiciones de plan que afectan a las cuotas de ESTE recibo.
///
/// Dos orígenes, porque la subida y la bajada no se guardan igual:
///  - **sube** → `cargos_extra` (origen='cambio_plan'), que suma a la cuota;
///  - **baja** → `saldos_favor`, que NO toca la cuota (invariante #4: el
///    crédito no es un pago).
///
/// ⚠️ El bucket `por_cobrador` de las sync rules NO baja `saldos_favor` (es
/// deliberado: los créditos son cosa del admin). O sea que en el celular de un
/// cobrador la consulta de bajada vuelve vacía y el bloque no se dibuja. En la
/// PC del admin sí. Documentado en docs/reglas/cambio-plan.md.
Future<List<Map<String, dynamic>>> fetchCambioPlan(List<String> cuotaIds) async {
  if (cuotaIds.isEmpty) return const [];
  final ph = List.filled(cuotaIds.length, '?').join(',');
  final subidas = await ps.db.getAll(
    '''
    SELECT cuota_id, monto, detalle, 1 AS sube
      FROM cargos_extra
     WHERE cuota_id IN ($ph) AND origen = 'cambio_plan' AND detalle IS NOT NULL
    ''',
    cuotaIds,
  );
  final bajadas = await ps.db.getAll(
    '''
    SELECT cuota_id, monto, detalle, 0 AS sube
      FROM saldos_favor
     WHERE cuota_id IN ($ph) AND detalle IS NOT NULL
    ''',
    cuotaIds,
  );
  return [...subidas, ...bajadas];
}

String _ddmm(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso);
  if (d == null) return '';
  return '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';
}

/// Arma las líneas del bloque para UNA cuota. Vacío = esta cuota no viene de un
/// cambio de plan, y entonces el bloque no ocupa ni una línea en el recibo.
///
/// [montoCuota] es el monto NOMINAL de la cuota (sin el cargo): es "el mes al
/// plan anterior", que es como la app realmente lo calcula. Se lo dice así de
/// frente en vez de fingir que la cuota se partió en dos tramos de plan: eso
/// daría otro número (ver docs/reglas/cambio-plan.md) y el papel tiene que
/// explicar el total que efectivamente se cobra.
List<LineaCambioPlan> lineasCambioPlan(
  List<Map<String, dynamic>> filas,
  Object? cuotaId, {
  double? montoCuota,
}) {
  if (cuotaId == null) return const [];
  Map<String, dynamic>? d;
  num monto = 0;
  var sube = true;
  for (final f in filas) {
    if (f['cuota_id'] != cuotaId) continue;
    try {
      d = jsonDecode(f['detalle'] as String) as Map<String, dynamic>;
    } catch (_) {
      continue; // detalle ilegible: mejor no imprimir nada que imprimir basura.
    }
    monto = f['monto'] as num? ?? 0;
    sube = (f['sube'] as num? ?? 1) == 1;
    break;
  }
  if (d == null) return const [];

  final planAntes = d['plan_antes'] as String?;
  final planDespues = d['plan_despues'] as String?;
  final precioAntes = (d['precio_antes'] as num?)?.toDouble();
  final precioDespues = (d['precio_despues'] as num?)?.toDouble();
  final dias = (d['dias'] as num?)?.toInt() ?? 0;
  final rango =
      '${_ddmm(d['desde'] as String?)} al ${_ddmm(d['hasta'] as String?)}';

  final out = <LineaCambioPlan>[];
  if (planAntes != null) {
    out.add(LineaCambioPlan('Antes  $planAntes'));
    if (precioAntes != null) {
      out.add(LineaCambioPlan('       ${Fmt.cordobas(precioAntes)} / mes'));
    }
  }
  if (planDespues != null) {
    out.add(LineaCambioPlan('Ahora  $planDespues'));
    if (precioDespues != null) {
      out.add(LineaCambioPlan('       ${Fmt.cordobas(precioDespues)} / mes'));
    }
  }

  if (sube) {
    if (montoCuota != null) {
      out.add(LineaCambioPlan(
          'Mes al plan anterior', Fmt.cordobas(montoCuota)));
    }
    out.add(LineaCambioPlan('Diferencia por $dias dias'));
    out.add(LineaCambioPlan(rango, Fmt.cordobas(monto)));
    if (montoCuota != null) {
      out.add(LineaCambioPlan(
          'Total del mes', Fmt.cordobas(montoCuota + monto), true));
    }
  } else {
    // BAJADA: la cuota NO baja — sigue facturando el plan anterior entero — y
    // la diferencia queda a favor del cliente. Decirlo así de explícito es el
    // punto: hoy una bajada de plan no aparece en NINGÚN comprobante y el
    // cliente nunca se entera de que tiene plata a favor.
    if (montoCuota != null) {
      out.add(const LineaCambioPlan('Este mes se factura'));
      out.add(const LineaCambioPlan('completo al plan'));
      out.add(LineaCambioPlan('anterior:', Fmt.cordobas(montoCuota)));
    }
    out.add(LineaCambioPlan('A su favor por $dias dias'));
    out.add(LineaCambioPlan(rango, Fmt.cordobas(monto), true));
    out.add(const LineaCambioPlan('Se aplica a su proxima'));
    out.add(const LineaCambioPlan('factura.'));
  }

  if (planDespues != null && precioDespues != null) {
    out.add(const LineaCambioPlan('Desde el proximo mes su'));
    out.add(LineaCambioPlan('cuota sera ${Fmt.cordobas(precioDespues)}'));
  }
  return out;
}
