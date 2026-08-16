import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/cobrador_admin.dart';
import '../models/cobrador_stats.dart';
import '../models/modulo.dart';
import '../models/tenant_admin.dart';
import '../utils/edge_functions.dart';

/// Repo del panel /super/*. Habla con Supabase por RPC — no toca el SQLite
/// local. Las tablas modulos / tenant_modulos no se sincronizan al cliente.
class SuperAdminRepo {
  const SuperAdminRepo(this._client);

  final SupabaseClient _client;

  Future<List<Modulo>> listModulos() async {
    final res = await _client.rpc('list_modulos') as List<dynamic>;
    return res
        .map((e) => Modulo.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Crea un tenant + invita al admin en una sola operación atómica
  /// (best-effort). Si el invite falla tras crear el tenant, la Edge
  /// Function intenta rollback. Devuelve el id del tenant nuevo para
  /// que el caller pueda navegar al detalle.
  ///
  /// Si `enviarEmail` es false, no se envía email — la Edge Function
  /// crea al admin con una password aleatoria y la devuelve en
  /// `adminPassword` para que el super_admin la comparta por otro
  /// canal (WhatsApp, etc.). Útil cuando el proveedor SMTP está en
  /// sandbox o no autoriza el destinatario. El admin se loguea con
  /// email+password normal por /login.
  Future<
      ({
        String tenantId,
        String adminUserId,
        String adminEmail,
        String? adminPassword,
      })> crearTenant({
    required String nombre,
    required String adminEmail,
    required String adminNombre,
    String? adminTelefono,
    List<String> modulosExtra = const [],
    String? redirectTo,
    bool enviarEmail = true,
    // Password manual (sólo path no-email): si se provee, el server la usa
    // en vez de generar una y NO la eco-devuelve en `admin_password`.
    String? passwordManual,
  }) async {
    final data = await invokeEdgeFunction(_client, 'crear-tenant', body: {
      'tenant_nombre': nombre,
      'admin_email': adminEmail,
      'admin_nombre': adminNombre,
      if (adminTelefono != null && adminTelefono.isNotEmpty)
        'admin_telefono': adminTelefono,
      if (modulosExtra.isNotEmpty) 'modulos_extra': modulosExtra,
      if (redirectTo != null) 'redirect_to': redirectTo,
      if (!enviarEmail && passwordManual != null && passwordManual.isNotEmpty)
        'password': passwordManual,
      // Mando el flag siempre (no condicional) — el server tiene su
      // propio default true, pero ser explícito previene ambigüedad si
      // cambia ese default en el futuro.
      'enviar_email': enviarEmail,
    });
    return (
      tenantId: data['tenant_id'] as String,
      adminUserId: data['admin_user_id'] as String,
      // Fallback al email que mandamos: si una Edge Function stale
      // (deploy roto, versión vieja) no eco el campo, evitamos el
      // crash por cast no-nulo.
      adminEmail: (data['admin_email'] as String?) ?? adminEmail,
      adminPassword: data['admin_password'] as String?,
    );
  }

  Future<List<TenantAdmin>> listTenants() async {
    final res = await _client.rpc('list_tenants_admin') as List<dynamic>;
    return res
        .map((e) => TenantAdmin.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> setTenantModulo({
    required String tenantId,
    required String modulo,
    required bool habilitado,
  }) async {
    await _client.rpc('set_tenant_modulo', params: {
      'p_tenant_id': tenantId,
      'p_modulo': modulo,
      'p_habilitado': habilitado,
    });
  }

  /// Suspende / reactiva un tenant entero (fix F0). Corta el acceso de TODOS
  /// sus usuarios vía el gate de login (`verificar_acceso`). Solo super_admin
  /// (el guard lo hace la función; System está protegido).
  Future<void> setTenantActivo({
    required String tenantId,
    required bool activo,
  }) async {
    await _client.rpc('set_tenant_activo', params: {
      'p_tenant_id': tenantId,
      'p_activo': activo,
    });
  }

  Future<List<CobradorAdmin>> listCobradoresTenant(String tenantId) async {
    final res = await _client.rpc('list_cobradores_tenant', params: {
      'p_tenant_id': tenantId,
    }) as List<dynamic>;
    return res
        .map((e) => CobradorAdmin.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> setCobradorActivo({
    required String cobradorId,
    required bool activo,
  }) async {
    await _client.rpc('set_cobrador_activo', params: {
      'p_cobrador_id': cobradorId,
      'p_activo': activo,
    });
  }

  Future<void> setCobradorRol({
    required String cobradorId,
    required String nuevoRol,
  }) async {
    await _client.rpc('set_cobrador_rol', params: {
      'p_cobrador_id': cobradorId,
      'p_nuevo_rol': nuevoRol,
    });
  }

  /// Llama a la Edge Function `forzar-password-cobrador` con service_role
  /// del lado server. Sólo super_admin lo puede usar; los guards los hace
  /// la Edge Function.
  Future<void> forzarPasswordCobrador({
    required String cobradorId,
    required String nuevaPassword,
  }) async {
    await invokeEdgeFunction(_client, 'forzar-password-cobrador', body: {
      'cobrador_id': cobradorId,
      'nueva_password': nuevaPassword,
    });
  }

  /// Llama a la Edge Function `reenviar-invitacion`. Borra el user
  /// pending y lo re-crea con la misma metadata.
  ///
  /// Si `enviarEmail` es true (default): Supabase manda un email nuevo
  /// con magic-link. Si es false: se genera password aleatoria server
  /// side y se devuelve en `nuevaPassword` para que el caller la
  /// muestre y el super_admin la comparta por otro canal (workaround
  /// SMTP en sandbox). En ambos modos devolvemos también el email y
  /// el nuevo user_id.
  Future<({String newUserId, String email, String? nuevaPassword})>
      reenviarInvitacion({
    required String cobradorId,
    String? redirectTo,
    bool enviarEmail = true,
  }) async {
    final data = await invokeEdgeFunction(_client, 'reenviar-invitacion', body: {
      'cobrador_id': cobradorId,
      if (redirectTo != null) 'redirect_to': redirectTo,
      // Explícito siempre para que un cambio futuro del default en el
      // server no rompa este caller silenciosamente.
      'enviar_email': enviarEmail,
    });
    return (
      newUserId: data['new_user_id'] as String,
      email: data['email'] as String,
      nuevaPassword: data['nueva_password'] as String?,
    );
  }

  /// Llama a la Edge Function `cambiar-email-cobrador`. Sólo super_admin.
  Future<void> cambiarEmailCobrador({
    required String cobradorId,
    required String nuevoEmail,
  }) async {
    await invokeEdgeFunction(_client, 'cambiar-email-cobrador', body: {
      'cobrador_id': cobradorId,
      'nuevo_email': nuevoEmail,
    });
  }

  /// Llama a la Edge Function `eliminar-cobrador`. Sólo super_admin.
  /// Bloquea si el usuario tiene historial operativo — sugerirá desactivar.
  Future<void> eliminarCobrador({required String cobradorId}) async {
    await invokeEdgeFunction(_client, 'eliminar-cobrador', body: {
      'cobrador_id': cobradorId,
    });
  }

  Future<CobradorStats?> getCobradorStats(String cobradorId) async {
    final res = await _client.rpc('get_cobrador_stats', params: {
      'p_cobrador_id': cobradorId,
    }) as List<dynamic>;
    if (res.isEmpty) return null;
    return CobradorStats.fromMap(
      Map<String, dynamic>.from(res.first as Map),
    );
  }
}

final superAdminRepoProvider = Provider<SuperAdminRepo>(
  (_) => SuperAdminRepo(Supabase.instance.client),
);

/// Catálogo de módulos (estable durante la sesión).
final modulosProvider = FutureProvider<List<Modulo>>((ref) {
  return ref.read(superAdminRepoProvider).listModulos();
});

/// Lista de tenants. Se invalida al cambiar un módulo (ver tenant detail).
final tenantsAdminProvider = FutureProvider<List<TenantAdmin>>((ref) {
  return ref.read(superAdminRepoProvider).listTenants();
});

/// Lista de miembros (cobradores) de un tenant específico. Family por
/// tenant_id, autoDispose para liberar memoria al salir de la pantalla
/// del tenant — `invalidate` + `read(future)` siguen funcionando porque
/// la pantalla mantiene un watcher activo mientras está mounted.
final cobradoresTenantProvider =
    FutureProvider.autoDispose.family<List<CobradorAdmin>, String>(
  (ref, tenantId) =>
      ref.read(superAdminRepoProvider).listCobradoresTenant(tenantId),
);

/// Stats agregadas de un miembro para la pantalla de detalle.
final cobradorStatsProvider =
    FutureProvider.autoDispose.family<CobradorStats?, String>(
  (ref, cobradorId) =>
      ref.read(superAdminRepoProvider).getCobradorStats(cobradorId),
);
