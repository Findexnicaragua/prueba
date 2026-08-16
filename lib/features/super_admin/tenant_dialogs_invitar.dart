import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/tenant_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/edge_functions.dart';
import '../../data/utils/validators.dart';
import '../shared/widgets/credenciales_dialog.dart';
import '../shared/widgets/password_mode_selector.dart';
import '../shared/widgets/phone_text_field.dart';

/// Dialog para que el super_admin invite el primer/otro admin de un tenant.
/// Llama a la Edge Function `invitar-cobrador` con tenant_id explícito.
///
/// Dos modos según el switch "Enviar email de invitación":
///   - ON (default): manda email automático con link de set-password.
///   - OFF: el server genera una password aleatoria y la devuelve para
///     que el super_admin la comparta por canal seguro. Misma UX que
///     `_CrearTenantDialog` (modo no-email) y `_ReenviarInvitacionDialog`.
class InvitarAdminDialog extends ConsumerStatefulWidget {
  const InvitarAdminDialog({super.key, required this.tenant});
  final TenantAdmin tenant;

  @override
  ConsumerState<InvitarAdminDialog> createState() =>
      _InvitarAdminDialogState();
}

class _InvitarAdminDialogState extends ConsumerState<InvitarAdminDialog> {
  final _email = TextEditingController();
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  bool _enviando = false;
  final bool _enviarEmail = false;
  String? _error;
  // Modo de contraseña (sólo aplica al path no-email). `_modoManual`
  // refleja el selector; `_passwordManual` es la password tipeada VÁLIDA
  // (null si está incompleta/inválida o si el modo es Generar).
  bool _modoManual = false;
  String? _passwordManual;

  // Bloquea el submit si el modo es manual pero la password todavía no es
  // válida (no coincide o < 8). En modo Generar / email no bloquea.
  bool get _passwordIncompleta =>
      !_enviarEmail && _modoManual && _passwordManual == null;

  @override
  void dispose() {
    _email.dispose();
    _nombre.dispose();
    _telefono.dispose();
    super.dispose();
  }

  Future<void> _invitar() async {
    final email = _email.text.trim();
    final nombre = _nombre.text.trim();
    if (email.isEmpty || nombre.isEmpty) {
      setState(() => _error = 'Email y nombre requeridos');
      return;
    }
    final emailErr = Validators.email(email);
    if (emailErr != null) {
      setState(() => _error = emailErr);
      return;
    }

    // Capturamos refs al Navigator y ScaffoldMessenger ANTES del await
    // para no usar el context del State (que puede estar desmontado
    // tras el primer pop, especialmente si hay browser back rápido).
    // Patrón estándar Flutter: el lint use_build_context_synchronously
    // flaggea el caso original.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final rootContext = Navigator.of(context, rootNavigator: true).context;

    setState(() {
      _enviando = true;
      _error = null;
    });

    try {
      final data = await invokeEdgeFunction(
        Supabase.instance.client,
        'invitar-cobrador',
        body: {
          'email': email,
          'nombre': nombre,
          'rol': 'admin',
          'tenant_id': widget.tenant.id,
          if (PhoneTextField.sanitized(_telefono) != null)
            'telefono': PhoneTextField.sanitized(_telefono),
          // Password manual (sólo path no-email): si el super_admin la
          // tipeó, la mandamos. El server la usa en vez de generar una y
          // NO la eco-devuelve (la conocemos local).
          if (!_enviarEmail && _modoManual && _passwordManual != null)
            'password': _passwordManual,
          // Explícito para que el server no asuma default si en el
          // futuro cambia (mismo patrón que crear-tenant).
          'enviar_email': _enviarEmail,
          // ?flow=invite: cuando el invitado clickea el link del email,
          // el app lo route a /set-password en vez del dashboard sin
          // password. Sólo aplica al path email. Ver _extractAuthFlow
          // en main.dart.
          if (kIsWeb && _enviarEmail)
            'redirect_to': '${Uri.base.origin}/?flow=invite',
        },
      );

      // Refrescar lista de tenants (cobradores_count) y lista de miembros
      // para que aparezca el nuevo invitado.
      ref.invalidate(tenantsAdminProvider);
      ref.invalidate(cobradoresTenantProvider(widget.tenant.id));

      // Si fue manual, la response trae `nueva_password: null` — usamos la
      // password TIPEADA local. Si fue Generar, usamos la de la response.
      final passwordManualEnviada =
          (!_enviarEmail && _modoManual) ? _passwordManual : null;
      final nuevaPassword =
          passwordManualEnviada ?? (data['nueva_password'] as String?);
      if (nuevaPassword != null && nuevaPassword.isNotEmpty) {
        // Path no-email: cerramos este dialog y abrimos el de
        // credenciales — el super_admin tiene UNA oportunidad de copiar
        // la password antes de que se pierda. Si cierra sin copiar
        // tiene que ir a "Forzar contraseña" en la fila del miembro.
        navigator.pop();
        await showDialog<bool>(
          // `rootContext` se captura ANTES de cualquier await y es el del Navigator
          // raiz: no se desmonta al popear este dialogo.
          // ignore: use_build_context_synchronously
          context: rootContext,
          barrierDismissible: false,
          builder: (_) => CredencialesDialog(
            title: 'Credenciales de $nombre',
            email: email,
            password: nuevaPassword,
            intro:
                'Admin creado en ${widget.tenant.nombre}. Pasale email + '
                'contraseña por canal seguro — esta es la única vez que '
                'la contraseña queda visible.',
          ),
        );
      } else {
        // Path email: snackbar tradicional + pop.
        navigator.pop();
        messenger.showSnackBar(SnackBar(
          content: Text('Invitación enviada a $email'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      // Helper invokeEdgeFunction lanza Exception(msg); pelamos el
      // prefijo "Exception: " — alineado con los hermanos de este
      // archivo y la convención del codebase. Si por algún motivo el
      // helper no procesó y llega un FunctionException raw, extraemos
      // el campo `error` del toString para no exponer el wrapper.
      if (mounted) {
        setState(() {
          _error = humanizarEdgeError(e);
          _enviando = false;
        });
      }
    } finally {
      // Defensive: si el happy path tira algo entre pop y showDialog
      // (browser back race), el _enviando queda colgado en "Procesando…"
      // sin recuperación. Lo reseteamos siempre que el State siga
      // mounted.
      if (mounted && _enviando) {
        setState(() => _enviando = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Width responsive (mismo patrón que _CrearTenantDialog): 400 en
    // desktop, 90% del viewport en mobile chico para evitar overflow
    // del subtitle del switch.
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;
    return AlertDialog(
      // scrollable: el form + campos de contraseña no entraban en pantalla
      // corta y desbordaban sobre los botones.
      scrollable: true,
      title: Text('Invitar admin a ${widget.tenant.nombre}'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Switch arriba — es el selector de modo del flow, todo lo
            // de abajo (body, warning, botones) depende de él. Sin esto
            // el user leía la explicación antes de saber qué modo
            // estaba eligiendo. Mismo patrón que _CrearTenantDialog y
            // _ReenviarInvitacionDialog.
            // SwitchListTile(
            //   value: _enviarEmail,
            //   onChanged: _enviando
            //       ? null
            //       : (v) => setState(() => _enviarEmail = v),
            //   title: const Text('Enviar email de invitación'),
            //   subtitle: Text(
            //     _enviarEmail
            //         ? 'El usuario recibe el link en su correo.'
            //         : 'No se envía email. Te generamos una contraseña '
            //             'para compartir manualmente.',
            //     style: const TextStyle(fontSize: 11),
            //   ),
            //   contentPadding: EdgeInsets.zero,
            //   dense: true,
            //   visualDensity: VisualDensity.compact,
            // ),
            // const SizedBox(height: 8),
            Text(
              _enviarEmail
                  ? 'El invitado recibirá un email para crear su contraseña. '
                      'Una vez logueado, será admin de este tenant.'
                  : 'Se creará el admin con una contraseña aleatoria '
                      '(no se manda email — la vas a copiar y compartir '
                      'vos). Será admin de este tenant.',
              style: TextStyle(color: scheme.outline, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              enabled: !_enviando,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'admin@empresa.com',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nombre,
              enabled: !_enviando,
              decoration: const InputDecoration(
                labelText: 'Nombre completo',
              ),
            ),
            const SizedBox(height: 12),
            PhoneTextField(
              controller: _telefono,
              enabled: !_enviando,
              label: 'Teléfono (opcional)',
            ),
            // Selector de contraseña: sólo en el path no-email (el único
            // donde la app define la password). Con email el invitado la
            // crea él mismo desde el link.
            if (!_enviarEmail) ...[
              const SizedBox(height: 16),
              PasswordModeSelector(
                enabled: !_enviando,
                onModeChanged: (m) => setState(() => _modoManual = m),
                onChanged: (pw) => setState(() => _passwordManual = pw),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!,
                    style: TextStyle(color: scheme.onErrorContainer)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        // Label e icono cambian según modo. Paralelo a
        // _ReenviarInvitacionDialog: ambos describen el artifact
        // resultante, no el canal.
        FilledButton.icon(
          icon: _enviando
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_enviarEmail ? Icons.send : Icons.lock_reset),
          label: Text(_enviando
              ? 'Procesando…'
              : _enviarEmail
                  ? 'Enviar invitación'
                  // Label "Crear admin" en modo manual (no "generar",
                  // que es engañoso si el super_admin tipeó la password).
                  : _modoManual
                      ? 'Crear admin'
                      : 'Generar contraseña'),
          onPressed: (_enviando || _passwordIncompleta) ? null : _invitar,
        ),
      ],
    );
  }
}
