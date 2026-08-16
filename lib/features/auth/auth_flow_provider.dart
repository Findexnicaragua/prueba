import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tipo de flujo de auth detectado al arrancar la app desde un link de
/// email (recovery / invite).
///
/// El valor se captura en `main.dart` ANTES de `Supabase.initialize`,
/// porque la SDK procesa y limpia el fragmento de la URL durante la
/// inicialización (queda inaccesible después).
///
/// Posibles valores:
///   - 'recovery'  → el user clickeó "olvidé mi contraseña"
///   - 'invite'    → primer login después de ser invitado
///   - 'signup'    → confirmación de email tras signup público (no usado
///                   en este SaaS B2B)
///   - null        → arranque normal (sin link de email)
///
/// El router lo lee en su redirect para mandar al user a `/set-password`
/// cuando aplica. La pantalla SetPasswordScreen lo setea a null tras
/// guardar la nueva contraseña con éxito, así no queda en redirect loop.
final initialAuthFlowProvider = StateProvider<String?>((ref) => null);

/// Mensaje de error de auth capturado desde la URL al arrancar la app
/// (ej. `?error=access_denied&error_code=otp_expired&error_description=...`).
///
/// Lo setea main.dart en el override inicial. La pantalla de login lo
/// muestra como banner y lo limpia (state = null) cuando el user
/// interactúa, así no queda persistente entre intentos.
final initialAuthErrorProvider = StateProvider<String?>((ref) => null);
