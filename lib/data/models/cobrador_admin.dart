/// Cobrador tal como lo ve el super_admin desde el panel /super.
/// Incluye datos de `cobradores` + metadata de `auth.users` (email,
/// último login, fecha de invitación) que llega vía la RPC
/// `list_cobradores_tenant`.
class CobradorAdmin {
  const CobradorAdmin({
    required this.id,
    this.email,
    required this.nombre,
    this.telefono,
    required this.rol,
    required this.activo,
    this.prefijoRecibo,
    required this.createdAt,
    this.lastSignInAt,
    this.emailConfirmedAt,
    this.invitedAt,
    this.clientesAsignados = 0,
  });

  final String id;
  // Nullable: auth.users.email puede ser null (signup por teléfono, usuario
  // borrado parcialmente).
  final String? email;
  final String nombre;
  final String? telefono;
  final String rol;
  final bool activo;
  final String? prefijoRecibo;
  final DateTime createdAt;
  final DateTime? lastSignInAt;
  final DateTime? emailConfirmedAt;
  final DateTime? invitedAt;
  /// Sólo para rol cobrador: cuántos clientes activos están asignados a
  /// este cobrador. 0 para otros roles.
  final int clientesAsignados;

  /// Fue invitado pero nunca confirmó el email (no completó el signup).
  bool get invitacionPendiente => emailConfirmedAt == null;

  /// Nunca inició sesión en la app (puede haber confirmado email pero no
  /// haberse logueado todavía).
  bool get nuncaLogueado => lastSignInAt == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CobradorAdmin &&
          other.id == id &&
          other.email == email &&
          other.nombre == nombre &&
          other.telefono == telefono &&
          other.rol == rol &&
          other.activo == activo &&
          other.prefijoRecibo == prefijoRecibo &&
          other.createdAt == createdAt &&
          other.lastSignInAt == lastSignInAt &&
          other.emailConfirmedAt == emailConfirmedAt &&
          other.invitedAt == invitedAt &&
          other.clientesAsignados == clientesAsignados;

  @override
  int get hashCode => Object.hash(
        id,
        email,
        nombre,
        telefono,
        rol,
        activo,
        prefijoRecibo,
        createdAt,
        lastSignInAt,
        emailConfirmedAt,
        invitedAt,
        clientesAsignados,
      );

  factory CobradorAdmin.fromMap(Map<String, dynamic> m) => CobradorAdmin(
        id: m['id'] as String,
        email: m['email'] as String?,
        nombre: m['nombre'] as String,
        telefono: m['telefono'] as String?,
        rol: m['rol'] as String,
        activo: m['activo'] as bool,
        prefijoRecibo: m['prefijo_recibo'] as String?,
        createdAt: DateTime.parse(m['created_at'] as String),
        lastSignInAt: m['last_sign_in_at'] != null
            ? DateTime.parse(m['last_sign_in_at'] as String)
            : null,
        emailConfirmedAt: m['email_confirmed_at'] != null
            ? DateTime.parse(m['email_confirmed_at'] as String)
            : null,
        invitedAt: m['invited_at'] != null
            ? DateTime.parse(m['invited_at'] as String)
            : null,
        clientesAsignados:
            (m['clientes_asignados'] as num?)?.toInt() ?? 0,
      );
}
