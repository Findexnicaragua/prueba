import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/utils/sign_out_helper.dart';
import '../shared/widgets/brand_login_logo.dart';
import 'auth_flow_provider.dart';

/// Pantalla a la que llega el user después de clickear un link de email
/// (recovery / invite). Le pide setear una nueva contraseña.
///
/// Cuando el user clickea un link válido, Supabase auto-crea la sesión
/// y limpia el fragmento de la URL. Acá sólo necesitamos:
///   1. Confirmar identidad mostrando el email del user actual.
///   2. Pedirle una contraseña nueva (con confirmación).
///   3. Llamar a `auth.updateUser(password: ...)` — la sesión actual
///      autoriza el cambio sin necesidad del password viejo.
///   4. Redirigir a `/` para que el router lo lleve al panel correcto
///      según rol.
class SetPasswordScreen extends ConsumerStatefulWidget {
  const SetPasswordScreen({super.key});

  @override
  ConsumerState<SetPasswordScreen> createState() =>
      _SetPasswordScreenState();
}

class _SetPasswordScreenState extends ConsumerState<SetPasswordScreen> {
  final _pwd = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  bool _mostrarPwd = false;
  String? _error;

  @override
  void dispose() {
    _pwd.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _clearError(_) {
    if (_error != null) setState(() => _error = null);
  }

  Future<void> _submit() async {
    final pwd = _pwd.text;
    if (pwd.length < 8) {
      setState(() => _error = 'La contraseña debe tener al menos 8 caracteres');
      return;
    }
    if (pwd != _confirm.text) {
      setState(() => _error = 'Las contraseñas no coinciden');
      return;
    }

    final esInvite = ref.read(initialAuthFlowProvider) == 'invite';

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // .timeout: sin él, una red colgada (TCP abierto sin respuesta,
      // captive-portal) deja el Future sin resolver → _saving nunca baja →
      // spinner infinito y el usuario invitado no puede entrar (mismo bug que
      // login/cambio de password; audit Fase 3 2026-07-05). El TimeoutException
      // cae en el catch genérico que baja _saving.
      await Supabase.instance.client.auth
          .updateUser(UserAttributes(password: pwd))
          .timeout(const Duration(seconds: 20));
      // Limpiamos el flow para que el router no nos mande de vuelta acá.
      ref.read(initialAuthFlowProvider.notifier).state = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          esInvite
              ? 'Contraseña creada. ¡Bienvenido!'
              : 'Contraseña actualizada.',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
      // Redirigimos al root — el router decide /admin, /, etc. según rol.
      context.go('/');
    } on AuthException catch (e) {
      // C7: e.message viene en inglés crudo de Supabase; mapeamos el caso
      // típico (repetir la contraseña vieja) y el resto cae a un genérico
      // accionable en español.
      final msg = e.message.toLowerCase();
      setState(() {
        _error = (msg.contains('same password') ||
                msg.contains('different from the old'))
            ? 'La nueva contraseña debe ser distinta a la anterior.'
            : 'No se pudo actualizar la contraseña. Reintentá.';
        _saving = false;
      });
    } catch (e) {
      // Errores no-Auth (red, plataforma): el toString cae en inglés técnico.
      // El único await del try es updateUser → mensaje genérico accionable en
      // español en vez de filtrar el crudo (audit 2026-06-30).
      setState(() {
        _error =
            'No se pudo actualizar la contraseña. Verificá tu conexión e intentá de nuevo.';
        _saving = false;
      });
    }
  }

  Future<void> _noSoyYo() async {
    // Limpiar impersonación activa (#9) ANTES del signOut: requiere el JWT
    // vivo para autorizar el DELETE server-side. Cubre el caso raro de un
    // super_admin impersonando que cae en este flow (invite/recovery) y se
    // desloguea — evita que la fila quede "pegajosa" al re-loguear.
    await limpiarImpersonacionSiActiva();
    await Supabase.instance.client.auth.signOut();
    // Limpiamos el flow para que el router no nos vuelva a mandar acá.
    ref.read(initialAuthFlowProvider.notifier).state = null;
    if (!mounted) return;
    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final flow = ref.watch(initialAuthFlowProvider);
    final esInvite = flow == 'invite';

    final titulo = esInvite ? '¡Bienvenido!' : 'Restablecer contraseña';
    final subtitulo = esInvite
        ? 'Creá una contraseña para empezar a usar la app.'
        : 'Tu link es válido. Definí una nueva contraseña.';

    final email = Supabase.instance.client.auth.currentUser?.email;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Brand identity igual que login para mantener anclaje
                  // visual del producto (white-label: logo del tenant).
                  const BrandLoginLogo(),
                  const SizedBox(height: 16),
                  Text(
                    titulo,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.outline),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    subtitulo,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 14),
                  ),
                  if (email != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.person_outline,
                              size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              email,
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _saving ? null : _noSoyYo,
                      child: const Text('¿No sos vos? Cerrar sesión'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pwd,
                    autofocus: true,
                    obscureText: !_mostrarPwd,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.next,
                    onChanged: _clearError,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: 'Nueva contraseña',
                      helperText: 'Mínimo 8 caracteres',
                      suffixIcon: IconButton(
                        tooltip: _mostrarPwd ? 'Ocultar' : 'Mostrar',
                        icon: Icon(_mostrarPwd
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () =>
                            setState(() => _mostrarPwd = !_mostrarPwd),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: !_mostrarPwd,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.done,
                    onChanged: _clearError,
                    onSubmitted: (_) => _saving ? null : _submit(),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: 'Confirmá la contraseña',
                      suffixIcon: IconButton(
                        tooltip: _mostrarPwd ? 'Ocultar' : 'Mostrar',
                        icon: Icon(_mostrarPwd
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () =>
                            setState(() => _mostrarPwd = !_mostrarPwd),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      container: true,
                      liveRegion: true,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline,
                                color: scheme.onErrorContainer, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                    color: scheme.onErrorContainer,
                                    fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _saving ? null : _submit,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: Text(
                        _saving ? 'Guardando…' : 'Guardar y continuar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
