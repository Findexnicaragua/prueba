import 'package:flutter/material.dart';

/// Selector de modo de contraseña para las altas de usuario (invitar
/// cobrador / invitar admin / crear tenant), path no-email.
///
/// Ofrece 2 modos:
///   - "Generar" (default): el server genera una password aleatoria y la
///     devuelve para mostrar en [CredencialesDialog].
///   - "Escribir yo": el admin tipea la password (con confirmación). En
///     este modo el server NO eco-devuelve la password — el caller usa la
///     tipeada local para mostrar las credenciales.
///
/// Comunica al padre vía [onChanged]:
///   - `null` cuando el modo es Generar, O cuando es Manual pero la
///     password todavía es inválida/incompleta (no coincide o < 8). El
///     padre debe deshabilitar el botón de submit si el modo es manual y
///     el callback dio `null`.
///   - la String tipeada cuando el modo es Manual y la password es válida.
///
/// El padre puede saber si el form de password bloquea el submit mirando
/// el último valor de [onChanged] contra el modo: en la práctica basta con
/// guardar `String? _passwordManual` en el State del padre y, si el modo
/// es manual, exigir que no sea null para habilitar el botón. Para eso el
/// callback también informa el modo vía [onModeChanged] (opcional).
class PasswordModeSelector extends StatefulWidget {
  const PasswordModeSelector({
    super.key,
    required this.onChanged,
    this.onModeChanged,
    this.enabled = true,
  });

  /// Recibe la password manual VÁLIDA, o `null` (modo generar, o manual
  /// inválida/incompleta).
  final ValueChanged<String?> onChanged;

  /// Opcional: notifica cambios de modo (true = manual, false = generar).
  /// Útil para que el padre sepa si tiene que exigir password no-null
  /// antes de habilitar el submit.
  final ValueChanged<bool>? onModeChanged;

  /// Deshabilita todos los controles (estado busy del dialog padre).
  final bool enabled;

  @override
  State<PasswordModeSelector> createState() => _PasswordModeSelectorState();
}

class _PasswordModeSelectorState extends State<PasswordModeSelector> {
  bool _manual = false;
  final _passwordCtrl = TextEditingController();
  final _repetirCtrl = TextEditingController();
  bool _mostrar = false;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _repetirCtrl.dispose();
    super.dispose();
  }

  /// Devuelve la password válida o null. Válida = modo manual, ambos
  /// campos no vacíos, min 8, y coinciden.
  String? _passwordValida() {
    if (!_manual) return null;
    final pw = _passwordCtrl.text;
    final rep = _repetirCtrl.text;
    if (pw.length < 8) return null;
    if (pw != rep) return null;
    return pw;
  }

  void _emitir() {
    widget.onChanged(_passwordValida());
  }

  void _setManual(bool v) {
    if (_manual == v) return;
    setState(() => _manual = v);
    widget.onModeChanged?.call(v);
    // Al cambiar de modo, re-emitimos: Generar siempre da null; Manual da
    // lo que haya tipeado (probablemente null al inicio).
    _emitir();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pw = _passwordCtrl.text;
    final rep = _repetirCtrl.text;
    // Mensaje de error contextual del campo "Repetir": sólo mostramos
    // "no coinciden" cuando el usuario ya tipeó algo en repetir.
    final noCoinciden = _manual && rep.isNotEmpty && pw != rep;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Contraseña',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment<bool>(
              value: false,
              label: Text('Generar'),
              icon: Icon(Icons.auto_awesome, size: 18),
            ),
            ButtonSegment<bool>(
              value: true,
              label: Text('Escribir yo'),
              icon: Icon(Icons.edit, size: 18),
            ),
          ],
          selected: {_manual},
          onSelectionChanged: widget.enabled
              ? (s) => _setManual(s.first)
              : null,
          showSelectedIcon: false,
        ),
        if (_manual) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _passwordCtrl,
            enabled: widget.enabled,
            obscureText: !_mostrar,
            onChanged: (_) {
              setState(() {});
              _emitir();
            },
            decoration: InputDecoration(
              labelText: 'Contraseña',
              helperText: 'Mínimo 8 caracteres',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: _mostrar ? 'Ocultar' : 'Mostrar',
                icon: Icon(
                    _mostrar ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _mostrar = !_mostrar),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _repetirCtrl,
            enabled: widget.enabled,
            obscureText: !_mostrar,
            onChanged: (_) {
              setState(() {});
              _emitir();
            },
            decoration: InputDecoration(
              labelText: 'Repetir contraseña',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: noCoinciden ? 'No coinciden' : null,
            ),
          ),
        ],
      ],
    );
  }
}
