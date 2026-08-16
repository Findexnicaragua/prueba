import 'package:supabase_flutter/supabase_flutter.dart';

import '../../powersync/db.dart' as ps;

/// Servicio para entrar/salir del modo impersonación de tenant.
///
/// Cuando el super_admin "entra" a un tenant:
///   1. UPSERT en `super_admin_impersonation` con el tenant elegido.
///   2. Disconnect + reconnect PowerSync (re-evalúa sync rules →
///      descarga la data del tenant impersonado).
///
/// Cuando "sale":
///   1. DELETE de `super_admin_impersonation`.
///   2. Disconnect + reconnect PowerSync (vuelve a System).
class ImpersonationService {
  ImpersonationService(this._supabase);
  final SupabaseClient _supabase;

  /// Entra al tenant indicado. El sync gate se encarga de mostrar
  /// progreso mientras PowerSync descarga la data.
  Future<void> enter({
    required String tenantId,
    required String tenantNombre,
  }) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) throw StateError('No hay sesión activa');

    const systemTenant = '00000000-0000-0000-0000-000000000000';
    if (tenantId == systemTenant) {
      throw ArgumentError('No se puede impersonar el tenant System');
    }

    // UPSERT: si ya estaba impersonando otro tenant, reemplaza.
    await _supabase.from('super_admin_impersonation').upsert({
      'user_id': userId,
      'tenant_id': tenantId,
    });

    // Reconnect PowerSync para que re-evalúe sync rules con el nuevo
    // tenant. Esto dispara el sync gate automáticamente.
    await ps.disconnectPowerSync();
    await ps.connectPowerSync();
  }

  /// Sale del modo impersonación. Vuelve al tenant System.
  ///
  /// [reconnect]: si es true (default), reconecta PowerSync para re-evaluar
  /// las sync rules y volver a la data de System. En el flujo de signOut se
  /// pasa false porque el signOut desconecta PowerSync de todos modos (#9).
  Future<void> exit({bool reconnect = true}) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    await _supabase
        .from('super_admin_impersonation')
        .delete()
        .eq('user_id', userId);

    if (reconnect) {
      await ps.disconnectPowerSync();
      await ps.connectPowerSync();
    }
  }
}
