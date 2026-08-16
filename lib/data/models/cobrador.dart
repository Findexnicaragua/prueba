/// Representa al usuario logueado (super_admin / admin / admin_cobranza /
/// admin_usuarios / cobrador / tecnico / admin_tickets).
/// Se sincroniza desde la tabla `cobradores`.
class Cobrador {
  const Cobrador({
    required this.id,
    required this.tenantId,
    required this.nombre,
    this.telefono,
    required this.rol,
    this.prefijoRecibo,
    required this.activo,
    this.puedeCambiarFecha = false,
    this.dashboardPinConfigurado = false,
  });

  final String id;
  final String tenantId;
  final String nombre;
  final String? telefono;
  final String rol;
  final String? prefijoRecibo;
  final bool activo;
  // Permiso (lo habilita el admin) para el cambio de fecha de pago por días.
  // El rol 'admin' siempre puede (con la feature ON); este flag es para
  // cobradores/admin_cobranza. Ver puede_cambiar_fecha (0119).
  final bool puedeCambiarFecha;
  /// Si el usuario TIENE PIN. El valor no viaja acá (0201/0202): el propio
  /// llega por `dashboard_pins` y el ajeno no llega a ningún lado.
  final bool dashboardPinConfigurado;

  bool get esSuperAdmin => rol == 'super_admin';
  bool get esAdmin => rol == 'admin';
  bool get esAdminCobranza => rol == 'admin_cobranza';
  bool get esCobrador => rol == 'cobrador';
  // Roles de Fase 3 (tickets). `tecnico` es móvil-first (shell propio);
  // `admin_tickets` es un admin acotado a tickets/inventario.
  bool get esTecnico => rol == 'tecnico';
  bool get esAdminTickets => rol == 'admin_tickets';
  bool get esAdminUsuarios => rol == 'admin_usuarios';

  /// "Solo lectura" (0198): ve TODO el tenant, incluida la plata, y no puede
  /// modificar nada. Pensado para los dueños del ISP. No es un rol de trabajo:
  /// no cobra, no edita y no resuelve solicitudes.
  bool get esLectura => rol == 'lectura';

  /// Coordinador técnico (0207): reparte el trabajo. Elige qué técnico lleva
  /// cada orden y en qué posición de su cola, pero NO modifica el trabajo en sí
  /// —ni título, ni tipo, ni cliente, ni estado— ni toca dinero. Lo enforza el
  /// trigger `tickets_coordinador_solo_orden` en el server; acá solo se ocultan
  /// los controles (la UI es comodidad, la barrera está en la DB).
  bool get esCoordinador => rol == 'coordinador';

  /// True para roles con acceso a opciones restringidas del panel admin
  /// (cobradores, settings, geografía, planes, auditoría).
  /// super_admin hereda todos los permisos de admin.
  bool get tieneAccesoAdmin => esAdmin || esSuperAdmin;

  /// True para todos los roles que entran al AdminShell (galería de cards).
  bool get tieneAccesoAdminShell =>
      esAdmin || esSuperAdmin || esAdminCobranza || esAdminUsuarios || esLectura;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cobrador &&
          other.id == id &&
          other.tenantId == tenantId &&
          other.nombre == nombre &&
          other.telefono == telefono &&
          other.rol == rol &&
          other.prefijoRecibo == prefijoRecibo &&
          other.activo == activo &&
          other.puedeCambiarFecha == puedeCambiarFecha &&
          other.dashboardPinConfigurado == dashboardPinConfigurado;

  @override
  int get hashCode => Object.hash(
        id,
        tenantId,
        nombre,
        telefono,
        rol,
        prefijoRecibo,
        activo,
        puedeCambiarFecha,
        dashboardPinConfigurado,
      );

  factory Cobrador.fromRow(Map<String, dynamic> row) => Cobrador(
        id: row['id'] as String,
        tenantId: row['tenant_id'] as String,
        nombre: row['nombre'] as String,
        telefono: row['telefono'] as String?,
        rol: row['rol'] as String,
        prefijoRecibo: row['prefijo_recibo'] as String?,
        activo: (row['activo'] as int? ?? 1) == 1,
        puedeCambiarFecha: (row['puede_cambiar_fecha'] as int? ?? 0) == 1,
        dashboardPinConfigurado:
            (row['dashboard_pin_configurado'] as int? ?? 0) == 1,
      );
}
