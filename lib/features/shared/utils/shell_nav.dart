import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/providers/form_dirty_provider.dart';
import '../widgets/confirm_discard_dialog.dart';

/// Helpers de navegación de los shells (`AdminShell`, `AppShell`,
/// `SuperShell`).
///
/// **Problema que resuelve**: `showDialog` imperativo monta un
/// `DialogRoute` (subclase de `PopupRoute`) en el Navigator del
/// `ShellRoute`. Cuando se cambia de ruta dentro del shell vía
/// `context.go(...)`, go_router actualiza la `matchedLocation` y rebuilda
/// el child, **pero NO desmonta los modales abiertos**. El user ve el
/// dialog flotando sobre la nueva pantalla — UX confusa.
///
/// **Cómo lo resuelve** (orden importante):
///   1. Si hay un Drawer abierto, lo cierra. El Drawer del Scaffold NO
///      es una `Route` propia — es un `LocalHistoryEntry` adjunto a la
///      `PageRoute` del shell, así que `popUntil` no lo alcanza. Hay
///      que cerrarlo con `Scaffold.closeDrawer()`.
///   2. Pop los `PopupRoute`s descartables encima del stack (dialogs,
///      bottom sheets con `barrierDismissible: true`, el default).
///      Las `PageRoute`s (incluyendo las pushed con `context.push`) se
///      conservan — pop solo lo que es `PopupRoute`.
///
/// **Respeta `barrierDismissible: false`**: hay dialogs críticos en el
/// repo (`CredencialesDialog` que muestra password generada UNA vez,
/// confirmaciones destructivas como forzar-password / eliminar
/// cobrador) marcados explícitamente como no descartables. Si el helper
/// los popeara, el user podría perder la password con un click
/// accidental al sidebar — peor UX que el bug original. En ese caso, el
/// helper NO navega y muestra un SnackBar pidiéndole al user que cierre
/// el dialog primero explícitamente.
///
/// **Limitación**: `Navigator.of(this)` usa `rootNavigator: false`, el
/// navigator del ShellRoute. No cubre dialogs pushed con
/// `useRootNavigator: true` (ninguno en el repo hoy — verificar antes
/// de meter uno nuevo).
extension ShellNav on BuildContext {
  /// Navega a [path] cerrando primero cualquier dialog/sheet descartable
  /// que esté abierto. Si hay un dialog crítico (barrierDismissible:
  /// false), aborta la navegación y muestra un SnackBar.
  void closeModalsAndGo(String path) {
    if (_tryCloseDismissibleModals(this)) {
      go(path);
    } else {
      _showCloseFirstSnackBar(this);
    }
  }

  /// Ejecuta [action] (típicamente abrir otro dialog) cerrando primero
  /// modales descartables. Si hay uno crítico, aborta y notifica.
  void closeModalsThenRun(VoidCallback action) {
    if (_tryCloseDismissibleModals(this)) {
      action();
    } else {
      _showCloseFirstSnackBar(this);
    }
  }

  /// Variante de `closeModalsAndGo` que respeta el `formDirtyProvider`:
  /// si la pantalla actual tiene un form con cambios sin guardar,
  /// muestra `confirmDiscardChanges` antes de navegar. Si el user
  /// confirma, resetea el provider y procede; si cancela, no navega.
  ///
  /// Necesario porque `context.go(...)` es REPLACE de ruta (no pop)
  /// y NO dispara `PopScope` — el sidebar y back arrow del shell
  /// usan go, así que sin este guard bypassaban el guard del form.
  ///
  /// **Detección de dialog crítico ya abierto**: si el user disparó
  /// `confirmDiscardChanges` vía PopScope (back arrow / browser back)
  /// y antes de confirmar tap un item del sidebar, llegamos acá con
  /// un dialog crítico ya en el stack. Apilar un segundo dialog
  /// idéntico es UX confusa; abortamos con el snackbar estándar.
  ///
  /// Usá esto desde los items del sidebar de cada shell (admin/super/
  /// cobrador) en vez de `closeModalsAndGo` cuando hay forms con
  /// `_dirty` tracking aguas abajo.
  Future<void> closeModalsAndGoGuarded(WidgetRef ref, String path) async {
    if (ref.read(formDirtyProvider)) {
      // Pre-check de modales críticos: si el dialog "¿Descartar?" ya
      // se disparó por otra vía (PopScope), no apilamos otro encima.
      if (!_tryCloseDismissibleModals(this)) {
        _showCloseFirstSnackBar(this);
        return;
      }
      final confirm = await confirmDiscardChanges(this);
      if (confirm != true || !mounted) return;
      // Reset proactivo: el dispose del form también lo haría, pero
      // hacerlo acá garantiza que si la transición tarda (animación
      // de route), el shell no vuelve a leer dirty=true en clicks
      // rápidos siguientes.
      ref.read(formDirtyProvider.notifier).state = false;
    }
    if (mounted) closeModalsAndGo(path);
  }
}

/// Cierra modales descartables. Retorna `true` si el stack quedó limpio
/// (se puede navegar), `false` si encontró un modal crítico
/// (barrierDismissible: false) y se debe abortar.
///
/// **PageRoutes (incluso pushed) se conservan**: usar `r is! PopupRoute`
/// en lugar de `r is PageRoute` evita el bug de "PageRoute pushed encima
/// de la activa queda visible mientras la URL cambia". Solo popeamos
/// PopupRoutes descartables.
///
/// **Drawer cerrado por separado**: el Drawer del Scaffold no es Route,
/// es LocalHistoryEntry. Hay que invocar `closeDrawer()` explícito.
bool _tryCloseDismissibleModals(BuildContext context) {
  // 1. Drawer (no es Route, no lo alcanza popUntil).
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold != null && scaffold.isDrawerOpen) {
    scaffold.closeDrawer();
  }

  // 2. PopupRoutes descartables encima.
  var foundCritical = false;
  Navigator.of(context).popUntil((route) {
    // Cualquier cosa que NO sea PopupRoute (PageRoute, MaterialPageRoute,
    // CupertinoPageRoute, las pushed por context.push, etc.) se conserva.
    if (route is! PopupRoute) return true;
    // PopupRoute crítico → conservar y avisar al caller.
    if (!route.barrierDismissible) {
      foundCritical = true;
      return true;
    }
    // PopupRoute descartable → popear.
    return false;
  });
  return !foundCritical;
}

void _showCloseFirstSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        'Cerrá el diálogo abierto primero. La acción que pediste no '
        'se puede hacer sin descartarlo.',
      ),
      duration: Duration(seconds: 4),
    ),
  );
}
