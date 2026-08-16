import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/pago.dart';
import '../services/correlativo_store.dart';
import '../utils/colchon_indefinido.dart';
import '../utils/cuota_estado.dart';
import '../utils/op_log.dart';
import '../utils/prorrateo.dart';

/// Resultado de un cobro exitoso. La UI navega a /recibo/[reciboId].
class CobroResultado {
  const CobroResultado({
    required this.pagoId,
    required this.reciboId,
    this.reciboIds,
    this.grupoCobro,
  });
  final String pagoId;
  final String reciboId;
  final List<String>? reciboIds;
  final String? grupoCobro;

  bool get esMultiCuota => reciboIds != null && reciboIds!.length > 1;
}

class CargoAutoInfo {
  const CargoAutoInfo({
    required this.cuotaId,
    required this.tipo,
    required this.monto,
    this.porcentaje,
    required this.descripcion,
  });
  final String cuotaId;
  final String tipo;
  final double monto;
  final double? porcentaje;
  final String descripcion;
}

/// Se intentó cobrar una cuota dejando atrás otra más antigua pendiente del
/// mismo contrato. Chokepoint oldest-first (#4 — backlog money-integrity): la
/// RED FINAL que hace IMPOSIBLE, para cualquier caller (online u offline),
/// saltear una cuota vieja impaga. El mensaje sale en español y
/// `mensajeErrorHumano` lo deja pasar tal cual (tiene tildes).
class CobroFueraDeOrdenException implements Exception {
  const CobroFueraDeOrdenException({this.periodo});

  /// Período de la cuota más antigua que falta cobrar (para el mensaje).
  final String? periodo;

  @override
  String toString() => periodo == null
      ? 'Cobrá primero la cuota más antigua pendiente de este contrato '
          'antes de pagar una más nueva.'
      : 'Cobrá primero la cuota más antigua pendiente de este contrato '
          '(período $periodo) antes de pagar una más nueva.';
}

class PagosRepo {
  /// [db] permite inyectar una `PowerSyncDatabase` para tests. En producción
  /// queda null y el repo usa la global `ps.db` (no se cambia el wiring).
  PagosRepo({PowerSyncDatabase? db}) : _db = db;
  final _uuid = const Uuid();
  final PowerSyncDatabase? _db;
  PowerSyncDatabase get _dbOrGlobal => _db ?? ps.db;
  /// Igual que [_dbOrGlobal] pero pasando por la guardia de solo-lectura
  /// (`ps.dbW`, 0198). SOLO para escrituras: las lecturas siguen por
  /// [_dbOrGlobal], que el rol `lectura` sí puede usar.
  ///
  /// Existe porque el reemplazo masivo a `ps.dbW` buscó el literal
  /// `ps.db.writeTransaction` y estos repos van por el getter — los 18
  /// writeTransaction de dinero se habían quedado fuera de la guardia (audit
  /// 2026-07-26). Al inyectar `_db` en tests, la guardia no aplica.
  PowerSyncDatabase get _dbWOrGlobal => _db ?? ps.dbW;

  /// Actor del op_log: el usuario REAL que ejecuta (lee su nombre del SQLite
  /// local). El super_admin —impersonando o no— se registra como **"System
  /// Admin"** (actor_id NULL), nunca con su nombre real, para no filtrar su
  /// identidad en el change log del tenant (diseño 0128 / op_log.dart). Para
  /// cobros el caller además bloquea la impersonación (atribución al usuario).
  Future<OpLogActor> _opLogActor(String cobradorId) =>
      OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);

  /// Chokepoint oldest-first (#4 — backlog money-integrity): la RED FINAL que
  /// impide cobrar una cuota dejando atrás otra más antigua pendiente del
  /// MISMO contrato. Corre al inicio de registrarCobro/registrarCobroMultiple,
  /// ANTES de cualquier INSERT, consultando el SQLite local → vale online y
  /// offline. NO reemplaza los guards de UX (snackbars, set contiguo, queries
  /// oldest): es el cierre para cualquier caller presente/futuro o un set que
  /// quedó stale entre que se armó y se confirmó.
  ///
  /// Reglas: agrupa por contrato; los CARGOS MANUALES (tipo_cargo_manual) y las
  /// cuotas anuladas/pagadas quedan FUERA del orden a propósito. Permite el
  /// adelanto CONTIGUO (pagar mayo+junio juntos). Dos cuotas con la MISMA
  /// (fecha_vencimiento, período) son intercambiables (no fuerza una sobre la
  /// otra). Límite conocido y aceptado: multi-device offline — si la cuota vieja
  /// aún no sincronizó a este device, no se detecta sin trigger server.
  Future<void> _validarOldestFirst(List<String> cuotaIds) async {
    if (cuotaIds.isEmpty) return;
    final ph = List.filled(cuotaIds.length, '?').join(',');
    final aCobrar = await _dbOrGlobal.getAll(
      'SELECT id, contrato_id, tipo_cargo_manual FROM cuotas WHERE id IN ($ph)',
      cuotaIds,
    );
    // Agrupar las cuotas REGULARES a cobrar por contrato (los cargos manuales
    // se cobran en cualquier orden → quedan fuera del chequeo).
    final porContrato = <String, Set<String>>{};
    for (final r in aCobrar) {
      final contratoId = r['contrato_id'] as String?;
      final esManual = r['tipo_cargo_manual'] != null;
      if (esManual || contratoId == null) continue;
      (porContrato[contratoId] ??= <String>{}).add(r['id'] as String);
    }

    String keyDe(Map<String, dynamic> r) =>
        '${r['fecha_vencimiento']}|${r['periodo']}';

    for (final entry in porContrato.entries) {
      // Cuotas regulares VIVAS (pendiente/parcial) del contrato, de la más
      // vieja a la más nueva. Las anuladas (suspensión) quedan fuera por el
      // estado → un hueco anulado no bloquea la siguiente.
      final pendientes = await _dbOrGlobal.getAll(
        'SELECT id, periodo, fecha_vencimiento FROM cuotas '
        'WHERE contrato_id = ? AND tipo_cargo_manual IS NULL '
        "AND estado IN ('pendiente','parcial') "
        'ORDER BY fecha_vencimiento ASC, periodo ASC',
        [entry.key],
      );
      final selSet = entry.value;
      // Solo cuentan las seleccionadas que están vivas (una ya pagada no
      // "adelanta" nada).
      final selPend = pendientes.where((r) => selSet.contains(r['id'])).toList();
      if (selPend.isEmpty) continue;
      // La clave (venc, período) más NUEVA que se está cobrando.
      final maxKeySel =
          selPend.map(keyDe).reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
      // ¿Hay una cuota viva ESTRICTAMENTE más vieja que esa, sin cobrar?
      for (final r in pendientes) {
        if (keyDe(r).compareTo(maxKeySel) < 0 && !selSet.contains(r['id'])) {
          throw CobroFueraDeOrdenException(periodo: r['periodo'] as String?);
        }
      }
    }
  }

  /// Registra un cobro: inserta pago + recibo en una transacción local.
  /// El trigger SQL del server actualizará cuota.monto_pagado/estado.
  ///
  /// El correlativo se calcula localmente (max(correlativo)+1 por
  /// cobrador+prefijo) SOLO como número PROVISIONAL para imprimir al toque.
  /// La VERDAD la pone el SERVER (migración 0215): el trigger
  /// `recibos_asignar_correlativo` reasigna el correlativo desde un contador
  /// atómico por (tenant, prefijo) al INSERT, ignorando el que adivinó el
  /// device. Así dos devices de la MISMA cuenta ("Oficina" en 2 PCs) ya NO
  /// colisionan: antes el 2º recibo quedaba DUPLICADO (no había unique) o —en la
  /// época en que sí lo había— se descartaba (cobro sin recibo, INV5). Solo en la
  /// carrera real el nº IMPRESO puede diferir del guardado (el server gana).
  Future<CobroResultado> registrarCobro({
    required String tenantId,
    required String cobradorId,
    required String prefijoRecibo,
    required String cuotaId,
    required double montoCordobas,
    double vueltoCordobas = 0,
    required Moneda moneda,
    required double montoOriginal,
    required double tasaConversion,
    required MetodoPago metodo,
    String? referencia,
    String? fotoComprobantePath,
    double? lat,
    double? lng,
    String? notas,
    DateTime? fechaPago,
    List<CargoAutoInfo>? cargosAuto,
  }) async {
    // Chokepoint oldest-first (#4): no cobrar dejando atrás una vieja impaga.
    await _validarOldestFirst([cuotaId]);

    final pagoId = _uuid.v4();
    final reciboId = _uuid.v4();
    final clientLocalIdPago = _uuid.v4();
    final clientLocalIdRecibo = _uuid.v4();
    final now = (fechaPago ?? DateTime.now()).toIso8601String();
    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final correlativoEmitido = <int>[];
    // op_log (rework change log): id de la intención + actor (el cobrador real).
    final opId = OpLog.nuevoOpId();
    final actor = await _opLogActor(cobradorId);

    // Guard correlativo: SIEMPRE consultar el server para el MAX porque
    // los recibos anulados no se sincronizan al cobrador (sync rules
    // filtran anulado = false), pero el server SÍ los tiene. Con timeout
    // corto: sin él, una señal degradada (1 raya / portal cautivo) colgaba
    // el flujo de COBRO varios minutos (audit 2026-06-11 M6); el catch
    // degrada al guard local. Complemento OFFLINE: el high-water mark de
    // CorrelativoStore nunca decrece — cubre el caso "recibo anulado recién
    // removido del SQLite por el sync + sin señal", donde el MAX local baja
    // y se reimprimía un número ya emitido (audit #2).
    int? pisoCorrelativo;
    try {
      final serverRows = await Supabase.instance.client
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijoRecibo)
          .order('correlativo', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 5));
      if (serverRows.isNotEmpty) {
        pisoCorrelativo = (serverRows.first['correlativo'] as num).toInt();
      }
    } catch (_) {}
    if (pisoCorrelativo != null) {
      // Reflejar en el hwm lo emitido desde OTROS dispositivos.
      await CorrelativoStore.subirA(
          cobradorId, prefijoRecibo, pisoCorrelativo);
    }
    final hwmLocal = await CorrelativoStore.leer(cobradorId, prefijoRecibo);

    await _dbWOrGlobal.writeTransaction((tx) async {
      if (cargosAuto != null) {
        for (final cargo in cargosAuto) {
          await tx.execute(
            '''
            INSERT INTO cargos_extra (
              id, tenant_id, cuota_id, cobrador_id, tipo, monto,
              porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id,
              ocurrido_en, origen, pago_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'cobro', ?)
            ''',
            [
              _uuid.v4(), tenantId, cargo.cuotaId, cobradorId,
              cargo.tipo, cargo.monto, cargo.porcentaje,
              cargo.descripcion, cobradorId,
              // aplicado_en en UTC (B10; antes heredaba el local-naive de fecha_pago)
              ocurridoEn, _uuid.v4(),
              ocurridoEn,
              // pago_id (0115): liga el cargo automático a SU cobro para que
              // anularlo revierta los descuentos (M3) — trigger server + mirror.
              pagoId,
            ],
          );
        }
      }

      // Calcular correlativo DENTRO de la transacción para evitar carrera
      // entre dos cobros simultáneos. NO filtramos anulado=0: si filtramos,
      // anular el recibo #1 hace que el próximo cobro reutilice el #1 y
      // colisiona con el unique constraint server (numero_completo).
      // La secuencia incluye anulados — quedan "huecos" referenciales OK.
      final rows = await tx.getAll(
        '''
        SELECT COALESCE(MAX(correlativo), 0) AS max_local
          FROM recibos
         WHERE cobrador_id = ? AND prefijo = ?
        ''',
        [cobradorId, prefijoRecibo],
      );
      final maxLocal = (rows.first['max_local'] as num).toInt();
      final pisoServer = pisoCorrelativo ?? 0;
      final piso = pisoServer > hwmLocal ? pisoServer : hwmLocal;
      final correlativo = (maxLocal > piso ? maxLocal : piso) + 1;
      correlativoEmitido.add(correlativo);
      final numeroCompleto =
          '$prefijoRecibo-${correlativo.toString().padLeft(5, '0')}';

      await tx.execute(
        '''
        INSERT INTO pagos (
          id, tenant_id, cuota_id, cobrador_id,
          monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion,
          metodo, referencia, foto_comprobante_path,
          lat, lng, notas, fecha_pago, anulado, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        ''',
        [
          pagoId,
          tenantId,
          cuotaId,
          cobradorId,
          montoCordobas,
          vueltoCordobas,
          moneda.value,
          montoOriginal,
          tasaConversion,
          metodo.value,
          referencia,
          fotoComprobantePath,
          lat,
          lng,
          notas,
          now,
          clientLocalIdPago,
          ocurridoEn,
        ],
      );

      await tx.execute(
        '''
        INSERT INTO recibos (
          id, tenant_id, pago_id, cobrador_id,
          prefijo, correlativo, numero_completo,
          reimpresiones, anulado, created_at, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
        ''',
        [
          reciboId,
          tenantId,
          pagoId,
          cobradorId,
          prefijoRecibo,
          correlativo,
          numeroCompleto,
          now,
          clientLocalIdRecibo,
          ocurridoEn,
        ],
      );

      // Reflejar localmente el efecto del trigger server. Calculamos el
      // nuevo estado en Dart espejando exactamente la lógica SQL de
      // `recalcular_cuota_desde_pagos` (migración 0018): el total real es
      // monto_cuota - descuentos + cargos. Sin esto, una cuota con
      // descuento podía mostrarse 'parcial' localmente y luego saltar a
      // 'pagada' cuando llegue el sync.
      final cuotaRows = await tx.getAll(
        'SELECT monto, monto_pagado, estado, cargos_neto, contrato_id FROM cuotas WHERE id = ?',
        [cuotaId],
      );
      if (cuotaRows.isNotEmpty) {
        final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
        final pagadoViejo =
            (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
        final estadoActual = cuotaRows.first['estado'] as String;
        final cargosNetoViejo =
            (cuotaRows.first['cargos_neto'] as num? ?? 0).toDouble();
        final pagadoNuevo = pagadoViejo + montoCordobas;
        final delta = await _deltaCargosExtra(tx, cuotaId);
        // Tope contra el saldo VIVO. Va DESPUÉS de aplicar `cargosAuto` porque
        // esos cargos (reconexión, etc.) suben el total de la propia cuota:
        // medido contra `cargos_neto` viejo rechazaba cobros legítimos.
        //
        // `cobro_calculo` ya hace `aplicado = min(entregado, saldo)`, pero con
        // el saldo que la PANTALLA tenía cargado, que puede estar viejo si otro
        // equipo cobró mientras tanto. Sin esto los dos cobros se suman: pasó en
        // producción (cuota de C$1.282 que quedó con C$2.564, dos pagos a 47
        // segundos). `editarPago` ya tenía su tope; faltaba en el alta.
        //
        // Tolerancia de 1 centavo: los montos son numeric(10,2) y no se rechaza
        // por ruido de redondeo.
        final totalVivo = montoCuota + delta;
        if (pagadoNuevo > totalVivo + 0.01) {
          final restante = (totalVivo - pagadoViejo).clamp(0, double.infinity);
          throw Exception(restante <= 0
              ? 'Esta cuota ya está cubierta. Actualizá la pantalla: alguien '
                  'más la cobró.'
              : 'La cuota solo admite C\$${restante.toStringAsFixed(2)} más. '
                  'Actualizá la pantalla: alguien más cobró parte.');
        }
        // M3-MONEY: el trigger Postgres `cargos_extra_actualizar_neto_trg`
        // (0023) mantiene cuotas.cargos_neto = SUM neta de cargos_extra.
        // Ese trigger corre recién al sync, así que offline reflejamos el
        // efecto localmente. `delta` ya es exactamente cargos_neto
        // (reconexion/otro suman, descuento_* restan).
        await tx.execute(
          'UPDATE cuotas SET cargos_neto = ?, ocurrido_en = ? WHERE id = ?',
          [delta, ocurridoEn, cuotaId],
        );
        final nuevoEstado = calcularEstadoCuota(
          estadoActual: estadoActual,
          montoCuota: montoCuota,
          pagadoNuevo: pagadoNuevo,
          deltaCargosExtra: delta,
        );
        await tx.execute(
          'UPDATE cuotas SET monto_pagado = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
          [pagadoNuevo, nuevoEstado, ocurridoEn, cuotaId],
        );

        // op_log (rework change log): UNA entrada en la cuota — "Cobró", scoped
        // a sus atributos (estado, saldo canónico). Monto y recibo van al
        // resumen para el título. Misma writeTransaction → atómico con el cobro.
        final saldoAntes = montoCuota + cargosNetoViejo - pagadoViejo;
        final saldoDespues = montoCuota + delta - pagadoNuevo;
        await OpLog.escribir(
          tx,
          tenantId: tenantId,
          opId: opId,
          tipoOp: 'cobro',
          entidad: 'cuotas',
          entidadId: cuotaId,
          accion: 'update',
          diff: {
            'campos': [
              {'campo': 'estado', 'antes': estadoActual, 'despues': nuevoEstado},
              {
                'campo': 'saldo',
                'antes': saldoAntes < 0 ? 0 : saldoAntes,
                'despues': saldoDespues < 0 ? 0 : saldoDespues,
              },
            ],
            // Guardamos TODO el resumen del cobro; el render decide qué mostrar
            // según la config (defaults universales + override del super_admin).
            'resumen': {
              'monto': montoCordobas, // aplicado a la cuota (caja)
              'entregado': montoOriginal, // lo que dio el cliente (moneda orig.)
              'moneda': moneda.value,
              'vuelto': vueltoCordobas, // siempre en córdobas
              'metodo': metodo.value,
              'fecha_pago': now, // fecha del cobro (puede ser retroactiva)
              'recibo': numeroCompleto,
              'notas': notas, // nota opcional del cobrador (si la dejó)
            },
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurridoEn),
        );

        // Colchón (indefinidos): tras aplicar el cobro, re-asegurar 3 cuotas
        // pendientes después de la última pagada (el server no corre offline).
        // No-op para fijos; idempotente.
        // Cuota manual (cargo suelto sin contrato) → contrato_id NULL: ni el
        // colchón (es de contratos indefinidos) ni el mirror por-contrato
        // aplican. Cast nullable para no crashear (cargos manuales hoy off en
        // los tenants, pero blindado para los que los habiliten).
        final contratoIdCobro = cuotaRows.first['contrato_id'] as String?;
        if (contratoIdCobro != null) {
          await asegurarColchonIndefinido(tx, contratoIdCobro);
          // Mirror offline del color del mapa (Opción 2): recalcular el
          // vencimiento_mas_viejo del cliente para que el pin cambie al toque,
          // sin esperar la sincronización (online lo hace el trigger server).
          await recalcVmvDeContrato(tx, contratoIdCobro);
        }
      }
    });

    // Persistir el high-water mark (best-effort, post-tx): si el sync luego
    // remueve este recibo (anulación del admin), el número no se reusa.
    if (correlativoEmitido.isNotEmpty) {
      await CorrelativoStore.subirA(
          cobradorId, prefijoRecibo, correlativoEmitido.last);
    }

    return CobroResultado(pagoId: pagoId, reciboId: reciboId);
  }

  /// Registra un cobro multi-cuota: N pagos + N recibos en una sola
  /// transacción, todos vinculados por el mismo grupo_cobro UUID.
  /// Cada cuota recibe un pago por su saldo completo.
  Future<CobroResultado> registrarCobroMultiple({
    required String tenantId,
    required String cobradorId,
    required String prefijoRecibo,
    required List<String> cuotaIds,
    required List<double> montosCordobas,
    double vueltoCordobas = 0,
    required Moneda moneda,
    required List<double> montosOriginal,
    required double tasaConversion,
    required MetodoPago metodo,
    String? referencia,
    String? fotoComprobantePath,
    double? lat,
    double? lng,
    String? notas,
    DateTime? fechaPago,
    List<CargoAutoInfo>? cargosAuto,
  }) async {
    assert(cuotaIds.length == montosCordobas.length);
    assert(cuotaIds.length == montosOriginal.length);

    // Chokepoint oldest-first (#4): no cobrar dejando atrás una vieja impaga.
    await _validarOldestFirst(cuotaIds);

    final grupoCobro = _uuid.v4();
    // op_log (rework change log): grupoCobro ES el op_id de esta intención
    // (generaliza el patrón). Una entrada op_log por cuota, todas con este id.
    final actor = await _opLogActor(cobradorId);
    final now = (fechaPago ?? DateTime.now()).toIso8601String();
    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final reciboIds = <String>[];
    String? primerPagoId;

    // Guard correlativo (mismo que registrarCobro: timeout + hwm local).
    int? pisoMulti;
    try {
      final sr = await Supabase.instance.client
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijoRecibo)
          .order('correlativo', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 5));
      if (sr.isNotEmpty) pisoMulti = (sr.first['correlativo'] as num).toInt();
    } catch (_) {}
    if (pisoMulti != null) {
      await CorrelativoStore.subirA(cobradorId, prefijoRecibo, pisoMulti);
    }
    final hwmMulti = await CorrelativoStore.leer(cobradorId, prefijoRecibo);
    final correlativosEmitidos = <int>[];
    // IDs de pago precomputados: los cargos automáticos se insertan ANTES
    // del loop y necesitan ligarse al pago de SU cuota (pago_id, 0115/M3).
    final pagoIds = [for (var i = 0; i < cuotaIds.length; i++) _uuid.v4()];

    await _dbWOrGlobal.writeTransaction((tx) async {
      // Insertar cargos automáticos (reconexión / pronto pago) antes de
      // los pagos para que el delta de cargos_extra ya los incluya.
      if (cargosAuto != null) {
        for (final cargo in cargosAuto) {
          await tx.execute(
            '''
            INSERT INTO cargos_extra (
              id, tenant_id, cuota_id, cobrador_id, tipo, monto,
              porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id,
              ocurrido_en, origen, pago_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'cobro', ?)
            ''',
            [
              _uuid.v4(), tenantId, cargo.cuotaId, cobradorId,
              cargo.tipo, cargo.monto, cargo.porcentaje,
              cargo.descripcion, cobradorId,
              // aplicado_en en UTC (B10; antes heredaba el local-naive de fecha_pago)
              ocurridoEn, _uuid.v4(),
              ocurridoEn,
              pagoIds[cuotaIds.indexOf(cargo.cuotaId)],
            ],
          );
        }
      }

      final contratosAfectados = <String>{};
      for (var i = 0; i < cuotaIds.length; i++) {
        final pagoId = pagoIds[i];
        final reciboId = _uuid.v4();
        primerPagoId ??= pagoId;
        reciboIds.add(reciboId);

        final rows = await tx.getAll(
          '''
          SELECT COALESCE(MAX(correlativo), 0) AS max_local
            FROM recibos
           WHERE cobrador_id = ? AND prefijo = ?
          ''',
          [cobradorId, prefijoRecibo],
        );
        final maxL = (rows.first['max_local'] as num).toInt();
        final pisoSrv = pisoMulti ?? 0;
        final pisoM = pisoSrv > hwmMulti ? pisoSrv : hwmMulti;
        final correlativo = (maxL > pisoM ? maxL : pisoM) + 1;
        correlativosEmitidos.add(correlativo);
        final numeroCompleto =
            '$prefijoRecibo-${correlativo.toString().padLeft(5, '0')}';

        // El vuelto sólo se asigna al ÚLTIMO pago del grupo (simplifica el
        // recibo: una sola línea de vuelto). Los demás pagos van con 0.
        final esUltimo = i == cuotaIds.length - 1;
        final vueltoPago = esUltimo ? vueltoCordobas : 0.0;

        await tx.execute(
          '''
          INSERT INTO pagos (
            id, tenant_id, cuota_id, cobrador_id,
            monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion,
            metodo, referencia, foto_comprobante_path,
            lat, lng, notas, fecha_pago, anulado, grupo_cobro, client_local_id,
            ocurrido_en
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
          ''',
          [
            pagoId, tenantId, cuotaIds[i], cobradorId,
            montosCordobas[i], vueltoPago, moneda.value, montosOriginal[i], tasaConversion,
            metodo.value, referencia, fotoComprobantePath,
            lat, lng, notas, now, grupoCobro, _uuid.v4(),
            ocurridoEn,
          ],
        );

        await tx.execute(
          '''
          INSERT INTO recibos (
            id, tenant_id, pago_id, cobrador_id,
            prefijo, correlativo, numero_completo,
            reimpresiones, anulado, created_at, client_local_id, ocurrido_en
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
          ''',
          [
            reciboId, tenantId, pagoId, cobradorId,
            prefijoRecibo, correlativo, numeroCompleto, now, _uuid.v4(),
            ocurridoEn,
          ],
        );

        // Reflejar localmente el efecto del trigger server.
        final cuotaRows = await tx.getAll(
          'SELECT monto, monto_pagado, estado, cargos_neto, contrato_id FROM cuotas WHERE id = ?',
          [cuotaIds[i]],
        );
        if (cuotaRows.isNotEmpty) {
          // contrato_id es nullable (cuotas manuales standalone del cobro
          // puntual) — saltar el null para no romper el recálculo por contrato.
          final cId = cuotaRows.first['contrato_id'] as String?;
          if (cId != null) contratosAfectados.add(cId);
          final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
          final pagadoViejo =
              (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
          final estadoActual = cuotaRows.first['estado'] as String;
          final cargosNetoViejo =
              (cuotaRows.first['cargos_neto'] as num? ?? 0).toDouble();
          final pagadoNuevo = pagadoViejo + montosCordobas[i];
          final delta = await _deltaCargosExtra(tx, cuotaIds[i]);
          // M3-MONEY: mirror del trigger `cargos_extra_actualizar_neto_trg`
          // (0023). `delta` ya es cargos_neto (reconexion/otro suman,
          // descuento_* restan). Sin esto el saldo offline queda stale
          // hasta el sync.
          await tx.execute(
            'UPDATE cuotas SET cargos_neto = ?, ocurrido_en = ? WHERE id = ?',
            [delta, ocurridoEn, cuotaIds[i]],
          );
          final nuevoEstado = calcularEstadoCuota(
            estadoActual: estadoActual,
            montoCuota: montoCuota,
            pagadoNuevo: pagadoNuevo,
            deltaCargosExtra: delta,
          );
          await tx.execute(
            'UPDATE cuotas SET monto_pagado = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
            [pagadoNuevo, nuevoEstado, ocurridoEn, cuotaIds[i]],
          );

          // op_log: UNA entrada por ESTA cuota (todas comparten grupoCobro como
          // op_id). Scoped a la cuota; su propio recibo va en el resumen.
          final saldoAntes = montoCuota + cargosNetoViejo - pagadoViejo;
          final saldoDespues = montoCuota + delta - pagadoNuevo;
          await OpLog.escribir(
            tx,
            tenantId: tenantId,
            opId: grupoCobro,
            tipoOp: 'cobro',
            entidad: 'cuotas',
            entidadId: cuotaIds[i],
            accion: 'update',
            diff: {
              'campos': [
                {'campo': 'estado', 'antes': estadoActual, 'despues': nuevoEstado},
                {
                  'campo': 'saldo',
                  'antes': saldoAntes < 0 ? 0 : saldoAntes,
                  'despues': saldoDespues < 0 ? 0 : saldoDespues,
                },
              ],
              'resumen': {
                'monto': montosCordobas[i],
                'entregado': montosOriginal[i],
                'moneda': moneda.value,
                'vuelto': vueltoPago, // solo el último pago lleva vuelto
                'metodo': metodo.value,
                'fecha_pago': now,
                'recibo': numeroCompleto,
                'notas': notas,
              },
            },
            actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn),
          );
        }
      }

      // Colchón (indefinidos): una vez por contrato afectado, con el estado
      // final (todos los pagos del grupo ya aplicados). Offline-first; el
      // server no corre acá. No-op para fijos.
      for (final cId in contratosAfectados) {
        await asegurarColchonIndefinido(tx, cId);
        // Mirror offline del color del mapa (Opción 2): ver registrarCobro.
        await recalcVmvDeContrato(tx, cId);
      }
    });

    // Persistir el high-water mark (best-effort, post-tx).
    if (correlativosEmitidos.isNotEmpty) {
      await CorrelativoStore.subirA(
          cobradorId, prefijoRecibo, correlativosEmitidos.last);
    }

    return CobroResultado(
      pagoId: primerPagoId!,
      reciboId: reciboIds.first,
      reciboIds: reciboIds,
      grupoCobro: grupoCobro,
    );
  }

  /// Anula un pago aplicando soft delete. También marca como anulados los
  /// recibos asociados. El trigger server recalcula cuota.monto_pagado/estado.
  Future<void> anularPago({
    required String pagoId,
    required String anuladoPorId,
    required String motivo,
  }) async {
    // Hora REAL del dispositivo en UTC — para el change log y los timestamps de
    // anulación (anulado_en del pago y del recibo), consistente entre sí (B10).
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    // op_log (rework change log): anular es su PROPIA intención (id propio).
    final opId = OpLog.nuevoOpId();
    final actor = await _opLogActor(anuladoPorId);
    await _dbWOrGlobal.writeTransaction((tx) async {
      // Snapshot del monto antes de marcar anulado, para ajustar cuota local.
      final pagoRows = await tx.getAll(
        'SELECT cuota_id, monto_cordobas, tenant_id FROM pagos WHERE id = ? AND anulado = 0',
        [pagoId],
      );
      if (pagoRows.isEmpty) return;
      final cuotaId = pagoRows.first['cuota_id'] as String;
      final monto = (pagoRows.first['monto_cordobas'] as num).toDouble();
      final tenantId = pagoRows.first['tenant_id'] as String;

      await tx.execute(
        '''
        UPDATE pagos
           SET anulado = 1, anulado_en = ?, anulado_por = ?, motivo_anulacion = ?,
               ocurrido_en = ?
         WHERE id = ?
        ''',
        [ocurridoEn, anuladoPorId, motivo, ocurridoEn, pagoId],
      );

      await tx.execute(
        '''
        UPDATE recibos
           SET anulado = 1, anulado_en = ?, anulado_por = ?, ocurrido_en = ?
         WHERE pago_id = ? AND anulado = 0
        ''',
        [ocurridoEn, anuladoPorId, ocurridoEn, pagoId],
      );

      // Mirror del trigger server trg_pagos_revertir_descuentos (0115, M3):
      // los DESCUENTOS que ESTE cobro insertó (pronto pago automático Y el
      // manual del cobrador — desde el rediseño 2026-06-11 ambos viajan
      // diferidos con pago_id) se borran — sin esto, la cuota quedaba con
      // el total rebajado para siempre. La reconexión y los cargos 'otro'
      // se preservan a propósito (se siguen debiendo). Sin pago_id no se
      // toca nada: solo cargos históricos pre-0115.
      await tx.execute(
        '''
        DELETE FROM cargos_extra
         WHERE pago_id = ?
           AND tipo IN ('descuento_monto', 'descuento_porcentaje')
        ''',
        [pagoId],
      );

      // Reflejar localmente el recálculo del trigger server, considerando
      // cargos_extra (descuentos restan, reconexión/otro suman). El delta se
      // lee DESPUÉS del DELETE de arriba, así que cargos_neto también espeja
      // la reversión.
      final cuotaRows = await tx.getAll(
        'SELECT monto, monto_pagado, estado, cargos_neto, contrato_id FROM cuotas WHERE id = ?',
        [cuotaId],
      );
      if (cuotaRows.isNotEmpty) {
        final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
        final pagadoViejo =
            (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
        final estadoActual = cuotaRows.first['estado'] as String;
        final cargosNetoViejo =
            (cuotaRows.first['cargos_neto'] as num? ?? 0).toDouble();
        final pagadoNuevo = (pagadoViejo - monto).clamp(0.0, double.infinity);
        final delta = await _deltaCargosExtra(tx, cuotaId);
        final nuevoEstado = calcularEstadoCuota(
          estadoActual: estadoActual,
          montoCuota: montoCuota,
          pagadoNuevo: pagadoNuevo.toDouble(),
          deltaCargosExtra: delta,
        );
        await tx.execute(
          'UPDATE cuotas SET monto_pagado = ?, estado = ?, cargos_neto = ?, ocurrido_en = ? WHERE id = ?',
          [pagadoNuevo, nuevoEstado, delta, ocurridoEn, cuotaId],
        );

        // Mirror offline del color del mapa (vencimiento_mas_viejo): la cuota
        // volvió a pendiente/parcial → online lo hace el trigger server.
        final contratoAnulado = cuotaRows.first['contrato_id'] as String?;
        if (contratoAnulado != null) {
          await recalcVmvDeContrato(tx, contratoAnulado);
        }

        // op_log: la anulación restaura la cuota — una entrada "Pago anulado",
        // scoped a la cuota (estado y saldo vuelven atrás). El motivo va al resumen.
        final saldoAntes = montoCuota + cargosNetoViejo - pagadoViejo;
        final saldoDespues = montoCuota + delta - pagadoNuevo;
        await OpLog.escribir(
          tx,
          tenantId: tenantId,
          opId: opId,
          tipoOp: 'anulacion_pago',
          entidad: 'cuotas',
          entidadId: cuotaId,
          accion: 'update',
          diff: {
            'campos': [
              {'campo': 'estado', 'antes': estadoActual, 'despues': nuevoEstado},
              {
                'campo': 'saldo',
                'antes': saldoAntes < 0 ? 0 : saldoAntes,
                'despues': saldoDespues < 0 ? 0 : saldoDespues,
              },
            ],
            'resumen': {'monto': monto, 'motivo': motivo},
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurridoEn),
        );
      }
    });
  }

  /// Resuelve una cuota EN REVISIÓN (cuarentena 0218): marca [pagoVerdaderoId]
  /// como el cobro VÁLIDO y anula TODOS los otros pagos vivos de la misma cuota.
  /// Queda exactamente un pago que cuenta → sin sobrepago ni efectivo fantasma.
  /// El server recalcula monto_pagado/estado y el valor correcto baja por sync.
  /// Lo usa "Cobros a revisar".
  ///
  /// Orden: primero anula los OTROS (reusa `anularPago`: recibos + reversión de
  /// descuentos + mirror), y RECIÉN saca de revisión al elegido, para que nunca
  /// haya un instante con dos pagos contando (sobrepago transitorio).
  ///
  /// OJO — ese orden depende de **0224**: el UPDATE que saca de revisión es el
  /// ÚLTIMO, así que si el trigger no escuchara `en_revision` la cuota quedaría
  /// como la dejó el paso 1 (el elegido todavía en cuarentena = no cuenta), o
  /// sea PENDIENTE con la plata ya cobrada. Hasta 0224 pasaba exactamente eso y
  /// este comentario decía que el server recalculaba: era falso para este
  /// camino. Si algún día se agrega otra columna al predicado de pagos vivos,
  /// va también al `AFTER UPDATE OF` de `trg_pagos_update_recalcular`.
  Future<void> elegirCobroVerdadero({
    required String cuotaId,
    required String pagoVerdaderoId,
    required String actorId,
  }) async {
    final otros = await _dbWOrGlobal.getAll(
      'SELECT id FROM pagos WHERE cuota_id = ? AND anulado = 0 AND id <> ?',
      [cuotaId, pagoVerdaderoId],
    );
    for (final row in otros) {
      await anularPago(
        pagoId: row['id'] as String,
        anuladoPorId: actorId,
        motivo: 'Duplicado resuelto: se eligió otro cobro como el verdadero',
      );
    }

    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await _opLogActor(actorId);
    await _dbWOrGlobal.writeTransaction((tx) async {
      final rows = await tx.getAll(
        'SELECT tenant_id, en_revision FROM pagos WHERE id = ?',
        [pagoVerdaderoId],
      );
      if (rows.isEmpty) return;
      final tenantId = rows.first['tenant_id'] as String;
      final eraEnRevision =
          ((rows.first['en_revision'] as num?)?.toInt() ?? 0) == 1;
      if (!eraEnRevision) return; // idempotente
      await tx.execute(
        'UPDATE pagos SET en_revision = 0, revision_motivo = NULL, '
        'ocurrido_en = ? WHERE id = ?',
        [ocurridoEn, pagoVerdaderoId],
      );
      await OpLog.escribir(
        tx,
        tenantId: tenantId,
        opId: opId,
        tipoOp: 'editar',
        entidad: 'pagos',
        entidadId: pagoVerdaderoId,
        accion: 'update',
        diff: {
          'campos': [
            {'campo': 'en_revision', 'antes': true, 'despues': false},
          ],
          'resumen': {'motivo': 'Confirmado como el cobro verdadero'},
        },
        actor: actor,
        ocurridoEn: DateTime.parse(ocurridoEn),
      );
    });
  }

  /// Edita un pago existente (monto, método, notas). Solo actualiza los
  /// campos proporcionados. El trigger server recalcula cuota si el monto
  /// cambió. Localmente espejamos el recálculo igual que en registrarCobro.
  Future<void> editarPago({
    required String pagoId,
    required String editadoPorId,
    double? montoCordobas,
    double? montoOriginal,
    double? tasaConversion,
    MetodoPago? metodo,
    String? notas,
    /// Pasar true para limpiar notas (null = no tocar).
    bool limpiarNotas = false,
  }) async {
    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    // op_log (rework change log): editar es su PROPIA intención (id propio).
    final opId = OpLog.nuevoOpId();
    final actor = await _opLogActor(editadoPorId);
    await _dbWOrGlobal.writeTransaction((tx) async {
      // Leer el pago actual: cuota_id, tenant + valores previos para el diff.
      final pagoRows = await tx.getAll(
        'SELECT cuota_id, tenant_id, monto_cordobas, vuelto_cordobas, moneda, '
        'metodo, notas FROM pagos WHERE id = ? AND anulado = 0',
        [pagoId],
      );
      if (pagoRows.isEmpty) {
        throw Exception('Pago no encontrado o ya anulado');
      }
      // Defense in depth: editar un pago con vuelto dejaría el vuelto
      // inconsistente con el nuevo monto. El flujo correcto es anular +
      // recobrar. El UI ya bloquea el botón, esto cubre cualquier callsite.
      final vueltoPrevio =
          (pagoRows.first['vuelto_cordobas'] as num? ?? 0).toDouble();
      if (vueltoPrevio > 0) {
        throw Exception(
          'No se puede editar un pago con vuelto. Anulalo y registrá el cobro de nuevo.',
        );
      }
      // Defense in depth (F1): el editor solo captura monto en córdobas; editar
      // un pago en moneda extranjera lo dejaría con monto_original en C$ y
      // tasa=1.0, corrompiendo el rastro de moneda (invariante #3). El flujo
      // correcto es anular + recobrar. El UI ya bloquea el botón.
      final monedaPrevia = pagoRows.first['moneda'] as String? ?? 'NIO';
      if (monedaPrevia != 'NIO') {
        throw Exception(
          'No se puede editar un pago en moneda extranjera. Anulalo y registrá el cobro de nuevo.',
        );
      }
      final cuotaId = pagoRows.first['cuota_id'] as String;
      final tenantId = pagoRows.first['tenant_id'] as String;
      final montoPrevio = (pagoRows.first['monto_cordobas'] as num).toDouble();
      final metodoPrevio = pagoRows.first['metodo'] as String?;
      final notasPrevias = pagoRows.first['notas'] as String?;
      // Diff curado del op_log: solo lo que el usuario cambió, antes → después.
      final campos = <Map<String, dynamic>>[];

      // Tope contra el saldo (M2, audit 2026-06-11): sin esto, un typo del
      // admin (500 → 5000) inflaba el recaudado en silencio — el trigger
      // server tampoco lo limita (marca 'pagada' y guarda el sobrepago, que
      // recién aparecía corriendo invariantes_dinero.sql INV4). El máximo
      // editable = total de la cuota (monto + cargos_neto) menos lo pagado
      // por LOS DEMÁS pagos (pagado actual − este pago).
      if (montoCordobas != null && montoCordobas != montoPrevio) {
        final topeRows = await tx.getAll(
          'SELECT monto, cargos_neto, monto_pagado FROM cuotas WHERE id = ?',
          [cuotaId],
        );
        if (topeRows.isNotEmpty) {
          final r = topeRows.first;
          final total = (r['monto'] as num).toDouble() +
              ((r['cargos_neto'] as num?)?.toDouble() ?? 0.0);
          final pagadoOtros =
              ((r['monto_pagado'] as num?)?.toDouble() ?? 0.0) - montoPrevio;
          final maximo = total - pagadoOtros;
          if (montoCordobas > maximo + 0.01) {
            throw Exception(
              'El monto excede el saldo de la cuota: máximo '
              '${maximo.toStringAsFixed(2)} (la cuota quedaría sobrepagada).',
            );
          }
        }
      }

      // Construir SET clause dinámico.
      final sets = <String>[];
      final params = <Object?>[];
      if (montoCordobas != null) {
        sets.add('monto_cordobas = ?');
        params.add(montoCordobas);
        if (montoCordobas != montoPrevio) {
          campos.add(
              {'campo': 'monto', 'antes': montoPrevio, 'despues': montoCordobas});
        }
      }
      if (montoOriginal != null) {
        sets.add('monto_original = ?');
        params.add(montoOriginal);
      }
      if (tasaConversion != null) {
        sets.add('tasa_conversion = ?');
        params.add(tasaConversion);
      }
      if (metodo != null) {
        sets.add('metodo = ?');
        params.add(metodo.value);
        if (metodo.value != metodoPrevio) {
          campos.add(
              {'campo': 'metodo', 'antes': metodoPrevio, 'despues': metodo.value});
        }
      }
      if (limpiarNotas) {
        sets.add('notas = NULL');
        if (notasPrevias != null && notasPrevias.isNotEmpty) {
          campos.add(
              {'campo': 'notas', 'antes': notasPrevias, 'despues': null});
        }
      } else if (notas != null) {
        sets.add('notas = ?');
        params.add(notas);
        if (notas != notasPrevias) {
          campos.add(
              {'campo': 'notas', 'antes': notasPrevias, 'despues': notas});
        }
      }

      if (sets.isEmpty) return;

      // Estampar la hora de dispositivo de esta edición (solo si hubo cambios).
      sets.add('ocurrido_en = ?');
      params.add(ocurridoEn);

      params.add(pagoId);
      await tx.execute(
        'UPDATE pagos SET ${sets.join(', ')} WHERE id = ?',
        params,
      );

      // Si el monto cambió, recalcular estado de la cuota localmente
      // (mirror del trigger server).
      if (montoCordobas != null && montoCordobas != montoPrevio) {
        final cuotaRows = await tx.getAll(
          'SELECT monto, monto_pagado, estado, cargos_neto, contrato_id FROM cuotas WHERE id = ?',
          [cuotaId],
        );
        if (cuotaRows.isNotEmpty) {
          final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
          final pagadoViejo =
              (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
          final estadoActual = cuotaRows.first['estado'] as String;
          final cargosNeto =
              (cuotaRows.first['cargos_neto'] as num? ?? 0).toDouble();
          // Ajustar: quitar el monto previo, sumar el nuevo.
          final pagadoNuevo = (pagadoViejo - montoPrevio + montoCordobas)
              .clamp(0.0, double.infinity);
          final delta = await _deltaCargosExtra(tx, cuotaId);
          final nuevoEstado = calcularEstadoCuota(
            estadoActual: estadoActual,
            montoCuota: montoCuota,
            pagadoNuevo: pagadoNuevo,
            deltaCargosExtra: delta,
          );
          await tx.execute(
            'UPDATE cuotas SET monto_pagado = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
            [pagadoNuevo, nuevoEstado, ocurridoEn, cuotaId],
          );

          // Mirror offline del color del mapa (vencimiento_mas_viejo): el monto
          // editado cambió el estado/saldo de la cuota → online lo hace el trigger.
          final contratoEditado = cuotaRows.first['contrato_id'] as String?;
          if (contratoEditado != null) {
            await recalcVmvDeContrato(tx, contratoEditado);
          }

          // Efecto en la cuota para el op_log (estado + saldo canónico).
          final saldoAntes = montoCuota + cargosNeto - pagadoViejo;
          final saldoDespues = montoCuota + delta - pagadoNuevo;
          campos.add(
              {'campo': 'estado', 'antes': estadoActual, 'despues': nuevoEstado});
          campos.add({
            'campo': 'saldo',
            'antes': saldoAntes < 0 ? 0 : saldoAntes,
            'despues': saldoDespues < 0 ? 0 : saldoDespues,
          });
        }
      }

      // op_log: UNA entrada en la cuota — "Pago editado", con lo que cambió
      // (antes → después). Si nada visible cambió, no ensucia el historial.
      if (campos.isNotEmpty) {
        final recRows = await tx.getAll(
          'SELECT numero_completo FROM recibos WHERE pago_id = ? AND anulado = 0 LIMIT 1',
          [pagoId],
        );
        final recibo =
            recRows.isNotEmpty ? recRows.first['numero_completo'] : null;
        await OpLog.escribir(
          tx,
          tenantId: tenantId,
          opId: opId,
          tipoOp: 'edicion_pago',
          entidad: 'cuotas',
          entidadId: cuotaId,
          accion: 'update',
          diff: {
            'campos': campos,
            if (recibo != null) 'resumen': {'recibo': recibo},
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurridoEn),
        );
      }
    });
  }

  /// **Cambio de fecha de pago por días (feature C, Diseño A).**
  /// El cliente AL DÍA mueve su día de pago al [diaNuevo] y paga el "puente"
  /// (días prorrateados entre lo que pagó y el ancla del nuevo día). Todo OFFLINE
  /// en UNA writeTransaction:
  ///  1. `pagado hasta` = MAX(venc) de cuotas pagadas → host del cargo puente.
  ///  2. cobro del puente: cargos_extra origen='puente' tipo='otro' (SUMA) sobre
  ///     la última cuota pagada + pago + recibo + mirror (la cuota host sigue pagada).
  ///  3. absorbe (anula) las cuotas pendientes que caen DENTRO del puente.
  ///  4. re-fecha las futuras pendientes al día nuevo (espejo del trigger 0018).
  ///  5. UPDATE contratos.dia_pago (+ fecha_fin en fijos); en fijos agrega 1 cuota
  ///     de cierre al final por cada absorbida (conserva el conteo activo).
  ///
  /// El monto aplicado del puente lo determina el helper [calcularPuenteCambioFecha]
  /// (NO el caller): el caller pasa lo ENTREGADO ([montoOriginal] en [moneda] a
  /// [tasaConversion]); el vuelto se calcula. Requiere RLS+guard de 0119.
  Future<CobroResultado> registrarCambioFecha({
    required String tenantId,
    required String cobradorId,
    required String prefijoRecibo,
    required String contratoId,
    required int diaNuevo,
    required double precioMensual,
    required Moneda moneda,
    required double montoOriginal,
    required double tasaConversion,
    required MetodoPago metodo,
    String? referencia,
    String? fotoComprobantePath,
    double? lat,
    double? lng,
    String? notas,
    DateTime? fechaPago,
  }) async {
    final pagoId = _uuid.v4();
    final reciboId = _uuid.v4();
    final clientLocalIdPago = _uuid.v4();
    final clientLocalIdRecibo = _uuid.v4();
    final now = (fechaPago ?? DateTime.now()).toIso8601String();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    // op_log (rework change log): id de la intención + actor (el cobrador real).
    final opId = OpLog.nuevoOpId();
    final actor = await _opLogActor(cobradorId);
    final correlativoEmitido = <int>[];

    // Guard de correlativo: mismo patrón que registrarCobro (server MAX con
    // timeout corto → hwm local de fallback).
    int? pisoCorrelativo;
    try {
      final serverRows = await Supabase.instance.client
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijoRecibo)
          .order('correlativo', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 5));
      if (serverRows.isNotEmpty) {
        pisoCorrelativo = (serverRows.first['correlativo'] as num).toInt();
      }
    } catch (_) {}
    if (pisoCorrelativo != null) {
      await CorrelativoStore.subirA(cobradorId, prefijoRecibo, pisoCorrelativo);
    }
    final hwmLocal = await CorrelativoStore.leer(cobradorId, prefijoRecibo);

    await _dbWOrGlobal.writeTransaction((tx) async {
      // 0. Contrato: día de pago viejo + cliente + duración (se usan desde acá).
      final contratoRows = await tx.getAll(
        'SELECT cliente_id, dia_pago, duracion_meses, fecha_fin FROM contratos WHERE id = ?',
        [contratoId],
      );
      if (contratoRows.isEmpty) {
        throw StateError('Contrato no encontrado.');
      }
      final clienteId = contratoRows.first['cliente_id'] as String;
      final diaPagoViejo = (contratoRows.first['dia_pago'] as num).toInt();
      final fechaFinViejo = contratoRows.first['fecha_fin'] as String?;
      final duracionMeses =
          (contratoRows.first['duracion_meses'] as num?)?.toInt();
      final esFijo = duracionMeses != null && duracionMeses > 0;

      // Guard no-op: cambiar al MISMO día rodaría un mes entero (anclaServicio
      // siempre busca la PRIMERA ocurrencia estrictamente posterior) → cobraría
      // ~1 mes de puente y absorbería una cuota, para un cambio que no cambia nada.
      if (diaNuevo == diaPagoViejo) {
        throw StateError('El día nuevo es igual al día de pago actual.');
      }

      // 1. Elegibilidad + cuota a cobrar (regla ESTRICTA de mora).
      //    Se cuentan las cuotas PENDIENTES VENCIDAS (venc < hoy, día local Nic).
      //      0 vencidas → cliente al día: cobra SOLO el puente, sobre la última
      //                   cuota pagada (host con saldo 0).
      //      1 vencida  → cobra ESA cuota + el puente, en UN solo recibo.
      //      2+ vencidas → BLOQUEO (sería cobro multi-cuota + puente; no permitido).
      //    Un 'parcial' en curso también bloquea (no se mezcla con el cambio).
      final parcialRows = await tx.getAll(
        "SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ? AND estado = 'parcial'",
        [contratoId],
      );
      if ((parcialRows.first['n'] as num).toInt() > 0) {
        throw StateError('Hay un pago parcial en curso: no se puede cambiar la fecha.');
      }
      // "Vencida" = ESTRICTAMENTE pasada (venc < hoy local Nicaragua). Una cuota
      // que vence HOY no está vencida ("vence hoy" ≠ "en mora", igual que el
      // estado visual). Las en gracia (ya pasaron su fecha) sí cuentan.
      final vencidas = await tx.getAll(
        '''
        SELECT id, periodo, monto, monto_pagado, cargos_neto FROM cuotas
         WHERE contrato_id = ? AND estado = 'pendiente'
           AND date(fecha_vencimiento) < date('now','-6 hours')
         ORDER BY date(periodo) ASC
        ''',
        [contratoId],
      );
      if (vencidas.length >= 2) {
        throw StateError(
            'El cliente tiene ${vencidas.length} cuotas vencidas; cobrá los atrasados antes de cambiar la fecha.');
      }

      final String hostCuotaId;
      final DateTime periodoHost;
      final double saldoHost; // lo que falta cobrar de la cuota host ANTES del puente
      if (vencidas.length == 1) {
        // 1 mes en mora: se cobra esa cuota vencida (su saldo) + el puente.
        final v = vencidas.first;
        hostCuotaId = v['id'] as String;
        periodoHost = _parsePeriodo(v['periodo'] as String);
        final s = (v['monto'] as num).toDouble() +
            (v['cargos_neto'] as num? ?? 0).toDouble() -
            (v['monto_pagado'] as num? ?? 0).toDouble();
        saldoHost = s < 0 ? 0 : s;
      } else {
        // Al día: el puente cuelga de la última cuota pagada (saldo 0).
        final pagadasRows = await tx.getAll(
          "SELECT id, periodo FROM cuotas WHERE contrato_id = ? AND estado = 'pagada' "
          'ORDER BY date(periodo) DESC LIMIT 1',
          [contratoId],
        );
        if (pagadasRows.isEmpty) {
          throw StateError(
              'El contrato no tiene cuotas pagadas ni vencidas: no hay nada para puentear.');
        }
        hostCuotaId = pagadasRows.first['id'] as String;
        periodoHost = _parsePeriodo(pagadasRows.first['periodo'] as String);
        saldoHost = 0;
      }
      // pagado hasta = día de servicio NOMINAL del período de la cuota host (su
      // período + el día viejo clampeado), SIN el ajuste domingo→lunes de
      // fecha_vencimiento (eso es fecha de COBRO, no de servicio).
      final pagadoHasta = DateTime(
        periodoHost.year,
        periodoHost.month,
        diaClampMes(periodoHost.year, periodoHost.month, diaPagoViejo),
      );

      // 2. Puente + total a cobrar (saldo de la cuota host + puente).
      final puente = calcularPuenteCambioFecha(
        pagadoHasta: pagadoHasta,
        diaNuevo: diaNuevo,
        precioMensual: precioMensual,
      );
      final puenteMonto = puente.montoPuente;
      if (puenteMonto <= 0) {
        throw StateError('El puente no aplica (el día nuevo no es posterior a lo pagado).');
      }
      final aplicado = saldoHost + puenteMonto; // lo que entra a caja (cuota + puente)
      final aplicadoCent = (aplicado * 100).round();
      final entregadoCent = (montoOriginal * tasaConversion * 100).round();
      if (entregadoCent < aplicadoCent) {
        throw StateError('El monto entregado no alcanza para la cuota + el puente.');
      }
      final vuelto = (entregadoCent - aplicadoCent) / 100.0;

      // 3a. Cargo puente sobre la cuota host (origen='puente', tipo='otro' SUMA).
      //     El cargo es SOLO el puente; el pago aplica saldo de la cuota + puente.
      await tx.execute(
        '''
        INSERT INTO cargos_extra (
          id, tenant_id, cuota_id, cobrador_id, tipo, monto,
          porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id,
          ocurrido_en, origen, pago_id
        ) VALUES (?, ?, ?, ?, 'otro', ?, NULL, ?, ?, ?, ?, ?, 'puente', ?)
        ''',
        [
          _uuid.v4(), tenantId, hostCuotaId, cobradorId, puenteMonto,
          'Puente de pago (cambio de fecha al día $diaNuevo)',
          cobradorId, ocurridoEn, _uuid.v4(), ocurridoEn, pagoId,
        ],
      );

      // 3b. Correlativo dentro de la tx (sin filtrar anulados).
      final rows = await tx.getAll(
        'SELECT COALESCE(MAX(correlativo), 0) AS max_local FROM recibos WHERE cobrador_id = ? AND prefijo = ?',
        [cobradorId, prefijoRecibo],
      );
      final maxLocal = (rows.first['max_local'] as num).toInt();
      final pisoServer = pisoCorrelativo ?? 0;
      final piso = pisoServer > hwmLocal ? pisoServer : hwmLocal;
      final correlativo = (maxLocal > piso ? maxLocal : piso) + 1;
      correlativoEmitido.add(correlativo);
      final numeroCompleto =
          '$prefijoRecibo-${correlativo.toString().padLeft(5, '0')}';

      // 3c. Pago del puente (monto_cordobas = aplicado; vuelto en C$).
      await tx.execute(
        '''
        INSERT INTO pagos (
          id, tenant_id, cuota_id, cobrador_id,
          monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion,
          metodo, referencia, foto_comprobante_path,
          lat, lng, notas, fecha_pago, anulado, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        ''',
        [
          pagoId, tenantId, hostCuotaId, cobradorId,
          aplicado, vuelto, moneda.value, montoOriginal, tasaConversion,
          metodo.value, referencia, fotoComprobantePath,
          lat, lng, notas, now, clientLocalIdPago, ocurridoEn,
        ],
      );

      // 3d. Recibo del puente.
      await tx.execute(
        '''
        INSERT INTO recibos (
          id, tenant_id, pago_id, cobrador_id,
          prefijo, correlativo, numero_completo,
          reimpresiones, anulado, created_at, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
        ''',
        [
          reciboId, tenantId, pagoId, cobradorId,
          prefijoRecibo, correlativo, numeroCompleto,
          now, clientLocalIdRecibo, ocurridoEn,
        ],
      );

      // 3e. Mirror de la cuota host (sigue 'pagada': se le suma el puente al
      //     monto_pagado y al cargos_neto; total = monto + cargos_neto).
      final hostRows = await tx.getAll(
        'SELECT monto, monto_pagado, estado, cargos_neto FROM cuotas WHERE id = ?',
        [hostCuotaId],
      );
      final montoCuota = (hostRows.first['monto'] as num).toDouble();
      final pagadoViejo =
          (hostRows.first['monto_pagado'] as num? ?? 0).toDouble();
      final estadoActual = hostRows.first['estado'] as String;
      final cargosNetoViejo =
          (hostRows.first['cargos_neto'] as num? ?? 0).toDouble();
      final pagadoNuevo = pagadoViejo + aplicado;
      final delta = await _deltaCargosExtra(tx, hostCuotaId);
      await tx.execute(
        'UPDATE cuotas SET cargos_neto = ?, ocurrido_en = ? WHERE id = ?',
        [delta, ocurridoEn, hostCuotaId],
      );
      final nuevoEstado = calcularEstadoCuota(
        estadoActual: estadoActual,
        montoCuota: montoCuota,
        pagadoNuevo: pagadoNuevo,
        deltaCargosExtra: delta,
      );
      await tx.execute(
        'UPDATE cuotas SET monto_pagado = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
        [pagadoNuevo, nuevoEstado, ocurridoEn, hostCuotaId],
      );

      // op_log: la cuota host recibe el cobro del puente (+ el saldo de la
      // vencida si la había). Scoped a la cuota; monto/recibo en el resumen.
      // Los campos se listan SOLO si cambiaron (en el caso "al día" el host
      // queda pagada/saldo 0 → sin filas no-op; el cobro vive en el resumen).
      final saldoHostAntes = montoCuota + cargosNetoViejo - pagadoViejo;
      final saldoHostDespues = montoCuota + delta - pagadoNuevo;
      final camposHost = <Map<String, dynamic>>[];
      if (estadoActual != nuevoEstado) {
        camposHost.add(
            {'campo': 'estado', 'antes': estadoActual, 'despues': nuevoEstado});
      }
      if ((saldoHostAntes * 100).round() != (saldoHostDespues * 100).round()) {
        camposHost.add({
          'campo': 'saldo',
          'antes': saldoHostAntes < 0 ? 0 : saldoHostAntes,
          'despues': saldoHostDespues < 0 ? 0 : saldoHostDespues,
        });
      }
      await OpLog.escribir(
        tx,
        tenantId: tenantId,
        opId: opId,
        tipoOp: 'cambio_fecha',
        entidad: 'cuotas',
        entidadId: hostCuotaId,
        accion: 'update',
        diff: {
          'campos': camposHost,
          'resumen': {
            'monto': aplicado,
            'vuelto': vuelto,
            'metodo': metodo.value,
            'fecha_pago': now,
            'recibo': numeroCompleto,
            if (notas != null) 'notas': notas,
          },
        },
        actor: actor,
        ocurridoEn: DateTime.parse(ocurridoEn),
      );

      // 4. Absorber: cuotas pendientes cuyo servicio (día nuevo de su mes, sin
      //    ajuste domingo→lunes) NO es posterior al ancla → caen en el puente.
      final pendientes = await tx.getAll(
        'SELECT id, periodo, monto, monto_pagado, cargos_neto FROM cuotas '
        "WHERE contrato_id = ? AND estado = 'pendiente'",
        [contratoId],
      );
      var absorbidas = 0;
      for (final c in pendientes) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final servicio = DateTime(periodo.year, periodo.month,
            diaClampMes(periodo.year, periodo.month, diaNuevo));
        if (!servicio.isAfter(puente.anclaServicio)) {
          await tx.execute(
            '''
            UPDATE cuotas
               SET estado = 'anulada', anulada_en = ?, anulada_por = ?,
                   motivo_anulacion = ?, ocurrido_en = ?
             WHERE id = ?
            ''',
            [
              ocurridoEn, cobradorId,
              'Absorbida por cambio de fecha de pago', ocurridoEn, c['id'],
            ],
          );
          // op_log: la cuota absorbida se anula (su servicio cae en el puente).
          final saldoAbs = (c['monto'] as num).toDouble() +
              (c['cargos_neto'] as num? ?? 0).toDouble() -
              (c['monto_pagado'] as num? ?? 0).toDouble();
          await OpLog.escribir(
            tx,
            tenantId: tenantId,
            opId: opId,
            tipoOp: 'cambio_fecha',
            entidad: 'cuotas',
            entidadId: c['id'] as String,
            accion: 'update',
            diff: {
              'campos': [
                {'campo': 'estado', 'antes': 'pendiente', 'despues': 'anulada'},
                {
                  'campo': 'saldo',
                  'antes': saldoAbs < 0 ? 0 : saldoAbs,
                  'despues': 0,
                },
              ],
              'resumen': {'motivo': 'Absorbida por cambio de fecha de pago'},
            },
            actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn),
          );
          absorbidas++;
        }
      }

      // 5. Re-fechar futuras pendientes al día nuevo (espejo del trigger 0018:
      //    periodo >= mes actual, estado='pendiente'; las absorbidas ya no son
      //    'pendiente' → no se tocan).
      final futuras = await tx.getAll(
        '''
        SELECT id, periodo, fecha_vencimiento FROM cuotas
         WHERE contrato_id = ? AND estado = 'pendiente'
           AND date(periodo) >= date('now','-6 hours','start of month')
        ''',
        [contratoId],
      );
      for (final c in futuras) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final venc = calcularFechaPago(periodo, diaNuevo);
        final vencNuevo = _fechaOnly(venc);
        final vencViejo = c['fecha_vencimiento'] as String?;
        await tx.execute(
          'UPDATE cuotas SET fecha_vencimiento = ?, ocurrido_en = ? WHERE id = ?',
          [vencNuevo, ocurridoEn, c['id']],
        );
        // op_log: solo si la fecha REALMENTE cambió (no ensucia con no-ops).
        if (vencViejo != vencNuevo) {
          await OpLog.escribir(
            tx,
            tenantId: tenantId,
            opId: opId,
            tipoOp: 'cambio_fecha',
            entidad: 'cuotas',
            entidadId: c['id'] as String,
            accion: 'update',
            diff: {
              'campos': [
                {
                  'campo': 'fecha_vencimiento',
                  'antes': vencViejo,
                  'despues': vencNuevo,
                },
              ],
            },
            actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn),
          );
        }
      }

      // 6. Contrato: cuota de cierre en fijos (1 por absorbida) + UPDATE dia_pago
      //    (+ fecha_fin en fijos, segura para limpiar_cuotas_excedentes).
      //    cliente_id / duracion_meses / esFijo se leyeron en el paso 0.
      if (esFijo && absorbidas > 0) {
        final maxRows = await tx.getAll(
          'SELECT MAX(date(periodo)) AS maxp FROM cuotas WHERE contrato_id = ?',
          [contratoId],
        );
        var ultimo = _parsePeriodo(maxRows.first['maxp'] as String);
        for (var i = 0; i < absorbidas; i++) {
          ultimo = DateTime(ultimo.year, ultimo.month + 1, 1);
          final venc = calcularFechaPago(ultimo, diaNuevo);
          final cierreId = _uuid.v4();
          final vencCierre = _fechaOnly(venc);
          await tx.execute(
            '''
            INSERT INTO cuotas (
              id, tenant_id, contrato_id, cliente_id, cobrador_id, periodo,
              fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, ocurrido_en
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 'pendiente', ?)
            ''',
            [
              cierreId, tenantId, contratoId, clienteId, cobradorId,
              _fechaOnly(ultimo), vencCierre, precioMensual, ocurridoEn,
            ],
          );
          // op_log: alta de la cuota de cierre (reemplaza una absorbida →
          // conserva el conteo activo del fijo).
          await OpLog.escribir(
            tx,
            tenantId: tenantId,
            opId: opId,
            tipoOp: 'cambio_fecha',
            entidad: 'cuotas',
            entidadId: cierreId,
            accion: 'create',
            diff: {
              'campos': [
                {'campo': 'monto', 'antes': null, 'despues': precioMensual},
                {
                  'campo': 'fecha_vencimiento',
                  'antes': null,
                  'despues': vencCierre,
                },
              ],
              'resumen': {'motivo': 'Cuota de cierre por cambio de fecha'},
            },
            actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn),
          );
        }
      }

      String? fechaFinNueva;
      if (esFijo) {
        final vencRows = await tx.getAll(
          "SELECT MAX(date(fecha_vencimiento)) AS maxv FROM cuotas WHERE contrato_id = ? AND estado <> 'anulada'",
          [contratoId],
        );
        final maxv = vencRows.first['maxv'] as String?;
        if (maxv != null) {
          // +1 día: que la última cuota NO caiga en fecha_fin (limpiar_cuotas_
          // excedentes borra pendientes con venc >= fecha_fin al acortar).
          fechaFinNueva =
              _fechaOnly(DateTime.parse(maxv).add(const Duration(days: 1)));
        }
      }
      if (fechaFinNueva != null) {
        await tx.execute(
          'UPDATE contratos SET dia_pago = ?, fecha_fin = ?, ocurrido_en = ? WHERE id = ?',
          [diaNuevo, fechaFinNueva, ocurridoEn, contratoId],
        );
      } else {
        await tx.execute(
          'UPDATE contratos SET dia_pago = ?, ocurrido_en = ? WHERE id = ?',
          [diaNuevo, ocurridoEn, contratoId],
        );
      }

      // op_log: 1 entrada en el CONTRATO — el día de pago (y fecha_fin en fijos)
      // se mueven. Scoped al contrato; se mostrará al cablear su historial en
      // Fase 3 (la data se captura ya). Recibo del puente en el resumen.
      final camposContrato = <Map<String, dynamic>>[
        {'campo': 'dia_pago', 'antes': diaPagoViejo, 'despues': diaNuevo},
      ];
      if (fechaFinNueva != null && fechaFinNueva != fechaFinViejo) {
        camposContrato.add({
          'campo': 'fecha_fin',
          'antes': fechaFinViejo,
          'despues': fechaFinNueva,
        });
      }
      await OpLog.escribir(
        tx,
        tenantId: tenantId,
        opId: opId,
        tipoOp: 'cambio_fecha',
        entidad: 'contratos',
        entidadId: contratoId,
        accion: 'update',
        diff: {
          'campos': camposContrato,
          'resumen': {'recibo': numeroCompleto},
        },
        actor: actor,
        ocurridoEn: DateTime.parse(ocurridoEn),
      );

      // Mirror offline del color del mapa (vencimiento_mas_viejo): se re-fecharon
      // y absorbieron cuotas → online lo hace el trigger server.
      await recalcVmvDeContrato(tx, contratoId);
    });

    if (correlativoEmitido.isNotEmpty) {
      await CorrelativoStore.subirA(
          cobradorId, prefijoRecibo, correlativoEmitido.last);
    }
    return CobroResultado(pagoId: pagoId, reciboId: reciboId);
  }

  /// Parsea `periodo` (cuotas) a primer día del mes. Tolera 'YYYY-MM' y
  /// 'YYYY-MM-DD' (el server lo normaliza al primer día del mes → 'YYYY-MM-01').
  DateTime _parsePeriodo(String s) {
    final p = s.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), 1);
  }

  /// Formatea una fecha como 'YYYY-MM-DD' (formato de las columnas date).
  String _fechaOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Suma neta de cargos_extra de la cuota: cargos sumados (reconexion/otro)
  /// menos descuentos. Mirror del SQL `cuota_total_a_cobrar` (0018).
  Future<double> _deltaCargosExtra(dynamic tx, String cuotaId) async {
    final rows = await tx.getAll(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN tipo IN ('reconexion','otro')
                          THEN monto ELSE 0 END), 0) AS sumar,
        COALESCE(SUM(CASE WHEN tipo IN ('descuento_monto','descuento_porcentaje','credito_aplicado')
                          THEN monto ELSE 0 END), 0) AS restar
        FROM cargos_extra WHERE cuota_id = ?
      ''',
      [cuotaId],
    );
    final sumar = (rows.first['sumar'] as num).toDouble();
    final restar = (rows.first['restar'] as num).toDouble();
    return sumar - restar;
  }
}

final pagosRepoProvider = Provider((_) => PagosRepo());
