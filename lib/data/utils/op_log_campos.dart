import 'audit_changelog.dart'
    show
        kAuditCamposCatalogo,
        kAuditCamposVisiblesDefault,
        kAuditEntidadLabel,
        auditFieldLabel;

/// Config de QUÉ campos se muestran en el change log unificado (op_log),
/// **por ENTIDAD/tabla** (clientes, contratos, cuotas, equipos, red, etc.) — el
/// mismo modelo que el panel de audit viejo, pero alimentando el op_log.
///
/// El op_log guarda TODO en `diff` (campos + resumen); acá se decide qué se
/// MUESTRA. Dos capas:
///  - **Defaults universales** por entidad → aplican a TODOS los tenants.
///  - **Override del super_admin por tenant** (`op_log.campos_visibles` =
///    `{entidad: [campos]}`); el render usa `override ?? default`.
///
/// El render filtra por `entidad`; sin entrada para una entidad → muestra todos
/// los campos que cambiaron (ediciones de entidad aún sin curar).

/// Catálogo de TODOS los campos toggleables, POR ENTIDAD. Reusa el catálogo de
/// entidades del audit (comprensivo: clientes, contratos, planes, red,
/// inventario/equipos, etc.) y SOBREESCRIBE `cuotas` con los campos propios del
/// op_log de cobro (estado/saldo + resumen del cobro).
final Map<String, List<String>> kOpLogCamposCatalogo = {
  ...kAuditCamposCatalogo,
  'cuotas': const [
    'estado',
    'saldo',
    'monto',
    'entregado',
    'vuelto',
    'metodo',
    'fecha_pago',
    'fecha_vencimiento',
    'notas',
    'recibo',
    'motivo',
  ],
};

/// Campos visibles POR DEFECTO, por entidad. Reusa los defaults curados del
/// audit y sobreescribe `cuotas` con los recomendados del cobro.
final Map<String, List<String>> kOpLogCamposVisiblesDefault = {
  for (final e in kAuditCamposVisiblesDefault.entries) e.key: e.value.toList(),
  'cuotas': const [
    'estado',
    'saldo',
    'monto',
    'entregado',
    'vuelto',
    'metodo',
    'fecha_pago',
    'fecha_vencimiento',
    'notas',
  ],
};

/// Label legible de la entidad (reusa el catálogo del audit).
String opLogEntidadLabel(String entidad) =>
    kAuditEntidadLabel[entidad] ?? entidad;

const _campoLabels = <String, String>{
  'monto': 'Monto',
  'entregado': 'Entregado',
  'vuelto': 'Vuelto',
  'metodo': 'Método',
  'fecha_pago': 'Fecha del cobro',
  'recibo': 'Recibo',
  'estado': 'Estado',
  'saldo': 'Saldo',
  'motivo': 'Motivo',
  'notas': 'Notas',
};

/// Label legible de un campo (cae a `auditFieldLabel` para campos de entidades
/// editadas, que no están en este catálogo fijo).
String opLogCampoLabel(String key) => _campoLabels[key] ?? auditFieldLabel(key);

/// Campos visibles efectivos para una ENTIDAD: el override del tenant si existe
/// (filtrado contra el catálogo, en el orden del catálogo), si no el default.
/// Devuelve `null` para entidades SIN catálogo → el render muestra todos los
/// campos que cambiaron.
List<String>? opLogCamposVisibles(
  String? entidad, {
  Map<String, List<String>>? override,
}) {
  if (entidad == null) return null;
  final catalogo = kOpLogCamposCatalogo[entidad];
  if (catalogo == null) return null;
  final ov = override?[entidad];
  if (ov == null) return kOpLogCamposVisiblesDefault[entidad] ?? catalogo;
  return [for (final k in catalogo) if (ov.contains(k)) k];
}
