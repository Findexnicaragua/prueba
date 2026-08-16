import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/router.dart' show mensajeGateAcceso;
import '../shared/widgets/app_version_label.dart';
import '../shared/widgets/brand_login_logo.dart';
import '../shared/widgets/update_banner.dart';
import 'auth_flow_provider.dart';

/// Pantalla de login.
///
/// Modelo SaaS B2B con onboarding manual: NO permite signup público.
/// El proveedor crea cada tenant + su admin desde Supabase Dashboard.
/// El admin del tenant invita cobradores via la Edge Function
/// `invitar-cobrador` desde el panel admin.
///
/// Sólo dos flujos visibles:
///   - Iniciar sesión
///   - Recuperar contraseña (olvidé mi contraseña)
enum _Modo { login, recuperar }

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  _Modo _modo = _Modo.login;
  bool _busy = false;
  // Toggle de visibilidad del campo Contraseña. Default false (oculto)
  // para no exponer la password a quien mire por arriba del hombro;
  // el icono del eye permite revelar cuando el user pega de clipboard
  // y quiere verificar typos.
  bool _passwordVisible = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    // Si el banner de error viene seteado desde el boot (link expirado,
    // ?error_code=otp_expired, etc.), `liveRegion` no dispara porque
    // está presente en el primer frame — no es una transición. Usamos
    // SemanticsService.announce para forzar la anunciación una vez
    // construido el árbol.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final err = ref.read(initialAuthErrorProvider);
      if (err != null && err.isNotEmpty) {
        SemanticsService.announce(
          _humanizeAuthError(err),
          Directionality.of(context),
        );
      }
      // Gate de revocación de acceso (fix F0): si el gate cerró la sesión por
      // cuenta/tenant desactivados, mostrar el motivo y limpiar el flag.
      final gateMsg = mensajeGateAcceso.value;
      if (gateMsg != null && gateMsg.isNotEmpty) {
        mensajeGateAcceso.value = null;
        // setState post-frame → el banner de error aparece como transición y su
        // liveRegion lo anuncia (no hace falta announce explícito como el de boot).
        setState(() => _error = gateMsg);
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _ejecutar() async {
    // Guards client-side antes de pegarle al backend. Sin esto, un submit
    // con campos vacíos se cuenta contra el rate-limit del IP/email y
    // gasta un round-trip al pedo. Además el error humanizado de
    // "credenciales inválidas" sería técnicamente correcto pero misleading
    // (el problema real es que no completaste el form).
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Ingresá tu email.');
      return;
    }
    if (_modo == _Modo.login && _pass.text.isEmpty) {
      setState(() => _error = 'Ingresá tu contraseña.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      switch (_modo) {
        case _Modo.login:
          // .timeout(20s): sin esto, si la red queda colgada (TCP abierto sin
          // respuesta, captive-portal), el Future no resuelve ni tira → _busy
          // nunca baja → spinner del botón infinito (audit 2026-07-04). El
          // TimeoutException cae en la rama de red de _humanizarLoginError.
          await Supabase.instance.client.auth
              .signInWithPassword(
                email: email,
                password: _pass.text,
              )
              .timeout(const Duration(seconds: 20));
          break;
        case _Modo.recuperar:
          // redirectTo con flow=recovery: necesario porque Supabase no
          // propaga el `type` original en el redirect del flow PKCE.
          // Sin esto, después del exchange caemos en el dashboard sin
          // pasar por /set-password.
          // .timeout(20s): mismo motivo que el login de arriba — sin esto una
          // red colgada deja _busy en true → spinner infinito en 'Enviar link'
          // (el fix del 2026-07-04 no cubrió este path; audit Fase 3).
          await Supabase.instance.client.auth
              .resetPasswordForEmail(
                email,
                redirectTo: kIsWeb
                    ? '${Uri.base.origin}/?flow=recovery'
                    : null,
              )
              .timeout(const Duration(seconds: 20));
          setState(() => _info =
              'Te mandamos un email con el link para recuperar tu contraseña.');
          break;
      }
    } on AuthException catch (e) {
      // Preservamos el Error en la consola del browser para debugging
      // sin exponerlo al user. developer.log queda accesible vía
      // DevTools incluso en release.
      developer.log('Login AuthException', name: 'login', error: e);
      setState(() => _error = _humanizarLoginError(e));
    } catch (e) {
      developer.log('Login error', name: 'login', error: e);
      setState(() => _error = _humanizarLoginError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Traduce excepciones del login/recovery a copy en español. Cubre:
  ///   - Network errors (`ClientException`, `SocketException`,
  ///     `TimeoutException`): el SDK los puede tirar crudos O wrappeados
  ///     en un `AuthException` cuyo `message` incluye "ClientException:
  ///     Failed to fetch, uri=https://...supabase.co/auth/v1/token...".
  ///     Chequeamos PRIMERO para no exponer la URL del backend, sin
  ///     importar el tipo del exception.
  ///   - `AuthException` con mensajes conocidos de Supabase Auth
  ///     (credenciales inválidas, email no confirmado, rate limit,
  ///     rate-limit-por-tiempo del recovery, formato de email, link
  ///     expirado, etc.).
  ///   - Fallback en español (no `e.message` crudo): los mensajes raros
  ///     de Supabase Auth en inglés ya no llegan al UI; el detalle queda
  ///     en `developer.log` para debugging en DevTools.
  String _humanizarLoginError(Object e) {
    // Network check primero. El AuthException de Supabase puede traer
    // "ClientException: Failed to fetch, uri=..." en el `message` cuando
    // el backend no respondió — si entráramos primero a la rama AuthException
    // por type, caeríamos al fallback `return e.message;` y mostraríamos
    // la URL del backend en el banner. Por eso evaluamos los marcadores de
    // red en toString() antes de discriminar por tipo.
    final str = e.toString();
    if (str.contains('ClientException') ||
        str.contains('Failed to fetch') ||
        str.contains('SocketException') ||
        str.contains('TimeoutException') ||
        str.contains('Network is unreachable') ||
        str.contains('XMLHttpRequest')) {
      return 'Sin conexión. Verificá tu red e intentá de nuevo.';
    }
    if (e is AuthException) {
      final m = e.message.toLowerCase();
      if (m.contains('invalid login') || m.contains('invalid credentials')) {
        return 'Credenciales inválidas. Verificá tu email y contraseña.';
      }
      if (m.contains('email not confirmed')) {
        return 'Tu cuenta todavía no confirmó el email. Revisá tu '
            'bandeja de entrada.';
      }
      if (m.contains('rate limit') || m.contains('too many requests')) {
        return 'Demasiados intentos. Esperá un momento y volvé a probar.';
      }
      // Rate limit del flow de recovery: Supabase devuelve "For security
      // purposes, you can only request this after X seconds".
      if (m.contains('for security purposes') ||
          m.contains('only request this after')) {
        return 'Esperá unos segundos antes de pedir otro link.';
      }
      if (m.contains('unable to validate email') ||
          m.contains('invalid format')) {
        return 'El email no tiene un formato válido.';
      }
      if (m.contains('user not found')) {
        return 'No encontramos ese email en el sistema.';
      }
      // Link de recovery expirado / ya usado. Mismo wording que el
      // banner del boot (_humanizeAuthError) — si en el futuro
      // consolidamos los dos helpers en uno (ver backlog CLAUDE.md),
      // este copy queda single-source.
      if (m.contains('invalid or has expired') ||
          m.contains('otp_expired')) {
        return 'El link expiró o ya fue usado. Pedí un nuevo email de '
            'recuperación.';
      }
      // Fallback en español. Antes devolvíamos e.message crudo —
      // re-exponía strings técnicos en inglés del SDK (ej:
      // "Database error querying schema", "Signup not allowed"). El
      // detalle queda en developer.log para debugging.
      return 'No pudimos completar la operación. Probá de nuevo en unos '
          'segundos.';
    }
    return 'No pudimos completar la operación. Probá de nuevo en unos '
        'segundos.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Error capturado desde la URL al boot (link expirado, etc.).
    // Lo mostramos como banner amber arriba del form. Se limpia cuando
    // el user clickea o cuando intenta loguear.
    final authError = ref.watch(initialAuthErrorProvider);
    return Scaffold(
      // El banner de update tambien en login: si hay version nueva, se puede
      // descargar antes de loguearse (full-width arriba; se auto-oculta si no hay).
      body: Column(
        children: [
          const UpdateBanner(),
          Expanded(
            child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (authError != null) ...[
                  // liveRegion + container para anuncio en transiciones
                  // (login → login con error). Para el caso boot (banner
                  // presente desde el primer frame) liveRegion no
                  // dispara — eso lo cubre el SemanticsService.announce
                  // de initState.
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
                          Icon(Icons.warning_amber,
                              color: scheme.onErrorContainer, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _humanizeAuthError(authError),
                              style: TextStyle(
                                color: scheme.onErrorContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close,
                                color: scheme.onErrorContainer, size: 18),
                            tooltip: 'Cerrar',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 28, minHeight: 28),
                            onPressed: () => ref
                                .read(initialAuthErrorProvider.notifier)
                                .state = null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                const BrandLoginLogo(),
                const SizedBox(height: 16),
                Text(
                  switch (_modo) {
                    _Modo.login => 'Iniciar sesión',
                    _Modo.recuperar => 'Recuperar contraseña',
                  },
                  style: TextStyle(color: scheme.outline),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: _modo == _Modo.login
                      ? TextInputAction.next
                      : TextInputAction.go,
                  onSubmitted: _modo == _Modo.recuperar
                      ? (_) => _busy ? null : _ejecutar()
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_modo == _Modo.login) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: !_passwordVisible,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _busy ? null : _ejecutar(),
                    decoration: InputDecoration(
                      labelText: 'Contraseña',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_passwordVisible
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        tooltip: _passwordVisible
                            ? 'Ocultar contraseña'
                            : 'Mostrar contraseña',
                        onPressed: () => setState(
                            () => _passwordVisible = !_passwordVisible),
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  // Mismo styling de errorContainer que el banner de
                  // arriba — antes era texto rojo suelto, débil en
                  // contraste no-texto (WCAG 1.4.11). liveRegion +
                  // container aseguran que NVDA/TalkBack anuncien al
                  // aparecer (null → String es una transición).
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
                if (_info != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    container: true,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(_info!, textAlign: TextAlign.center),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _ejecutar,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(switch (_modo) {
                          _Modo.login => 'Iniciar sesión',
                          _Modo.recuperar => 'Enviar link',
                        }),
                ),
                const SizedBox(height: 12),
                if (_modo == _Modo.login)
                  TextButton(
                    onPressed: () => setState(() {
                      _modo = _Modo.recuperar;
                      _error = null;
                      _info = null;
                    }),
                    child: const Text('Olvidé mi contraseña'),
                  )
                else
                  TextButton(
                    onPressed: () => setState(() {
                      _modo = _Modo.login;
                      _error = null;
                      _info = null;
                    }),
                    child: const Text('Volver a iniciar sesión'),
                  ),
                const SizedBox(height: 16),
                const AppVersionLabel(),
              ],
            ),
          ),
        ),
      ),
          ),
          ],
        ),
    );
  }

  /// Convierte códigos de error técnicos de Supabase en mensajes legibles.
  /// Fallback genérico en español (C7: antes devolvía el string técnico
  /// crudo en inglés del SDK).
  String _humanizeAuthError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('otp_expired') ||
        lower.contains('invalid or has expired')) {
      return 'El link expiró o ya fue usado. Pedí un nuevo email de '
          'recuperación abajo.';
    }
    if (lower.contains('access_denied')) {
      return 'Acceso denegado. Probá iniciar sesión normalmente.';
    }
    return 'No se pudo completar la operación. Reintentá o pedí un link '
        'nuevo.';
  }
}
