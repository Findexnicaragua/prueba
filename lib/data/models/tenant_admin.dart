import 'package:flutter/foundation.dart';

/// Tenant tal como lo ve el super_admin. Llega desde la RPC
/// `list_tenants_admin` con métricas pre-calculadas.
class TenantAdmin {
  const TenantAdmin({
    required this.id,
    required this.nombre,
    required this.activo,
    required this.createdAt,
    required this.cobradoresCount,
    required this.modulosHabilitados,
  });

  final String id;
  final String nombre;
  final bool activo;
  final DateTime createdAt;
  final int cobradoresCount;
  final List<String> modulosHabilitados;

  bool tieneModulo(String codigo) => modulosHabilitados.contains(codigo);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TenantAdmin &&
          other.id == id &&
          other.nombre == nombre &&
          other.activo == activo &&
          other.createdAt == createdAt &&
          other.cobradoresCount == cobradoresCount &&
          listEquals(other.modulosHabilitados, modulosHabilitados);

  @override
  int get hashCode => Object.hash(
        id,
        nombre,
        activo,
        createdAt,
        cobradoresCount,
        Object.hashAll(modulosHabilitados),
      );

  factory TenantAdmin.fromMap(Map<String, dynamic> m) => TenantAdmin(
        id: m['id'] as String,
        nombre: m['nombre'] as String,
        activo: m['activo'] as bool? ?? true,
        createdAt: DateTime.parse(m['created_at'] as String),
        cobradoresCount: (m['cobradores_count'] as num).toInt(),
        modulosHabilitados:
            (m['modulos_habilitados'] as List).cast<String>(),
      );
}
