/// Helpers compartidos para renderizar info de cobradores y tenants. Antes
/// vivían duplicados en cada pantalla del panel super_admin; los movimos
/// acá para que cambiar un label sólo requiera tocar un archivo.
library;

/// Iniciales para CircleAvatar a partir de un nombre. Devuelve una o dos
/// letras (primera de la primera palabra + primera de la última); '?' si
/// el string está vacío o sólo tiene whitespace. Tolerante a espacios
/// múltiples.
String initialsFromName(String s) {
  final parts =
      s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

/// Label legible del rol (el código vive en DB como snake_case). Fallback
/// al string crudo si aparece un rol que no conocemos — preferible a
/// mostrar nada si en el futuro se agrega un rol nuevo.
String rolLabel(String rol) => switch (rol) {
      'super_admin' => 'Dev',
      'admin' => 'Administrador',
      'admin_cobranza' => 'Admin de cobranza',
      'admin_usuarios' => 'Admin de usuarios',
      'cobrador' => 'Cobrador',
      'tecnico' => 'Técnico',
      'admin_tickets' => 'Admin de tickets',
      'coordinador' => 'Coordinador técnico',
      'lectura' => 'Solo lectura',
      _ => rol,
    };

/// Label legible de un código de módulo del catálogo `modulos`. El código vive
/// en DB en minúscula; el chip del panel super_admin lo mostraba crudo
/// ('inventario' en vez de 'Inventario' — audit 2026-06-30). Fallback:
/// capitaliza la primera letra para módulos futuros no listados. La fuente de
/// verdad sigue siendo la RPC `list_modulos` (para las pantallas con `ref`);
/// esto es solo para el chip del `_TenantCard`, un StatelessWidget sin acceso al
/// provider async.
String moduloLabel(String codigo) => switch (codigo) {
      'cobranza' => 'Cobranza',
      'inventario' => 'Inventario',
      'tickets' => 'Tickets',
      _ => codigo.isEmpty
          ? codigo
          : codigo[0].toUpperCase() + codigo.substring(1),
    };
