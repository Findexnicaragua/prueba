import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/modulo.dart';
import '../../data/models/tenant_admin.dart';
import '../../data/providers/auth_identity_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/services/impersonation_service.dart';
import '../../data/utils/cobrador_helpers.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/phone_text_field.dart';
import '../../data/utils/validators.dart';
import '../shared/widgets/animated_list_entry.dart';
import '../shared/widgets/credenciales_dialog.dart';
import '../shared/widgets/password_mode_selector.dart';
import '../shared/widgets/skeleton.dart';

Future<void> _abrirCrearTenant(BuildContext context, WidgetRef ref) async {
  // Capturamos messenger antes del await — el showSnackBar post-éxito lo
  // usamos sin pasar por el context (que podría tener cambios pendientes).
  final messenger = ScaffoldMessenger.of(context);
  final resultado = await showDialog<
      ({
        String tenantId,
        String adminUserId,
        String adminEmail,
        String? adminPassword,
      })>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _CrearTenantDialog(),
  );
  if (resultado == null) return;
  ref.invalidate(tenantsAdminProvider);

  // Si vino una password, el super_admin pidió no-email — abrimos
  // dialog que muestra email+password para copiar (mismo patrón que
  // PasswordCopiarDialog de forzar-password). La password se generó
  // server-side y NO queda guardada en ningún lado — esta es la
  // única oportunidad de verla; si la pierde, hay que ir a "Forzar
  // contraseña" desde el detalle del miembro para generar otra.
  //
  // El dialog devuelve true si el user copió la password — sólo en
  // ese caso navegamos al detalle (parity con la action "Ver detalle"
  // del path de email). Si cerró sin copiar, lo dejamos en la lista
  // por si quiere reintentar.
  final password = resultado.adminPassword;
  if (password != null && password.isNotEmpty) {
    if (!context.mounted) return;
    final copio = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CredencialesDialog(
        title: 'Credenciales del admin',
        email: resultado.adminEmail,
        password: password,
        intro: 'El ISP ya está creado y el admin puede loguearse ya '
            'mismo con estas credenciales. Pasalas por canal seguro — '
            'si las compartiste por uno inseguro, podés rotarle la '
            'contraseña en cualquier momento desde el detalle del ISP.',
      ),
    );
    if (copio == true && context.mounted) {
      context.go('/super/tenants/${resultado.tenantId}');
    }
    return;
  }

  // Path con email: snackbar + acción "Ver detalle". Nos quedamos en
  // la lista para que el super_admin pueda crear varios seguidos sin
  // navegar manualmente cada vez.
  messenger.showSnackBar(
    SnackBar(
      content: const Text('ISP creado e invitación enviada por email'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Ver detalle',
        onPressed: () {
          if (!context.mounted) return;
          context.go('/super/tenants/${resultado.tenantId}');
        },
      ),
    ),
  );
}

/// Lista de tenants — pantalla raíz del panel /super.
class TenantsListScreen extends ConsumerWidget {
  const TenantsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenantsAsync = ref.watch(tenantsAdminProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(tenantsAdminProvider),
      child: tenantsAsync.when(
        // Skeleton imitando la altura final — sin layout jump al cargar.
        // Usamos ListView (no SingleChildScrollView) para que el
        // RefreshIndicator funcione consistente entre loading y data.
        loading: () => ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            SkeletonList(
              count: 3,
              hasAvatar: true,
              hasChip: true,
              cardMarginBottom: 12,
            ),
          ],
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(mensajeErrorHumano(e, contexto: 'cargar los tenants'),
                textAlign: TextAlign.center),
          ),
        ),
        data: (tenants) {
          if (tenants.isEmpty) {
            // Sin tenants: la card del CTA es suficiente — agregar un
            // EmptyState debajo era duplicar el mismo mensaje.
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _CrearTenantCard(
                  onTap: () => _abrirCrearTenant(context, ref),
                ),
              ],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            // +1 por la card de "crear" que renderizamos en index 0.
            itemCount: tenants.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) {
                return _CrearTenantCard(
                  onTap: () => _abrirCrearTenant(context, ref),
                );
              }
              final tenant = tenants[i - 1];
              return AnimatedListEntry(
                // Key estable por id: si la lista crece/shrinkea, los items
                // existentes no se re-animan ni se descolocan.
                key: ValueKey(tenant.id),
                index: i - 1,
                child: _TenantCard(tenant: tenant),
              );
            },
          );
        },
      ),
    );
  }
}

class _TenantCard extends ConsumerStatefulWidget {
  const _TenantCard({required this.tenant});
  final TenantAdmin tenant;

  @override
  ConsumerState<_TenantCard> createState() => _TenantCardState();
}

class _TenantCardState extends ConsumerState<_TenantCard> {
  bool _hover = false;
  bool _entering = false;

  Future<void> _enterTenant(BuildContext context, TenantAdmin tenant) async {
    if (_entering) return;
    setState(() => _entering = true);
    try {
      final service = ImpersonationService(Supabase.instance.client);
      await service.enter(
        tenantId: tenant.id,
        tenantNombre: tenant.nombre,
      );
      // Re-armar el sync gate: no mostrar data del tenant anterior hasta que
      // PowerSync baje la del tenant nuevo (#9 / S2). El router redirige a
      // /sync-gate y luego a /admin cuando sincroniza la impersonación.
      ref.read(authIdentityProvider.notifier).onImpersonationChanged();
      // Estado optimista: el router ve impersonando=true YA (sin esperar que
      // baje la fila local) → landing a /admin sin flashear /super/tenants.
      ref.read(pendingImpersonacionProvider.notifier).state =
          PendingImpersonacion.entrando(tenant.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(mensajeErrorHumano(e, contexto: 'entrar al tenant'))),
        );
      }
    } finally {
      if (mounted) setState(() => _entering = false);
    }
  }

  /// Suspende / reactiva el tenant (fix F0). Suspender corta el acceso de TODOS
  /// sus usuarios (gate de login). Reversible.
  Future<void> _toggleActivo(BuildContext context, TenantAdmin tenant) async {
    final suspender = tenant.activo;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(suspender ? 'Suspender ISP' : 'Reactivar ISP'),
        content: Text(suspender
            ? 'Se cortará el acceso de TODOS los usuarios de "${tenant.nombre}": '
                'no podrán iniciar sesión ni sincronizar. Es reversible.'
            : 'Se restaurará el acceso de todos los usuarios de "${tenant.nombre}".'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(suspender ? 'Suspender' : 'Reactivar')),
        ],
      ),
    );
    if (confirmar != true) return;
    try {
      await ref
          .read(superAdminRepoProvider)
          .setTenantActivo(tenantId: tenant.id, activo: !tenant.activo);
      ref.invalidate(tenantsAdminProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  mensajeErrorHumano(e, contexto: 'cambiar el estado del ISP'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tenant = widget.tenant;
    // Reduce motion (WCAG): si el OS lo pide, animamos sin duración.
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final animDur = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 150);
    // Lift sólo si hover activo Y no reducimos motion.
    final lift = (_hover && !reduceMotion) ? -2.0 : 0.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // AnimatedContainer maneja color, shadow y desplazamiento en una sola
      // animación. Material transparente adentro para que el InkWell tenga
      // su ripple sin pelearse con el bg.
      child: AnimatedContainer(
        duration: animDur,
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 12),
        transform: Matrix4.identity()..translate(0.0, lift),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          // Salto de 2 tonos en dark theme + borde sutil en hover para
          // que la diferencia sea perceptible (sin border, surfaceLow→High
          // en dark es apenas visible).
          color: _hover
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _hover ? scheme.outlineVariant : Colors.transparent,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: _hover ? 0.18 : 0.05),
              blurRadius: _hover ? 10 : 3,
              offset: Offset(0, _hover ? 4 : 1),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push('/super/tenants/${tenant.id}'),
            child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      initialsFromName(tenant.nombre),
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tenant.nombre,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Creado ${Fmt.fechaLarga(tenant.createdAt)}',
                          style: TextStyle(
                              color: scheme.outline, fontSize: 12),
                        ),
                        if (!tenant.activo) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: scheme.errorContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Suspendido',
                              style: TextStyle(
                                color: scheme.onErrorContainer,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.people_outline,
                      size: 16, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    '${tenant.cobradoresCount} cobradores activos',
                    style: TextStyle(color: scheme.outline, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: tenant.modulosHabilitados
                    .map((m) => Chip(
                          label: Text(moduloLabel(m)),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: scheme.secondaryContainer,
                          labelStyle:
                              TextStyle(color: scheme.onSecondaryContainer),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    icon: Icon(
                        tenant.activo
                            ? Icons.pause_circle_outline
                            : Icons.play_circle_outline,
                        size: 18),
                    label: Text(tenant.activo ? 'Suspender' : 'Reactivar'),
                    style: tenant.activo
                        ? TextButton.styleFrom(foregroundColor: scheme.error)
                        : null,
                    onPressed: () => _toggleActivo(context, tenant),
                  ),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Entrar como admin'),
                    onPressed: () => _enterTenant(context, tenant),
                  ),
                ],
              ),
            ],
          ),
        ),
          ),
        ),
      ),
    );
  }

}

/// Card "+ Crear nuevo tenant" arriba de la lista. Mismo border-radius
/// y altura aproximada que los _TenantCard para que la lista no salte
/// visualmente, pero con tinte primary y borde resaltado para que sea
/// claramente un CTA y no un row más.
class _CrearTenantCard extends StatelessWidget {
  const _CrearTenantCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 18),
            child: Row(
              children: [
                Icon(Icons.add_business, color: scheme.primary, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Crear nuevo ISP',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Da de alta un ISP y enviá la invitación',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward, color: scheme.primary, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dialog del flow alta-tenant. Toma nombre del tenant, datos del admin
/// y módulos no-base opcionales; llama a la Edge Function `crear-tenant`
/// y al éxito devuelve {tenantId, adminUserId} al caller para que
/// navegue al detalle.
class _CrearTenantDialog extends ConsumerStatefulWidget {
  const _CrearTenantDialog();

  @override
  ConsumerState<_CrearTenantDialog> createState() =>
      _CrearTenantDialogState();
}

class _CrearTenantDialogState extends ConsumerState<_CrearTenantDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nombreCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _adminNombreCtrl = TextEditingController();
  final _telefonoCtrl = TextEditingController();
  // Set de códigos de módulos extras seleccionados (los base ya van
  // automáticos vía trigger, no se muestran como opciones).
  final Set<String> _modulosExtras = {};
  // Default false: por decisión de producto (onboarding sin email).
  final bool _enviarEmail = false;
  bool _busy = false;
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
    _nombreCtrl.dispose();
    _emailCtrl.dispose();
    _adminNombreCtrl.dispose();
    _telefonoCtrl.dispose();
    super.dispose();
  }

  Future<void> _crear() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(superAdminRepoProvider);
      // Telefono opcional: si el campo quedó vacío, mandamos null para
      // que la metadata del invite no quede con "" — el trigger
      // handle_new_user trataría "" como un valor seteado.
      final telTrim = PhoneTextField.sanitized(_telefonoCtrl) ?? '';
      final resultado = await repo.crearTenant(
        nombre: _nombreCtrl.text.trim(),
        adminEmail: _emailCtrl.text.trim(),
        adminNombre: _adminNombreCtrl.text.trim(),
        adminTelefono: telTrim.isEmpty ? null : telTrim,
        modulosExtra: _modulosExtras.toList(),
        // Sin redirect_to con flow=invite, el link cae al root y se
        // pierde el routing a /set-password — tanto para emails como
        // para links generados manualmente.
        redirectTo:
            kIsWeb ? '${Uri.base.origin}/?flow=invite' : null,
        enviarEmail: _enviarEmail,
        passwordManual: _modoManual ? _passwordManual : null,
      );
      if (!mounted) return;
      // Si fue manual, el server devolvió `admin_password: null` — el
      // caller (_abrirCrearTenant) necesita la password para mostrar las
      // credenciales, así que se la inyectamos local. Si fue Generar (o, por
      // defensa, manual sin password válida), usamos la del server tal cual
      // (sino se pisaría con null y se perdería la generada).
      final conPassword =
          (!_enviarEmail && _modoManual && _passwordManual != null)
          ? (
              tenantId: resultado.tenantId,
              adminUserId: resultado.adminUserId,
              adminEmail: resultado.adminEmail,
              adminPassword: _passwordManual,
            )
          : resultado;
      Navigator.of(context).pop(conPassword);
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
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 480.0;
    final modulosAsync = ref.watch(modulosProvider);
    // PopScope con canPop:!_busy: evita que Esc o el back-gesture
    // cierren el dialog mid-request (la operación sigue corriendo en
    // el server, dejaríamos al user sin saber el resultado).
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
      icon: Icon(Icons.add_business, color: scheme.primary, size: 32),
      title: const Text('Crear ISP'),
      content: SizedBox(
        width: dialogW,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nombreCtrl,
                  enabled: !_busy,
                  // autofocus: queremos que arranque tipeando el
                  // nombre, no que tenga que tabbear primero. Sin esto,
                  // el textInputAction.next del primer field no tiene
                  // de dónde saltar.
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del ISP',
                    hintText: 'ej: ISP Las Lomas',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      Validators.requiredField(v, label: 'Nombre') ??
                      Validators.maxLength(v, 120),
                ),
                const SizedBox(height: 16),
                Text(
                  'Admin del tenant',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _emailCtrl,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    hintText: 'marcos@laslomas.ni',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      Validators.requiredField(v, label: 'Email') ??
                      Validators.email(v),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _adminNombreCtrl,
                  enabled: !_busy,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(
                    labelText: 'Nombre completo',
                    hintText: 'Marcos Pineda',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      Validators.requiredField(v, label: 'Nombre'),
                ),
                const SizedBox(height: 12),
                PhoneTextField(
                  controller: _telefonoCtrl,
                  enabled: !_busy,
                  label: 'Teléfono (opcional)',
                  hint: '+505 8888 1234',
                ),
                const SizedBox(height: 16),
                Text(
                  'Módulos adicionales',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                modulosAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(),
                  ),
                  error: (e, _) => Text(
                    'No se pudieron cargar los módulos: $e',
                    style: TextStyle(
                        color: scheme.error, fontSize: 12),
                  ),
                  // Renderiza TODOS los módulos (base y no-base). Los
                  // base aparecen disabled-checked para que el
                  // super_admin vea qué viene incluido y no se quede
                  // buscando Cobranza en la lista.
                  data: (mods) => _ModulosPicker(
                    modulos: mods,
                    seleccionadosExtra: _modulosExtras,
                    onChanged: _busy
                        ? null
                        : (codigo, checked) {
                            setState(() {
                              if (checked) {
                                _modulosExtras.add(codigo);
                              } else {
                                _modulosExtras.remove(codigo);
                              }
                            });
                          },
                  ),
                ),
                // SwitchListTile(
                //   value: _enviarEmail,
                //   onChanged: _busy
                //       ? null
                //       : (v) => setState(() => _enviarEmail = v),
                //   title: const Text('Enviar email de invitación'),
                //   subtitle: Text(
                //     _enviarEmail
                //         ? 'El admin recibe el link en su correo.'
                //         : 'No se envía email. Te generamos una '
                //             'contraseña para compartir manualmente.',
                //     style: const TextStyle(fontSize: 11),
                //   ),
                //   contentPadding: EdgeInsets.zero,
                //   dense: true,
                //   visualDensity: VisualDensity.compact,
                // ),
                // const SizedBox(height: 8),
                // Selector de contraseña: sólo en el path no-email (el
                // único donde la app define la password). Con email el
                // admin la crea él mismo desde el link.
                if (!_enviarEmail) ...[
                  const SizedBox(height: 16),
                  PasswordModeSelector(
                    enabled: !_busy,
                    onModeChanged: (m) => setState(() => _modoManual = m),
                    onChanged: (pw) =>
                        setState(() => _passwordManual = pw),
                  ),
                ],
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
              _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        // Semantics.hint comunica el side-effect al screen reader.
        // El label y el ícono cambian según el modo: email vs
        // password generada server-side.
        Semantics(
          button: true,
          enabled: !_busy,
          hint: _enviarEmail
              ? 'Envía un correo de invitación al admin del ISP'
              : 'Crea el ISP y genera la contraseña del admin para '
                  'que la copies',
          child: FilledButton.icon(
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_enviarEmail ? Icons.send : Icons.lock_reset),
            label: Text(
              _busy
                  ? 'Creando…'
                  : _enviarEmail
                      ? 'Crear y enviar invitación'
                      // Label "Crear ISP" en modo manual (no "generar",
                      // que es engañoso si el super_admin tipeó la pass).
                      : _modoManual
                          ? 'Crear ISP'
                          : 'Crear y generar contraseña',
            ),
            onPressed: (_busy || _passwordIncompleta) ? null : _crear,
          ),
        ),
      ],
    ),
    );
  }
}

/// Picker de módulos para el alta de tenant. Los módulos base se
/// renderean disabled-checked (el trigger los habilita automáticamente
/// al crear el tenant — el super_admin no puede ni deseleccionarlos);
/// los no-base son checkboxes interactivos cuyo estado vive en
/// `seleccionadosExtra` (set de códigos elegidos por el caller).
class _ModulosPicker extends StatelessWidget {
  const _ModulosPicker({
    required this.modulos,
    required this.seleccionadosExtra,
    required this.onChanged,
  });

  final List<Modulo> modulos;
  final Set<String> seleccionadosExtra;
  // onChanged null = todos los checkboxes deshabilitados (estado busy
  // del dialog padre). Sólo se llama para módulos no-base.
  final void Function(String codigo, bool checked)? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (modulos.isEmpty) {
      return Text(
        'No hay módulos en el catálogo.',
        style: TextStyle(
            color: scheme.onSurfaceVariant, fontSize: 12),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: modulos.map((m) {
        final esBase = m.esBase;
        return CheckboxListTile(
          value: esBase || seleccionadosExtra.contains(m.codigo),
          // Base: onChanged null (greyed-out, no se puede tocar).
          // No-base: si el dialog está busy, también null.
          onChanged: (esBase || onChanged == null)
              ? null
              : (v) => onChanged!(m.codigo, v ?? false),
          title: Row(
            children: [
              Expanded(child: Text(m.nombre)),
              if (esBase)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'incluido',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          subtitle: m.descripcion == null
              ? null
              : Text(
                  m.descripcion!,
                  style: const TextStyle(fontSize: 11),
                ),
          contentPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
          controlAffinity: ListTileControlAffinity.leading,
        );
      }).toList(),
    );
  }
}

