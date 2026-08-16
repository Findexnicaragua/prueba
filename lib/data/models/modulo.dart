/// Módulo del catálogo del sistema (cobranza, inventario, etc.).
/// Sólo el panel Super Admin lo lee — vía RPC `list_modulos`.
class Modulo {
  const Modulo({
    required this.codigo,
    required this.nombre,
    this.descripcion,
    required this.esBase,
    required this.orden,
  });

  final String codigo;
  final String nombre;
  final String? descripcion;
  final bool esBase;
  final int orden;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Modulo &&
          other.codigo == codigo &&
          other.nombre == nombre &&
          other.descripcion == descripcion &&
          other.esBase == esBase &&
          other.orden == orden;

  @override
  int get hashCode => Object.hash(
        codigo,
        nombre,
        descripcion,
        esBase,
        orden,
      );

  factory Modulo.fromMap(Map<String, dynamic> m) => Modulo(
        codigo: m['codigo'] as String,
        nombre: m['nombre'] as String,
        descripcion: m['descripcion'] as String?,
        esBase: m['es_base'] as bool,
        orden: (m['orden'] as num).toInt(),
      );
}
