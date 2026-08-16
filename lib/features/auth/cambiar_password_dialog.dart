import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/utils/validators.dart';

/// Dialog de cambio de contraseña self-service.
///
/// Disponible en /perfil (cobrador) y en el shell admin. Pide contraseña
/// actual + nueva + confirmación. Verifica la actual con un
/// signInWithPassword (refresca la sesión si matchea, sin desloguear).
/// Después llama a auth.updateUser para setear la nueva.
///
/// Para v1 el largo mínimo es 8 chars (mismo criterio que
/// ForzarPasswordDialog del panel super_admin); más adelante podemos
/// agregar checks de complejidad (mix de mayúsculas/dígitos/etc.).
class CambiarPasswordDialog extends StatefulWidget {
  const CambiarPasswordDialog({super.key});

  @override
  State<CambiarPasswordDialog> createState() => _CambiarPasswordDialogState();
}

class _CambiarPasswordDialogState extends State<CambiarPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _actualCtrl = TextEditingController();
  final _nuevaCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  // Cada field tiene su propio toggle de visibilidad. Compartir nueva
  // + confirmar invalida el sentido del campo confirmar (el user no
  // puede revelar uno sin revelar el otro).
  bool _mostrarActual = false;
  bool _mostrarNueva = false;
  bool _mostrarConfirm = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _actualCtrl.dispose();
    _nuevaCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _cambiar() async {
    if (!_formKey.currentState!.validate()) return;
    final email = Supabase.instance.client.auth.currentUser?.email;
    if (email == null) {
      setState(() => _error = 'Sesión inválida — volvé a loguearte');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Side effect conocido: signInWithPassword dispara
    // AuthChangeEvent.signedIn aunque sea el mismo user — el listener
    // del router invalida providers y refresca el route. Para el dialog
    // es transparente (PopScope nos protege de un pop accidental), pero
    // si en el futuro se loguea algún hook adicional a signedIn habría
    // que considerarlo.
    bool actualVerificada = false;
    try {
      // .timeout(20s) en ambas: sin esto una red colgada deja _busy=true y el
      // spinner infinito (mismo bug que el login — audit 2026-07-04). El
      // TimeoutException cae en el catch genérico de abajo (baja _busy).
      await Supabase.instance.client.auth
          .signInWithPassword(
            email: email,
            password: _actualCtrl.text,
          )
          .timeout(const Duration(seconds: 20));
      actualVerificada = true;
      await Supabase.instance.client.auth
          .updateUser(
            UserAttributes(password: _nuevaCtrl.text),
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (!mounted) return;
      final msg = e.message.toLowerCase();
      setState(() {
        _busy = false;
        // Mensaje específico cuando la actual no matchea — sino el
        // usuario ve "Invalid login credentials" en inglés y se
        // confunde pensando que el email está mal.
        if (!actualVerificada &&
            (msg.contains('invalid login') ||
                msg.contains('invalid credentials'))) {
          _error = 'La contraseña actual no es correcta.';
        } else if (msg.contains('rate limit') ||
            msg.contains('too many')) {
          _error = 'Demasiados intentos — esperá un minuto y reintentá.';
        } else if (actualVerificada) {
          // signInWithPassword OK, falló updateUser. La sesión ya rotó
          // pero la password vieja sigue activa — el user puede
          // reintentar el dialog sin problema. C7: sin e.message crudo
          // (inglés de Supabase); el caso típico es repetir la vieja.
          _error = (msg.contains('same password') ||
                  msg.contains('different from the old'))
              ? 'La nueva contraseña debe ser distinta a la anterior.'
              : 'No se pudo actualizar la contraseña. Tu contraseña sigue '
                  'siendo la actual, reintentá.';
        } else {
          // C7: resto de AuthExceptions del signIn — genérico en español.
          _error = 'No se pudo actualizar la contraseña. Reintentá.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Evitamos e.toString() — puede incluir stack traces o data
        // sensible. Para errores de red el mensaje genérico es más
        // honesto que mostrar internals.
        _error = actualVerificada
            ? 'No pude actualizar la contraseña. Tu contraseña sigue '
                'siendo la actual, reintentá.'
            : 'Ocurrió un error verificando. Intentá de nuevo.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        icon: Icon(Icons.lock_outline, color: scheme.primary, size: 32),
        title: const Text('Cambiar contraseña'),
        content: SizedBox(
          width: dialogW,
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Vas a actualizar tu contraseña de acceso a la app.',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _actualCtrl,
                    enabled: !_busy,
                    autofocus: true,
                    obscureText: !_mostrarActual,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.password],
                    // Supabase usa bcrypt (cap 72 bytes); pasar más
                    // chars al server haría truncate silencioso —
                    // mejor bloquear acá con un mensaje claro.
                    maxLength: 72,
                    decoration: InputDecoration(
                      labelText: 'Contraseña actual',
                      // Sin counter — 72 es un techo técnico, no algo
                      // que el user deba ver mientras tipea.
                      counterText: '',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _mostrarActual ? 'Ocultar' : 'Mostrar',
                        icon: Icon(_mostrarActual
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _mostrarActual = !_mostrarActual),
                      ),
                    ),
                    validator: (v) =>
                        Validators.requiredField(v, label: 'Contraseña'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _nuevaCtrl,
                    enabled: !_busy,
                    obscureText: !_mostrarNueva,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.newPassword],
                    maxLength: 72,
                    decoration: InputDecoration(
                      labelText: 'Nueva contraseña',
                      helperText: 'Mínimo 8 caracteres',
                      counterText: '',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _mostrarNueva ? 'Ocultar' : 'Mostrar',
                        icon: Icon(_mostrarNueva
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _mostrarNueva = !_mostrarNueva),
                      ),
                    ),
                    validator: (v) {
                      final reqErr = Validators.requiredField(v,
                          label: 'Contraseña');
                      if (reqErr != null) return reqErr;
                      final minErr = Validators.minLength(v, 8);
                      if (minErr != null) return minErr;
                      if ((v ?? '') == _actualCtrl.text) {
                        return 'La nueva tiene que ser distinta de la actual';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirmCtrl,
                    enabled: !_busy,
                    obscureText: !_mostrarConfirm,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.newPassword],
                    maxLength: 72,
                    decoration: InputDecoration(
                      labelText: 'Confirmar nueva contraseña',
                      counterText: '',
                      border: const OutlineInputBorder(),
                      // Toggle propio para que el user pueda verificar
                      // visualmente que la confirm matchea la nueva
                      // sin tener que revelar ambas.
                      suffixIcon: IconButton(
                        tooltip:
                            _mostrarConfirm ? 'Ocultar' : 'Mostrar',
                        icon: Icon(_mostrarConfirm
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _mostrarConfirm = !_mostrarConfirm),
                      ),
                    ),
                    validator: (v) {
                      final reqErr = Validators.requiredField(v,
                          label: 'Contraseña');
                      if (reqErr != null) return reqErr;
                      if (v != _nuevaCtrl.text) return 'No coincide';
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      container: true,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline,
                                color: scheme.onErrorContainer, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: scheme.onErrorContainer,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed:
                _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          // Semantics.hint para que el screen reader anuncie el flow
          // de dos pasos (verifica actual + guarda nueva). Icono
          // lock_reset alinea visualmente con ForzarPasswordDialog
          // del panel super_admin (mismo concepto de "rotar password").
          // Label corto "Guardar" para no duplicar el título arriba.
          Semantics(
            button: true,
            enabled: !_busy,
            hint: 'Verifica la contraseña actual y guarda la nueva',
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_reset),
              label: Text(_busy ? 'Guardando…' : 'Guardar'),
              onPressed: _busy ? null : _cambiar,
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper para mostrar el dialog desde cualquier callsite con el snackbar
/// de éxito + manejo de errores ya cableado. Devuelve true si la
/// contraseña se cambió.
Future<bool> mostrarCambiarPasswordDialog(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const CambiarPasswordDialog(),
  );
  if (ok == true) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Contraseña actualizada'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 3),
      ),
    );
    return true;
  }
  return false;
}
