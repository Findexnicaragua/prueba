import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/deuda_snapshot.dart';
import '../models/solicitud_accion.dart';
import '../utils/busqueda_cliente.dart';
import '../utils/op_log.dart';
import 'contratos_repo.dart';
import 'settings_repo.dart';

class SolicitudesRepo {
  const SolicitudesRepo();

  Future<void> crear({
    required String tenantId,
    required String solicitanteId,
    required TipoSolicitud tipo,
    required String entidadId,
    Map<String, dynamic> datos = const {},
    required String solicitanteLabel,
    String? motivo,
    String? notas,
    DeudaSnapshot? deudaSnapshot,
  }) async {
    final tipoDb = _tipoToDb(tipo);
    final existente = await ps.db.getAll(
      'SELECT id FROM solicitudes_accion '
      "WHERE tipo = ? AND entidad_id = ? AND estado = 'pendiente' LIMIT 1",
      [tipoDb, entidadId],
    );
    if (existente.isNotEmpty) {
      throw StateError(
        'Ya existe una solicitud pendiente de "${tipo.name}" para esta entidad.',
      );
    }

    final id = const Uuid().v4();
    final now = DateTime.now();
    final ocurridoEn = now.toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, solicitanteId);

    await ps.dbW.writeTransaction((tx) async {
      await tx.execute(
        // `motivo`/`notas` son COLUMNAS desde 0222: `datos` queda SOLO para el
        // borrador de la entidad (ahí su `notas` son las del CONTRATO).
        'INSERT INTO solicitudes_accion '
        '(id, tenant_id, solicitante_id, tipo, entidad_id, datos, motivo, '
        'notas, deuda_snapshot, estado, solicitante_label, created_at, '
        'ocurrido_en) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          tenantId,
          solicitanteId,
          tipoDb,
          entidadId,
          jsonEncode(datos),
          motivo,
          notas,
          // Columna propia (0229), NO adentro de `datos`: ese mapa es el
          // BORRADOR de la entidad y `_ejecutarCrearContrato` lo lee campo por
          // campo. Mezclar cosas ahí fue el bug de v0.31.20.
          deudaSnapshot?.encode(),
          'pendiente',
          solicitanteLabel,
          now.toIso8601String(),
          ocurridoEn.toIso8601String(),
        ],
      );
      await OpLog.escribirCambioEntidad(
        tx,
        tenantId: tenantId,
        opId: opId,
        entidad: 'solicitudes_accion',
        entidadId: id,
        antes: const {},
        despues: {
          'tipo': tipoDb,
          'entidad_id': entidadId,
          'estado': 'pendiente',
        },
        actor: actor,
        ocurridoEn: ocurridoEn,
      );
    });
  }

  Future<void> aprobar({
    required String solicitudId,
    required String aprobadorId,
    required String tenantId,
  }) async {
    final ocurridoEn = DateTime.now().toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, aprobadorId);

    await ps.dbW.writeTransaction((tx) async {
      final antes = (await tx.getAll(
        'SELECT * FROM solicitudes_accion WHERE id = ?',
        [solicitudId],
      ))
          .first;
      await tx.execute(
        'UPDATE solicitudes_accion SET estado = ?, aprobador_id = ?, '
        'resolved_at = ? WHERE id = ?',
        [
          'aprobada',
          aprobadorId,
          ocurridoEn.toIso8601String(),
          solicitudId,
        ],
      );
      final despues = (await tx.getAll(
        'SELECT * FROM solicitudes_accion WHERE id = ?',
        [solicitudId],
      ))
          .first;
      await OpLog.escribirCambioEntidad(
        tx,
        tenantId: tenantId,
        opId: opId,
        entidad: 'solicitudes_accion',
        entidadId: solicitudId,
        antes: antes,
        despues: despues,
        actor: actor,
        ocurridoEn: ocurridoEn,
      );
    });
  }

  Future<void> rechazar({
    required String solicitudId,
    required String aprobadorId,
    required String tenantId,
    required String motivo,
  }) async {
    final ocurridoEn = DateTime.now().toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, aprobadorId);

    await ps.dbW.writeTransaction((tx) async {
      final antes = (await tx.getAll(
        'SELECT * FROM solicitudes_accion WHERE id = ?',
        [solicitudId],
      ))
          .first;
      await tx.execute(
        'UPDATE solicitudes_accion SET estado = ?, aprobador_id = ?, '
        'motivo_rechazo = ?, resolved_at = ? WHERE id = ?',
        [
          'rechazada',
          aprobadorId,
          motivo,
          ocurridoEn.toIso8601String(),
          solicitudId,
        ],
      );
      final despues = (await tx.getAll(
        'SELECT * FROM solicitudes_accion WHERE id = ?',
        [solicitudId],
      ))
          .first;
      await OpLog.escribirCambioEntidad(
        tx,
        tenantId: tenantId,
        opId: opId,
        entidad: 'solicitudes_accion',
        entidadId: solicitudId,
        antes: antes,
        despues: despues,
        actor: actor,
        ocurridoEn: ocurridoEn,
      );
    });
  }

  Future<void> ejecutarAccionAprobada(SolicitudAccion s, String aprobadorId) async {
    switch (s.tipo) {
      case TipoSolicitud.crearContrato:
        await _ejecutarCrearContrato(s, aprobadorId);
      case TipoSolicitud.cancelarContrato:
        await _ejecutarCancelarContrato(s, aprobadorId);
      case TipoSolicitud.suspenderContrato:
        await _ejecutarSuspenderContrato(s, aprobadorId);
      case TipoSolicitud.reactivarContrato:
        await _ejecutarReactivarContrato(s, aprobadorId);
      case TipoSolicitud.desactivarCliente:
        await _ejecutarDesactivarCliente(s, aprobadorId);
      case TipoSolicitud.cambiarPlan:
        await _ejecutarCambiarPlan(s, aprobadorId);
      case TipoSolicitud.desconocido:
        // La creó una app MÁS NUEVA que ésta. Ejecutarla a ciegas sería peor
        // que no hacer nada: no sabemos qué pidió. Se corta con un mensaje
        // accionable en vez de dejar la solicitud "aprobada" sin efecto.
        throw Exception(
          'Esta solicitud la creó una versión más nueva de la app. '
          'Actualizá para poder aprobarla.',
        );
    }
  }

  /// ¿El código de contrato sigue libre AHORA, al momento de aprobar?
  ///
  /// Mira los dos lados, en este orden:
  ///  1. La RÉPLICA LOCAL — instantánea y suficiente para el caso común (el
  ///     bucket del admin baja los contratos y las solicitudes del tenant).
  ///  2. El SERVER — porque la réplica puede estar atrasada respecto de otro
  ///     dispositivo, que es justo cómo se perdieron los 10 contratos.
  ///
  /// Si no hay internet no se bloquea la aprobación: se deja pasar con el
  /// chequeo local. Preferimos que la operación siga funcionando offline; el
  /// caso que quedaría sin cubrir es una carrera entre dos dispositivos SIN
  /// conexión, mucho más raro que el que estamos cerrando.
  Future<void> _verificarCodigoLibre(String tenantId,
      {required String? codigoPedido}) async {
    final codigo = codigoPedido?.trim();
    if (codigo == null || codigo.isEmpty) return; // el código es opcional

    final buscado = foldBusqueda(codigo);

    // 1. Local, con consulta DIRIGIDA. `foldSqlExpr` pliega ñ y acentos del
    //    lado de SQLite (regla 1d: su lower() es ASCII-only), así que el
    //    filtro lo hace la base y no se traen 4.500 filas a memoria.
    final locales = await ps.db.getAll(
      'SELECT ct.codigo, c.nombre AS cliente '
      '  FROM contratos ct '
      '  LEFT JOIN clientes c ON c.id = ct.cliente_id '
      ' WHERE ct.tenant_id = ? AND ${foldSqlExpr('ct.codigo')} = ? LIMIT 1',
      [tenantId, buscado],
    );
    if (locales.isNotEmpty) {
      final quien = locales.first['cliente'] as String?;
      throw StateError(
        'El código "$codigo" ya lo tiene otro contrato'
        '${quien != null ? ' (cliente $quien)' : ''}. '
        'Rechazá esta solicitud y pedila con otro número.',
      );
    }

    // 2. Server. También DIRIGIDA: `ilike` con el código exacto es la misma
    //    semántica del índice único `contratos_codigo_tenant_uq`
    //    (UNIQUE (tenant_id, upper(codigo))), y se confirma en Dart porque el
    //    plegado de ñ/acentos no lo hace Postgres.
    //
    //    OJO — la versión anterior traía las filas del tenant con un límite y
    //    filtraba en memoria: Telecable Mairena tiene 4.524 contratos con
    //    código, así que cualquier tope daba un FALSO "libre" para los que
    //    quedaban afuera. Justo lo contrario de lo que este guard busca.
    try {
      final filas = await Supabase.instance.client
          .from('contratos')
          .select('codigo')
          .eq('tenant_id', tenantId)
          .ilike('codigo', codigo.replaceAll('%', r'\%').replaceAll('_', r'\_'))
          .limit(5)
          .timeout(const Duration(seconds: 8));
      for (final row in filas) {
        final c = (row['codigo'] as String?)?.trim();
        if (c != null && foldBusqueda(c) == buscado) {
          throw StateError(
            'El código "$codigo" ya lo tiene otro contrato en el servidor. '
            'Rechazá esta solicitud y pedila con otro número.',
          );
        }
      }
    } on StateError {
      rethrow; // el conflicto encontrado arriba: no lo tapamos con el catch
    } catch (e) {
      // Distinguir "no llegué al server" de "el server me contestó un error".
      // Tragarse los dos por igual daba un falso "libre" justo en la última
      // línea antes de escribir el contrato — el mismo modo de falla que este
      // guard vino a cerrar. Sin red seguimos con el chequeo local (no trabamos
      // al admin); con un error del server frenamos, porque no sabemos.
      if (!_esErrorDeRed(e)) {
        throw StateError(
          'No se pudo verificar el código contra el servidor. '
          'Probá de nuevo en un momento.',
        );
      }
    }
  }

  /// ¿El error fue de RED, o el server respondió? Mismo criterio que
  /// `contrato_form_screen._esErrorDeRed`: si hubo `PostgrestException` el
  /// server contestó, así que el problema no es la conexión.
  static bool _esErrorDeRed(Object e) {
    if (e is PostgrestException) return false;
    return e is SocketException ||
        e is HandshakeException ||
        e is HttpException ||
        e is TimeoutException;
  }

  /// Cambio de plan aprobado (0226).
  ///
  /// DECISIÓN DE DINERO — qué precio se usa. El plan pudo cambiar de precio
  /// entre el pedido y la aprobación. Se usa el precio **VIVO** al ejecutar, no
  /// el que se guardó al pedir: las cuotas son snapshots del precio de SU
  /// momento (invariante #5), así que la re-valuación tiene que reflejar lo que
  /// el cliente va a pagar de verdad, no lo que costaba cuando se pidió.
  /// Si difiere del snapshot, queda escrito en el motivo para que se vea.
  Future<void> _ejecutarCambiarPlan(
      SolicitudAccion s, String aprobadorId) async {
    final d = s.datos;
    final planNuevoId = d['plan_nuevo_id'] as String?;
    if (planNuevoId == null || planNuevoId.isEmpty) {
      throw Exception('La solicitud no dice a qué plan cambiar.');
    }

    final fila = await ps.db.getOptional(
      'SELECT nombre, precio_mensual FROM planes WHERE id = ?',
      [planNuevoId],
    );
    if (fila == null) {
      throw Exception(
        'El plan pedido ya no existe. Rechazá la solicitud y pedila de nuevo.',
      );
    }
    final precioVivo = ((fila['precio_mensual'] as num?) ?? 0).toDouble();
    final precioPedido = (d['precio_nuevo'] as num?)?.toDouble();

    var motivo = _motivoDeSolicitud(s);
    if (precioPedido != null && (precioPedido - precioVivo).abs() > 0.009) {
      motivo = '$motivo — OJO: el precio del plan cambió desde el pedido '
          '(pedido ${precioPedido.toStringAsFixed(2)}, '
          'aplicado ${precioVivo.toStringAsFixed(2)})';
    }
    final notas = s.notas;
    if (notas != null) motivo = '$motivo — $notas';

    await ContratosRepo().cambiarPlan(
      tenantId: s.tenantId,
      contratoId: s.entidadId,
      cobradorId: aprobadorId,
      planNuevoId: planNuevoId,
      precioNuevo: precioVivo,
      hoy: fechaEjecucion(),
      modoHoy: d['modo_hoy'] == true,
      motivo: motivo,
    );
  }

  Future<void> _ejecutarCrearContrato(
      SolicitudAccion s, String aprobadorId) async {
    final d = s.datos;
    final clienteId = d['cliente_id'] as String? ?? s.entidadId;
    final planId = d['plan_id'] as String?;
    if (planId == null) throw StateError('Falta plan_id en la solicitud.');

    final dup = await ps.db.getAll(
      'SELECT id FROM contratos '
      "WHERE cliente_id = ? AND plan_id = ? AND estado = 'activo' LIMIT 1",
      [clienteId, planId],
    );
    if (dup.isNotEmpty) {
      throw StateError(
        'Este cliente ya tiene un contrato activo con ese plan.',
      );
    }

    // REVALIDAR EL CÓDIGO AL APROBAR. Este guard NO existía y costó 10
    // contratos en Telecable Mairena: dos gestores pedían el mismo número para
    // clientes DISTINTOS (así que el chequeo de cliente+plan de arriba no los
    // veía), el admin aprobaba las dos, el INSERT entraba en el SQLite local
    // —que no tiene el índice único— y al subir el segundo lo rechazaba el
    // server con 23505. La solicitud quedaba "aprobada" y el contrato no
    // existía en ningún lado: 8 clientes activos, con servicio, sin contrato
    // ni cuotas, sin que nadie les facturara.
    //
    // El formulario ya valida esto al PEDIR (v0.31.24), pero entre el pedido y
    // la aprobación pueden pasar horas: en los casos reales fueron 18. La única
    // validación que sirve es la del momento de escribir.
    await _verificarCodigoLibre(s.tenantId, codigoPedido: d['codigo'] as String?);

    final fechaInicioStr = d['fecha_inicio'] as String?;
    if (fechaInicioStr == null) throw StateError('Falta fecha_inicio.');
    final fechaInicio = DateTime.parse(fechaInicioStr);

    final diaPago = (d['dia_pago'] as num?)?.toInt() ?? fechaInicio.day;
    final duracionMeses = (d['duracion_meses'] as num?)?.toInt();
    final costoInstalacion = (d['costo_instalacion'] as num?)?.toDouble() ?? 0;
    final codigo = d['codigo'] as String?;
    final notas = d['notas'] as String?;

    DateTime? fechaFin;
    if (duracionMeses != null) {
      fechaFin = DateTime(
        fechaInicio.year + duracionMeses ~/ 12,
        fechaInicio.month + duracionMeses % 12,
        fechaInicio.day,
      );
    }

    final primerCobro = _primerCobroEstimado(fechaInicio);
    final primerCobroStr =
        '${primerCobro.year.toString().padLeft(4, '0')}-${primerCobro.month.toString().padLeft(2, '0')}-${primerCobro.day.toString().padLeft(2, '0')}';

    final clienteRow = await ps.db.getOptional(
      'SELECT cobrador_id FROM clientes WHERE id = ?',
      [clienteId],
    );
    final cobradorId = clienteRow?['cobrador_id'] as String?;

    final nuevoId = const Uuid().v4();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, aprobadorId);

    await ps.dbW.writeTransaction((tx) async {
      await tx.execute(
        '''
        INSERT INTO contratos (
          id, tenant_id, cliente_id, codigo, cobrador_id, plan_id, dia_pago,
          fecha_inicio, fecha_fin, duracion_meses, fecha_primer_cobro,
          costo_instalacion, notas, estado, created_at, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'activo', ?, ?)
        ''',
        [
          nuevoId,
          s.tenantId,
          clienteId,
          codigo,
          cobradorId,
          planId,
          diaPago,
          fechaInicioStr,
          fechaFin != null
              ? '${fechaFin.year.toString().padLeft(4, '0')}-${fechaFin.month.toString().padLeft(2, '0')}-${fechaFin.day.toString().padLeft(2, '0')}'
              : null,
          duracionMeses,
          primerCobroStr,
          costoInstalacion,
          notas,
          DateTime.now().toIso8601String(),
          ocurridoEn,
        ],
      );
      final despues = (await tx
              .getAll('SELECT * FROM contratos WHERE id = ?', [nuevoId]))
          .first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: s.tenantId,
          opId: opId,
          entidad: 'contratos',
          entidadId: nuevoId,
          antes: const {},
          despues: despues,
          actor: actor,
          ocurridoEn: DateTime.parse(ocurridoEn));
    });
  }

  Future<void> _ejecutarCancelarContrato(
      SolicitudAccion s, String aprobadorId) async {
    final precio = await _precioMensualDeContrato(s.entidadId);
    final notas = s.notas;
    final fecha = fechaEjecucion();
    // cancelarContrato no acepta `notas` → se anexan al motivo.
    await ContratosRepo().cancelarContrato(
      tenantId: s.tenantId,
      contratoId: s.entidadId,
      cobradorId: aprobadorId,
      fechaCancelacion: fecha,
      precioMensual: precio,
      motivo: notas != null
          ? '${_motivoDeSolicitud(s)} — $notas'
          : _motivoDeSolicitud(s),
    );
    // Cancelación → sin fila de evento: origenEventoId = null.
    await _disponerExcedente(s.entidadId, fecha, precio, aprobadorId, null);
  }

  /// Acredita el excedente que el cliente pagó por adelantado y no va a usar.
  ///
  /// Faltaba en los dos ejecutores de aprobación, y no era menor: los DOS
  /// caminos directos (el diálogo de suspensión y el de cancelación) sí lo
  /// hacían, así que el mismo corte registraba el crédito o no según por dónde
  /// hubiera pasado. Un cliente que pagó tres meses por adelantado y era
  /// suspendido por la cola perdía el rastro de su plata: las cuotas futuras se
  /// anulaban y no le quedaba fila en `saldos_favor`.
  ///
  /// Importa más desde v0.31.28, cuando la cola pasó a ser el ÚNICO camino del
  /// admin_cobranza —que decide más de la mitad de las bajas— y desde que se
  /// eliminó la suspensión en lote, que sí lo registraba.
  ///
  /// `acreditar` es el default seguro: deja el crédito a favor del cliente. NO
  /// se elige 'devolver' ni 'condonar' por la cola — sacarían plata de caja sin
  /// una decisión explícita por cliente. Si hace falta devolverlo, es un acto
  /// aparte desde la ficha.
  ///
  /// No-op si no hay excedente o si el tenant tiene el crédito apagado. Si falla
  /// NO se propaga: la suspensión ya está hecha y tirar acá dejaría la
  /// solicitud marcada como fallida con el contrato ya cortado.
  Future<void> _disponerExcedente(String contratoId, DateTime fecha,
      double precio, String aprobadorId, String? origenEventoId) async {
    try {
      final on =
          await const SettingsRepo().read('cobranza.credito_excedente',
              fallback: true);
      if (on != true) return;
      await ContratosRepo().registrarDisposicionExcedente(
        contratoId: contratoId,
        fechaCorte: fecha,
        precioMensual: precio,
        disposicion: 'acreditar',
        cobradorId: aprobadorId,
        origenEventoId: origenEventoId,
        motivo: 'Aprobación de solicitud',
      );
    } catch (_) {
      // El corte ya se aplicó; el crédito se puede reponer a mano desde la
      // ficha del cliente.
    }
  }

  /// Motivo que queda escrito en el EVENTO del contrato al aprobar.
  ///
  /// El motivo/notas ya vienen resueltos por el modelo (columnas 0222 con
  /// fallback al JSON viejo). Acá solo se cubre la solicitud que no trae
  /// ninguno — las creadas antes de que el motivo fuera obligatorio.
  static String _motivoDeSolicitud(SolicitudAccion s) =>
      s.motivo ??
      'Aprobada solicitud de ${s.solicitanteLabel ?? 'admin_usuarios'}';

  Future<void> _ejecutarSuspenderContrato(
      SolicitudAccion s, String aprobadorId) async {
    final precio = await _precioMensualDeContrato(s.entidadId);
    final fecha = fechaEjecucion();
    final suspId = await ContratosRepo().suspenderContrato(
      tenantId: s.tenantId,
      contratoId: s.entidadId,
      cobradorId: aprobadorId,
      fechaSuspension: fecha,
      precioMensual: precio,
      motivo: _motivoDeSolicitud(s),
      notas: s.notas,
    );
    await _disponerExcedente(s.entidadId, fecha, precio, aprobadorId, suspId);
  }

  Future<void> _ejecutarReactivarContrato(
      SolicitudAccion s, String aprobadorId) async {
    final precio = await _precioMensualDeContrato(s.entidadId);
    await ContratosRepo().reactivarContrato(
      contratoId: s.entidadId,
      cobradorId: aprobadorId,
      fechaReactivacion: fechaEjecucion(),
      precioMensual: precio,
    );
  }

  /// La fecha con la que el APROBADOR va a ejecutar la acción: hoy en Nicaragua
  /// (UTC-6, regla #1b), SIN truncar a medianoche.
  ///
  /// Pública a propósito: el diálogo de solicitud y la tarjeta de aprobación
  /// calculan la deuda con ESTA misma fecha. Si la UI usara otra, el número que
  /// se le muestra al admin no sería el que el sistema va a aplicar.
  ///
  /// OJO — NO es `Fmt.hoyNicaragua()`, que sí trunca a medianoche. No se
  /// unifican: la truncada alimenta los cortes de mora/gracia y cambiarla acá
  /// movería el prorrateo del ciclo en curso, que es plata.
  static DateTime fechaEjecucion() =>
      DateTime.now().toUtc().subtract(const Duration(hours: 6));

  Future<void> _ejecutarDesactivarCliente(
      SolicitudAccion s, String aprobadorId) async {
    final rows = await ps.db.getAll(
      'SELECT COUNT(*) AS n FROM contratos '
      "WHERE cliente_id = ? AND estado = 'activo'",
      [s.entidadId],
    );
    final n = (rows.first['n'] as int?) ?? 0;
    if (n > 0) {
      throw StateError(
        'No se puede desactivar: el cliente tiene $n contrato(s) activo(s). '
        'Suspendé o cancelá primero.',
      );
    }

    // MISMO CRITERIO QUE EL SERVER. El trigger `trg_clientes_guard_desactivar`
    // (0220) bloquea por DEUDA, no por contratos activos, así que un cliente
    // con el contrato ya cancelado pero con cuotas impagas pasaba este chequeo
    // y lo rechazaba el server al sincronizar: la solicitud quedaba aprobada y
    // el cliente seguía activo. Hoy hay 5 clientes en ese hueco.
    final deuda = await ps.db.getAll(
      'SELECT COUNT(*) AS n, '
      '       COALESCE(SUM(max(monto + COALESCE(cargos_neto, 0) '
      '                        - COALESCE(monto_pagado, 0), 0)), 0) AS saldo '
      '  FROM cuotas '
      " WHERE cliente_id = ? AND estado IN ('pendiente','parcial')",
      [s.entidadId],
    );
    final saldo = ((deuda.first['saldo'] as num?) ?? 0).toDouble();
    if (saldo > 0.01) {
      final cuantas = (deuda.first['n'] as num?)?.toInt() ?? 0;
      throw StateError(
        'No se puede desactivar: debe ${saldo.toStringAsFixed(2)} en $cuantas '
        'cuota(s). Un cliente desactivado no debe tener deuda: cobrale o '
        'condonale la deuda primero.',
      );
    }

    final ocurridoEn = DateTime.now().toUtc();
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, aprobadorId);

    await ps.dbW.writeTransaction((tx) async {
      final antes = (await tx.getAll(
        'SELECT * FROM clientes WHERE id = ?',
        [s.entidadId],
      ))
          .first;
      await tx.execute(
        'UPDATE clientes SET activo = 0, updated_at = ?, ocurrido_en = ? '
        'WHERE id = ?',
        [
          DateTime.now().toIso8601String(),
          ocurridoEn.toIso8601String(),
          s.entidadId,
        ],
      );
      final despues = (await tx.getAll(
        'SELECT * FROM clientes WHERE id = ?',
        [s.entidadId],
      ))
          .first;
      await OpLog.escribirCambioEntidad(tx,
          tenantId: s.tenantId,
          opId: opId,
          entidad: 'clientes',
          entidadId: s.entidadId,
          antes: antes,
          despues: despues,
          actor: actor,
          ocurridoEn: ocurridoEn);
    });
  }

  static Future<double> _precioMensualDeContrato(String contratoId) async {
    final row = await ps.db.getOptional(
      'SELECT p.precio_mensual FROM contratos c '
      'JOIN planes p ON c.plan_id = p.id WHERE c.id = ?',
      [contratoId],
    );
    return (row?['precio_mensual'] as num?)?.toDouble() ?? 0;
  }

  static DateTime _primerCobroEstimado(DateTime fechaInicio) {
    final base = DateTime(fechaInicio.year, fechaInicio.month + 1, 1);
    final ultimoDia = DateTime(base.year, base.month + 1, 0).day;
    final dia = fechaInicio.day < ultimoDia ? fechaInicio.day : ultimoDia;
    return DateTime(base.year, base.month, dia);
  }

  /// Delegado al modelo: era una COPIA literal de `SolicitudAccion.tipoDb`.
  static String _tipoToDb(TipoSolicitud tipo) => SolicitudAccion.tipoDbDe(tipo);
}

final solicitudesRepoProvider =
    Provider<SolicitudesRepo>((ref) => const SolicitudesRepo());

final solicitudesPendientesCountProvider = StreamProvider<int>((ref) {
  return ps.db
      .watch(
        "SELECT COUNT(*) as cnt FROM solicitudes_accion WHERE estado = 'pendiente'",
      )
      .map((rows) => (rows.first['cnt'] as num?)?.toInt() ?? 0);
});

final solicitudesPendientesProvider =
    StreamProvider<List<SolicitudAccion>>((ref) {
  return ps.db
      .watch(
        'SELECT * FROM solicitudes_accion WHERE estado = ? '
        'ORDER BY ocurrido_en DESC',
        parameters: ['pendiente'],
      )
      .map((rows) => rows.map(SolicitudAccion.fromRow).toList());
});

final misSolicitudesProvider =
    StreamProvider.family<List<SolicitudAccion>, String>(
        (ref, solicitanteId) {
  return ps.db
      .watch(
        'SELECT * FROM solicitudes_accion WHERE solicitante_id = ? '
        'ORDER BY ocurrido_en DESC',
        parameters: [solicitanteId],
      )
      .map((rows) => rows.map(SolicitudAccion.fromRow).toList());
});
