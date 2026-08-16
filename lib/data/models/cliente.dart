class Cliente {
  const Cliente({
    required this.id,
    required this.tenantId,
    this.cobradorId,
    this.comunidadId,
    this.codigo,
    required this.nombre,
    this.cedula,
    this.telefono,
    this.email,
    this.direccion,
    this.direccionReferencia,
    this.latitud,
    this.longitud,
    this.fotoPath,
    this.notas,
    required this.activo,
  });

  final String id;
  final String tenantId;
  final String? cobradorId;
  final String? comunidadId;
  // Código simbólico legible del cliente (ej. CL00027). Identidad VISUAL,
  // no reemplaza el id (uuid). Único por tenant, inmutable una vez asignado.
  final String? codigo;
  final String nombre;
  final String? cedula;
  final String? telefono;
  final String? email;
  final String? direccion;
  final String? direccionReferencia;
  final double? latitud;
  final double? longitud;
  final String? fotoPath;
  // Nota interna sobre la PERSONA (no sobre su servicio — eso va en
  // `contratos.notas`). La ven todos los roles; la edita solo `admin`.
  final String? notas;
  final bool activo;

  bool get tieneUbicacion => latitud != null && longitud != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cliente &&
          other.id == id &&
          other.tenantId == tenantId &&
          other.cobradorId == cobradorId &&
          other.comunidadId == comunidadId &&
          other.codigo == codigo &&
          other.nombre == nombre &&
          other.cedula == cedula &&
          other.telefono == telefono &&
          other.email == email &&
          other.direccion == direccion &&
          other.direccionReferencia == direccionReferencia &&
          other.latitud == latitud &&
          other.longitud == longitud &&
          other.fotoPath == fotoPath &&
          other.notas == notas &&
          other.activo == activo;

  @override
  int get hashCode => Object.hash(
        id,
        tenantId,
        cobradorId,
        comunidadId,
        codigo,
        nombre,
        cedula,
        telefono,
        email,
        direccion,
        direccionReferencia,
        latitud,
        longitud,
        fotoPath,
        notas,
        activo,
      );

  factory Cliente.fromRow(Map<String, dynamic> row) => Cliente(
        id: row['id'] as String,
        tenantId: row['tenant_id'] as String,
        cobradorId: row['cobrador_id'] as String?,
        comunidadId: row['comunidad_id'] as String?,
        codigo: row['codigo'] as String?,
        nombre: row['nombre'] as String,
        cedula: row['cedula'] as String?,
        telefono: row['telefono'] as String?,
        email: row['email'] as String?,
        direccion: row['direccion'] as String?,
        direccionReferencia: row['direccion_referencia'] as String?,
        latitud: (row['latitud'] as num?)?.toDouble(),
        longitud: (row['longitud'] as num?)?.toDouble(),
        fotoPath: row['foto_path'] as String?,
        notas: row['notas'] as String?,
        activo: (row['activo'] as int? ?? 1) == 1,
      );
}
