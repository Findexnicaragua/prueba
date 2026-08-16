import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/cobrador.dart';
import 'cobrador_provider.dart';

/// Acciones del ciclo de contrato que pueden requerir autorización del admin.
enum AccionSensible {
  crearContrato,
  suspenderContrato,
  reactivarContrato,
  cancelarContrato,
  cambiarPlan,
  desactivarCliente,
}

/// ¿Esta acción, para este rol, tiene que pasar por aprobación del admin?
///
/// ESTA ES LA PREGUNTA QUE FALTABA. Antes cada botón preguntaba
/// `esAdminUsuarios ? solicitar : ejecutarDirecto` — o sea decidía por ROL y
/// por descarte: todo el que no fuera `admin_usuarios` caía en la rama directa,
/// incluido el `admin_cobranza` y cualquier rol que se agregue mañana. Ese
/// "por descarte" es exactamente el bug que reportó Rubén (2026-08-09):
/// el admin_cobranza suspendía y cancelaba sin pedirle permiso a nadie, y en
/// producción resultó ser quien decide el 55% de las bajas de contrato.
///
/// La regla ahora es al revés y es explícita: **requiere aprobación salvo que
/// seas quien aprueba**. Un rol nuevo nace pidiendo permiso, no saltándoselo.
///
/// OJO — esto es la mitad CLIENTE de la barrera. La otra mitad es la RLS: hoy
/// `contratos_write_admins` deja escribir a admin Y admin_cobranza por igual,
/// así que una app vieja instalada sigue ejecutando directo. Cerrar esa policy
/// es el paso siguiente, y va DESPUÉS de que todos actualicen (por eso 0225
/// registra la versión de cada dispositivo).
bool requiereAprobacionPara(Cobrador? c, AccionSensible accion) {
  if (c == null) return false; // sin identidad no se decide nada
  // El admin ES quien aprueba: pedirse permiso a sí mismo no tiene sentido y
  // dejaría la operación sin nadie que la destrabe.
  if (c.esAdmin || c.esSuperAdmin) return false;
  // Todos los demás roles con acceso a estas pantallas piden permiso.
  return true;
}

/// Versión provider, para usar en el `build` de las pantallas.
final requiereAprobacionProvider =
    Provider.family<bool, AccionSensible>((ref, accion) {
  final c = ref.watch(cobradorActualProvider).valueOrNull;
  return requiereAprobacionPara(c, accion);
});
