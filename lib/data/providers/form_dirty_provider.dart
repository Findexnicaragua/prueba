import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Indica si el screen actual tiene un form con cambios sin guardar.
///
/// **Por qué existe**: el PopScope de los forms solo intercepta
/// `Navigator.pop()` (browser back, hardware back, botón Cancelar).
/// NO cubre `context.go(...)` del go_router que es REPLACE de ruta —
/// el sidebar y el back arrow usan eso y bypasseaban el guard del form.
///
/// **Cómo se usa**:
///   1. Los forms (cliente, contrato, etc.) publican su `_dirty` acá.
///      Sync por build (post-frame para no setState durante consumo) o
///      en cada path de mutation del state local.
///   2. El shell del rol (admin/super/cobrador) llama
///      `context.closeModalsAndGoGuarded(ref, path)` desde los items
///      del sidebar. Ese helper lee este provider, muestra el dialog
///      `confirmDiscardChanges` si está dirty, y solo procede si el
///      user confirma.
///   3. El dispose del form resetea acá a `false` por defensa.
///
/// **Por qué un solo bool y no un Set de routes**: go_router muestra
/// un screen activo a la vez. Cuando un form sale, su State es
/// disposed → resetea acá → el próximo screen lee `false`. No hay
/// overlap real entre forms en producción (los pushed via Navigator
/// también disponen el state previo correctamente).
///
/// **Por qué NO es autoDispose**: el shell lo watchea continuamente
/// (cada item del sidebar lo lee al onTap). autoDispose lo reciclaría
/// entre navegaciones y perdería estado en la primera nav post-warm-up.
final formDirtyProvider = StateProvider<bool>((ref) => false);
