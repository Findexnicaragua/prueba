import 'dart:convert';

import '../../powersync/db.dart' as ps;

/// Data del DESGLOSE de descuentos/cargos del recibo (rediseño 2026-06-11):
/// el bloque `cuota` muestra una línea por cada cargo_extra vigente de la(s)
/// cuota(s) cobrada(s), para que el cliente vea POR QUÉ el saldo es el que
/// es (antes los descuentos eran invisibles: solo cambiaba el neto).
///
/// Mismo patrón que `fetchMoraContrato`: los renderers (ticket/PDF) son
/// puros — el call-site busca la data y la pasa hecha. 100% offline.
Future<List<Map<String, dynamic>>> fetchCargosCuotas(
    List<String> cuotaIds, {
  List<String> pagoIds = const [],
}) async {
  if (cuotaIds.isEmpty) return const [];
  final cuotaPh = List.filled(cuotaIds.length, '?').join(',');
  // Los cargos `origen='puente'` (cambio de fecha de pago) llevan el `pago_id`
  // de SU operación. En el recibo se muestran SOLO los del/los pago(s) de ESTE
  // recibo: una cuota con varios cambios de fecha acumula varios puentes, y
  // mostrarlos todos no cuadraría con el COBRADO (que es solo este pago). El
  // RESTO de cargos (descuentos/reconexión/ajustes) NO se filtra — comportamiento
  // intacto. Sin `pagoIds` (no debería pasar en un recibo) se ocultan los puentes
  // por seguridad (mejor omitir que mostrar puentes ajenos).
  final puenteScope = pagoIds.isEmpty
      ? "AND (origen IS NULL OR origen != 'puente')"
      : "AND (origen IS NULL OR origen != 'puente' "
          "OR pago_id IN (${List.filled(pagoIds.length, '?').join(',')}))";
  return ps.db.getAll(
    '''
    SELECT cuota_id, tipo, monto, porcentaje, descripcion, origen, aplicado_en
      FROM cargos_extra
     WHERE cuota_id IN ($cuotaPh)
       $puenteScope
     ORDER BY aplicado_en ASC
    ''',
    [...cuotaIds, ...pagoIds],
  );
}

/// Etiqueta de una línea de cargo en el recibo. Con [conMotivo] apagado
/// queda solo la semántica (Ajuste / Promo / Descuento / Reconexión /
/// Cargo); encendido se agrega el motivo, evitando redundancia en los
/// automáticos cuyo motivo ya ES la etiqueta.
String cargoEtiquetaRecibo(Map<String, dynamic> c, {required bool conMotivo}) {
  final tipo = c['tipo'] as String? ?? '';
  final origen = c['origen'] as String? ?? 'cobro';
  final motivo = (c['descripcion'] as String?)?.trim() ?? '';
  // Puente del cambio de fecha de pago (feature C): etiqueta fija y
  // autoexplicada (el motivo guardado es verboso → sería redundante repetirlo).
  if (origen == 'puente') return 'Puente de pago';
  // Cambio de plan (R22, origen propio desde 0267). Antes nacía con
  // origen='cobro' y caía en el genérico "Cargo", indistinguible de un cargo
  // que alguien puso a mano. La línea corta es solo el respaldo: cuando el
  // cargo trae `detalle`, el recibo dibuja el BLOQUE de transición completo
  // (de qué plan a cuál, los días y el precio diario de cada mes) y esta
  // etiqueta no se usa.
  if (origen == 'cambio_plan') return 'Cambio de plan';
  final esDescuento = tipo.startsWith('descuento');
  final etiqueta = !esDescuento
      ? (tipo == 'reconexion' ? 'Reconexión' : 'Cargo')
      : switch (origen) {
          'ajuste' => 'Ajuste',
          'promo' => 'Promo',
          _ => 'Descuento',
        };
  if (!conMotivo || motivo.isEmpty) return etiqueta;
  // Los automáticos del cobro se explican solos ("Descuento pronto pago",
  // "Cargo por reconexión") — repetir la etiqueta sería ruido.
  if (motivo == 'Descuento pronto pago' || motivo == 'Cargo por reconexión') {
    return motivo;
  }
  return '$etiqueta: $motivo';
}

/// Los DOS renglones con que se muestra un cargo en pantalla: la etiqueta y,
/// si el cargo trae contexto, una línea de apoyo que lo explica.
///
/// Nace del reporte de Rubén (2026-09-02) probando un cambio de plan: la
/// pantalla de cobro decía *"Cobro de Septiembre 2026 · 500,00 C$"* en grande y
/// *"Con descuentos/cargos: 846,67 C$"* en gris. Él mismo leyó el 846,67 como
/// "la cantidad del prorrateo" cuando es el TOTAL —el prorrateo son 346,67—, y
/// si le pasa a quien diseñó la pantalla, al cobrador le pasa seguro.
///
/// **De dónde sale lo específico.** Del `detalle` que el cargo congeló al
/// nacer (migración `0267`), NO de un JOIN al plan vivo: el plan del contrato
/// ya cambió —de eso se trata el cargo—, así que resolverlo por JOIN diría el
/// plan NUEVO donde tiene que decir el viejo. Es la lección 18 de AGENTS, la
/// misma que obligó a congelar el plan en el recibo.
///
/// Devuelve `null` cuando no hay nada que agregar: la mayoría de los cargos se
/// explican con su etiqueta y una línea vacía sería ruido.
String? cargoLineaDetalle(Map<String, dynamic> c) {
  if ((c['origen'] as String?) != 'cambio_plan') return null;
  final crudo = c['detalle'] as String?;
  if (crudo == null || crudo.trim().isEmpty) return null;
  try {
    final d = jsonDecode(crudo);
    if (d is! Map) return null;
    final dias = (d['dias'] as num?)?.toInt();
    final desde = _fechaCorta(d['desde'] as String?);
    final hasta = _fechaCorta(d['hasta'] as String?);
    if (dias == null || dias <= 0) return null;
    final plural = dias == 1 ? 'día' : 'días';
    if (desde == null || hasta == null) return '$dias $plural';
    return '$dias $plural, del $desde al $hasta';
  } catch (_) {
    // Un `detalle` que no parsea NO puede romper la pantalla de cobro: se
    // cae a la etiqueta sola, que es lo que había antes de 0267.
    return null;
  }
}

/// El plan al que corresponde la MENSUALIDAD de la cuota, según el cargo de
/// cambio de plan que tenga.
///
/// La base de la cuota (500) se facturó con el plan VIEJO — el cargo solo
/// agrega la diferencia. Nombrarlo evita la lectura de que los 500 son del
/// plan nuevo, que es la confusión que motivó todo esto.
String? planDeLaMensualidad(List<Map<String, dynamic>> cargos) {
  for (final c in cargos) {
    if ((c['origen'] as String?) != 'cambio_plan') continue;
    final crudo = c['detalle'] as String?;
    if (crudo == null || crudo.trim().isEmpty) continue;
    try {
      final d = jsonDecode(crudo);
      if (d is Map) {
        final p = (d['plan_antes'] as String?)?.trim();
        if (p != null && p.isNotEmpty) return p;
      }
    } catch (_) {
      // Igual que arriba: sin detalle utilizable se muestra "Mensualidad".
    }
  }
  return null;
}

/// `2026-09-03` → `03/09`. Devuelve null si no parsea.
String? _fechaCorta(String? iso) {
  if (iso == null) return null;
  final d = DateTime.tryParse(iso);
  if (d == null) return null;
  return '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';
}
