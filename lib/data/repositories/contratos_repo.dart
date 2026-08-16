import 'dart:convert';

import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../utils/colchon_indefinido.dart';
import '../utils/cuota_estado.dart';
import '../utils/op_log.dart';
import '../utils/prorrateo.dart';

/// Operaciones de ciclo de vida del contrato que tocan cuotas (= dinero) y por
/// eso viven en un repo testeable (capa 3), no inline en la UI.
///
/// **Suspensión temporal (Feature A):** pausa un contrato. El cron y
/// `generar_cuotas_contrato` (0074) ya gatean por `estado='activo'`, así que al
/// dejar el contrato en `'suspendido'` la generación se detiene sola. Esta
/// transacción (offline-first, espejo del server) hace el resto: anula las
/// cuotas futuras pendientes y prorratea la del mes en curso (días consumidos),
/// con el MISMO prorrateo del puente (`montoPuente`/`precioPorDia`). Solo
/// admin/admin_cobranza (gateado por RLS `contratos_write_admins`/`cuotas_*` +
/// la UI); el guard de cobradores (0119) no los afecta.
/// Decodifica un snapshot JSON tolerando el DOBLE-ENCODING del round-trip de
/// PowerSync sobre columnas `jsonb` (`cancelacion_deuda_snapshot`, 0123): un
/// string ya-codificado entra al jsonb como string-scalar y vuelve como
/// `"{...}"`, así que `jsonDecode` da un String en vez de un Map. Si pasa eso,
/// decodifica una segunda vez. (El `deuda_snapshot` de suspensión es `text` y no
/// sufre esto, pero el helper sirve igual.)
Map<String, dynamic> decodeSnapshotMap(String s) {
  var v = jsonDecode(s);
  if (v is String) v = jsonDecode(v);
  return (v as Map).cast<String, dynamic>();
}

class ContratosRepo {
  ContratosRepo({PowerSyncDatabase? db}) : _db = db;
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

  static const _uuid = Uuid();

  /// Formatea una fecha como 'YYYY-MM-DD' (formato de las columnas date).
  static String _fechaOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Emite UNA fila op_log scoped a una CUOTA (rework change log). Thin wrapper
  /// sobre OpLog.escribir para no repetir el boilerplate en cada función.
  Future<void> _opCuota(
    dynamic tx, {
    required String tenantId,
    required String opId,
    required String tipoOp,
    required OpLogActor actor,
    required String ocurridoEn,
    required Object cuotaId,
    required List<Map<String, dynamic>> campos,
    Map<String, dynamic>? resumen,
    String accion = 'update',
  }) =>
      OpLog.escribir(
        tx,
        tenantId: tenantId,
        opId: opId,
        tipoOp: tipoOp,
        entidad: 'cuotas',
        entidadId: cuotaId as String,
        accion: accion,
        diff: {'campos': campos, if (resumen != null) 'resumen': resumen},
        actor: actor,
        ocurridoEn: DateTime.parse(ocurridoEn),
      );

  /// Emite UNA fila op_log scoped al CONTRATO.
  Future<void> _opContrato(
    dynamic tx, {
    required String tenantId,
    required String opId,
    required String tipoOp,
    required OpLogActor actor,
    required String ocurridoEn,
    required String contratoId,
    required List<Map<String, dynamic>> campos,
    Map<String, dynamic>? resumen,
  }) =>
      OpLog.escribir(
        tx,
        tenantId: tenantId,
        opId: opId,
        tipoOp: tipoOp,
        entidad: 'contratos',
        entidadId: contratoId,
        accion: 'update',
        diff: {'campos': campos, if (resumen != null) 'resumen': resumen},
        actor: actor,
        ocurridoEn: DateTime.parse(ocurridoEn),
      );

  /// Suspende un contrato ACTIVO con efecto desde [fechaSuspension].
  ///
  /// Reglas (decisiones cerradas 2026-06-15):
  ///  - El PAGO de una cuota NUNCA se revierte: no se ANULA una cuota con pago
  ///    (dispararía `cuotas_anular_pagos_asociados_trg`); las parciales se
  ///    prorratean/conservan, nunca se anulan.
  ///  - Cuota del MES de suspensión (`pendiente` o `parcial`): se prorratea a los
  ///    días consumidos (1° del mes → [fechaSuspension] inclusive) con el prorrateo
  ///    del puente, CLAMPEADA al pago (monto nuevo ≥ lo abonado, respeta el CHECK
  ///    monto_pagado≤monto). Si el abono ya cubre el prorrateo → 'pagada' (sin
  ///    reembolso). Si no hay pago ni días consumidos → se anula entera.
  ///  - Cuotas FUTURAS: las `pendiente` (sin pago) se anulan ('Suspensión
  ///    temporal'); las `parcial` (con pago) sobreviven y entran al snapshot.
  ///  - Cuotas pendientes de meses PASADOS (mora previa) → se dejan (deuda viva).
  ///  - El contrato pasa a `estado='suspendido'` y se registra la fila en
  ///    `contrato_suspensiones` con el snapshot de la deuda sobreviviente (para
  ///    el PDF de deuda, reimprimible).
  ///
  /// [precioMensual] viene del plan (lo provee el call-site, como en el puente).
  /// Devuelve el `id` de la fila `contrato_suspensiones` creada (lo usa el
  /// diálogo para vincular la disposición del excedente al evento — A6).
  Future<String> suspenderContrato({
    required String tenantId,
    required String contratoId,
    required String cobradorId,
    required DateTime fechaSuspension,
    required double precioMensual,
    required String motivo,
    String? notas,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final suspensionId = _uuid.v4();
    // op_log (rework change log): 1 intención, 1 entrada por objeto afectado.
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);

    await _dbWOrGlobal.writeTransaction((tx) async {
      // 0. Solo se suspende un contrato ACTIVO.
      final cRows = await tx.getAll(
          'SELECT estado, dia_pago FROM contratos WHERE id = ?', [contratoId]);
      if (cRows.isEmpty) throw StateError('Contrato no encontrado.');
      if ((cRows.first['estado'] as String?) != 'activo') {
        throw StateError('Solo se puede suspender un contrato activo.');
      }
      final diaPago = (cRows.first['dia_pago'] as num?)?.toInt() ?? 1;

      // Snapshot de la deuda SOBREVIVIENTE (mismo cálculo que el preview del
      // diálogo), tomado ANTES de mutar → se guarda para el PDF (DRY con preview).
      // `dia_pago` viaja en el snapshot → el PDF rotula el mes de servicio igual
      // que el diálogo/lista, reimprimible aunque luego se reactive.
      final deuda = await _calcularDeudaSuspension(
          tx, contratoId, fechaSuspension, precioMensual);
      // Estado PREVIO de las cuotas vivas → permite REVERTIR al estado exacto
      // (la cuota en curso pierde su `monto` original al prorratear). Va en el
      // snapshot JSON (sin columna nueva); `monto_pagado` es la guarda del revert.
      final cuotasPrevias = await _snapshotCuotasPrevias(tx, contratoId);
      final snapshot = jsonEncode({
        'generado_en': ocurridoEn,
        'dia_pago': diaPago,
        'total': deuda.total,
        'cuotas': deuda.cuotas,
        'cuotas_previas': cuotasPrevias,
      });

      // 1-2. Clasificar cada cuota viva por su VENTANA DE SERVICIO anclada al
      //      día_pago (NO al mes calendario):
      //   - CUMPLIDA (servicio entregado completo) → queda ENTERA (deuda real).
      //   - EN CURSO (su período de servicio contiene la fecha) → prorratear los
      //     días consumidos (inicio → fechaSuspension) con el prorrateo del
      //     puente, CLAMP al pago (nunca baja de lo abonado). Si el abono cubre
      //     el prorrateo → saldada ('pagada', sin reembolso); sin pago ni días → anular.
      //   - FUTURA (servicio no empezó) → anular el `pendiente`; el `parcial`
      //     (con abono) sobrevive con su saldo.
      Future<void> anular(Object id) => tx.execute(
            '''
            UPDATE cuotas
               SET estado = 'anulada', anulada_en = ?, anulada_por = ?,
                   motivo_anulacion = ?, ocurrido_en = ?
             WHERE id = ?
            ''',
            [ocurridoEn, cobradorId, 'Suspensión temporal', ocurridoEn, id],
          );
      final vivasRows = await tx.getAll(
        '''
        SELECT id, periodo, estado, monto,
               COALESCE(monto_pagado, 0) AS monto_pagado,
               COALESCE(cargos_neto, 0) AS cargos_neto
          FROM cuotas
         WHERE contrato_id = ? AND estado IN ('pendiente','parcial')
        ''',
        [contratoId],
      );
      for (final c in vivasRows) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final est = estadoServicio(periodo, diaPago, fechaSuspension);
        if (est == 'cumplido') continue; // deuda real → intacta (sin cambio).
        final estadoAntes = c['estado'] as String;
        final montoAntes = (c['monto'] as num).toDouble();
        final pagado = (c['monto_pagado'] as num).toDouble();
        final cargos = (c['cargos_neto'] as num).toDouble();
        final saldoAntes = montoAntes + cargos - pagado;
        final clamp0 = saldoAntes < 0 ? 0 : saldoAntes;
        if (est == 'futuro') {
          if (estadoAntes == 'pendiente') {
            await anular(c['id']!);
            await _opCuota(tx, tenantId: tenantId, opId: opId,
                tipoOp: 'suspension', actor: actor, ocurridoEn: ocurridoEn,
                cuotaId: c['id']!, campos: [
                  {'campo': 'estado', 'antes': estadoAntes, 'despues': 'anulada'},
                  {'campo': 'saldo', 'antes': clamp0, 'despues': 0},
                ], resumen: {'motivo': 'Suspensión temporal'});
          }
          continue; // parcial futuro: sobrevive (lo abonado vale).
        }
        // en_curso → prorratear los días consumidos del ciclo, clamp al pago.
        final v = ventanaServicio(periodo, diaPago);
        final prorrateado =
            montoPuente(v.inicio, fechaSuspension, precioMensual);
        final nuevoMonto = prorrateado < pagado ? pagado : prorrateado;
        final saldo = nuevoMonto + cargos - pagado;
        if (pagado < 0.01 && saldo < 0.01) {
          await anular(c['id']!); // sin pago ni días consumidos.
          await _opCuota(tx, tenantId: tenantId, opId: opId,
              tipoOp: 'suspension', actor: actor, ocurridoEn: ocurridoEn,
              cuotaId: c['id']!, campos: [
                {'campo': 'estado', 'antes': estadoAntes, 'despues': 'anulada'},
                {'campo': 'saldo', 'antes': clamp0, 'despues': 0},
              ], resumen: {'motivo': 'Suspensión temporal'});
        } else if (saldo < 0.01) {
          await tx.execute(
            "UPDATE cuotas SET monto = ?, estado = 'pagada', ocurrido_en = ? WHERE id = ?",
            [nuevoMonto, ocurridoEn, c['id']],
          );
          await _opCuota(tx, tenantId: tenantId, opId: opId,
              tipoOp: 'suspension', actor: actor, ocurridoEn: ocurridoEn,
              cuotaId: c['id']!, campos: [
                {'campo': 'monto', 'antes': montoAntes, 'despues': nuevoMonto},
                {'campo': 'estado', 'antes': estadoAntes, 'despues': 'pagada'},
                {'campo': 'saldo', 'antes': clamp0, 'despues': 0},
              ], resumen: {'motivo': 'Prorrateo por suspensión'});
        } else {
          await tx.execute(
            'UPDATE cuotas SET monto = ?, ocurrido_en = ? WHERE id = ?',
            [nuevoMonto, ocurridoEn, c['id']],
          );
          await _opCuota(tx, tenantId: tenantId, opId: opId,
              tipoOp: 'suspension', actor: actor, ocurridoEn: ocurridoEn,
              cuotaId: c['id']!, campos: [
                {'campo': 'monto', 'antes': montoAntes, 'despues': nuevoMonto},
                {'campo': 'saldo', 'antes': clamp0, 'despues': saldo < 0 ? 0 : saldo},
              ], resumen: {'motivo': 'Prorrateo por suspensión'});
        }
      }

      // 3. El contrato pasa a suspendido (el cron deja de generar — gate 0074).
      await tx.execute(
        'UPDATE contratos SET estado = ?, ocurrido_en = ? WHERE id = ?',
        ['suspendido', ocurridoEn, contratoId],
      );
      await _opContrato(tx, tenantId: tenantId, opId: opId, tipoOp: 'suspension',
          actor: actor, ocurridoEn: ocurridoEn, contratoId: contratoId, campos: [
            {'campo': 'estado', 'antes': 'activo', 'despues': 'suspendido'},
          ], resumen: {'motivo': motivo});

      // 4. Registro de la suspensión + snapshot de deuda.
      await tx.execute(
        '''
        INSERT INTO contrato_suspensiones (
          id, tenant_id, contrato_id, motivo, notas, deuda_snapshot,
          suspendido_en, suspendido_por, created_at, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          suspensionId, tenantId, contratoId, motivo, notas, snapshot,
          _fechaOnly(fechaSuspension), cobradorId, ocurridoEn, ocurridoEn,
        ],
      );

      // Mirror offline del color del mapa (vencimiento_mas_viejo): online lo
      // hace el trigger server. Ver recalcVmvDeContrato.
      await recalcVmvDeContrato(tx, contratoId);
    });
    return suspensionId;
  }

  /// Cambia el PLAN de un contrato activo MANTENIENDO su vigencia (feature
  /// contract-new-feature). El precio vive en `planes` (no en `contratos`), así
  /// que esto = UPDATE `plan_id` + re-valuar el `monto` de las cuotas FUTURAS
  /// pendientes (las cuyo servicio aún NO empezó, `estadoServicio='futuro'`
  /// anclado al día_pago) al [precioNuevo]. El **conteo de cuotas NO cambia** →
  /// invariante #11 intacto. Las cumplidas/en-curso/pagadas/parciales/vencidas/
  /// anuladas NO se tocan.
  ///
  /// Dos modos ([modoHoy]): "Próximo ciclo" (default `modoHoy=false`) — el ciclo
  /// en curso termina al plan viejo, el nuevo arranca limpio en su próxima
  /// ventana; CERO plata en el acto. "Hoy con prorrateo" (`modoHoy=true`,
  /// requiere [precioViejo]) — además ajusta los días NO servidos del ciclo en
  /// curso a la DIFERENCIA de precio: upgrade → `cargos_extra` (SUMA) sobre la
  /// cuota en curso (el admin lo cobra con el flujo normal); downgrade → crédito
  /// en `saldos_favor` (R17, NO toca pagos ni caja). NUNCA toca el día_pago (a
  /// diferencia de R13): la fecha de servicio queda idéntica.
  ///
  /// El re-valúo es 100% CLIENT-SIDE (NO hay trigger server de reconciliación): el
  /// cliente UPDATEa `plan_id` + los `monto` de las cuotas y eso sincroniza tal
  /// cual (last-write-wins; límite multi-device aceptado, como R13). La
  /// autorización viene de la RLS GENÉRICA de contratos/cuotas para admin
  /// (`contratos_write_admins` = `is_admin_or_cobranza()`); el cobrador queda
  /// bloqueado de `plan_id`/`monto` por los guards `*_check_cobrador_update`. NO se
  /// agregó RLS ni trigger propio (auditado en fase 2). Los precios se leen FRESCOS
  /// de `planes` dentro de la transacción (no se confía en el snapshot de la UI).
  Future<void> cambiarPlan({
    required String tenantId,
    required String contratoId,
    required String cobradorId,
    required String planNuevoId,
    required double precioNuevo,
    required DateTime hoy,
    bool modoHoy = false,
    double? precioViejo,
    /// Por qué se cambia el plan. Queda en el op_log del contrato: sin esto, el
    /// cambio de plan era la única acción del ciclo que no dejaba explicación
    /// escrita por NINGÚN camino (audit 2026-08-09).
    String? motivo,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);

    await _dbWOrGlobal.writeTransaction((tx) async {
      // 0. Solo un contrato ACTIVO; leer día_pago, plan actual y cliente.
      final cRows = await tx.getAll(
          'SELECT estado, dia_pago, plan_id, cliente_id FROM contratos WHERE id = ?',
          [contratoId]);
      if (cRows.isEmpty) throw StateError('Contrato no encontrado.');
      final c = cRows.first;
      if ((c['estado'] as String?) != 'activo') {
        throw StateError('Solo se puede cambiar el plan de un contrato activo.');
      }
      final diaPago = (c['dia_pago'] as num?)?.toInt() ?? 1;
      final planViejoId = c['plan_id'] as String?;
      final clienteId = c['cliente_id'] as String;
      if (planViejoId == planNuevoId) {
        throw StateError('El contrato ya tiene ese plan.');
      }
      // Pre-chequeo del índice único (cliente_id, plan_id) WHERE estado='activo':
      // si el cliente ya tiene OTRO contrato activo en el plan destino, el UPDATE
      // plan_id rebotaría (online rechazado / offline al sincronizar) → lo
      // bloqueamos acá con un mensaje claro (precedente: contrato_form_screen).
      final dup = await tx.getAll(
          'SELECT 1 FROM contratos WHERE cliente_id = ? AND plan_id = ? '
          "AND estado = 'activo' AND id <> ? LIMIT 1",
          [clienteId, planNuevoId, contratoId]);
      if (dup.isNotEmpty) {
        throw StateError('El cliente ya tiene un contrato activo en ese plan.');
      }

      // Precios FRESCOS de `planes` dentro de la tx (server gana — no confiar en
      // el snapshot de la UI, que pudo quedar viejo si otro admin editó el precio
      // del plan entre abrir el diálogo y confirmar). Fallback al parámetro.
      var precioNuevoReal = precioNuevo;
      var precioViejoReal = precioViejo;
      final precios = await tx.getAll(
        'SELECT id, precio_mensual FROM planes WHERE id IN (?, ?)',
        [planNuevoId, planViejoId],
      );
      for (final p in precios) {
        final pm = (p['precio_mensual'] as num?)?.toDouble();
        if (pm == null) continue;
        if (p['id'] == planNuevoId) precioNuevoReal = pm;
        if (p['id'] == planViejoId) precioViejoReal = pm;
      }

      // 1. Re-valuar las cuotas FUTURAS pendientes al precio nuevo. Clamp >= lo
      //    pagado (CHECK monto_pagado<=monto). La del ciclo en curso (en_curso)
      //    NO se toca acá — solo en modo Hoy (3b-ii).
      final pendientes = await tx.getAll(
        '''
        SELECT id, periodo, monto, COALESCE(monto_pagado,0) AS monto_pagado
          FROM cuotas
         WHERE contrato_id = ? AND estado = 'pendiente'
        ''',
        [contratoId],
      );
      for (final cu in pendientes) {
        final periodo = _parsePeriodo(cu['periodo'] as String);
        if (estadoServicio(periodo, diaPago, hoy) != 'futuro') continue;
        final montoAntes = (cu['monto'] as num).toDouble();
        final pagado = (cu['monto_pagado'] as num).toDouble();
        final montoNuevo = montoCuotaRevaluada(precioNuevoReal, pagado);
        if ((montoNuevo - montoAntes).abs() < 0.005) continue; // sin cambio real
        await tx.execute(
            'UPDATE cuotas SET monto = ?, ocurrido_en = ? WHERE id = ?',
            [montoNuevo, ocurridoEn, cu['id']]);
        await _opCuota(tx, tenantId: tenantId, opId: opId, tipoOp: 'cambio_plan',
            actor: actor, ocurridoEn: ocurridoEn, cuotaId: cu['id']!, campos: [
              {'campo': 'monto', 'antes': montoAntes, 'despues': montoNuevo},
            ], resumen: {'motivo': 'Cambio de plan'});
      }

      // 1.5. Modo "Hoy con prorrateo": ajustar los días NO servidos del ciclo en
      //      curso a la DIFERENCIA de precio. Upgrade → cargo (SUMA) sobre la
      //      cuota host; downgrade → crédito en saldos_favor (R17). Solo si hay
      //      un ciclo en curso y se pasó el precio viejo.
      if (modoHoy && precioViejoReal != null) {
        final vivas = await tx.getAll(
          '''
          SELECT id, periodo, estado, monto, cobrador_id,
                 COALESCE(monto_pagado,0) AS monto_pagado,
                 COALESCE(cargos_neto,0) AS cargos_neto
            FROM cuotas
           WHERE contrato_id = ? AND estado <> 'anulada'
          ''',
          [contratoId],
        );
        Map<String, dynamic>? host;
        for (final cu in vivas) {
          if (estadoServicio(_parsePeriodo(cu['periodo'] as String), diaPago, hoy) ==
              'en_curso') {
            host = cu;
            break;
          }
        }
        if (host != null) {
          final prorr = prorrateoCambioPlanHoy(
            hoy: hoy,
            finVentanaActual:
                servicioFin(_parsePeriodo(host['periodo'] as String), diaPago),
            precioViejo: precioViejoReal,
            precioNuevo: precioNuevoReal,
          );
          if (!prorr.sinAjuste) {
            final hostId = host['id'] as String;
            if (prorr.esUpgrade) {
              // UPGRADE: cargo_extra (SUMA) sobre la cuota en curso + recalc del
              // espejo (cargos_neto/estado), calcando aplicarCredito. El admin lo
              // cobra con el flujo normal (la cuota muestra el saldo mayor).
              final hostEstado = host['estado'] as String;
              final hostMonto = (host['monto'] as num).toDouble();
              final hostPagado = (host['monto_pagado'] as num).toDouble();
              final saldoAntes =
                  hostMonto + (host['cargos_neto'] as num).toDouble() - hostPagado;
              await tx.execute(
                '''
                INSERT INTO cargos_extra (id, tenant_id, cuota_id, cobrador_id,
                  tipo, monto, porcentaje, descripcion, aplicado_por, aplicado_en,
                  client_local_id, ocurrido_en, origen)
                VALUES (?, ?, ?, ?, 'otro', ?, NULL, ?, ?, ?, ?, ?, 'cobro')
                ''',
                [
                  _uuid.v4(), tenantId, hostId,
                  (host['cobrador_id'] as String?) ?? cobradorId, prorr.monto,
                  'Diferencia por cambio de plan', cobradorId, ocurridoEn,
                  _uuid.v4(), ocurridoEn,
                ],
              );
              final delta = await _deltaCargosExtraLocal(tx, hostId);
              final nuevoEstado = calcularEstadoCuota(
                estadoActual: hostEstado,
                montoCuota: hostMonto,
                pagadoNuevo: hostPagado,
                deltaCargosExtra: delta,
              );
              await tx.execute(
                'UPDATE cuotas SET cargos_neto = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
                [delta, nuevoEstado, ocurridoEn, hostId],
              );
              final saldoDespues = hostMonto + delta - hostPagado;
              await _opCuota(tx, tenantId: tenantId, opId: opId,
                  tipoOp: 'cambio_plan', actor: actor, ocurridoEn: ocurridoEn,
                  cuotaId: hostId, campos: [
                    {'campo': 'estado', 'antes': hostEstado, 'despues': nuevoEstado},
                    {
                      'campo': 'saldo',
                      'antes': saldoAntes < 0 ? 0 : saldoAntes,
                      'despues': saldoDespues < 0 ? 0 : saldoDespues,
                    },
                  ], resumen: {
                    'monto': prorr.monto,
                    'motivo': 'Diferencia por cambio de plan (upgrade)'
                  });
            } else {
              // DOWNGRADE: acreditar la diferencia en saldos_favor (R17). NO toca
              // pagos ni baja una cuota pagada → no infla caja, respeta el CHECK.
              await tx.execute(
                '''
                INSERT INTO saldos_favor (id, tenant_id, cliente_id, contrato_id,
                  tipo, monto, cuota_id, origen_evento_id, motivo, creado_por,
                  ocurrido_en)
                VALUES (?, ?, ?, ?, 'acreditado', ?, ?, ?, ?, ?, ?)
                ''',
                [
                  _uuid.v4(), tenantId, clienteId, contratoId, prorr.monto,
                  hostId, opId, 'Crédito por cambio de plan (downgrade)',
                  cobradorId, ocurridoEn,
                ],
              );
              await _opContrato(tx, tenantId: tenantId, opId: opId,
                  tipoOp: 'cambio_plan', actor: actor, ocurridoEn: ocurridoEn,
                  contratoId: contratoId, campos: const [], resumen: {
                    'monto': prorr.monto,
                    'motivo': 'Crédito por cambio de plan (downgrade)'
                  });
            }
          }
        }
      }

      // 2. UPDATE del plan del contrato (el precio sale del JOIN a planes).
      await tx.execute(
          'UPDATE contratos SET plan_id = ?, ocurrido_en = ? WHERE id = ?',
          [planNuevoId, ocurridoEn, contratoId]);
      await _opContrato(tx, tenantId: tenantId, opId: opId, tipoOp: 'cambio_plan',
          actor: actor, ocurridoEn: ocurridoEn, contratoId: contratoId, campos: [
            {'campo': 'plan_id', 'antes': planViejoId, 'despues': planNuevoId},
          ], resumen: {'motivo': 'Cambio de plan'});

      // 3. Mirror offline del color del mapa (online lo hace el trigger server).
      await recalcVmvDeContrato(tx, contratoId);
    });
  }

  /// Cancela un contrato con la MISMA dinámica de dinero que suspender, pero
  /// PERMANENTE (no se reactiva). Deja viva/cobrable la deuda real (meses
  /// cumplidos + mora previa), prorratea el mes en curso por la ventana de
  /// servicio del día_pago (CLAMP al pago) y anula solo los meses futuros.
  /// Guarda motivo + snapshot de deuda en `contratos` (para reimprimir el doc).
  /// A diferencia del cancelar viejo: NO anula la mora previa ni liquida las
  /// parciales a 0 → la deuda real sigue cobrable.
  Future<void> cancelarContrato({
    required String tenantId,
    required String contratoId,
    required String cobradorId,
    required DateTime fechaCancelacion,
    required double precioMensual,
    required String motivo,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);

    await _dbWOrGlobal.writeTransaction((tx) async {
      final cRows = await tx.getAll(
          'SELECT estado, dia_pago FROM contratos WHERE id = ?', [contratoId]);
      if (cRows.isEmpty) throw StateError('Contrato no encontrado.');
      final estadoContratoAntes = cRows.first['estado'] as String? ?? 'activo';
      if (estadoContratoAntes == 'cancelado') {
        throw StateError('El contrato ya está cancelado.');
      }
      final diaPago = (cRows.first['dia_pago'] as num?)?.toInt() ?? 1;

      // Snapshot de la deuda SOBREVIVIENTE (mismo cálculo que suspender, DRY) →
      // se guarda para reimprimir el documento de cancelación.
      final deuda = await _calcularDeudaSuspension(
          tx, contratoId, fechaCancelacion, precioMensual);
      // Estado PREVIO de las cuotas vivas → permite REVERTIR la cancelación al
      // estado exacto. `monto_pagado` es la guarda (si cambió, hubo cobros).
      final cuotasPrevias = await _snapshotCuotasPrevias(tx, contratoId);
      final snapshot = jsonEncode({
        'generado_en': ocurridoEn,
        'dia_pago': diaPago,
        'total': deuda.total,
        'cuotas': deuda.cuotas,
        'cuotas_previas': cuotasPrevias,
      });

      // Clasificar cada cuota viva por ventana de servicio del día_pago (igual
      // que suspender): cumplido → INTACTA (deuda real cobrable); en_curso →
      // prorratear con clamp al pago; futuro → anular el pendiente (el parcial
      // sobrevive). NUNCA anular una cuota con pago.
      Future<void> anular(Object id) => tx.execute(
            '''
            UPDATE cuotas
               SET estado = 'anulada', anulada_en = ?, anulada_por = ?,
                   motivo_anulacion = ?, ocurrido_en = ?
             WHERE id = ?
            ''',
            [ocurridoEn, cobradorId, 'Cancelación de contrato', ocurridoEn, id],
          );
      final vivasRows = await tx.getAll(
        '''
        SELECT id, periodo, estado, monto,
               COALESCE(monto_pagado, 0) AS monto_pagado,
               COALESCE(cargos_neto, 0) AS cargos_neto
          FROM cuotas
         WHERE contrato_id = ? AND estado IN ('pendiente','parcial')
        ''',
        [contratoId],
      );
      for (final c in vivasRows) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final est = estadoServicio(periodo, diaPago, fechaCancelacion);
        if (est == 'cumplido') continue; // deuda real → intacta (cobrable).
        final estadoAntes = c['estado'] as String;
        final montoAntes = (c['monto'] as num).toDouble();
        final pagado = (c['monto_pagado'] as num).toDouble();
        final cargos = (c['cargos_neto'] as num).toDouble();
        final saldoAntes = montoAntes + cargos - pagado;
        final clamp0 = saldoAntes < 0 ? 0 : saldoAntes;
        if (est == 'futuro') {
          if (estadoAntes == 'pendiente') {
            await anular(c['id']!);
            await _opCuota(tx, tenantId: tenantId, opId: opId,
                tipoOp: 'cancelacion', actor: actor, ocurridoEn: ocurridoEn,
                cuotaId: c['id']!, campos: [
                  {'campo': 'estado', 'antes': estadoAntes, 'despues': 'anulada'},
                  {'campo': 'saldo', 'antes': clamp0, 'despues': 0},
                ], resumen: {'motivo': 'Cancelación de contrato'});
          }
          continue; // parcial futuro: sobrevive (lo abonado vale).
        }
        // en_curso → prorratear días consumidos, clamp al pago.
        final v = ventanaServicio(periodo, diaPago);
        final prorrateado =
            montoPuente(v.inicio, fechaCancelacion, precioMensual);
        final nuevoMonto = prorrateado < pagado ? pagado : prorrateado;
        final saldo = nuevoMonto + cargos - pagado;
        if (pagado < 0.01 && saldo < 0.01) {
          await anular(c['id']!);
          await _opCuota(tx, tenantId: tenantId, opId: opId,
              tipoOp: 'cancelacion', actor: actor, ocurridoEn: ocurridoEn,
              cuotaId: c['id']!, campos: [
                {'campo': 'estado', 'antes': estadoAntes, 'despues': 'anulada'},
                {'campo': 'saldo', 'antes': clamp0, 'despues': 0},
              ], resumen: {'motivo': 'Cancelación de contrato'});
        } else if (saldo < 0.01) {
          await tx.execute(
            "UPDATE cuotas SET monto = ?, estado = 'pagada', ocurrido_en = ? WHERE id = ?",
            [nuevoMonto, ocurridoEn, c['id']],
          );
          await _opCuota(tx, tenantId: tenantId, opId: opId,
              tipoOp: 'cancelacion', actor: actor, ocurridoEn: ocurridoEn,
              cuotaId: c['id']!, campos: [
                {'campo': 'monto', 'antes': montoAntes, 'despues': nuevoMonto},
                {'campo': 'estado', 'antes': estadoAntes, 'despues': 'pagada'},
                {'campo': 'saldo', 'antes': clamp0, 'despues': 0},
              ], resumen: {'motivo': 'Prorrateo por cancelación'});
        } else {
          await tx.execute(
            'UPDATE cuotas SET monto = ?, ocurrido_en = ? WHERE id = ?',
            [nuevoMonto, ocurridoEn, c['id']],
          );
          await _opCuota(tx, tenantId: tenantId, opId: opId,
              tipoOp: 'cancelacion', actor: actor, ocurridoEn: ocurridoEn,
              cuotaId: c['id']!, campos: [
                {'campo': 'monto', 'antes': montoAntes, 'despues': nuevoMonto},
                {'campo': 'saldo', 'antes': clamp0, 'despues': saldo < 0 ? 0 : saldo},
              ], resumen: {'motivo': 'Prorrateo por cancelación'});
        }
      }

      // Resolver las notificaciones de mora de este contrato: un cancelado sale
      // del flujo de mora del cobrador (la deuda se cobra desde el detalle). El
      // cron 0124 ya no las regenera; esto limpia las existentes en el acto.
      await tx.execute(
        '''
        UPDATE notificaciones_mora
           SET resuelta_en = ?, resuelta_por = ?
         WHERE resuelta_en IS NULL
           AND cuota_id IN (SELECT id FROM cuotas WHERE contrato_id = ?)
        ''',
        [ocurridoEn, cobradorId, contratoId],
      );

      // El contrato pasa a cancelado (permanente). El cron 0074 deja de generar
      // (gate estado IS DISTINCT FROM 'activo'). Sin fila en contrato_suspensiones
      // (no es reactivable) → el snapshot vive en la propia fila del contrato.
      await tx.execute(
        '''
        UPDATE contratos
           SET estado = 'cancelado', cancelado_en = ?, cancelado_por = ?,
               motivo_cancelacion = ?, cancelacion_deuda_snapshot = ?,
               ocurrido_en = ?
         WHERE id = ?
        ''',
        [ocurridoEn, cobradorId, motivo, snapshot, ocurridoEn, contratoId],
      );
      await _opContrato(tx, tenantId: tenantId, opId: opId, tipoOp: 'cancelacion',
          actor: actor, ocurridoEn: ocurridoEn, contratoId: contratoId, campos: [
            {'campo': 'estado', 'antes': estadoContratoAntes, 'despues': 'cancelado'},
          ], resumen: {'motivo': motivo});

      // Mirror offline del color del mapa (vencimiento_mas_viejo): online lo
      // hace el trigger server. Ver recalcVmvDeContrato.
      await recalcVmvDeContrato(tx, contratoId);
    });
  }

  /// Preview de la deuda cobrable al cancelar (mismo cálculo que suspender).
  Future<({double total, List<Map<String, dynamic>> cuotas})>
      previewDeudaCancelacion({
    required String contratoId,
    required DateTime fechaCancelacion,
    required double precioMensual,
  }) =>
          _calcularDeudaSuspension(
              _dbOrGlobal, contratoId, fechaCancelacion, precioMensual);

  /// Cambio de estado SIMPLE del contrato (el UPDATE pelado, sin tocar cuotas)
  /// — NO la dinámica de suspender/cancelar, que tienen su propio flujo porque
  /// prorratean y anulan cuotas. Emite op_log para que la transición aparezca
  /// en el historial del contrato (sin esto quedaría invisible tras pasar el
  /// historial a op_log). Desde que se eliminó 'completado' (era un alias de
  /// 'cancelado'), el dropdown del header solo ofrece 'cancelado' → esta ruta
  /// queda para volver a 'activo' un estado no terminal.
  Future<void> cambiarEstadoSimple({
    required String contratoId,
    required String cobradorId,
    required String nuevoEstado,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);
    await _dbWOrGlobal.writeTransaction((tx) async {
      final cRows = await tx.getAll(
          'SELECT estado, tenant_id FROM contratos WHERE id = ?', [contratoId]);
      if (cRows.isEmpty) throw StateError('Contrato no encontrado.');
      final estadoAntes = cRows.first['estado'] as String? ?? 'activo';
      final tenantId = cRows.first['tenant_id'] as String;
      if (estadoAntes == nuevoEstado) return; // no-op: nada que registrar.
      await tx.execute(
        'UPDATE contratos SET estado = ?, ocurrido_en = ? WHERE id = ?',
        [nuevoEstado, ocurridoEn, contratoId],
      );
      await _opContrato(tx, tenantId: tenantId, opId: opId,
          tipoOp: 'edicion_entidad', actor: actor, ocurridoEn: ocurridoEn,
          contratoId: contratoId, campos: [
            {'campo': 'estado', 'antes': estadoAntes, 'despues': nuevoEstado},
          ]);

      // Mirror offline del color del mapa (vencimiento_mas_viejo): online lo
      // hace el trigger server. Ver recalcVmvDeContrato.
      await recalcVmvDeContrato(tx, contratoId);
    });
  }

  /// Reactiva un contrato SUSPENDIDO con efecto desde [fechaReactivacion].
  ///
  /// Se puede reactivar en CUALQUIER día posterior a la suspensión (el mismo día
  /// → Revertir). Re-ancla el día de pago a la fecha de reactivación y REVIVE las
  /// cuotas que la suspensión anuló de período >= mes siguiente al de reactivación,
  /// hasta el `fecha_fin` ORIGINAL (sin estirar; reúsa filas por
  /// `UNIQUE(contrato_id,periodo)`). Los meses realmente suspendidos (entre la
  /// suspensión y la reactivación) QUEDAN anulados → no se facturan. No cobra
  /// puente. **Caso borde (sub-caso 4):** si se suspendió DESPUÉS del día de pago y
  /// se reactiva el MISMO ciclo, la cuota de corte (prorrateada) colisiona con el
  /// primer ciclo reanudado → se RE-COMPLETA (prorrateo + mes reanudado) para no
  /// sub-cobrar. Indefinidos: revive el colchón y completa 3 meses si la pausa fue larga.
  Future<void> reactivarContrato({
    required String contratoId,
    required String cobradorId,
    required DateTime fechaReactivacion,
    required double precioMensual,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);
    final mesR = DateTime(fechaReactivacion.year, fechaReactivacion.month, 1);
    // Facturación VENCIDA: el primer ciclo a facturar tras reactivar arranca EN
    // la fecha de reactivación, y su cuota vence el mes SIGUIENTE (periodo =
    // mesR+1). El período cuyo venc cae en mesR cubre el mes ya suspendido → no
    // se factura. Por eso el reinicio limpio revive desde mesR+1, no desde mesR.
    final mesRNext = DateTime(mesR.year, mesR.month + 1, 1);
    final mesRNextStr = _fechaOnly(mesRNext);
    final diaNuevo = fechaReactivacion.day;

    await _dbWOrGlobal.writeTransaction((tx) async {
      // 0. Solo se reactiva un contrato SUSPENDIDO.
      final cRows = await tx.getAll(
          'SELECT estado, fecha_fin, dia_pago, tenant_id FROM contratos WHERE id = ?',
          [contratoId]);
      if (cRows.isEmpty) throw StateError('Contrato no encontrado.');
      if ((cRows.first['estado'] as String?) != 'suspendido') {
        throw StateError('Solo se puede reactivar un contrato suspendido.');
      }
      final esIndefinido = cRows.first['fecha_fin'] == null;
      final diaPagoViejo = (cRows.first['dia_pago'] as num?)?.toInt();
      final tenantId = cRows.first['tenant_id'] as String;

      // La reactivación puede ser CUALQUIER día POSTERIOR a la suspensión (el
      // mismo día = nada pasó → se usa Revertir). Una fecha anterior es incoherente.
      final sRows = await tx.getAll(
        '''
        SELECT suspendido_en FROM contrato_suspensiones
         WHERE contrato_id = ? AND reactivado_en IS NULL
         ORDER BY date(suspendido_en) DESC LIMIT 1
        ''',
        [contratoId],
      );
      if (sRows.isNotEmpty && sRows.first['suspendido_en'] != null) {
        final suspDate = DateTime.parse(sRows.first['suspendido_en'] as String);
        final rDate = DateTime(fechaReactivacion.year, fechaReactivacion.month,
            fechaReactivacion.day);
        if (!rDate.isAfter(suspDate)) {
          throw StateError(
              'La reactivación debe ser un día posterior al de la suspensión. '
              'Si fue el mismo día, usá Revertir.');
        }
      }

      // 1. Caso COLISIÓN de ciclo (se suspendió DESPUÉS del día de pago y se
      //    reactiva el MISMO ciclo): la cuota de corte (en_curso prorrateada al
      //    suspender) tiene periodo == mesRNext — el mismo del primer ciclo
      //    reanudado — y NO se revive (no está anulada). Para no SUB-COBRAR ese
      //    ciclo, se RE-COMPLETA: su monto suma el mes reanudado completo y se
      //    re-fecha al día nuevo (el recibo desglosa prorrateo del corte + mes
      //    reanudado). Si NO hay corte en mesRNext (se suspendió ANTES del día de
      //    pago, o la pausa cruzó ≥1 ciclo), no hace nada → flujo normal de revivir.
      // Gate `monto < precioMensual`: la cuota de corte SIEMPRE quedó prorrateada a
      // MENOS de un ciclo completo. Una cuota de ese período ya facturada/pagada
      // entera (monto = precioMensual, p.ej. un pago adelantado) NO es el corte y
      // NO debe re-completarse → sería sobre-cobro de un mes ya cobrado.
      final corteRows = await tx.getAll(
        'SELECT id, monto, estado, fecha_vencimiento, COALESCE(monto_pagado,0) AS mp, '
        'COALESCE(cargos_neto,0) AS cn FROM cuotas '
        'WHERE contrato_id = ? AND date(periodo) = date(?) '
        "AND estado != 'anulada' AND monto < ?",
        [contratoId, mesRNextStr, precioMensual - 0.005],
      );
      if (corteRows.isNotEmpty) {
        final c = corteRows.first;
        final montoAntes = (c['monto'] as num?)?.toDouble() ?? 0;
        final estadoAntes = c['estado'] as String;
        final vencAntes = c['fecha_vencimiento'] as String?;
        final nuevoMonto = montoAntes + precioMensual;
        final pagado = (c['mp'] as num).toDouble();
        final cargos = (c['cn'] as num).toDouble();
        final saldo = nuevoMonto + cargos - pagado;
        final nuevoEstado =
            saldo < 0.01 ? 'pagada' : (pagado > 0.005 ? 'parcial' : 'pendiente');
        final vencNuevo = _fechaOnly(calcularFechaPago(mesRNext, diaNuevo));
        await tx.execute(
          'UPDATE cuotas SET monto = ?, estado = ?, fecha_vencimiento = ?, '
          'ocurrido_en = ? WHERE id = ?',
          [nuevoMonto, nuevoEstado, vencNuevo, ocurridoEn, c['id']],
        );
        await _opCuota(tx, tenantId: tenantId, opId: opId, tipoOp: 'reactivacion',
            actor: actor, ocurridoEn: ocurridoEn, cuotaId: c['id']!, campos: [
              {'campo': 'monto', 'antes': montoAntes, 'despues': nuevoMonto},
              {'campo': 'estado', 'antes': estadoAntes, 'despues': nuevoEstado},
              {'campo': 'fecha_vencimiento', 'antes': vencAntes, 'despues': vencNuevo},
            ], resumen: {'motivo': 'Cuota de corte re-completada al reactivar'});
      }

      // 2. Reinicio limpio: revivir las cuotas anuladas cuyo período (venc) sea
      //    >= mesR+1 — esas cubren servicio DESDE la fecha de reactivación en
      //    adelante. Las de los meses suspendidos (período <= mesR) quedan
      //    anuladas (no se cobran). Vuelven a 'pendiente', monto COMPLETO, venc
      //    recalculada con el día nuevo (ciclos completos desde la reactivación).
      final aRevivir = await tx.getAll(
        '''
        SELECT id, periodo, monto, fecha_vencimiento FROM cuotas
         WHERE contrato_id = ? AND estado = 'anulada'
           AND motivo_anulacion = 'Suspensión temporal'
           AND date(periodo) >= date(?)
        ''',
        [contratoId, mesRNextStr],
      );
      for (final c in aRevivir) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final venc = calcularFechaPago(periodo, diaNuevo);
        final vencNuevo = _fechaOnly(venc);
        final montoAntes = (c['monto'] as num?)?.toDouble() ?? 0;
        final vencAntes = c['fecha_vencimiento'] as String?;
        await tx.execute(
          '''
          UPDATE cuotas
             SET estado = 'pendiente', anulada_en = NULL, anulada_por = NULL,
                 motivo_anulacion = NULL, monto = ?, fecha_vencimiento = ?,
                 ocurrido_en = ?
           WHERE id = ?
          ''',
          [precioMensual, vencNuevo, ocurridoEn, c['id']],
        );
        await _opCuota(tx, tenantId: tenantId, opId: opId, tipoOp: 'reactivacion',
            actor: actor, ocurridoEn: ocurridoEn, cuotaId: c['id']!, campos: [
              {'campo': 'estado', 'antes': 'anulada', 'despues': 'pendiente'},
              {'campo': 'monto', 'antes': montoAntes, 'despues': precioMensual},
              {'campo': 'fecha_vencimiento', 'antes': vencAntes, 'despues': vencNuevo},
            ], resumen: {'motivo': 'Cuota revivida al reactivar'});
      }

      // 3. Indefinidos: garantizar 3 meses de colchón desde el PRIMER mes a
      //    facturar (mesR+1, igual que el reinicio limpio; si la pausa fue larga
      //    puede no haber filas que revivir). INSERT solo si el período no tiene
      //    ninguna fila (UNIQUE).
      if (esIndefinido) {
        final meta = await tx.getAll(
            'SELECT tenant_id, cliente_id, cobrador_id FROM contratos WHERE id = ?',
            [contratoId]);
        final tId = meta.first['tenant_id'] as String;
        final cliId = meta.first['cliente_id'] as String;
        final coId = meta.first['cobrador_id'] as String?;
        for (var i = 0; i < 3; i++) {
          final periodo = DateTime(mesRNext.year, mesRNext.month + i, 1);
          final pStr = _fechaOnly(periodo);
          final existe = await tx.getAll(
              'SELECT id FROM cuotas WHERE contrato_id = ? AND date(periodo) = date(?)',
              [contratoId, pStr]);
          if (existe.isEmpty) {
            final venc = calcularFechaPago(periodo, diaNuevo);
            final nuevaId = _uuid.v4();
            final vencStr = _fechaOnly(venc);
            await tx.execute(
              '''
              INSERT INTO cuotas (
                id, tenant_id, contrato_id, cliente_id, cobrador_id, periodo,
                fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, ocurrido_en
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 'pendiente', ?)
              ''',
              [
                nuevaId, tId, contratoId, cliId, coId, pStr,
                vencStr, precioMensual, ocurridoEn,
              ],
            );
            await _opCuota(tx, tenantId: tenantId, opId: opId,
                tipoOp: 'reactivacion', actor: actor, ocurridoEn: ocurridoEn,
                cuotaId: nuevaId, accion: 'create', campos: [
                  {'campo': 'monto', 'antes': null, 'despues': precioMensual},
                  {'campo': 'fecha_vencimiento', 'antes': null, 'despues': vencStr},
                ], resumen: {'motivo': 'Cuota generada al reactivar (indefinido)'});
          }
        }
      }

      // 3. Contrato: vuelve a activo con el día nuevo (fecha_fin NO cambia).
      await tx.execute(
        'UPDATE contratos SET estado = ?, dia_pago = ?, ocurrido_en = ? WHERE id = ?',
        ['activo', diaNuevo, ocurridoEn, contratoId],
      );
      final camposReact = <Map<String, dynamic>>[
        {'campo': 'estado', 'antes': 'suspendido', 'despues': 'activo'},
      ];
      if (diaPagoViejo != null && diaPagoViejo != diaNuevo) {
        camposReact.add(
            {'campo': 'dia_pago', 'antes': diaPagoViejo, 'despues': diaNuevo});
      }
      await _opContrato(tx, tenantId: tenantId, opId: opId,
          tipoOp: 'reactivacion', actor: actor, ocurridoEn: ocurridoEn,
          contratoId: contratoId, campos: camposReact);

      // 4. Cerrar la suspensión vigente (la fila sin reactivar).
      await tx.execute(
        '''
        UPDATE contrato_suspensiones
           SET reactivado_en = ?, reactivado_por = ?, ocurrido_en = ?
         WHERE contrato_id = ? AND reactivado_en IS NULL
        ''',
        [ocurridoEn, cobradorId, ocurridoEn, contratoId],
      );

      // Mirror offline del color del mapa (vencimiento_mas_viejo): online lo
      // hace el trigger server. Ver recalcVmvDeContrato.
      await recalcVmvDeContrato(tx, contratoId);
    });
  }

  /// Captura el estado PREVIO de las cuotas vivas (para revertir al estado
  /// exacto). `monto_pagado` viaja como guarda: si cambió al momento de
  /// revertir, hubo cobros después → el revert se bloquea.
  Future<List<Map<String, dynamic>>> _snapshotCuotasPrevias(
      dynamic tx, String contratoId) async {
    final rows = await tx.getAll(
      'SELECT id, monto, estado, fecha_vencimiento, '
      'COALESCE(monto_pagado, 0) AS monto_pagado, '
      'COALESCE(cargos_neto, 0) AS cargos_neto '
      "FROM cuotas WHERE contrato_id = ? AND estado IN ('pendiente','parcial')",
      [contratoId],
    );
    return [
      for (final c in rows)
        {
          'id': c['id'],
          'monto': c['monto'],
          'estado': c['estado'],
          'fecha_vencimiento': c['fecha_vencimiento'],
          'monto_pagado': (c['monto_pagado'] as num).toDouble(),
          'cargos_neto': (c['cargos_neto'] as num).toDouble(),
        }
    ];
  }

  /// Revierte una SUSPENSIÓN hecha por error: restaura las cuotas al estado
  /// EXACTO previo (desde `cuotas_previas` del snapshot) y deja el contrato
  /// `activo`, sin re-anclar el día de pago. Solo si NO se cobró nada después.
  /// Append-only: no borra nada; cierra la fila de suspensión y el change-log
  /// registra el revert. Distinto de Reactivar (reinicio limpio tras una pausa
  /// real); esto es para cuando la suspensión NUNCA debió pasar.
  /// Guard del revert frente al crédito por excedente (A6, READ-ONLY):
  ///  - sin crédito de este evento → 0 (revert normal).
  ///  - si ya se DEVOLVIÓ/CONDONÓ (fila terminal del evento) → BLOQUEA
  ///    (decisión irreversible; usar el flujo normal).
  ///  - si se ACREDITÓ pero el disponible del cliente bajó (= ya se aplicó a una
  ///    cuota) → BLOQUEA.
  ///  - si el crédito sigue intacto → devuelve el monto a NEUTRALIZAR (fila
  ///    `revertido` dentro de la transacción).
  /// [eventId] = `contrato_suspensiones.id` (suspensión); null = cancelación
  /// (sus créditos quedaron con `origen_evento_id` NULL).
  Future<List<Map<String, dynamic>>> _prepararRevertCredito(
      dynamic ex, String contratoId, String clienteId, String? eventId) async {
    final filtro = eventId != null
        ? 'origen_evento_id = ?'
        : 'contrato_id = ? AND origen_evento_id IS NULL';
    final args = eventId != null ? [eventId] : [contratoId];
    // Agrupado POR CUOTA: el revert inserta una fila 'revertido' por cada cuota
    // CON su cuota_id, para que el neteo A8 (_calcularExcedente, WHERE
    // cuota_id = ?) cancele acreditado−revertido=0 y vuelva a ofrecer el
    // excedente en una re-suspensión. Un 'revertido' lump SIN cuota_id no
    // casaba con ese WHERE → el excedente real quedaba indisponible (audit Fable 5).
    final aRows = await ex.getAll(
        'SELECT cuota_id, COALESCE(SUM(monto), 0) AS m FROM saldos_favor '
        "WHERE tipo = 'acreditado' AND $filtro GROUP BY cuota_id",
        args);
    // NB: aRows es dinámico (ex.getAll) → un fold<double> tipado revienta en
    // runtime ('(dynamic,dynamic)=>dynamic' no es '(double,Row)=>double').
    // Acumulá con for, igual que el for-in de abajo (audit Fable 5).
    double acreditado = 0.0;
    for (final r in aRows) {
      acreditado += (r['m'] as num?)?.toDouble() ?? 0;
    }
    if (acreditado <= 0.005) return const [];
    // Atribución segura (audit Fase 4 #8): NO comparar el disponible global del
    // cliente contra el acreditado de ESTE evento (con varios créditos da falso
    // bloqueo/permiso). Regla conservadora: si se CONSUMIÓ cualquier saldo a
    // favor del cliente (aplicado/devuelto/condonado/revertido) ya no se puede
    // atribuir qué crédito quedó en pie → BLOQUEAR. El revert solo compensa
    // cuando el crédito de este evento sigue 100% intacto (nada consumido).
    final cRows = await ex.getAll(
        'SELECT COALESCE(SUM(monto), 0) AS m FROM saldos_favor '
        'WHERE cliente_id = ? '
        "AND tipo IN ('aplicado','devuelto','condonado','revertido')",
        [clienteId]);
    final consumo = ((cRows.first['m'] as num?)?.toDouble() ?? 0);
    if (consumo > 0.005) {
      throw StateError(
          'No se puede revertir: ya se usó saldo a favor de este cliente '
          '(aplicado, devuelto o condonado). Usá Reactivar o el cobro normal.');
    }
    return [
      for (final r in aRows)
        if (((r['m'] as num?)?.toDouble() ?? 0) > 0.005)
          {
            'cuota_id': r['cuota_id'],
            'monto': ((r['m'] as num).toDouble() * 100).round() / 100,
          }
    ];
  }

  Future<void> _insertarRevertidoCredito(
      dynamic tx,
      String tenantId,
      String clienteId,
      String contratoId,
      String? eventId,
      List<Map<String, dynamic>> porCuota,
      String cobradorId,
      String ocurridoEn) async {
    // Una fila 'revertido' POR CUOTA (con cuota_id) que espeja el 'acreditado'
    // de esa cuota → el neteo A8 la cancela y el excedente se re-ofrece.
    for (final c in porCuota) {
      await tx.execute(
        '''
        INSERT INTO saldos_favor (id, tenant_id, cliente_id, contrato_id,
          cuota_id, tipo, monto, origen_evento_id, motivo, creado_por, ocurrido_en)
        VALUES (?, ?, ?, ?, ?, 'revertido', ?, ?, ?, ?, ?)
        ''',
        [
          _uuid.v4(), tenantId, clienteId, contratoId, c['cuota_id'],
          (c['monto'] as num).toDouble(), eventId,
          'Revert del crédito por excedente', cobradorId, ocurridoEn,
        ],
      );
    }
  }

  Future<void> revertirSuspension({
    required String contratoId,
    required String cobradorId,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);
    // Validación read-only ANTES de abrir la transacción (el StateError llega
    // limpio a la UI; dentro de writeTransaction el wrapper lo puede enmascarar).
    final cRows = await _dbOrGlobal.getAll(
        'SELECT estado, cliente_id, tenant_id FROM contratos WHERE id = ?',
        [contratoId]);
    if (cRows.isEmpty) throw StateError('Contrato no encontrado.');
    if ((cRows.first['estado'] as String?) != 'suspendido') {
      throw StateError('Solo se puede revertir un contrato suspendido.');
    }
    final clienteId = cRows.first['cliente_id'] as String;
    final tenantId = cRows.first['tenant_id'] as String;
    final sRows = await _dbOrGlobal.getAll(
      '''
      SELECT id, deuda_snapshot FROM contrato_suspensiones
       WHERE contrato_id = ? AND reactivado_en IS NULL
       ORDER BY date(suspendido_en) DESC LIMIT 1
      ''',
      [contratoId],
    );
    if (sRows.isEmpty) {
      throw StateError('No hay una suspensión vigente para revertir.');
    }
    final eventoId = sRows.first['id'] as String;
    final previas = await _previasValidadas(
        _dbOrGlobal, sRows.first['deuda_snapshot'] as String?, 'suspensión');
    // A6: si la suspensión generó crédito, neutralizarlo (o bloquear si ya se usó).
    final compensarCredito =
        await _prepararRevertCredito(_dbOrGlobal, contratoId, clienteId, eventoId);

    await _dbWOrGlobal.writeTransaction((tx) async {
      await _aplicarPrevias(tx, previas, ocurridoEn,
          tenantId: tenantId, opId: opId, tipoOp: 'revertir_suspension',
          actor: actor);
      if (compensarCredito.isNotEmpty) {
        await _insertarRevertidoCredito(tx, tenantId, clienteId, contratoId,
            eventoId, compensarCredito, cobradorId, ocurridoEn);
      }
      await tx.execute(
        "UPDATE contratos SET estado = 'activo', ocurrido_en = ? WHERE id = ?",
        [ocurridoEn, contratoId],
      );
      await _opContrato(tx, tenantId: tenantId, opId: opId,
          tipoOp: 'revertir_suspension', actor: actor, ocurridoEn: ocurridoEn,
          contratoId: contratoId, campos: [
            {'campo': 'estado', 'antes': 'suspendido', 'despues': 'activo'},
          ], resumen: {'motivo': 'Revert de la suspensión'});
      // Cierra la fila (code-only marker; el change-log distingue el revert).
      await tx.execute(
        '''
        UPDATE contrato_suspensiones
           SET reactivado_en = ?, reactivado_por = ?, ocurrido_en = ?
         WHERE id = ?
        ''',
        [ocurridoEn, cobradorId, ocurridoEn, sRows.first['id']],
      );

      // Mirror offline del color del mapa (vencimiento_mas_viejo): online lo
      // hace el trigger server. Ver recalcVmvDeContrato.
      await recalcVmvDeContrato(tx, contratoId);
    });
  }

  /// Revierte una CANCELACIÓN hecha por error: restaura las cuotas al estado
  /// EXACTO previo, re-abre las notificaciones de mora que la cancelación
  /// resolvió y deja el contrato `activo` (limpia las columnas de cancelación).
  /// Solo si NO se cobró nada de la deuda después de cancelar.
  Future<void> revertirCancelacion({
    required String contratoId,
    required String cobradorId,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);
    // Validación read-only ANTES de la transacción (StateError limpio a la UI).
    final cRows = await _dbOrGlobal.getAll(
      'SELECT estado, cancelado_en, cancelacion_deuda_snapshot, cliente_id, '
      'tenant_id FROM contratos WHERE id = ?',
      [contratoId],
    );
    if (cRows.isEmpty) throw StateError('Contrato no encontrado.');
    if ((cRows.first['estado'] as String?) != 'cancelado') {
      throw StateError('Solo se puede revertir un contrato cancelado.');
    }
    final canceladoEn = cRows.first['cancelado_en'] as String?;
    final clienteId = cRows.first['cliente_id'] as String;
    final tenantId = cRows.first['tenant_id'] as String;
    final previas = await _previasValidadas(_dbOrGlobal,
        cRows.first['cancelacion_deuda_snapshot'] as String?, 'cancelación');
    // A6: la cancelación no tiene fila de evento → sus créditos quedaron con
    // origen_evento_id NULL; neutralizarlos (o bloquear si ya se usaron).
    final compensarCredito =
        await _prepararRevertCredito(_dbOrGlobal, contratoId, clienteId, null);

    await _dbWOrGlobal.writeTransaction((tx) async {
      await _aplicarPrevias(tx, previas, ocurridoEn,
          tenantId: tenantId, opId: opId, tipoOp: 'revertir_cancelacion',
          actor: actor);
      if (compensarCredito.isNotEmpty) {
        await _insertarRevertidoCredito(tx, tenantId, clienteId, contratoId,
            null, compensarCredito, cobradorId, ocurridoEn);
      }
      // Re-abrir las notificaciones de mora que la cancelación resolvió.
      if (canceladoEn != null) {
        await tx.execute(
          '''
          UPDATE notificaciones_mora
             SET resuelta_en = NULL, resuelta_por = NULL
           WHERE resuelta_en = ?
             AND cuota_id IN (SELECT id FROM cuotas WHERE contrato_id = ?)
          ''',
          [canceladoEn, contratoId],
        );
      }
      await tx.execute(
        '''
        UPDATE contratos
           SET estado = 'activo', cancelado_en = NULL, cancelado_por = NULL,
               motivo_cancelacion = NULL, cancelacion_deuda_snapshot = NULL,
               ocurrido_en = ?
         WHERE id = ?
        ''',
        [ocurridoEn, contratoId],
      );
      await _opContrato(tx, tenantId: tenantId, opId: opId,
          tipoOp: 'revertir_cancelacion', actor: actor, ocurridoEn: ocurridoEn,
          contratoId: contratoId, campos: [
            {'campo': 'estado', 'antes': 'cancelado', 'despues': 'activo'},
          ], resumen: {'motivo': 'Revert de la cancelación'});

      // Mirror offline del color del mapa (vencimiento_mas_viejo): online lo
      // hace el trigger server. Ver recalcVmvDeContrato.
      await recalcVmvDeContrato(tx, contratoId);
    });
  }

  /// Valida el snapshot y la GUARDA del revert (READ-ONLY) y devuelve la lista
  /// `cuotas_previas`. Lanza StateError si el snapshot es legacy (sin
  /// `cuotas_previas`, p.ej. cancelado con una versión anterior) o si hubo
  /// cobros/cargos después (monto_pagado/cargos_neto difieren). Corre FUERA de la
  /// transacción para que el mensaje llegue limpio a la UI. `cuotas_previas`
  /// presente pero vacío = contrato sin cuotas vivas → revert válido (no-op acá).
  Future<List> _previasValidadas(
      dynamic ex, String? snapStr, String accion) async {
    if (snapStr == null) {
      throw StateError(
          'No se puede revertir esta $accion: no guardó el estado previo.');
    }
    final map = decodeSnapshotMap(snapStr);
    if (!map.containsKey('cuotas_previas')) {
      throw StateError(
          'No se puede revertir esta $accion: se hizo con una versión anterior '
          '(sin el estado previo guardado).');
    }
    final previas = (map['cuotas_previas'] as List?) ?? const [];
    for (final p in previas) {
      final m = p as Map<String, dynamic>;
      final cur = await ex.getAll(
          'SELECT COALESCE(monto_pagado, 0) AS mp, COALESCE(cargos_neto, 0) AS cn '
          'FROM cuotas WHERE id = ?',
          [m['id']]);
      if (cur.isEmpty) continue;
      final curMp = (cur.first['mp'] as num).toDouble();
      final snapMp = ((m['monto_pagado'] as num?) ?? 0).toDouble();
      final curCn = (cur.first['cn'] as num).toDouble();
      final snapCn = ((m['cargos_neto'] as num?) ?? 0).toDouble();
      if ((curMp - snapMp).abs() > 0.005 || (curCn - snapCn).abs() > 0.005) {
        throw StateError(
            'No se puede revertir: hubo cobros o cargos después de la $accion. '
            'Usá Reactivar o el cobro normal.');
      }
    }
    return previas;
  }

  /// Aplica la restauración de las cuotas (MUTACIÓN, dentro de la transacción):
  /// estado/monto/vencimiento previos + limpia la anulación. Salta las cuotas que
  /// no cambiaron (no-op → sin evento de change-log espurio).
  Future<void> _aplicarPrevias(
    dynamic tx,
    List previas,
    String ocurridoEn, {
    required String tenantId,
    required String opId,
    required String tipoOp,
    required OpLogActor actor,
  }) async {
    for (final p in previas) {
      final m = p as Map<String, dynamic>;
      final cur = await tx.getAll(
          'SELECT estado, monto, fecha_vencimiento FROM cuotas WHERE id = ?',
          [m['id']]);
      if (cur.isEmpty) continue;
      final estadoAntes = cur.first['estado'] as String?;
      final montoAntes = ((cur.first['monto'] as num?) ?? 0).toDouble();
      final vencAntes = cur.first['fecha_vencimiento'] as String?;
      final igual = estadoAntes == m['estado'] &&
          (montoAntes - ((m['monto'] as num?) ?? 0).toDouble()).abs() < 0.005 &&
          vencAntes == m['fecha_vencimiento'];
      if (igual) continue;
      await tx.execute(
        '''
        UPDATE cuotas
           SET estado = ?, monto = ?, fecha_vencimiento = ?,
               anulada_en = NULL, anulada_por = NULL, motivo_anulacion = NULL,
               ocurrido_en = ?
         WHERE id = ?
        ''',
        [m['estado'], m['monto'], m['fecha_vencimiento'], ocurridoEn, m['id']],
      );
      // op_log: la cuota vuelve a su estado EXACTO previo al evento revertido.
      await _opCuota(tx, tenantId: tenantId, opId: opId, tipoOp: tipoOp,
          actor: actor, ocurridoEn: ocurridoEn, cuotaId: m['id']!, campos: [
            {'campo': 'estado', 'antes': estadoAntes, 'despues': m['estado']},
            {
              'campo': 'monto',
              'antes': montoAntes,
              'despues': ((m['monto'] as num?) ?? 0).toDouble()
            },
            {
              'campo': 'fecha_vencimiento',
              'antes': vencAntes,
              'despues': m['fecha_vencimiento']
            },
          ], resumen: {
        'motivo': tipoOp == 'revertir_suspension'
            ? 'Restaurada (revert de suspensión)'
            : 'Restaurada (revert de cancelación)'
      });
    }
  }

  /// Parsea `periodo` ('YYYY-MM' o 'YYYY-MM-DD') al primer día del mes.
  static DateTime _parsePeriodo(String s) {
    final p = s.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), 1);
  }

  /// Deuda que SOBREVIVE a una suspensión en [fechaSuspension] (read-only):
  /// pendientes/parciales de meses ANTERIORES al de la suspensión (deuda previa)
  /// + la del mes en curso PRORRATEADA a los días consumidos (mismo prorrateo
  /// que el puente). Excluye los meses futuros (que la suspensión anula). Lo
  /// COMPARTEN el preview del diálogo y el snapshot de `suspenderContrato` (DRY).
  Future<({double total, List<Map<String, dynamic>> cuotas})>
      previewDeudaSuspension({
    required String contratoId,
    required DateTime fechaSuspension,
    required double precioMensual,
  }) =>
          _calcularDeudaSuspension(
              _dbOrGlobal, contratoId, fechaSuspension, precioMensual);

  Future<({double total, List<Map<String, dynamic>> cuotas})>
      _calcularDeudaSuspension(dynamic ex, String contratoId,
          DateTime fechaSuspension, double precioMensual) async {
    final cRows = await ex
        .getAll('SELECT dia_pago FROM contratos WHERE id = ?', [contratoId]);
    final diaPago =
        (cRows.isNotEmpty ? (cRows.first['dia_pago'] as num?)?.toInt() : null) ?? 1;
    final rows = await ex.getAll(
      '''
      SELECT periodo, estado, fecha_vencimiento,
             COALESCE(cargos_neto, 0) AS cargos_neto,
             COALESCE(monto_pagado, 0) AS monto_pagado,
             max(monto + COALESCE(cargos_neto, 0) - COALESCE(monto_pagado, 0), 0) AS saldo
        FROM cuotas
       WHERE contrato_id = ? AND estado IN ('pendiente','parcial')
       ORDER BY date(periodo) ASC
      ''',
      [contratoId],
    );
    var total = 0.0;
    final cuotas = <Map<String, dynamic>>[];
    for (final r in rows) {
      final periodo = _parsePeriodo(r['periodo'] as String);
      // Clasificación por VENTANA DE SERVICIO anclada al día_pago (no mes calendario).
      final est = estadoServicio(periodo, diaPago, fechaSuspension);
      final cargos = (r['cargos_neto'] as num).toDouble();
      final pagado = (r['monto_pagado'] as num).toDouble();
      double saldo;
      int? diasCons;
      int? diasCiclo;
      if (est == 'futuro') {
        // Servicio no empezó: el `pendiente` (sin pago) se anula → no se debe.
        // El `parcial` (con abono) sobrevive con su saldo.
        if (r['estado'] == 'pendiente') continue;
        saldo = (r['saldo'] as num).toDouble();
      } else if (est == 'en_curso') {
        // Período EN CURSO → prorratear los días consumidos del CICLO (inicio →
        // fecha de suspensión), CLAMP al pago. Espeja la mutación.
        final v = ventanaServicio(periodo, diaPago);
        final prorrateado =
            montoPuente(v.inicio, fechaSuspension, precioMensual);
        final nuevoMonto = prorrateado < pagado ? pagado : prorrateado;
        saldo = nuevoMonto + cargos - pagado;
        if (saldo < 0.01) continue; // cubierto por el abono o sin días.
        diasCons = diasPuente(v.inicio, fechaSuspension);
        diasCiclo = v.fin.difference(v.inicio).inDays;
      } else {
        // Servicio CUMPLIDO (mora previa / mes ya entregado) → deuda viva entera.
        saldo = (r['saldo'] as num).toDouble();
      }
      if (saldo <= 0) continue;
      saldo = (saldo * 100).round() / 100;
      total += saldo;
      cuotas.add({
        'periodo': r['periodo'],
        'saldo': saldo,
        'monto_pagado': pagado,
        'fecha_vencimiento': r['fecha_vencimiento'],
        'en_curso': est == 'en_curso',
        if (diasCons != null) 'dias_consumidos': diasCons,
        if (diasCiclo != null) 'dias_ciclo': diasCiclo,
      });
    }
    return (total: (total * 100).round() / 100, cuotas: cuotas);
  }

  /// **Excedente** disponible al suspender/cancelar en [fechaCorte] (read-only):
  /// la plata PAGADA por servicio que NO se va a prestar (cuotas futuras pagadas
  /// + el sobre-pago del mes en curso), anclado al día_pago. INCLUYE cuotas
  /// `pagada` (el caso que motiva la feature — el preview de deuda NO las mira).
  /// Resta lo ya acreditado de cada cuota (A8: no duplicar en doble-suspensión).
  /// Lo comparten el diálogo (preview) y `suspender/cancelar` (mutación) — DRY.
  Future<({double total, List<Map<String, dynamic>> cuotas})> previewExcedente({
    required String contratoId,
    required DateTime fechaCorte,
    required double precioMensual,
  }) =>
      _calcularExcedente(
          _dbOrGlobal, contratoId, fechaCorte, precioMensual);

  Future<({double total, List<Map<String, dynamic>> cuotas})> _calcularExcedente(
      dynamic ex, String contratoId, DateTime fechaCorte,
      double precioMensual) async {
    final cRows = await ex
        .getAll('SELECT dia_pago FROM contratos WHERE id = ?', [contratoId]);
    final diaPago =
        (cRows.isNotEmpty ? (cRows.first['dia_pago'] as num?)?.toInt() : null) ?? 1;
    final rows = await ex.getAll(
      '''
      SELECT id, periodo, COALESCE(monto_pagado, 0) AS monto_pagado
        FROM cuotas
       WHERE contrato_id = ? AND estado != 'anulada'
         AND COALESCE(monto_pagado, 0) > 0
       ORDER BY date(periodo) ASC
      ''',
      [contratoId],
    );
    var total = 0.0;
    final cuotas = <Map<String, dynamic>>[];
    for (final r in rows) {
      final periodo = _parsePeriodo(r['periodo'] as String);
      final pagado = (r['monto_pagado'] as num).toDouble();
      var exc = excedenteCuota(
        periodo: periodo,
        diaPago: diaPago,
        montoPagado: pagado,
        x: fechaCorte,
        precioMensual: precioMensual,
      );
      if (exc <= 0) continue;
      // A8: descontar lo ya capturado de ESTA cuota (acreditado − revertido).
      // Una segunda suspensión no vuelve a ofrecer un excedente ya acreditado.
      final yaRows = await ex.getAll(
        "SELECT COALESCE(SUM(CASE WHEN tipo='acreditado' THEN monto "
        "WHEN tipo='revertido' THEN -monto ELSE 0 END), 0) AS ya "
        'FROM saldos_favor WHERE cuota_id = ?',
        [r['id']],
      );
      final ya = (yaRows.first['ya'] as num?)?.toDouble() ?? 0;
      exc = exc - ya;
      if (exc <= 0.005) continue;
      exc = (exc * 100).round() / 100;
      total += exc;
      cuotas.add({
        'cuota_id': r['id'],
        'periodo': r['periodo'],
        'excedente': exc,
        'monto_pagado': pagado,
      });
    }
    return (total: (total * 100).round() / 100, cuotas: cuotas);
  }

  /// Saldo a favor DISPONIBLE del cliente (firma del libro `saldos_favor`):
  /// `SUM(+acreditado) − SUM(aplicado+devuelto+condonado+revertido)`. El crédito
  /// es a nivel CLIENTE (cruza contratos). Read-only (chip + gate de aplicar).
  Future<double> saldoFavorDisponible(String clienteId) =>
      _saldoFavorDisponibleTx(_dbOrGlobal, clienteId);

  Future<double> _saldoFavorDisponibleTx(dynamic ex, String clienteId) async {
    final rows = await ex.getAll(
      "SELECT COALESCE(SUM(CASE WHEN tipo='acreditado' THEN monto "
      'ELSE -monto END), 0) AS d FROM saldos_favor WHERE cliente_id = ?',
      [clienteId],
    );
    return ((rows.first['d'] as num?)?.toDouble() ?? 0);
  }

  /// Registra la DECISIÓN sobre el excedente tras suspender/cancelar (NUNCA
  /// automática; la elige admin/admin_cobranza). Append-only en `saldos_favor`:
  ///   - una fila `'acreditado'` (+) por cada cuota con excedente (trazable a su
  ///     `cuota_id` → A8: una 2ª suspensión no la re-ofrece),
  ///   - + según [disposicion]: nada (acreditar, el crédito queda disponible) /
  ///     `'condonado'` (la plata queda en caja, auditada) / `'devuelto'` (sale de
  ///     caja: lleva `cobrador_id` + `fecha_devolucion` local-naive para el arqueo).
  /// NO toca `pagos` ni el recaudado (la plata ya entró). [origenEventoId] =
  /// `contrato_suspensiones.id` (suspensión) o null (cancelación). Idempotente
  /// (reusa `_calcularExcedente`, que descuenta lo ya acreditado). Devuelve el
  /// total acreditado. Llamar JUSTO DESPUÉS de suspender/cancelar (mismo corte).
  Future<double> registrarDisposicionExcedente({
    required String contratoId,
    required DateTime fechaCorte,
    required double precioMensual,
    required String disposicion, // 'acreditar' | 'devolver' | 'condonar'
    required String cobradorId,
    String? origenEventoId,
    String? motivo,
  }) async {
    assert(['acreditar', 'devolver', 'condonar'].contains(disposicion));
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final fechaLocal = _fechaOnly(DateTime.now()); // bucketing de caja (devuelto)
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);
    return _dbWOrGlobal.writeTransaction((tx) async {
      final meta = await tx.getAll(
          'SELECT tenant_id, cliente_id FROM contratos WHERE id = ?', [contratoId]);
      if (meta.isEmpty) throw StateError('Contrato no encontrado.');
      final tenantId = meta.first['tenant_id'] as String;
      final clienteId = meta.first['cliente_id'] as String;

      final exc =
          await _calcularExcedente(tx, contratoId, fechaCorte, precioMensual);
      if (exc.total <= 0.005) return 0.0;

      // 1. Acreditar por cuota (trazable + anti doble-acreditación A8).
      for (final c in exc.cuotas) {
        await tx.execute(
          '''
          INSERT INTO saldos_favor (id, tenant_id, cliente_id, contrato_id, tipo,
            monto, cuota_id, origen_evento_id, motivo, creado_por, ocurrido_en)
          VALUES (?, ?, ?, ?, 'acreditado', ?, ?, ?, ?, ?, ?)
          ''',
          [
            _uuid.v4(), tenantId, clienteId, contratoId, c['excedente'],
            c['cuota_id'], origenEventoId, motivo, cobradorId, ocurridoEn,
          ],
        );
      }
      final total = (exc.total * 100).round() / 100;

      // 2. Disposición (neutraliza el acreditado recién creado, salvo acreditar).
      //    El trigger server anti-sobregiro valida que no exceda el disponible.
      if (disposicion == 'condonar') {
        await tx.execute(
          '''
          INSERT INTO saldos_favor (id, tenant_id, cliente_id, contrato_id, tipo,
            monto, origen_evento_id, motivo, creado_por, ocurrido_en)
          VALUES (?, ?, ?, ?, 'condonado', ?, ?, ?, ?, ?)
          ''',
          [
            _uuid.v4(), tenantId, clienteId, contratoId, total,
            origenEventoId, motivo, cobradorId, ocurridoEn,
          ],
        );
      } else if (disposicion == 'devolver') {
        await tx.execute(
          '''
          INSERT INTO saldos_favor (id, tenant_id, cliente_id, contrato_id, tipo,
            monto, origen_evento_id, cobrador_id, fecha_devolucion, motivo,
            creado_por, ocurrido_en)
          VALUES (?, ?, ?, ?, 'devuelto', ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            _uuid.v4(), tenantId, clienteId, contratoId, total,
            origenEventoId, cobradorId, fechaLocal, motivo, cobradorId, ocurridoEn,
          ],
        );
      }
      // op_log: 1 entrada en el contrato — disposición del excedente (acreditar/
      // devolver/condonar). No toca pagos; monto/motivo van en el resumen.
      final motivoDisp = disposicion == 'devolver'
          ? 'Excedente devuelto'
          : disposicion == 'condonar'
              ? 'Excedente condonado'
              : 'Crédito acreditado a favor';
      await _opContrato(tx, tenantId: tenantId, opId: opId,
          tipoOp: 'disposicion_excedente', actor: actor, ocurridoEn: ocurridoEn,
          contratoId: contratoId, campos: const [],
          resumen: {'monto': total, 'motivo': motivoDisp});
      return total;
    });
  }

  /// Aplica saldo a favor del cliente a una [cuotaId] (la elige el call-site,
  /// oldest-first). Modela la cobertura como un `cargos_extra` origen='credito'
  /// tipo='credito_aplicado' (RESTA del saldo canónico, NO toca `pagos` ni el
  /// arqueo) + una fila `saldos_favor` tipo='aplicado'. Clampea a `min(saldo de
  /// la cuota, disponible)`. Espeja offline `cargos_neto`/estado (los triggers no
  /// corren en SQLite); el server valida el no-sobregiro al sincronizar.
  /// Devuelve lo aplicado.
  Future<double> aplicarCredito({
    required String cuotaId,
    required String cobradorId,
    double? montoMax,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(_dbOrGlobal, cobradorId);
    return _dbWOrGlobal.writeTransaction((tx) async {
      final cu = await tx.getAll(
        '''
        SELECT tenant_id, cliente_id, contrato_id, cobrador_id, estado, monto,
               COALESCE(cargos_neto, 0) AS cargos_neto,
               COALESCE(monto_pagado, 0) AS monto_pagado
          FROM cuotas WHERE id = ?
        ''',
        [cuotaId],
      );
      if (cu.isEmpty) throw StateError('Cuota no encontrada.');
      final r = cu.first;
      final estado = r['estado'] as String;
      if (estado == 'anulada' || estado == 'pagada') {
        throw StateError('La cuota no admite crédito (anulada o ya pagada).');
      }
      final tenantId = r['tenant_id'] as String;
      final clienteId = r['cliente_id'] as String;
      final montoCuota = (r['monto'] as num).toDouble();
      final cargosNeto = (r['cargos_neto'] as num).toDouble();
      final pagado = (r['monto_pagado'] as num).toDouble();
      final saldoCuota = montoCuota + cargosNeto - pagado;
      if (saldoCuota <= 0.005) {
        throw StateError('La cuota no tiene saldo pendiente.');
      }

      final disp = await _saldoFavorDisponibleTx(tx, clienteId);
      if (disp <= 0.005) throw StateError('El cliente no tiene saldo a favor.');

      var aplicar = saldoCuota < disp ? saldoCuota : disp;
      if (montoMax != null && montoMax < aplicar) aplicar = montoMax;
      aplicar = (aplicar * 100).round() / 100;
      if (aplicar <= 0.005) return 0.0;

      // cobrador_id denormalizado = el de la cuota (para que el cobrador vea el
      // saldo reducido); si es admin-managed (NULL) usa el que aplica (admin).
      final cargoCobradorId = (r['cobrador_id'] as String?) ?? cobradorId;
      final cargoId = _uuid.v4();
      await tx.execute(
        '''
        INSERT INTO cargos_extra (id, tenant_id, cuota_id, cobrador_id, tipo,
          monto, porcentaje, descripcion, aplicado_por, aplicado_en,
          client_local_id, ocurrido_en, origen)
        VALUES (?, ?, ?, ?, 'credito_aplicado', ?, NULL, ?, ?, ?, ?, ?, 'credito')
        ''',
        [
          cargoId, tenantId, cuotaId, cargoCobradorId, aplicar,
          'Crédito a favor aplicado', cobradorId, ocurridoEn, _uuid.v4(),
          ocurridoEn,
        ],
      );

      // Espejo offline de cargos_neto + estado (el server lo recalcula al sync).
      final delta = await _deltaCargosExtraLocal(tx, cuotaId);
      final nuevoEstado = calcularEstadoCuota(
        estadoActual: estado,
        montoCuota: montoCuota,
        pagadoNuevo: pagado,
        deltaCargosExtra: delta,
      );
      await tx.execute(
        'UPDATE cuotas SET cargos_neto = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
        [delta, nuevoEstado, ocurridoEn, cuotaId],
      );

      // Fila del libro: consumo del crédito (server valida no-sobregiro).
      await tx.execute(
        '''
        INSERT INTO saldos_favor (id, tenant_id, cliente_id, contrato_id, tipo,
          monto, cuota_id, cargo_id, cobrador_id, creado_por, ocurrido_en)
        VALUES (?, ?, ?, ?, 'aplicado', ?, ?, ?, ?, ?, ?)
        ''',
        [
          _uuid.v4(), tenantId, clienteId, r['contrato_id'], aplicar, cuotaId,
          cargoId, cobradorId, cobradorId, ocurridoEn,
        ],
      );

      // op_log: el crédito a favor cubre parte/total de la cuota (el saldo baja;
      // no toca pagos/arqueo). Scoped a la cuota; monto en el resumen.
      final saldoDespues = montoCuota + delta - pagado;
      await _opCuota(tx, tenantId: tenantId, opId: opId,
          tipoOp: 'aplicar_credito', actor: actor, ocurridoEn: ocurridoEn,
          cuotaId: cuotaId, campos: [
            {'campo': 'estado', 'antes': estado, 'despues': nuevoEstado},
            {
              'campo': 'saldo',
              'antes': saldoCuota < 0 ? 0 : saldoCuota,
              'despues': saldoDespues < 0 ? 0 : saldoDespues,
            },
          ], resumen: {'monto': aplicar, 'motivo': 'Crédito a favor aplicado'});

      // Mirror offline del color del mapa: el crédito cambió estado/saldo de la
      // cuota → recalcular vencimiento_mas_viejo (no-op si es cargo manual).
      final contratoCredito = r['contrato_id'] as String?;
      if (contratoCredito != null) {
        await recalcVmvDeContrato(tx, contratoCredito);
      }
      return aplicar;
    });
  }

  /// Suma neta de `cargos_extra` de una cuota (espeja `calcular_cargos_neto`
  /// 0023/0127): reconexión/otro suman; descuentos y `credito_aplicado` restan.
  Future<double> _deltaCargosExtraLocal(dynamic ex, String cuotaId) async {
    final rows = await ex.getAll(
      '''
      SELECT COALESCE(SUM(CASE WHEN tipo IN ('reconexion','otro')
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
