import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import '../models/cliente.dart';

/// Repo de clientes. Todos los queries leen del SQLite local sincronizado.
class ClientesRepo {
  const ClientesRepo();

  Stream<Cliente?> watchById(String id) {
    return ps.db
        .watch('SELECT * FROM clientes WHERE id = ?', parameters: [id])
        .map((rows) => rows.isEmpty ? null : Cliente.fromRow(rows.first));
  }

  Future<Cliente?> getById(String id) async {
    final rows = await ps.db
        .getAll('SELECT * FROM clientes WHERE id = ?', [id]);
    return rows.isEmpty ? null : Cliente.fromRow(rows.first);
  }
}

final clientesRepoProvider = Provider((_) => const ClientesRepo());

final clienteByIdProvider =
    StreamProvider.autoDispose.family<Cliente?, String>((ref, id) {
  return ref.watch(clientesRepoProvider).watchById(id);
});

/// Nombre del cobrador asignado al cliente (LEFT JOIN a `cobradores`).
/// Provider auxiliar para no inflar el modelo `Cliente` con un campo derivado
/// de otra tabla — se observa aparte en la pantalla de detalle del cliente.
/// Emite null cuando el cliente no tiene cobrador asignado (o no existe).
final clienteCobradorNombreProvider =
    StreamProvider.autoDispose.family<String?, String>((ref, clienteId) {
  return ps.db
      .watch(
        '''
        SELECT co.nombre AS cobrador_nombre
          FROM clientes c
     LEFT JOIN cobradores co ON co.id = c.cobrador_id
         WHERE c.id = ?
        ''',
        parameters: [clienteId],
      )
      .map((rows) =>
          rows.isEmpty ? null : rows.first['cobrador_nombre'] as String?);
});
