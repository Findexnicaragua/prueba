import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import '../repositories/settings_repo.dart';
import '../utils/ticket_sla.dart';
import 'db_epoch_provider.dart';

/// Cuenta de tickets EN RIESGO (por vencer + vencidos) entre los ACTIVOS del
/// técnico — alimenta el badge de la tab "Mis tickets". El SQLite local ya viene
/// acotado por el bucket `por_tecnico_tickets` (sólo los suyos), así que contamos
/// todo lo local activo: el ticket asignado aparece solo (la sync ES el aviso) y
/// el badge avisa del vencimiento inminente.
///
/// Se recomputa al cambiar las filas (sync) Y cada 60s — el paso del TIEMPO solo
/// ya puede cruzar un ticket a "por vencer" sin que cambie nada en la DB. Es
/// matemática pura sobre data local → funciona OFFLINE.
final ticketsEnRiesgoCountProvider = StreamProvider.autoDispose<int>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (per-user)
  final slaMap = ref.watch(appSettingsProvider).slaHorasPorPrioridad;

  final controller = StreamController<int>();
  var ultimas = <Map<String, dynamic>>[];

  void emitir() {
    if (!controller.isClosed) controller.add(_contarEnRiesgo(ultimas, slaMap));
  }

  final sub = ps.db.watch('''
    SELECT t.estado, t.prioridad, t.created_at, t.segundos_pausado, tt.sla_horas
      FROM tickets t
 LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
     WHERE t.estado IN ('abierto','asignado','en_progreso','en_espera','reabierto')
  ''').listen((rows) {
    ultimas = rows;
    emitir();
  });
  final timer = Timer.periodic(const Duration(seconds: 60), (_) => emitir());

  ref.onDispose(() {
    sub.cancel();
    timer.cancel();
    controller.close();
  });

  emitir(); // 0 inicial hasta que llegue la primera fila
  return controller.stream;
});

int _contarEnRiesgo(List<Map<String, dynamic>> rows, Map<String, int> slaMap) {
  var n = 0;
  for (final t in rows) {
    final createdRaw = t['created_at'] as String?;
    if (createdRaw == null) continue;
    final estado = t['estado'] as String? ?? 'abierto';
    final prioridad = t['prioridad'] as String?;
    final ef = slaHorasEfectivas(t['sla_horas'] as int?, slaMap[prioridad]);
    final sla = ticketSlaEstado(
      estado: estado,
      createdAt: parseTicketWallClock(createdRaw),
      slaHoras: ef,
      prioridad: prioridad,
      segundosPausado: (t['segundos_pausado'] as int?) ?? 0,
    );
    if (sla == SlaEstado.porVencer || sla == SlaEstado.vencido) n++;
  }
  return n;
}
