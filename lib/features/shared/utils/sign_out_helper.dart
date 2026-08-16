import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/services/impersonation_service.dart';
import '../../../powersync/db.dart' as ps;

/// Verifica si hay cambios locales sin sincronizar antes de cerrar sesión.
/// Si hay pendientes, muestra un dialog de confirmación. Si no hay, hace
/// sign-out directo. Cierra modals/drawers abiertos antes de mostrar el dialog.
Future<void> confirmarSignOut(BuildContext context) async {
  // Cerrar drawer/modals primero para tener un context limpio.
  Navigator.of(context).popUntil((route) => route.isFirst);

  final pendientes = await _contarCrudPendientes();

  if (pendientes > 0 && context.mounted) {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.cloud_off, size: 32),
        title: const Text('Cambios sin sincronizar'),
        content: Text(
          'Tenés $pendientes cambio${pendientes > 1 ? 's' : ''} que '
          'todavía no se subieron al servidor.\n\n'
          'Se van a guardar localmente y se sincronizarán '
          'la próxima vez que inicies sesión.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (confirmar != true || !context.mounted) return;
  }

  // Limpiar impersonación activa (#9) antes de cerrar sesión: si el
  // super_admin estaba dentro de un tenant, salimos para no quedar "pegajoso"
  // al re-loguear. Sin reconectar PowerSync (el signOut desconecta igual).
  await limpiarImpersonacionSiActiva();

  await Supabase.instance.client.auth.signOut();
}

/// Si hay una impersonación activa (fila local), sale de ella antes del
/// signOut. Best-effort: no bloquea el cierre de sesión si falla.
///
/// DEBE llamarse SIEMPRE antes de cualquier `auth.signOut()` crudo: la
/// limpieza es un WRITE server-side (DELETE en `super_admin_impersonation`)
/// que requiere el JWT del super_admin, así que tiene que correr mientras la
/// sesión sigue viva. Después del signOut no hay sesión para autorizar el
/// delete y la fila quedaría "pegajosa" (re-login impersonando el tenant
/// viejo). Reusada por sync_gate_screen y set_password_screen además de
/// confirmarSignOut.
Future<void> limpiarImpersonacionSiActiva() async {
  try {
    final rows = await ps.db.getAll(
      'SELECT 1 FROM super_admin_impersonation LIMIT 1',
    );
    if (rows.isEmpty) return;
    await ImpersonationService(Supabase.instance.client).exit(reconnect: false);
  } catch (_) {
    // best-effort: no impedir el signOut si falla la limpieza.
  }
}

Future<int> _contarCrudPendientes() async {
  try {
    final rows = await ps.db.getAll(
      'SELECT COUNT(*) AS total FROM ps_crud',
    );
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  } catch (_) {
    return 0;
  }
}
