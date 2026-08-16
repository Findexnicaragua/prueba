import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/cobrador_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/validators.dart';

/// Caja de advertencia con ícono — usada en varios dialogs del panel.
/// 13px para texto en background coloreado: 12px era apenas legible para
/// algunos usuarios; 13px mantiene compactness pero mejora contraste.
class WarningBox extends StatelessWidget {
  const WarningBox({
    super.key,
    required this.icon,
    required this.color,
    required this.onColor,
    required this.texto,
  });

  final IconData icon;
  final Color color;
  final Color onColor;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: onColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(color: onColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Texto del warning "tiene N clientes asignados que van a quedar
/// huérfanos". Centralizado para que cambiar-rol y desactivar tengan
/// exactamente la misma copy y para resolver la concordancia
/// gramatical (1 cliente VA, N clientes VAN).
String warningClientesHuerfanos(int n) {
  if (n == 1) {
    return 'Tiene 1 cliente asignado que va a quedar sin cobrador. '
        'Reasignalo primero desde Clientes '
        '(seleccionalo → cambiar cobrador).';
  }
  return 'Tiene $n clientes asignados que van a quedar sin cobrador. '
      'Reasignalos primero desde Clientes '
      '(seleccionalos → cambiar cobrador).';
}

/// Dialog de confirmación + ejecución del reenvío de invitación. El
/// switch elige modo (email vs no-email) y se renderea ARRIBA del
/// body para que sea el anchor de la decisión — el resto del contenido
/// (texto explicativo, warning, copy del botón) varía según el modo.
///
/// El dialog corre el network call internamente (mismo patrón que
/// _CrearTenantDialog) — evita el flash entre "confirm pop" y "open
/// credenciales dialog" que se veía cuando dos modales se intercambian
/// con un await en el medio. En éxito devuelve el record completo;
/// el caller decide qué hacer con `nuevaPassword`.
class ReenviarInvitacionDialog extends ConsumerStatefulWidget {
  const ReenviarInvitacionDialog({
    super.key,
    required this.cobrador,
    required this.dialogW,
  });

  final CobradorAdmin cobrador;
  final double dialogW;

  @override
  ConsumerState<ReenviarInvitacionDialog> createState() =>
      _ReenviarInvitacionDialogState();
}

class _ReenviarInvitacionDialogState
    extends ConsumerState<ReenviarInvitacionDialog> {
  final bool _enviarEmail = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(superAdminRepoProvider);
      final r = await repo.reenviarInvitacion(
        cobradorId: widget.cobrador.id,
        redirectTo: kIsWeb ? '${Uri.base.origin}/?flow=invite' : null,
        enviarEmail: _enviarEmail,
      );
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final email = widget.cobrador.email ?? '(sin email)';
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text('¿Reenviar invitación a ${widget.cobrador.nombre}?'),
        content: SizedBox(
          width: widget.dialogW,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Switch arriba — es el selector de modo del flow, todo
              // lo de abajo (body, warning, botones) depende de él.
              // Sin esto el user leía la explicación antes de saber
              // qué modo estaba eligiendo.
              // SwitchListTile(
              //   value: _enviarEmail,
              //   onChanged: _busy
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
                    ? 'Se le enviará un nuevo email de invitación a $email.'
                    : 'Se generará una contraseña nueva para $email '
                        '(no se manda email — la vas a copiar y '
                        'compartir vos).',
              ),
              const SizedBox(height: 12),
              WarningBox(
                icon: Icons.warning_amber,
                color: s.errorContainer,
                onColor: s.onErrorContainer,
                // Mode-aware: el "qué deja de funcionar" cambia entre
                // invitaciones (link) y contraseñas (string). Antes
                // era "link / contraseña" con slash — ambiguo.
                texto: _enviarEmail
                    ? 'Cualquier invitación anterior deja de '
                        'funcionar. Avisale al usuario que use sólo '
                        'el último email.'
                    : 'Cualquier contraseña anterior deja de '
                        'funcionar. Compartile sólo la nueva.',
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
                      color: s.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline,
                            color: s.onErrorContainer, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: s.onErrorContainer,
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
        actions: [
          TextButton(
            autofocus: true,
            onPressed:
                _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          // Labels paralelos: ambos describen el artifact resultante
          // ("invitación" en email-mode, "nueva contraseña" en
          // no-email-mode), no el canal. Sin esto teníamos
          // "Reenviar email" (canal) vs "Generar contraseña"
          // (artifact) — verbos descalibrados.
          Semantics(
            button: true,
            enabled: !_busy,
            hint: _enviarEmail
                ? 'Manda un nuevo email de invitación al usuario'
                : 'Genera una contraseña nueva para que la copies',
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_enviarEmail ? Icons.send : Icons.lock_reset),
              label: Text(_busy
                  ? 'Procesando…'
                  : _enviarEmail
                      ? 'Reenviar invitación'
                      : 'Generar nueva contraseña'),
              onPressed: _busy ? null : _submit,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pide / genera una nueva contraseña para un miembro y la devuelve al
/// caller cerrando el dialog con Navigator.pop(password). Si el caller
/// recibe null o "", interpreta cancelación.
class ForzarPasswordDialog extends StatefulWidget {
  const ForzarPasswordDialog({super.key, required this.nombre});

  final String nombre;

  @override
  State<ForzarPasswordDialog> createState() => _ForzarPasswordDialogState();
}

class _ForzarPasswordDialogState extends State<ForzarPasswordDialog> {
  final _ctrl = TextEditingController();
  bool _mostrar = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _generar() {
    // Random.secure() usa una fuente criptográficamente segura del SO.
    // Excluye caracteres ambiguos para dictar (I, l, 1, O, 0) y limita
    // símbolos a los que no se confunden con markdown / espacios.
    const chars =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%*-+';
    final rand = Random.secure();
    final nueva =
        List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
    setState(() {
      _ctrl.text = nueva;
      _mostrar = true;
      _error = null;
    });
  }

  void _submit() {
    final v = _ctrl.text;
    final err = Validators.minLength(v, 8);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Responsive width: 420 en desktop/tablet, 90% del viewport en mobile
    // chico (iPhone SE = 375, no entra el 420 fijo).
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;
    return AlertDialog(
      title: Text('¿Forzar nueva contraseña para ${widget.nombre}?'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber,
                      color: scheme.onErrorContainer, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Vas a ver la contraseña una sola vez al terminar. '
                      'El usuario NO recibe notificación — pasásela por '
                      'canal seguro (Whatsapp, en persona).',
                      style: TextStyle(
                          color: scheme.onErrorContainer, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              obscureText: !_mostrar,
              onChanged: (_) {
                // Clear stale error tan pronto el usuario corrige.
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                labelText: 'Nueva contraseña',
                hintText: 'Mínimo 8 caracteres',
                suffixIcon: IconButton(
                  tooltip: _mostrar ? 'Ocultar' : 'Mostrar',
                  icon: Icon(
                      _mostrar ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _mostrar = !_mostrar),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Generar segura'),
                onPressed: _generar,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.lock_reset),
          label: const Text('Aplicar'),
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// Tras forzar la password con éxito, mostramos esto para que el super_admin
/// pueda copiar al portapapeles y comunicar al usuario por canal seguro.
/// Copiar es la acción primaria; cerrar pierde la password permanentemente.
class PasswordCopiarDialog extends StatefulWidget {
  const PasswordCopiarDialog({
    super.key,
    required this.nombre,
    required this.password,
  });

  final String nombre;
  final String password;

  @override
  State<PasswordCopiarDialog> createState() => _PasswordCopiarDialogState();
}

class _PasswordCopiarDialogState extends State<PasswordCopiarDialog> {
  bool _copiado = false;

  Future<void> _copiar() async {
    await Clipboard.setData(ClipboardData(text: widget.password));
    if (!mounted) return;
    setState(() => _copiado = true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;
    return AlertDialog(
      icon: Icon(Icons.check_circle, color: scheme.primary, size: 40),
      title: Text('Contraseña aplicada para ${widget.nombre}'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Esta es la única oportunidad de copiarla. Al cerrar el '
              'diálogo no vas a poder verla otra vez. Pasásela al usuario '
              'por un canal seguro.',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                widget.password,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
      // Copiar es la acción PRIMARIA — visualmente más prominente. Listo
      // sólo cierra y la password se pierde.
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_copiado ? 'Listo' : 'Cerrar sin copiar'),
        ),
        FilledButton.icon(
          icon: Icon(_copiado ? Icons.check : Icons.content_copy),
          label: Text(_copiado ? 'Copiada' : 'Copiar contraseña'),
          onPressed: _copiar,
        ),
      ],
    );
  }
}

/// Dialog para elegir un nuevo rol para un miembro del tenant. Devuelve
/// el rol seleccionado vía Navigator.pop(String) o null si se canceló /
/// no cambió la selección.
class CambiarRolDialog extends StatefulWidget {
  const CambiarRolDialog({
    super.key,
    required this.nombre,
    required this.rolActual,
    required this.prefijoActual,
    required this.clientesAsignados,
    required this.esUltimoAdmin,
  });

  final String nombre;
  final String rolActual;
  final String? prefijoActual;
  final int clientesAsignados;
  final bool esUltimoAdmin;

  @override
  State<CambiarRolDialog> createState() => _CambiarRolDialogState();
}

class _CambiarRolDialogState extends State<CambiarRolDialog> {
  late String _seleccionado;

  @override
  void initState() {
    super.initState();
    _seleccionado = widget.rolActual;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;

    // Warnings que dependen del cambio elegido.
    final perderaAdmin =
        widget.rolActual == 'admin' && _seleccionado != 'admin';
    final dejaraDeSerCobrador =
        widget.rolActual == 'cobrador' && _seleccionado != 'cobrador';
    final dejaraClientesHuerfanos =
        dejaraDeSerCobrador && widget.clientesAsignados > 0;
    final perderaPrefijo =
        dejaraDeSerCobrador && widget.prefijoActual != null;
    final pasaACobradorSinPrefijo = widget.rolActual != 'cobrador' &&
        _seleccionado == 'cobrador';
    final cambioReal = _seleccionado != widget.rolActual;

    return AlertDialog(
      title: Text('¿Cambiar rol de ${widget.nombre}?'),
      content: SizedBox(
        width: dialogW,
        // Wrap en SingleChildScrollView para no clipear contenido en
        // pantallas cortas (laptop landscape, móvil horizontal).
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rol actual: ${_label(widget.rolActual)}',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ..._roles.map((r) {
                final esActual = r == widget.rolActual;
                return RadioListTile<String>(
                  value: r,
                  groupValue: _seleccionado,
                  onChanged: (v) => setState(() => _seleccionado = v!),
                  title: Row(
                    children: [
                      Text(_label(r)),
                      if (esActual) ...[
                        const SizedBox(width: 6),
                        Text(
                          '(actual)',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    _descripcion(r),
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                  tileColor: esActual ? scheme.surfaceContainerLow : null,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                );
              }),
              if (widget.esUltimoAdmin && perderaAdmin) ...[
                const SizedBox(height: 12),
                WarningBox(
                  icon: Icons.warning_amber,
                  color: scheme.errorContainer,
                  onColor: scheme.onErrorContainer,
                  texto: 'Es el único admin activo del tenant. Tras este '
                      'cambio nadie podrá administrar este ISP hasta que '
                      'designes otro admin.',
                ),
              ],
              if (dejaraClientesHuerfanos) ...[
                const SizedBox(height: 12),
                WarningBox(
                  icon: Icons.warning_amber,
                  color: scheme.errorContainer,
                  onColor: scheme.onErrorContainer,
                  texto: warningClientesHuerfanos(widget.clientesAsignados),
                ),
              ],
              if (perderaPrefijo) ...[
                const SizedBox(height: 12),
                WarningBox(
                  icon: Icons.info_outline,
                  color: scheme.surfaceContainerHighest,
                  onColor: scheme.onSurfaceVariant,
                  texto:
                      'El prefijo de recibo "${widget.prefijoActual}" se '
                      'va a eliminar (no aplica fuera del rol cobrador).',
                ),
              ],
              if (pasaACobradorSinPrefijo) ...[
                const SizedBox(height: 12),
                WarningBox(
                  icon: Icons.info_outline,
                  color: scheme.surfaceContainerHighest,
                  onColor: scheme.onSurfaceVariant,
                  texto: 'Después tenés que asignarle un prefijo de recibo '
                      'desde el panel del tenant antes de que pueda cobrar.',
                ),
              ],
              if (!cambioReal) ...[
                const SizedBox(height: 12),
                Text(
                  'Elegí un rol distinto al actual para habilitar el cambio.',
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Cambiar'),
          // Color error si hay warning severo (último admin o clientes
          // huérfanos) — alinea visualmente con la severidad del aviso.
          style: ((widget.esUltimoAdmin && perderaAdmin) ||
                  dejaraClientesHuerfanos)
              ? FilledButton.styleFrom(
                  backgroundColor:
                      Theme.of(context).colorScheme.error,
                  foregroundColor:
                      Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: cambioReal
              ? () => Navigator.of(context).pop(_seleccionado)
              : null,
        ),
      ],
    );
  }

  // `tecnico` y `admin_tickets` (Fase 3, módulo tickets): cada uno con su shell
  // propio. Se ofrecen SIEMPRE acá (a diferencia del dropdown del admin, gateado
  // por ticketsOn): el super_admin habilita módulos, así que puede asignar el
  // rol antes/después de encender tickets en /super/tenants/:id — con el módulo
  // OFF verían su shell vacío (y 0114 bloquea writes server-side).
  static const _roles = [
    'admin',
    'admin_cobranza',
    'admin_usuarios',
    'cobrador',
    'tecnico',
    'admin_tickets',
    'coordinador',
    'lectura',
  ];

  static String _label(String r) => switch (r) {
        'admin' => 'Administrador',
        'admin_cobranza' => 'Admin de cobranza',
        'admin_usuarios' => 'Admin de usuarios',
        'cobrador' => 'Cobrador',
        'tecnico' => 'Técnico',
        'admin_tickets' => 'Admin de tickets',
        'coordinador' => 'Coordinador técnico',
      'lectura' => 'Solo lectura',
        _ => r,
      };

  static String _descripcion(String r) => switch (r) {
        'admin' =>
          'Acceso completo: clientes, contratos, planes, cobradores, config.',
        'admin_cobranza' =>
          'Clientes, contratos, cuotas y pagos. Sin acceso a config.',
        'admin_usuarios' =>
          'Clientes y contratos (crear, editar, suspender). Sin cobros ni config.',
        'cobrador' =>
          'Sólo sus clientes asignados. Cobra y emite recibos.',
        'tecnico' =>
          'Campo: sus tickets asignados. Resuelve, comenta y adjunta fotos.',
        'admin_tickets' =>
          'Soporte: TODOS los tickets del tenant. Asigna, resuelve, comenta. Sin cobranza.',
        'coordinador' =>
          'Reparte el trabajo: elige qué técnico lleva cada orden y en qué orden. No modifica las órdenes ni ve plata.',
        'lectura' =>
          'Supervisión: ve TODO el tenant, incluida la plata. No modifica nada.',
        _ => '',
      };
}

/// Pide un nuevo email para un miembro confirmado. Devuelve el email
/// vía Navigator.pop(String) o null si se canceló.
class CambiarEmailDialog extends StatefulWidget {
  const CambiarEmailDialog({
    super.key,
    required this.nombre,
    required this.emailActual,
  });

  final String nombre;
  final String emailActual;

  @override
  State<CambiarEmailDialog> createState() => _CambiarEmailDialogState();
}

class _CambiarEmailDialogState extends State<CambiarEmailDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) {
      setState(() => _error = 'Ingresá el nuevo email');
      return;
    }
    final emailErr = Validators.email(v);
    if (emailErr != null) {
      setState(() => _error = emailErr);
      return;
    }
    if (v == widget.emailActual) {
      setState(() => _error = 'Ya es ese email');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;
    return AlertDialog(
      title: Text('Cambiar email de ${widget.nombre}'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Email actual: ${widget.emailActual}',
              style: TextStyle(
                  color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Nuevo email',
                hintText: 'usuario@empresa.com',
              ),
            ),
            const SizedBox(height: 12),
            WarningBox(
              icon: Icons.info_outline,
              color: scheme.surfaceContainerHighest,
              onColor: scheme.onSurfaceVariant,
              texto: 'El nuevo email queda confirmado automáticamente — no '
                  'se envía verificación. Avisá al usuario por canal '
                  'seguro que su email de login cambió.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.check),
          label: const Text('Cambiar email'),
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// Dialog destructivo para eliminar un miembro. Doble confirmación:
///   1. Aviso explicativo + ack del usuario.
///   2. Tipear el nombre del miembro tal cual para habilitar el botón.
class EliminarDialog extends StatefulWidget {
  const EliminarDialog({super.key, required this.cobrador});
  final CobradorAdmin cobrador;

  @override
  State<EliminarDialog> createState() => _EliminarDialogState();
}

class _EliminarDialogState extends State<EliminarDialog> {
  final _confirmCtrl = TextEditingController();
  bool _entiendo = false;

  @override
  void dispose() {
    _confirmCtrl.dispose();
    super.dispose();
  }

  bool get _puedeEliminar =>
      _entiendo && _confirmCtrl.text.trim() == widget.cobrador.nombre.trim();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 460.0;
    return AlertDialog(
      icon: Icon(Icons.warning_amber, color: scheme.error, size: 36),
      title: Text('¿Eliminar a ${widget.cobrador.nombre}?'),
      content: SizedBox(
        width: dialogW,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WarningBox(
                icon: Icons.warning_amber,
                color: scheme.errorContainer,
                onColor: scheme.onErrorContainer,
                texto: 'Esta acción es PERMANENTE. Si el usuario tiene '
                    'historial operativo (pagos, recibos, clientes '
                    'asignados), la operación va a fallar. Para esos '
                    'casos, usá "Desactivar" — preserva todo el historial.',
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                value: _entiendo,
                onChanged: (v) => setState(() => _entiendo = v ?? false),
                title: const Text(
                  'Entiendo que esta acción no se puede deshacer',
                  style: TextStyle(fontSize: 13),
                ),
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 8),
              Text(
                'Tipeá el nombre exacto (con mayúsculas y tildes) '
                'para confirmar:',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 4),
              // SelectableText: el usuario puede copiarlo si tiene
              // problemas con tildes/mayúsculas en su teclado.
              // Semantics.label explícito porque sin contexto el SR
              // lee el nombre suelto sin saber su propósito.
              Semantics(
                label: 'Nombre a confirmar: ${widget.cobrador.nombre}',
                excludeSemantics: true,
                child: SelectableText(
                  widget.cobrador.nombre,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _confirmCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  // labelText (no sólo hintText) — NVDA anuncia
                  // "edit, blank" cuando solo hay hint; labelText
                  // queda como nombre accesible del campo.
                  labelText: 'Confirmá tipeando el nombre',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        // Botón destructivo: label rico para screen readers que
        // exponga la naturaleza permanente de la acción. Cuando está
        // disabled el estado se anuncia por Semantics(enabled).
        Semantics(
          button: true,
          enabled: _puedeEliminar,
          label: 'Eliminar permanentemente a ${widget.cobrador.nombre}',
          excludeSemantics: true,
          child: FilledButton.icon(
            icon: const Icon(Icons.delete_forever),
            label: const Text('Eliminar'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              disabledBackgroundColor: scheme.surfaceContainerHighest,
            ),
            onPressed: _puedeEliminar
                ? () => Navigator.of(context).pop(true)
                : null,
          ),
        ),
      ],
    );
  }
}
