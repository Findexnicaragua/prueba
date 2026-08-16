import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

/// Dialog que muestra email + contraseña generadas server-side, con UX
/// "copiar primero, salir después". La contraseña sólo se ve una vez —
/// no queda guardada en la app, así que si el caller cierra sin
/// copiar, se pierde.
///
/// Devuelve true via Navigator.pop si el usuario copió la contraseña,
/// false en otro caso. El caller usa eso para decidir navegación
/// (ej: ir al detalle del tenant nuevo) vs quedarse en la lista.
///
/// Usos:
/// - Post-creación de tenant (super_admin → "Crear ISP" sin email).
/// - Post-reenvío de invitación en modo no-email.
/// Ambos comparten layout y semántica; varía sólo la copia
/// introductoria.
class CredencialesDialog extends StatefulWidget {
  const CredencialesDialog({
    super.key,
    required this.email,
    required this.password,
    required this.intro,
    this.title = 'Credenciales del usuario',
  });

  final String email;
  final String password;

  /// Texto que va arriba del bloque de credenciales explicando el
  /// contexto. Variará entre "ISP creado..." y "Invitación
  /// regenerada..." según el caller.
  final String intro;

  /// Título del dialog. Default genérico, pero el caller debería
  /// personalizar con el nombre del target (ej: 'Credenciales de
  /// Marcos Pineda') para que screen readers lo anuncien al abrir y
  /// que escaneando visualmente quede claro de quién son.
  final String title;

  @override
  State<CredencialesDialog> createState() => _CredencialesDialogState();
}

class _CredencialesDialogState extends State<CredencialesDialog> {
  bool _copiadoPassword = false;
  bool _copiadoEmail = false;
  String? _copyError;

  Future<void> _copiarPassword() async {
    // En web con clipboard bloqueado (iframe, permiso denegado, etc.)
    // Clipboard.setData lanza PlatformException. Capturamos y mostramos
    // el error en vez de mentir diciendo "Copiado" con portapapeles
    // vacío — el user puede copiar a mano del SelectableText.
    try {
      await Clipboard.setData(ClipboardData(text: widget.password));
      if (!mounted) return;
      setState(() {
        _copiadoPassword = true;
        _copyError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _copyError = 'No pude copiar al portapapeles: '
            'seleccioná la contraseña y copiala a mano (Ctrl+C).';
      });
    }
  }

  Future<void> _copiarEmail() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.email));
      if (!mounted) return;
      setState(() => _copiadoEmail = true);
    } catch (_) {
      // El email no es secreto — si falla, no rompemos UX. Si la
      // password también falló, ya hay un banner avisando.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 480.0;
    return AlertDialog(
      icon: Icon(Icons.check_circle, color: scheme.primary, size: 40),
      title: Text(widget.title),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.intro),
            const SizedBox(height: 16),
            // Email primero — username, recuperable de la conversación
            // original si se pierde. La contraseña va abajo, junto al
            // warning específico que la cubre.
            Text(
              'Email',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            _CredencialRow(
              valor: widget.email,
              copiado: _copiadoEmail,
              onCopiar: _copiarEmail,
              semanticLabel: 'Copiar email',
            ),
            const SizedBox(height: 12),
            // Warning específico para la contraseña: la posicionamos
            // INMEDIATAMENTE arriba del bloque de la contraseña, no
            // como header del dialog — sino se lee primero, se
            // olvida, y se vuelve a la copia sin contexto.
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined,
                      color: scheme.onErrorContainer, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'La contraseña sólo se muestra una vez. Si la '
                      'perdés, abrí el ISP y usá "Forzar contraseña" '
                      'en la fila del usuario para generar otra. Si '
                      'vas a probar el login en este browser, hacelo '
                      'en una ventana de incógnito — sino vas a '
                      'cerrar tu sesión de Dev.',
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Contraseña',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            _CredencialRow(
              valor: widget.password,
              copiado: _copiadoPassword,
              onCopiar: _copiarPassword,
              semanticLabel: 'Copiar contraseña',
            ),
            if (_copyError != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  _copyError!,
                  style: TextStyle(
                    color: scheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      // Una vez copiada la contraseña, el flow está completo: el
      // FilledButton primario pasa a ser "Listo" (acción de salir),
      // y el copy duplicado pasa a TextButton secundario (acción de
      // re-copiar). Antes había 2 botones compitiendo por la atención
      // del super_admin tras copiar.
      actions: _copiadoPassword
          ? [
              TextButton.icon(
                icon: const Icon(Icons.content_copy, size: 18),
                label: const Text('Copiar otra vez'),
                onPressed: _copiarPassword,
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Listo'),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cerrar sin copiar'),
              ),
              Semantics(
                button: true,
                hint: 'Copia la contraseña al portapapeles',
                child: FilledButton.icon(
                  icon: const Icon(Icons.content_copy),
                  label: const Text('Copiar contraseña'),
                  onPressed: _copiarPassword,
                ),
              ),
            ],
    );
  }
}

/// Bloque "monospace + botón copiar" para mostrar una credencial
/// individual (email o password). El semanticLabel distingue ambos
/// roles para screen readers (sino TalkBack lee "Copiar" suelto sin
/// contexto).
class _CredencialRow extends StatelessWidget {
  const _CredencialRow({
    required this.valor,
    required this.copiado,
    required this.onCopiar,
    required this.semanticLabel,
  });

  final String valor;
  final bool copiado;
  final VoidCallback onCopiar;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      // Top alignment: para emails largos (50+ chars) que wrappean en
      // 2 líneas, el ícono queda anclado al inicio en vez de
      // centrado a la mitad del bloque.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              valor,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: copiado ? 'Copiado' : semanticLabel,
            icon: Icon(
              copiado ? Icons.check : Icons.content_copy,
              size: 18,
            ),
            onPressed: onCopiar,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
