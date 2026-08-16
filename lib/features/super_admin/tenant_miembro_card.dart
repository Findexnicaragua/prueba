import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/cobrador_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/cobrador_helpers.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/chips.dart';
import '../shared/widgets/credenciales_dialog.dart';
import 'tenant_dialogs_miembro.dart';

/// Acciones disponibles en el menú "..." de cada miembro.
/// Algunas son condicionales según el estado del miembro:
///   - resetPasswordEmail / forzarPassword: sólo si emailConfirmedAt != null
///   - reenviarInvitacion: sólo si invitacionPendiente
enum _AccionMiembro {
  toggleActivo,
  forzarPassword,
  resetPasswordEmail,
  reenviarInvitacion,
  cambiarRol,
  cambiarEmail,
  eliminar,
}

class MiembroCard extends ConsumerStatefulWidget {
  const MiembroCard({super.key, required this.cobrador, required this.tenantId});

  final CobradorAdmin cobrador;
  final String tenantId;

  @override
  ConsumerState<MiembroCard> createState() => _MiembroCardState();
}

class _MiembroCardState extends ConsumerState<MiembroCard> {
  bool _saving = false;

  Future<void> _ejecutarAccion(_AccionMiembro accion) async {
    switch (accion) {
      case _AccionMiembro.toggleActivo:
        await _toggleActivo();
      case _AccionMiembro.forzarPassword:
        await _forzarPassword();
      case _AccionMiembro.resetPasswordEmail:
        await _resetPasswordEmail();
      case _AccionMiembro.reenviarInvitacion:
        await _reenviarInvitacion();
      case _AccionMiembro.cambiarRol:
        await _cambiarRol();
      case _AccionMiembro.cambiarEmail:
        await _cambiarEmail();
      case _AccionMiembro.eliminar:
        await _eliminar();
    }
  }

  Future<void> _cambiarEmail() async {
    final c = widget.cobrador;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final repo = container.read(superAdminRepoProvider);

    final nuevo = await showDialog<String>(
      context: context,
      builder: (_) => CambiarEmailDialog(
        nombre: c.nombre,
        emailActual: c.email ?? '(sin email)',
      ),
    );
    if (nuevo == null || nuevo.isEmpty || nuevo == c.email) return;

    setState(() => _saving = true);
    try {
      await repo.cambiarEmailCobrador(
        cobradorId: c.id,
        nuevoEmail: nuevo,
      );
      container.invalidate(cobradoresTenantProvider(widget.tenantId));
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('${c.nombre}: email cambiado a $nuevo'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('No se pudo cambiar el email: $msg'),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _eliminar() async {
    final c = widget.cobrador;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final repo = container.read(superAdminRepoProvider);

    final confirmado = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EliminarDialog(cobrador: c),
    );
    if (confirmado != true) return;

    setState(() => _saving = true);
    try {
      await repo.eliminarCobrador(cobradorId: c.id);
      container.invalidate(cobradoresTenantProvider(widget.tenantId));
      container.invalidate(tenantsAdminProvider);
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('${c.nombre} eliminado'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text(msg),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetPasswordEmail() async {
    final c = widget.cobrador;
    final email = c.email;
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (email == null) {
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: const Text(
            'Este usuario no tiene email registrado. No se puede mandar reset.',
          ),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final s = Theme.of(dialogCtx).colorScheme;
        return AlertDialog(
          title: Text('¿Mandar reset password a ${c.nombre}?'),
          content: SizedBox(
            width: dialogW,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Se le enviará un email a $email con un link para '
                  'definir una nueva contraseña.',
                ),
                const SizedBox(height: 12),
                WarningBox(
                  icon: Icons.info_outline,
                  color: s.surfaceContainerHighest,
                  onColor: s.onSurfaceVariant,
                  texto: 'No abras el link en este browser: quedarías '
                      'logueado como ${c.nombre} y perderías tu sesión '
                      'de Dev.',
                ),
                if (!c.activo) ...[
                  const SizedBox(height: 12),
                  WarningBox(
                    icon: Icons.warning_amber,
                    color: s.errorContainer,
                    onColor: s.onErrorContainer,
                    texto: '${c.nombre} está inactivo. Aunque resetee su '
                        'contraseña no va a poder iniciar sesión hasta '
                        'que lo reactives.',
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.mail_outline),
              label: const Text('Enviar email'),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
            ),
          ],
        );
      },
    );
    if (confirmar != true) return;

    setState(() => _saving = true);
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: kIsWeb ? '${Uri.base.origin}/?flow=recovery' : null,
      );
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('Email de reset enviado a $email'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e is AuthException
          ? e.message
          : e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('No se pudo enviar reset: $msg'),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reenviarInvitacion() async {
    final c = widget.cobrador;
    final email = c.email;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (email == null) {
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: const Text(
            'Este usuario no tiene email registrado. No se puede reenviar.',
          ),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;

    // Dialog ConsumerStateful que corre el network call internamente
    // (mismo patrón que _CrearTenantDialog). Devuelve null si cancela,
    // o el record completo con nuevaPassword? null/non-null según
    // el modo elegido. Sin esto teníamos un await entre dos modales
    // que en web mostraba un frame en blanco.
    final r = await showDialog<
        ({String newUserId, String email, String? nuevaPassword})>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ReenviarInvitacionDialog(cobrador: c, dialogW: dialogW),
    );
    if (r == null) return;
    container.invalidate(cobradoresTenantProvider(widget.tenantId));
    container.invalidate(tenantsAdminProvider);
    if (!mounted) return;

    final nueva = r.nuevaPassword;
    if (nueva != null && nueva.isNotEmpty) {
      // Path no-email: el server creó al user con password aleatoria;
      // mostramos email + password para copiar. Si el super_admin
      // cierra sin copiar, la password se pierde — puede regenerar con
      // "Forzar contraseña" en la fila del miembro.
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CredencialesDialog(
          title: 'Credenciales de ${c.nombre}',
          email: r.email,
          password: nueva,
          intro: 'Generamos una contraseña nueva para ${c.nombre}. '
              'Pasale email + contraseña por canal seguro — la '
              'invitación anterior dejó de funcionar.',
        ),
      );
    } else {
      // Path email: snackbar tradicional.
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('Invitación reenviada a ${r.email}'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _cambiarRol() async {
    final c = widget.cobrador;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    // El color se captura ACÁ, junto al messenger, y no adentro de los catch.
    // El de "Deshacer" es un callback del SnackBarAction: corre cuando el
    // usuario lo toca, hasta 5 segundos después, y el snackbar sobrevive a que
    // el super_admin salga de la pantalla del tenant. Si ahí el revert falla
    // —sin conexión, la regla de último admin— un `Theme.of(context)` pegaría
    // contra un widget ya muerto y el aviso "No se pudo deshacer" NUNCA se
    // vería: el super_admin se queda creyendo que revirtió un cambio de rol
    // que sigue aplicado. Un permiso mal seteado, en silencio.
    final colorError = Theme.of(context).colorScheme.error;
    final repo = container.read(superAdminRepoProvider);

    // Re-fetch para que esUltimoAdmin esté basado en datos frescos del
    // server, no en una snapshot de hace minutos.
    container.invalidate(cobradoresTenantProvider(widget.tenantId));
    final miembros = await container
        .read(cobradoresTenantProvider(widget.tenantId).future);
    final otrosAdminsActivos = miembros
        .where((m) => m.rol == 'admin' && m.activo && m.id != c.id)
        .length;
    if (!mounted) return;

    final nuevo = await showDialog<String>(
      context: context,
      builder: (_) => CambiarRolDialog(
        nombre: c.nombre,
        rolActual: c.rol,
        prefijoActual: c.prefijoRecibo,
        clientesAsignados: c.clientesAsignados,
        esUltimoAdmin: c.rol == 'admin' && otrosAdminsActivos == 0,
      ),
    );
    if (nuevo == null || nuevo == c.rol) return;

    setState(() => _saving = true);
    try {
      await repo.setCobradorRol(
        cobradorId: c.id,
        nuevoRol: nuevo,
      );
      container.invalidate(cobradoresTenantProvider(widget.tenantId));
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text(
            '${c.nombre}: ${rolLabel(nuevo)}. '
            'Si está logueado, debe salir y volver a entrar.',
          ),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Deshacer',
            onPressed: () async {
              try {
                await repo.setCobradorRol(
                  cobradorId: c.id,
                  nuevoRol: c.rol,
                );
                container.invalidate(
                    cobradoresTenantProvider(widget.tenantId));
                _mostrarSnackBar(
                  messenger,
                  SnackBar(
                    content: Text(
                      '${c.nombre}: revertido a ${rolLabel(c.rol)}',
                    ),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } catch (e) {
                _mostrarSnackBar(
                  messenger,
                  SnackBar(
                    content: Text('No se pudo deshacer: ${e.toString().replaceFirst('Exception: ', '')}'),
                    backgroundColor: colorError,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('No se pudo cambiar el rol: $msg'),
          backgroundColor: colorError,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _forzarPassword() async {
    final c = widget.cobrador;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final repo = container.read(superAdminRepoProvider);

    final nueva = await showDialog<String>(
      context: context,
      // No permitimos dismiss accidental: si el super_admin ya generó una
      // password, debe explícitamente Cancelar o Aplicar.
      barrierDismissible: false,
      builder: (_) => ForzarPasswordDialog(nombre: c.nombre),
    );
    if (nueva == null || nueva.isEmpty) return;

    setState(() => _saving = true);
    try {
      await repo.forzarPasswordCobrador(
        cobradorId: c.id,
        nuevaPassword: nueva,
      );
      if (!mounted) return;
      // El dialog de copia es CRÍTICO: si el super_admin lo cierra sin
      // copiar pierde la password. Bloqueamos dismiss accidental.
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PasswordCopiarDialog(
          nombre: c.nombre,
          password: nueva,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // Cleaneamos "Exception: " del wrapper del repo para mostrar sólo el
      // mensaje real del servidor.
      final msg = e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('No se pudo cambiar la contraseña: $msg'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleActivo() async {
    final c = widget.cobrador;
    final scheme = Theme.of(context).colorScheme;
    // Estado al que estamos pasando, capturado antes del await para que el
    // snackbar lea el valor correcto aún si el widget se reconstruye con
    // datos frescos del provider.
    final nuevoEstado = !c.activo;

    // Capturamos container y messenger antes de cualquier await — el
    // SnackBarAction sobrevive al rebuild del widget tras la invalidación
    // de providers, y si usamos `ref` del state, el callback de Deshacer
    // puede correr cuando el state ya no es válido y tira en silencio.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final tenantId = widget.tenantId;
    final repo = container.read(superAdminRepoProvider);

    if (c.activo) {
      // Warnings que muestra el confirm dialog:
      //   - "último admin": al desactivarlo nadie administra el tenant.
      //   - "clientes huérfanos": si es cobrador con clientes asignados,
      //     quedan sin nadie que los cobre hasta reasignar.
      // Re-fetch antes de leer la lista — así el count y el conteo de
      // admins están frescos (mismo patrón que _cambiarRol).
      container.invalidate(cobradoresTenantProvider(widget.tenantId));
      final miembros = await container
          .read(cobradoresTenantProvider(widget.tenantId).future);
      if (!mounted) return;
      // c también puede estar desactualizado por la invalidación; busco
      // la versión fresca para tomar clientesAsignados correcto.
      final cFresh = miembros.firstWhere(
        (m) => m.id == c.id,
        orElse: () => c,
      );
      final adminsActivos = miembros
          .where((m) => m.rol == 'admin' && m.activo && m.id != cFresh.id)
          .length;
      final esUltimoAdmin = cFresh.rol == 'admin' && adminsActivos == 0;
      final dejaraClientesHuerfanos =
          cFresh.rol == 'cobrador' && cFresh.clientesAsignados > 0;

      final confirmar = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) {
          final dialogScheme = Theme.of(dialogCtx).colorScheme;
          return AlertDialog(
            title: Text('¿Desactivar a ${c.nombre}?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'El usuario no podrá iniciar sesión. Sus datos históricos '
                  '(pagos, recibos, auditoría) se conservan y podés '
                  'reactivarlo más tarde sin pérdida.',
                ),
                if (esUltimoAdmin) ...[
                  const SizedBox(height: 12),
                  WarningBox(
                    icon: Icons.warning_amber,
                    color: dialogScheme.errorContainer,
                    onColor: dialogScheme.onErrorContainer,
                    texto: 'Es el único admin activo del tenant. Tras '
                        'desactivarlo, nadie podrá administrar este ISP '
                        'hasta que reactives a alguien o invites otro '
                        'admin.',
                  ),
                ],
                if (dejaraClientesHuerfanos) ...[
                  const SizedBox(height: 12),
                  WarningBox(
                    icon: Icons.warning_amber,
                    color: dialogScheme.errorContainer,
                    onColor: dialogScheme.onErrorContainer,
                    texto:
                        warningClientesHuerfanos(cFresh.clientesAsignados),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(dialogCtx).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: dialogScheme.error,
                  foregroundColor: dialogScheme.onError,
                ),
                onPressed: () => Navigator.of(dialogCtx).pop(true),
                child: const Text('Desactivar'),
              ),
            ],
          );
        },
      );
      if (confirmar != true) return;
    }

    setState(() => _saving = true);
    try {
      await repo.setCobradorActivo(
        cobradorId: c.id,
        activo: nuevoEstado,
      );
      container.invalidate(cobradoresTenantProvider(tenantId));
      container.invalidate(tenantsAdminProvider);
      if (!mounted) return;
      final accionPasada = nuevoEstado ? 'activado' : 'desactivado';
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('${c.nombre} $accionPasada'),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Deshacer',
            onPressed: () async {
              try {
                await repo.setCobradorActivo(
                  cobradorId: c.id,
                  activo: !nuevoEstado,
                );
                container.invalidate(cobradoresTenantProvider(tenantId));
                container.invalidate(tenantsAdminProvider);
                _mostrarSnackBar(
                  messenger,
                  SnackBar(
                    content: Text(
                      '${c.nombre} '
                      '${!nuevoEstado ? "activado" : "desactivado"} '
                      '(deshacer)',
                    ),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } catch (e) {
                _mostrarSnackBar(
                  messenger,
                  SnackBar(
                    content: Text('No se pudo deshacer: ${e.toString().replaceFirst('Exception: ', '')}'),
                    backgroundColor: scheme.error,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('Error: ${e.toString().replaceFirst('Exception: ', '')}'),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Muestra una SnackBar y fuerza el cierre tras `duration` con un Timer
  /// manual. Flutter web tiene un bug conocido donde el MouseRegion interno
  /// del SnackBar mantiene el hover en true permanentemente cuando el
  /// snackbar contiene un action, lo que pausa el auto-dismiss. Cerramos
  /// nosotros por las dudas — si ya se cerró por otra vía, close() es no-op.
  static void _mostrarSnackBar(
    ScaffoldMessengerState messenger,
    SnackBar bar,
  ) {
    final controller = messenger.showSnackBar(bar);
    Timer(bar.duration, () {
      try {
        controller.close();
      } catch (_) {/* controller ya cerrado */}
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cobrador;
    final scheme = Theme.of(context).colorScheme;
    final rolColor = _rolColor(scheme, c.rol);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Si hay una acción en curso (spinner), bloqueamos la navegación
        // para que el usuario no pierda el snackbar / feedback en medio.
        onTap: _saving
            ? null
            : () => GoRouter.of(context)
                .push('/super/tenants/${widget.tenantId}/miembros/${c.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: c.activo
                  ? rolColor.withValues(alpha: 0.15)
                  : scheme.surfaceContainerHighest,
              foregroundColor: c.activo ? rolColor : scheme.outline,
              child: Text(
                initialsFromName(c.nombre),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Nombre + chip de rol en Wrap, no Row, para evitar
                  // overflow en pantallas angostas.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        c.nombre,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      RolChip(rol: c.rol),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.email ?? '(sin email)',
                    style: TextStyle(color: scheme.outline, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      EstadoChip(cobrador: c),
                      Text(
                        _ultimoLoginLabel(c),
                        style: TextStyle(color: scheme.outline, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Menú de acciones a la derecha. Mostramos spinner mientras una
            // acción está corriendo para evitar dobles clicks.
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              PopupMenuButton<_AccionMiembro>(
                tooltip: 'Acciones para ${c.nombre}',
                onSelected: _ejecutarAccion,
                itemBuilder: (_) => [
                  // Grupo 1: estado.
                  PopupMenuItem(
                    value: _AccionMiembro.toggleActivo,
                    child: Row(
                      children: [
                        Icon(
                          c.activo ? Icons.block : Icons.check_circle,
                          color: c.activo ? scheme.error : scheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(c.activo ? 'Desactivar' : 'Activar'),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  // Grupo 2: credenciales.
                  // forzarPassword usa error color porque es la única que
                  // genera una password visible para el super_admin — más
                  // sensible que las otras dos acciones de credenciales.
                  //
                  // Las dos acciones de password están bloqueadas en backend
                  // para super_admin targets (forzar-password edge fn y la
                  // RPC audit_reset_password). Ocultamos del menú para que
                  // el super_admin no envíe un email que después no se va
                  // a poder auditar — además del flow frustrante de tipear
                  // datos y comerse un 403.
                  if (!c.invitacionPendiente && c.rol != 'super_admin')
                    PopupMenuItem(
                      value: _AccionMiembro.forzarPassword,
                      // Label explícito para screen readers — el color
                      // rojo del ícono comunica "sensible" a usuarios
                      // viendo, pero no a quienes navegan con TalkBack.
                      //
                      // Sin button:true — el PopupMenuItem ya provee el
                      // rol "menuitem"; ponerlo de nuevo duplicaría la
                      // anunciación. `hint` se lee con pausa, así no
                      // satura la traversal con texto de workflow.
                      child: Semantics(
                        label: 'Forzar contraseña — acción sensible',
                        hint: 'Genera una contraseña visible para el '
                            'Dev',
                        excludeSemantics: true,
                        child: Row(
                          children: [
                            Icon(Icons.password,
                                color: scheme.error, size: 20),
                            const SizedBox(width: 12),
                            const Text('Forzar contraseña'),
                          ],
                        ),
                      ),
                    ),
                  if (!c.invitacionPendiente && c.rol != 'super_admin')
                    PopupMenuItem(
                      value: _AccionMiembro.resetPasswordEmail,
                      child: Row(
                        children: [
                          Icon(Icons.mail_outline,
                              color: scheme.tertiary, size: 20),
                          const SizedBox(width: 12),
                          const Text('Reset password vía email'),
                        ],
                      ),
                    ),
                  // Reenviar invitación: sólo para pending invites — el
                  // user no aceptó todavía. Para confirmados usá reset.
                  if (c.invitacionPendiente)
                    PopupMenuItem(
                      value: _AccionMiembro.reenviarInvitacion,
                      child: Row(
                        children: [
                          Icon(Icons.send,
                              color: scheme.tertiary, size: 20),
                          const SizedBox(width: 12),
                          const Text('Reenviar invitación'),
                        ],
                      ),
                    ),
                  const PopupMenuDivider(),
                  // Grupo 3: identidad (rol + email).
                  PopupMenuItem(
                    value: _AccionMiembro.cambiarRol,
                    child: Row(
                      children: [
                        Icon(Icons.swap_horiz,
                            color: scheme.primary, size: 20),
                        const SizedBox(width: 12),
                        const Text('Cambiar rol'),
                      ],
                    ),
                  ),
                  if (!c.invitacionPendiente)
                    PopupMenuItem(
                      value: _AccionMiembro.cambiarEmail,
                      child: Row(
                        children: [
                          Icon(Icons.alternate_email,
                              color: scheme.primary, size: 20),
                          const SizedBox(width: 12),
                          const Text('Cambiar email'),
                        ],
                      ),
                    ),
                  // Grupo 4: destructivo (al fondo, separado por divider).
                  // Ocultamos para self y para otros super_admin — el
                  // backend ya bloquea, pero esconder evita el flujo
                  // frustrante de abrir el dialog 'tipear nombre' para
                  // acabar viendo un error.
                  if (c.id !=
                          Supabase
                              .instance.client.auth.currentUser?.id &&
                      c.rol != 'super_admin') ...[
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _AccionMiembro.eliminar,
                      child: Semantics(
                        label: 'Eliminar miembro — acción destructiva',
                        hint: 'Va a pedir confirmación tipeando el '
                            'nombre',
                        excludeSemantics: true,
                        child: Row(
                          children: [
                            Icon(Icons.delete_forever,
                                color: scheme.error, size: 20),
                            const SizedBox(width: 12),
                            Text(
                              'Eliminar miembro',
                              style: TextStyle(color: scheme.error),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
      ),
    );
  }

  static Color _rolColor(ColorScheme s, String rol) => switch (rol) {
        'super_admin' => s.tertiary,
        'admin' => s.primary,
        // s.secondary es primary al 10% → iniciales del avatar ilegibles.
        'admin_cobranza' => Colors.teal.shade700,
        _ => s.onSurfaceVariant,
      };

  static String _ultimoLoginLabel(CobradorAdmin c) {
    if (c.lastSignInAt == null) return 'Nunca inició sesión';
    // Guard contra clock skew (device atrás del server): nunca mostramos
    // "hace -1 días". Si la diferencia es negativa o cero → "hoy".
    final raw = DateTime.now().difference(c.lastSignInAt!).inDays;
    final dias = raw < 0 ? 0 : raw;
    if (dias == 0) return 'Última sesión: hoy';
    if (dias == 1) return 'Última sesión: ayer';
    if (dias < 30) return 'Última sesión: hace $dias días';
    return 'Última sesión: ${Fmt.fechaLarga(c.lastSignInAt!)}';
  }
}
