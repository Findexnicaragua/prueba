import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/utils/validators.dart';

/// Campo de texto para números de teléfono que centraliza el patrón
/// `inputFormatters` + `sanitizePhone` que originalmente vivía duplicado
/// en `cliente_form_screen.dart` (PR #11) y se extendió a los 5 forms
/// con teléfono del repo.
///
/// **Por qué existe**:
/// - El validator solo contaba dígitos; sin `inputFormatters` el user
///   podía guardar `"abc12345678"` en BD. Los consumers (`tel:`, `wa.me`)
///   sanitizaban en el momento pero la UI re-mostraba el valor sucio.
/// - El regex `[0-9+\s\-]` permite formato visual mientras el user tipea
///   (`+505 8888-8888`) y `sanitizePhone` lo normaliza a `[0-9+]` al
///   persistir.
///
/// **Patrón de uso**:
///
/// ```dart
/// // En el form:
/// PhoneTextField(controller: _telefono)  // o required: true
///
/// // Al guardar:
/// final telefono = PhoneTextField.sanitized(_telefono);
/// // → '+50588888888' si el user tipeó '+505 8888-8888'
/// // → null si el campo quedó vacío o solo con '+' sin dígitos
/// ```
///
/// Internamente usa `TextFormField` para soportar `validator` cuando el
/// caller envuelve en un `Form`. Si no hay Form, los `inputFormatters`
/// + `sanitized()` al guardar siguen siendo la defensa.
class PhoneTextField extends StatelessWidget {
  const PhoneTextField({
    super.key,
    required this.controller,
    this.label = 'Teléfono',
    this.hint = '+505 8888-8888',
    this.enabled = true,
    this.required = false,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;

  /// Si true, el validator rechaza vacío con "$label requerido" y agrega
  /// `*` al label. Si false (default), el campo es opcional.
  final bool required;
  final bool autofocus;

  /// Retorna el valor del controller normalizado a `[0-9+]`, o null si
  /// queda vacío después del strip (caso `""`, solo whitespace, o solo
  /// `+` sin dígitos). Llamar al persistir, NO al validar.
  ///
  /// Defensa en profundidad: aunque el `inputFormatters` del field
  /// rechaza letras en el input del user, NO aplica a texto seteado
  /// programáticamente (ej. `controller.text = legacy_value`). Esta
  /// función sanitiza siempre antes de persistir.
  static String? sanitized(TextEditingController controller) {
    final t = sanitizePhone(controller.text);
    // Si sólo quedan `+` sin dígitos (caso "+", "+++", "  +  "),
    // tratar como vacío. tel:+ y wa.me/+ son inutilizables.
    if (sanitizePhoneForWhatsApp(t).isEmpty) return null;
    return t;
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      keyboardType: TextInputType.phone,
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        hintText: hint,
      ),
      // Bloquea letras en el input. Permite dígitos, `+`, espacios y
      // guiones para que el user pueda tipear el formato del hint
      // (`+505 8888-8888`) — al guardar `sanitized()` lo normaliza.
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s\-]')),
      ],
      validator: (v) {
        final digits = sanitizePhoneForWhatsApp(v ?? '');
        if (digits.isEmpty) {
          return required ? '$label requerido' : null;
        }
        if (digits.length < 8) return 'Mínimo 8 dígitos';
        return null;
      },
    );
  }
}
