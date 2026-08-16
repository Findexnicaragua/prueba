/// Validators centralizados para `TextFormField.validator` y checks
/// imperativos (R13).
///
/// Patrón: cada `Validators.X(v)` retorna `String?` — `null` si es
/// válido, mensaje en español si no. Compatible directo con la
/// firma esperada por `TextFormField.validator`.
///
/// Convención de "campo vacío": los validators que NO chequean
/// presencia (email, minLength, maxLength) pasan si está vacío —
/// asumen que el caller compone con `requiredField` cuando necesita
/// que el campo sea obligatorio. Esto evita duplicar mensajes ("Email
/// inválido" vs "Email requerido") y deja la decisión de presencia
/// donde corresponde al diseño del form.
class Validators {
  Validators._();

  /// Email básico. No exige presencia — combiná con `requiredField`
  /// si el form lo requiere.
  ///
  /// Regex prohíbe espacios explícitamente. Es la variante más
  /// estricta de las 4 que había sueltas por la UI (algunas usaban
  /// `[^@]+` sin `\s`, lo cual aceptaba "foo bar@x.com" como válido).
  static String? email(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    if (!_emailRegex.hasMatch(t)) return 'Email inválido';
    return null;
  }

  /// Campo no vacío (post-trim). El `label` parametriza el género del
  /// mensaje: "Email requerido", "Contraseña requerida", etc.
  static String? requiredField(String? v, {String label = 'Campo'}) {
    if ((v ?? '').trim().isEmpty) return '$label requerido';
    return null;
  }

  /// Largo mínimo (post-trim). Pasa si está vacío — combiná con
  /// `requiredField` si aplica.
  static String? minLength(String? v, int min) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    if (t.length < min) return 'Mínimo $min caracteres';
    return null;
  }

  /// Largo máximo (post-trim).
  static String? maxLength(String? v, int max) {
    final t = (v ?? '').trim();
    if (t.length > max) return 'Máximo $max caracteres';
    return null;
  }
}

/// Limpia un teléfono dejando dígitos + signo `+`. Apto para `tel:`
/// links (admite prefijo internacional).
String sanitizePhone(String s) {
  return s.replaceAll(_phoneWithPlusStripRegex, '');
}

/// Limpia un teléfono dejando sólo dígitos. Apto para WhatsApp wa.me.
String sanitizePhoneForWhatsApp(String s) {
  return s.replaceAll(_phoneDigitsOnlyStripRegex, '');
}

/// Teléfono en formato INTERNACIONAL para wa.me (Nicaragua = 505). Deja solo
/// dígitos y, si son 8 (número local nica), antepone 505. Si ya trae código de
/// país (≠ 8 dígitos), lo deja como está. wa.me/<n> EXIGE el código de país.
String phoneWhatsappIntl(String s) {
  final d = s.replaceAll(_phoneDigitsOnlyStripRegex, '');
  if (d.length == 8) return '505$d';
  return d;
}

final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _phoneWithPlusStripRegex = RegExp(r'[^0-9+]');
final _phoneDigitsOnlyStripRegex = RegExp(r'[^0-9]');
