import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../providers/cobrador_provider.dart';
import '../providers/impersonation_provider.dart';
import '../utils/op_log.dart';

enum VisitaResultado {
  cobrado('Cobrado'),
  noEstaba('No estaba'),
  sinPago('Sin pago'),
  promesaPago('Promesa de pago'),
  otro('Otro');

  const VisitaResultado(this.label);
  final String label;

  static VisitaResultado fromString(String s) => switch (s) {
        'cobrado' => VisitaResultado.cobrado,
        'no_estaba' => VisitaResultado.noEstaba,
        'sin_pago' => VisitaResultado.sinPago,
        'promesa_pago' => VisitaResultado.promesaPago,
        _ => VisitaResultado.otro,
      };

  String get value => switch (this) {
        VisitaResultado.cobrado => 'cobrado',
        VisitaResultado.noEstaba => 'no_estaba',
        VisitaResultado.sinPago => 'sin_pago',
        VisitaResultado.promesaPago => 'promesa_pago',
        VisitaResultado.otro => 'otro',
      };
}

class Visita {
  const Visita({
    required this.id,
    required this.fecha,
    required this.resultado,
    required this.cobradorId,
    this.cobradorNombre,
    this.notas,
  });

  final String id;
  final DateTime fecha;
  final VisitaResultado resultado;
  final String cobradorId;
  final String? cobradorNombre;
  final String? notas;

  factory Visita.fromRow(Map<String, dynamic> row) => Visita(
        id: row['id'] as String,
        fecha: DateTime.parse(row['fecha'] as String),
        resultado: VisitaResultado.fromString(row['resultado'] as String),
        cobradorId: row['cobrador_id'] as String,
        cobradorNombre: row['cobrador_nombre'] as String?,
        notas: row['notas'] as String?,
      );
}

class VisitasService {
  VisitasService(this._ref);
  final Ref _ref;

  Future<void> registrar({
    required String clienteId,
    required VisitaResultado resultado,
    String? notas,
  }) async {
    // Guard (#9): no registrar visitas impersonando — se atribuiría al tenant
    // System (fila real del super_admin), no al impersonado.
    if (_ref.read(estaImpersonandoProvider)) {
      throw StateError(
          'No se puede registrar visitas mientras gestionás un tenant como super_admin.');
    }
    final cobrador = _ref.read(cobradorActualProvider).valueOrNull;
    final user = Supabase.instance.client.auth.currentUser;
    if (cobrador == null || user == null) {
      throw StateError('Usuario no autenticado');
    }

    // ocurrido_en = hora REAL del dispositivo (UTC) para el change log.
    // Coincide con `fecha` (también device time UTC).
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final id = const Uuid().v4();
    // op_log (rework change log): el alta de la visita queda en su historial.
    final opId = OpLog.nuevoOpId();
    final actor = await OpLog.actorDeUsuario(ps.db, user.id);
    await ps.dbW.writeTransaction((tx) async {
      await tx.execute(
        '''
        INSERT INTO visitas (id, tenant_id, cliente_id, cobrador_id,
                             resultado, notas, fecha, ocurrido_en)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          id,
          cobrador.tenantId,
          clienteId,
          user.id,
          resultado.value,
          notas?.trim().isEmpty ?? true ? null : notas?.trim(),
          ocurridoEn,
          ocurridoEn,
        ],
      );
      // Scoped al CLIENTE (patrón fotos/etiquetas): la visita no tiene pantalla
      // de detalle propia, así que su rastro debe caer en el historial del
      // cliente. Antes se emitía con entidad='visitas' → NINGÚN HistorialOpLog
      // la leía (change-log muerto que igual consumía sync; audit Fase 3).
      await OpLog.escribir(tx,
          tenantId: cobrador.tenantId, opId: opId, tipoOp: 'alta_entidad',
          entidad: 'clientes', entidadId: clienteId, accion: 'update',
          diff: {
            'campos': const [],
            'resumen': {'motivo': 'Visita registrada: ${resultado.label}'},
          },
          actor: actor, ocurridoEn: DateTime.parse(ocurridoEn));
    });
  }

  Stream<List<Visita>> watch(String clienteId) {
    return ps.db.watch(
      '''
      SELECT v.id, v.fecha, v.resultado, v.cobrador_id, v.notas,
             co.nombre AS cobrador_nombre
        FROM visitas v
   LEFT JOIN cobradores co ON co.id = v.cobrador_id
       WHERE v.cliente_id = ?
       ORDER BY v.fecha DESC
       LIMIT 50
      ''',
      parameters: [clienteId],
    ).map((rows) => rows.map(Visita.fromRow).toList()).asBroadcastStream();
  }
}

final visitasServiceProvider =
    Provider((ref) => VisitasService(ref));
