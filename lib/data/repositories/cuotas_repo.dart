import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/cuota.dart';
import '../utils/cobro_puntual.dart';
import '../utils/colchon_indefinido.dart';
import '../utils/cuota_estado.dart';
import '../utils/formatters.dart';
import '../utils/op_log.dart';

class CuotasRepo {
  /// [db] permite inyectar una `PowerSyncDatabase` para tests (mismo patrón
  /// que PagosRepo). En producción queda null y usa la global `ps.db`.
  CuotasRepo({PowerSyncDatabase? db}) : _db = db;
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

  Future<Cuota?> getById(String id) async {
    final rows =
        await _dbOrGlobal.getAll('SELECT * FROM cuotas WHERE id = ?', [id]);
    return rows.isEmpty ? null : Cuota.fromRow(rows.first);
  }

  /// Calcula total a cobrar de una cuota considerando cargos extra
  /// (descuentos restan, reconexión/otro suman). Mirror del SQL.
  Future<double> totalACobrar(String cuotaId) async {
    final cuota = await getById(cuotaId);
    if (cuota == null) return 0;
    final rows = await _dbOrGlobal.getAll(
      '''
      SELECT tipo, SUM(monto) AS total
        FROM cargos_extra
       WHERE cuota_id = ?
       GROUP BY tipo
      ''',
      [cuotaId],
    );
    var total = cuota.monto;
    for (final r in rows) {
      final tipo = r['tipo'] as String;
      final monto = (r['total'] as num).toDouble();
      if (tipo == 'descuento_monto' ||
          tipo == 'descuento_porcentaje' ||
          tipo == 'credito_aplicado') {
        // credito_aplicado RESTA (igual que el server cuota_total_a_cobrar 0127
        // y los mirrors _deltaCargosExtra). Sin esto el cobro presentaba un
        // saldo inflado y sobre-cobraba (audit ALTA 2026-06-24).
        total -= monto;
      } else if (tipo == 'reconexion' || tipo == 'otro') {
        total += monto;
      }
    }
    return total < 0 ? 0 : total;
  }

  // ─────────────────────────────────────────────────────────────────────
  // DESCUENTOS del admin: AJUSTES y PROMOS (Sprint 2 0115 + rediseño
  // 2026-06-11: las promos van por el MISMO riel con origen='promo' —
  // misma mecánica, etiqueta distinta en historial/recibo/reportes).
  // Principio rector: un descuento es una fila de cargos_extra — NUNCA se
  // muta cuotas.monto. Capas de validación: acá lo básico offline-first
  // (motivo/valor/estado/saldo); los TOPES del súper viven en el dialog
  // (feedback inmediato) y en el guard server trg_cargos_ajuste_guard
  // (el control REAL: habilitado + rol + motivo + tipo + topes; cubre
  // 'ajuste' y 'promo' desde 0117).
  // ─────────────────────────────────────────────────────────────────────

  /// Aplica un descuento de admin (ajuste o promo, con motivo) a una cuota
  /// pendiente/parcial. [valor] es % (0-100] si [esPorcentaje], o C$ si no.
  Future<void> aplicarAjuste({
    required String tenantId,
    required String cuotaId,
    required bool esPorcentaje,
    required double valor,
    required String motivo,
    required String aplicadoPorId,
    String origen = 'ajuste',
  }) async {
    if (origen != 'ajuste' && origen != 'promo') {
      throw Exception('Origen inválido: solo ajuste o promo.');
    }
    if (motivo.trim().isEmpty) {
      throw Exception('El ajuste requiere un motivo.');
    }
    if (valor <= 0) {
      throw Exception('El valor del ajuste debe ser mayor a cero.');
    }
    if (esPorcentaje && valor > 100) {
      throw Exception('El porcentaje no puede exceder 100.');
    }

    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await _dbWOrGlobal.writeTransaction((tx) async {
      final rows = await tx.getAll(
        '''
        SELECT monto, monto_pagado, cargos_neto, estado, cobrador_id
          FROM cuotas WHERE id = ?
        ''',
        [cuotaId],
      );
      if (rows.isEmpty) throw Exception('Cuota no encontrada.');
      final r = rows.first;
      final estado = r['estado'] as String? ?? '';
      if (estado != 'pendiente' && estado != 'parcial') {
        throw Exception('Solo se ajustan cuotas pendientes o parciales.');
      }
      final montoCuota = (r['monto'] as num).toDouble();
      final cargosNeto = (r['cargos_neto'] as num?)?.toDouble() ?? 0.0;
      final pagado = (r['monto_pagado'] as num?)?.toDouble() ?? 0.0;
      final saldo = montoCuota + cargosNeto - pagado;

      final monto = esPorcentaje ? montoCuota * valor / 100 : valor;
      if (monto > saldo + 0.01) {
        throw Exception(
          'El ajuste no puede exceder el saldo de la cuota '
          '(${saldo.toStringAsFixed(2)}).',
        );
      }

      await tx.execute(
        '''
        INSERT INTO cargos_extra (
          id, tenant_id, cuota_id, cobrador_id, tipo, monto, porcentaje,
          descripcion, aplicado_por, aplicado_en, client_local_id, ocurrido_en,
          origen
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          const Uuid().v4(),
          tenantId,
          cuotaId,
          // Denormalizado para las sync rules del cobrador (mismo patrón que
          // todo INSERT de cargos): el cargo viaja en el bucket de la cuota.
          (r['cobrador_id'] as String?) ?? aplicadoPorId,
          esPorcentaje ? 'descuento_porcentaje' : 'descuento_monto',
          monto,
          esPorcentaje ? valor : null,
          motivo.trim(),
          aplicadoPorId,
          ocurridoEn,
          const Uuid().v4(),
          ocurridoEn,
          origen,
        ],
      );
      await _recalcularCuotaLocal(tx, cuotaId, ocurridoEn: ocurridoEn);
      final desp = (await tx.getAll(
              'SELECT estado, cargos_neto FROM cuotas WHERE id = ?', [cuotaId]))
          .first;
      await _opLogCargo(tx,
          tenantId: tenantId,
          cuotaId: cuotaId,
          aplicadoPorId: aplicadoPorId,
          tipoOp: 'descuento_cuota',
          accion: 'update',
          saldoAntes: saldo,
          saldoDespues: montoCuota +
              ((desp['cargos_neto'] as num?)?.toDouble() ?? 0.0) -
              pagado,
          estadoAntes: estado,
          estadoDespues: desp['estado'] as String? ?? estado,
          monto: monto,
          motivo: motivo.trim(),
          ocurridoEn: ocurridoEn);
    });
  }

  /// TODOS los cargos/descuentos de una cuota (cualquier origen), más
  /// nuevo primero, con quién lo aplicó. El sheet del contrato los lista
  /// completos (rediseño 2026-06-12): los nacidos de un pago (`pago_id`)
  /// van solo-lectura — se revierten anulando el pago, no desde acá.
  Future<List<Map<String, dynamic>>> cargosDeCuota(String cuotaId) {
    return _dbOrGlobal.getAll(
      '''
      SELECT ce.id, ce.tipo, ce.monto, ce.porcentaje, ce.descripcion,
             ce.origen, ce.pago_id, ce.ocurrido_en, ce.aplicado_en,
             co.nombre AS aplicado_por_nombre
        FROM cargos_extra ce
   LEFT JOIN cobradores co ON co.id = ce.aplicado_por
       WHERE ce.cuota_id = ?
       ORDER BY COALESCE(ce.ocurrido_en, ce.aplicado_en) DESC
      ''',
      [cuotaId],
    );
  }

  /// Aplica un CARGO manual del admin (reconexión / otro) a una cuota
  /// abierta, desde el detalle del contrato (rediseño 2026-06-12: los
  /// cargos también se gestionan acá; el cobro solo referencia).
  /// origen='cobro' — el valor histórico de los cargos manuales: el CHECK
  /// de 0115 no tiene un origen 'admin' y el guard de ajustes solo admite
  /// descuentos. SIN pago_id: no nace de un pago, así que anular un cobro
  /// no lo toca y el admin lo puede quitar con [quitarCargo].
  Future<void> aplicarCargo({
    required String tenantId,
    required String cuotaId,
    required String tipo, // 'reconexion' | 'otro'
    required double monto,
    String? descripcion,
    required String aplicadoPorId,
  }) async {
    if (tipo != 'reconexion' && tipo != 'otro') {
      throw Exception('Tipo de cargo inválido.');
    }
    if (monto <= 0) {
      throw Exception('El monto del cargo debe ser mayor a cero.');
    }
    final desc = descripcion?.trim() ?? '';
    if (tipo == 'otro' && desc.isEmpty) {
      throw Exception('Describí el cargo (qué se está cobrando).');
    }
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await _dbWOrGlobal.writeTransaction((tx) async {
      final rows = await tx.getAll(
        'SELECT estado, cobrador_id, monto, cargos_neto, monto_pagado '
        'FROM cuotas WHERE id = ?',
        [cuotaId],
      );
      if (rows.isEmpty) throw Exception('Cuota no encontrada.');
      final estado = rows.first['estado'] as String? ?? '';
      if (estado != 'pendiente' && estado != 'parcial') {
        throw Exception('Solo se cargan cuotas pendientes o parciales.');
      }
      final montoCuota = (rows.first['monto'] as num).toDouble();
      final pagado = (rows.first['monto_pagado'] as num?)?.toDouble() ?? 0.0;
      final saldoAntes = montoCuota +
          ((rows.first['cargos_neto'] as num?)?.toDouble() ?? 0.0) -
          pagado;
      await tx.execute(
        '''
        INSERT INTO cargos_extra (
          id, tenant_id, cuota_id, cobrador_id, tipo, monto, porcentaje,
          descripcion, aplicado_por, aplicado_en, client_local_id, ocurrido_en,
          origen
        ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, 'cobro')
        ''',
        [
          const Uuid().v4(),
          tenantId,
          cuotaId,
          // Denormalizado para las sync rules del cobrador (mismo patrón
          // que todo INSERT de cargos).
          (rows.first['cobrador_id'] as String?) ?? aplicadoPorId,
          tipo,
          monto,
          desc.isEmpty ? 'Cargo por reconexión' : desc,
          aplicadoPorId,
          ocurridoEn,
          const Uuid().v4(),
          ocurridoEn,
        ],
      );
      await _recalcularCuotaLocal(tx, cuotaId, ocurridoEn: ocurridoEn);
      final desp = (await tx.getAll(
              'SELECT estado, cargos_neto FROM cuotas WHERE id = ?', [cuotaId]))
          .first;
      await _opLogCargo(tx,
          tenantId: tenantId,
          cuotaId: cuotaId,
          aplicadoPorId: aplicadoPorId,
          tipoOp: 'cargo_cuota',
          accion: 'update',
          saldoAntes: saldoAntes,
          saldoDespues: montoCuota +
              ((desp['cargos_neto'] as num?)?.toDouble() ?? 0.0) -
              pagado,
          estadoAntes: estado,
          estadoDespues: desp['estado'] as String? ?? estado,
          monto: monto,
          motivo: desc.isEmpty ? 'Cargo por reconexión' : desc,
          ocurridoEn: ocurridoEn);
    });
  }

  /// Crea una **CUOTA MANUAL** standalone para un COBRO PUNTUAL (instalación,
  /// reinstalación, anexo, multa, reconexión). No es del ciclo del contrato
  /// (`contrato_id` NULL) → excluida del total facturable y de los invariantes
  /// de dinero (INV11 ignora `tipo_cargo_manual`). Se cobra y recibe igual que
  /// una cuota mensual (mismo `registrarCobro` → pago → recibo → correlativo).
  /// Emite op_log de ALTA (1 fila, scoped a la cuota) DENTRO de la tx.
  /// Denormaliza `cobrador_id` (regla #6: el del cliente, o quien la crea si el
  /// cliente es admin-managed). Devuelve el id de la cuota para enrutar al cobro.
  Future<String> crearCuotaManual({
    required String tenantId,
    required String clienteId,
    required String tipo, // tipo_cargo_manual canónico (kCobroPuntualTipos)
    required double monto,
    required String descripcion,
    required String creadoPorId,
    String? ticketId, // liga el cobro al ticket que lo originó (cobro de campo)
  }) async {
    if (!kCobroPuntualTipos.containsKey(tipo)) {
      throw Exception('Concepto de cobro inválido.');
    }
    if (monto <= 0) {
      throw Exception('El monto debe ser mayor a cero.');
    }
    final desc = descripcion.trim();
    if (desc.isEmpty) {
      throw Exception('Describí el cobro (qué se está cobrando).');
    }
    final id = const Uuid().v4();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    // Fecha de HOY anclada a Nicaragua (UTC-6, regla #1b) — NO la local del
    // device: periodo = fecha_vencimiento = hoy. Con venc=hoy la cuota no entra
    // a mora/gracia ni a oldest-first (éste excluye las manuales por tipo).
    final hoy = Fmt.hoyNicaragua().toIso8601String().split('T').first;
    await _dbWOrGlobal.writeTransaction((tx) async {
      // Anti-doble-cobro por ticket (audit 2026-07-05): re-check DENTRO de la tx
      // — el guard de UI es reactivo y no cubre el mismo device offline / doble
      // tap. La red DURA es el índice UNIQUE parcial 0175 (rechaza el 2º del otro
      // device al sync); esto corta el 2º en el mismo device antes de insertar.
      if (ticketId != null) {
        final yaHay = await tx.getAll(
          "SELECT id FROM cuotas WHERE ticket_id = ? AND estado <> 'anulada' "
          'LIMIT 1',
          [ticketId],
        );
        if (yaHay.isNotEmpty) {
          throw StateError('Este ticket ya tiene un cobro registrado.');
        }
      }
      // cobrador_id denormalizado (sync rules del cobrador): el del cliente, o
      // quien crea el cobro si el cliente es admin-managed (cobrador_id NULL).
      final cli = await tx.getAll(
          'SELECT cobrador_id FROM clientes WHERE id = ?', [clienteId]);
      final cobradorId =
          (cli.isNotEmpty ? cli.first['cobrador_id'] as String? : null) ??
              creadoPorId;
      await tx.execute(
        '''
        INSERT INTO cuotas (
          id, tenant_id, contrato_id, cliente_id, cobrador_id, periodo,
          fecha_vencimiento, monto, monto_pagado, cargos_neto, estado,
          descripcion, tipo_cargo_manual, ticket_id, ocurrido_en
        ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 0, 0, 'pendiente', ?, ?, ?, ?)
        ''',
        [
          id, tenantId, clienteId, cobradorId, hoy, hoy, monto, desc, tipo,
          ticketId, ocurridoEn,
        ],
      );
      final actor = await OpLog.actorDeUsuario(tx, creadoPorId);
      await OpLog.escribir(
        tx,
        tenantId: tenantId,
        opId: OpLog.nuevoOpId(),
        tipoOp: 'cobro_puntual',
        entidad: 'cuotas',
        entidadId: id,
        accion: 'create',
        diff: {
          'campos': [
            {'campo': 'monto', 'antes': null, 'despues': monto},
            {'campo': 'fecha_vencimiento', 'antes': null, 'despues': hoy},
          ],
          'resumen': {
            'motivo': 'Cobro puntual — ${etiquetaCobroPuntual(tipo)}: $desc',
          },
        },
        actor: actor,
        ocurridoEn: DateTime.parse(ocurridoEn),
      );
    });
    return id;
  }

  /// Quita un cargo/descuento gestionable por el admin: DELETE físico del cargo.
  /// Emite op_log scoped a la cuota (1 fila) DENTRO de la tx — sin esto el borrado
  /// no dejaba rastro (audit 2026-06-28; el diálogo promete "queda en el
  /// historial"). [aplicadoPorId] = quién lo quita (para el actor). Protegidos:
  /// los nacidos de un pago (`pago_id` — se revierten anulando el pago) y los de
  /// liquidación (cancelación terminal). Server: trg_cargos_extra_actualizar_neto
  /// + recalcular_cuota rehacen neto/estado; acá los espejamos.
  Future<void> quitarCargo({
    required String cargoId,
    required String aplicadoPorId,
  }) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await _dbWOrGlobal.writeTransaction((tx) async {
      // PROTEGIDO (audit 2026-07-04, crítico $): se excluye origen='credito' —
      // un crédito aplicado está ligado a una fila '-' de saldos_favor (FK
      // cargo_id ON DELETE SET NULL, NO cascade); borrar solo el cargo dejaba
      // el libro huérfano marcando el crédito consumido y des-descontaba la
      // cuota → el cliente perdía el saldo a favor (invariante #4/#15). El
      // crédito se revierte por su flujo dedicado que compensa saldos_favor.
      final rows = await tx.getAll(
        'SELECT cuota_id, tenant_id, tipo, monto, descripcion FROM cargos_extra '
        "WHERE id = ? AND pago_id IS NULL AND origen NOT IN ('liquidacion', 'credito')",
        [cargoId],
      );
      if (rows.isEmpty) return; // ya quitado o protegido: no-op idempotente
      final cuotaId = rows.first['cuota_id'] as String;
      final tenantId = rows.first['tenant_id'] as String;
      final esDescuento =
          (rows.first['tipo'] as String? ?? '').startsWith('descuento');
      final montoCargo = (rows.first['monto'] as num?)?.toDouble() ?? 0.0;
      final descCargo = (rows.first['descripcion'] as String?) ?? '';
      // Saldo/estado de la cuota ANTES de quitar, para el diff del change log.
      final antesCuota = (await tx.getAll(
              'SELECT estado, monto, cargos_neto, monto_pagado FROM cuotas WHERE id = ?',
              [cuotaId]))
          .first;
      final montoCuota = (antesCuota['monto'] as num).toDouble();
      final pagado = (antesCuota['monto_pagado'] as num?)?.toDouble() ?? 0.0;
      final estadoAntes = antesCuota['estado'] as String? ?? '';
      final saldoAntes = montoCuota +
          ((antesCuota['cargos_neto'] as num?)?.toDouble() ?? 0.0) -
          pagado;

      await tx.execute('DELETE FROM cargos_extra WHERE id = ?', [cargoId]);
      await _recalcularCuotaLocal(tx, cuotaId, ocurridoEn: ocurridoEn);

      final desp = (await tx.getAll(
              'SELECT estado, cargos_neto FROM cuotas WHERE id = ?', [cuotaId]))
          .first;
      await _opLogCargo(tx,
          tenantId: tenantId,
          cuotaId: cuotaId,
          aplicadoPorId: aplicadoPorId,
          tipoOp: 'quitar_cargo_cuota',
          accion: 'delete',
          saldoAntes: saldoAntes,
          saldoDespues: montoCuota +
              ((desp['cargos_neto'] as num?)?.toDouble() ?? 0.0) -
              pagado,
          estadoAntes: estadoAntes,
          estadoDespues: desp['estado'] as String? ?? estadoAntes,
          monto: montoCargo,
          motivo: '${esDescuento ? 'Descuento' : 'Cargo'} quitado'
              '${descCargo.isEmpty ? '' : ': $descCargo'}',
          ocurridoEn: ocurridoEn);
    });
  }

  /// Emite UNA fila op_log scoped a la CUOTA por un cambio de cargo/descuento del
  /// admin (audit 2026-06-28: antes estos movimientos de saldo no dejaban rastro).
  /// Visible en el HistorialOpLog de la cuota; el `motivo` va al subtítulo. El
  /// super_admin se registra como "System Admin" (lo resuelve actorDeUsuario).
  Future<void> _opLogCargo(
    dynamic tx, {
    required String tenantId,
    required String cuotaId,
    required String aplicadoPorId,
    required String tipoOp,
    required String accion,
    required double saldoAntes,
    required double saldoDespues,
    required String estadoAntes,
    required String estadoDespues,
    required double monto,
    required String motivo,
    required String ocurridoEn,
  }) async {
    final actor = await OpLog.actorDeUsuario(tx, aplicadoPorId);
    await OpLog.escribir(
      tx,
      tenantId: tenantId,
      opId: OpLog.nuevoOpId(),
      tipoOp: tipoOp,
      entidad: 'cuotas',
      entidadId: cuotaId,
      accion: accion,
      diff: {
        'campos': [
          {'campo': 'saldo', 'antes': saldoAntes, 'despues': saldoDespues},
          if (estadoDespues != estadoAntes)
            {'campo': 'estado', 'antes': estadoAntes, 'despues': estadoDespues},
        ],
        'resumen': {'monto': monto, 'motivo': motivo},
      },
      actor: actor,
      ocurridoEn: DateTime.parse(ocurridoEn),
    );
  }

  /// Mirror local de los triggers server (0023 neto + 0083 estado) tras
  /// insertar/borrar cargos — mismo cálculo que AplicarCargoDialog y
  /// PagosRepo._deltaCargosExtra.
  Future<void> _recalcularCuotaLocal(
    // `dynamic` como en PagosRepo._deltaCargosExtra: el contexto de la tx.
    dynamic tx,
    String cuotaId, {
    required String ocurridoEn,
  }) async {
    final cuotaInfo = await tx.getAll(
      'SELECT monto, monto_pagado, estado, contrato_id FROM cuotas WHERE id = ?',
      [cuotaId],
    );
    if (cuotaInfo.isEmpty) return;
    final montoCuota = (cuotaInfo.first['monto'] as num).toDouble();
    final pagado = (cuotaInfo.first['monto_pagado'] as num?)?.toDouble() ?? 0.0;
    final estadoActual = cuotaInfo.first['estado'] as String? ?? 'pendiente';
    final deltaRows = await tx.getAll(
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
    final delta = (deltaRows.first['sumar'] as num).toDouble() -
        (deltaRows.first['restar'] as num).toDouble();
    final nuevoEstado = calcularEstadoCuota(
      estadoActual: estadoActual,
      montoCuota: montoCuota,
      pagadoNuevo: pagado,
      deltaCargosExtra: delta,
    );
    await tx.execute(
      'UPDATE cuotas SET cargos_neto = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
      [delta, nuevoEstado, ocurridoEn, cuotaId],
    );
    // Mirror offline del color del mapa: el ajuste/cargo cambio estado/saldo de
    // la cuota -> recalcular vencimiento_mas_viejo (no-op si es cargo manual sin
    // contrato). El server lo hace via trg_cuotas_vmv (AFTER UPDATE OF estado).
    final contratoId = cuotaInfo.first['contrato_id'] as String?;
    if (contratoId != null) {
      await recalcVmvDeContrato(tx, contratoId);
    }
  }
}

final cuotasRepoProvider = Provider((_) => CuotasRepo());
