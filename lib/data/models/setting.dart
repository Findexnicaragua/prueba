import 'dart:convert';

/// Setting tipado. El valor se guarda en BD como JSON serializado.
class Setting {
  const Setting({
    required this.id,
    required this.tenantId,
    required this.clave,
    required this.valor,
    required this.tipo,
    required this.categoria,
    this.descripcion,
    required this.editablePor,
    this.updatedAt,
  });

  final String id;
  final String tenantId;
  final String clave;
  final dynamic valor;
  final String tipo;
  final String categoria;
  final String? descripcion;
  final String editablePor;

  /// `settings.updated_at` del server, tal cual llegó (string ISO).
  ///
  /// Es el TOKEN DE VERSIÓN de los archivos que este setting referencia:
  /// `empresa.logo_path` apunta a un objeto de Storage, y como el path es
  /// SIEMPRE `{tenant}/logo.png`, el path solo no distingue un logo nuevo de
  /// uno viejo. `settings_repo.update` reescribe `updated_at` en CADA cambio
  /// (incluso si el valor no cambió), así que este campo sí lo distingue.
  /// Lo consume `LogoCacheService.obtenerLogo` para no bajar de gusto.
  final String? updatedAt;

  // Getters defensivos: el widget de settings lee asBool en initState para
  // cualquier setting (no sólo los de tipo='boolean'), así que si `valor`
  // no es del tipo esperado devolvemos un default en vez de tirar TypeError.
  bool get asBool => valor is bool ? valor as bool : false;
  num get asNumber => valor is num ? valor as num : 0;
  String get asString => valor is String ? valor as String : (valor?.toString() ?? '');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Setting &&
          other.id == id &&
          other.tenantId == tenantId &&
          other.clave == clave &&
          other.valor == valor &&
          other.tipo == tipo &&
          other.categoria == categoria &&
          other.descripcion == descripcion &&
          other.editablePor == editablePor &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        tenantId,
        clave,
        valor,
        tipo,
        categoria,
        descripcion,
        editablePor,
        updatedAt,
      );

  factory Setting.fromRow(Map<String, dynamic> row) {
    final raw = row['valor'] as String?;
    dynamic decoded;
    try {
      decoded = raw == null ? null : jsonDecode(raw);
    } catch (_) {
      decoded = raw;
    }
    return Setting(
      id: row['id'] as String,
      tenantId: row['tenant_id'] as String,
      clave: row['clave'] as String,
      valor: decoded,
      tipo: row['tipo'] as String,
      categoria: row['categoria'] as String,
      descripcion: row['descripcion'] as String?,
      editablePor: row['editable_por'] as String? ?? 'admin',
      updatedAt: row['updated_at'] as String?,
    );
  }
}
