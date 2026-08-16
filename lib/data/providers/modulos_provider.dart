import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import 'cobrador_provider.dart';
import 'db_epoch_provider.dart';

/// Códigos de módulos opcionales HABILITADOS para el tenant actual (o el
/// impersonado por el super_admin). Read-only: la fuente de verdad es
/// `tenant_modulos`, que togglea el super_admin vía RPC (`set_tenant_modulo`).
/// Se sincroniza por PowerSync. Gatea la UI de módulos opcionales (Inventario).
///
/// - `ref.watch(dbEpochProvider)`: la DB global se reasigna al cambiar de usuario
///   → hay que recrear el stream (si no, queda suscripto a la DB vieja/cerrada).
/// - Filtra por `tenant_id`: la SQLite del super_admin puede tener filas de
///   `tenant_modulos` de DOS tenants (el suyo = System + el impersonado). Sin el
///   filtro, el `SELECT` daría la UNIÓN → falso positivo si en el futuro un
///   módulo opcional pudiera estar ON en más de uno. `tenantIdProvider` ya
///   resuelve el tenant efectivo (impersonado si corresponde).
/// `habilitado` se guarda como entero 0/1 en SQLite (PowerSync no tiene bool).
final modulosHabilitadosProvider = StreamProvider<Set<String>>((ref) {
  ref.watch(dbEpochProvider);
  final tenantId = ref.watch(tenantIdProvider);
  if (tenantId == null) return Stream.value(<String>{});
  return ps.db
      .watch(
        'SELECT modulo_codigo FROM tenant_modulos WHERE habilitado = 1 AND tenant_id = ?',
        parameters: [tenantId],
      )
      .map((rows) => rows.map((r) => r['modulo_codigo'] as String).toSet());
});
