import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/repositories/super_admin_repo.dart';
import '../../../data/utils/edge_functions.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log.dart';
import '../../../data/utils/validators.dart';
import '../../../powersync/db.dart' as ps;
import '../../super_admin/tenant_dialogs_miembro.dart' show ForzarPasswordDialog;
import '../../shared/widgets/credenciales_dialog.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import '../../shared/widgets/password_mode_selector.dart';
import '../../shared/widgets/phone_text_field.dart';
import '../../../data/utils/busqueda_cliente.dart';
import '../../../data/utils/errores.dart';

/// Los 3 roles que cobran en campo y por lo tanto necesitan prefijo de
/// recibo (correlativo propio). El super_admin NO cobra → no lleva prefijo.
const _kRolesQueCobran = {'cobrador', 'admin', 'admin_cobranza'};

/// True si [prefijo] (no vacío) ya lo usa OTRO cobrador del tenant (fix F0:
/// unicidad validada en cliente → error claro en vez de rechazo silencioso del
/// sync). La tabla local ya está scopeada al tenant por el sync, así que no
/// filtra tenant_id. Prefijo es [A-Z0-9-] (ASCII) → upper() es seguro (la
/// regla #1d de ñ/acentos no aplica). El backstop DURO sigue siendo el UNIQUE
/// server (esto solo evita la divergencia local silenciosa y da mejor UX).
Future<bool> _prefijoEnUso(String prefijo, {String? excluirId}) async {
  if (prefijo.isEmpty) return false;
  final rows = await ps.db.getAll(
    "SELECT id FROM cobradores WHERE upper(COALESCE(prefijo_recibo,'')) = ?"
    "${excluirId != null ? ' AND id <> ?' : ''}",
    [prefijo.toUpperCase(), if (excluirId != null) excluirId],
  );
  return rows.isNotEmpty;
}

/// Map cobrador_id → email para los miembros del tenant del caller. El email
/// vive en `auth.users` (no en `cobradores`), así que se trae por RPC
/// SECURITY DEFINER `list_cobrador_emails` (migración 0091) con guard de rol.
///
/// Es online-only (toca auth.users vía RPC): si no hay conexión el provider
/// queda en error/loading y la UI degrada elegante (no muestra email, no
/// rompe la lista). autoDispose para no retener el map al salir de la pantalla.
final _cobradorEmailsProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final res = await Supabase.instance.client.rpc('list_cobrador_emails')
      as List<dynamic>;
  final map = <String, String>{};
  for (final e in res) {
    final row = Map<String, dynamic>.from(e as Map);
    final id = row['cobrador_id'] as String?;
    final email = row['email'] as String?;
    if (id != null && email != null) map[id] = email;
  }
  return map;
});

/// Gestión de cobradores: ver lista, asignar prefijo de recibo, cambiar
/// rol, activar/desactivar.
///
/// Nota: la creación del usuario en auth.users requiere Supabase Admin
/// API (service role key), que NO va en el cliente. Se invita desde
/// Supabase Dashboard; cuando el cobrador se logea por primera vez
/// (después de que el trigger de Supabase cree su fila en cobradores
/// vía una Edge Function pendiente), aparece acá para configurar.
class CobradoresAdminScreen extends ConsumerStatefulWidget {
  const CobradoresAdminScreen({super.key});

  @override
  ConsumerState<CobradoresAdminScreen> createState() =>
      _CobradoresAdminScreenState();
}

class _CobradoresAdminScreenState
    extends ConsumerState<CobradoresAdminScreen> {
  late final Stream<List<Map<String, dynamic>>> _cobradoresStream;

  @override
  void initState() {
    super.initState();
    // Subqueries en SELECT evitan el producto cartesiano que tendrían
    // dos LEFT JOINs (clientes × pagos) sobre el mismo cobrador.
    _cobradoresStream = ps.db.watch(
      '''
      SELECT co.id, co.nombre, co.telefono, co.rol,
             co.prefijo_recibo, co.activo, co.puede_cambiar_fecha,
             co.dashboard_pin_configurado,
             (SELECT COUNT(*) FROM clientes
               WHERE cobrador_id = co.id AND activo = 1
             ) AS clientes_asignados,
             (SELECT COALESCE(SUM(monto_cordobas), 0) FROM pagos
               WHERE cobrador_id = co.id
                 AND COALESCE(anulado, 0) = 0 AND COALESCE(en_revision, 0) = 0
                 AND date(fecha_pago) >= date('now', '-6 hours', 'start of month')
             ) AS cobrado_mes
        FROM cobradores co
       ORDER BY co.activo DESC, co.rol, co.nombre
      ''',
    );
  }

  Future<void> _abrirInvitar(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _InvitarDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cobradoresStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(mensajeErrorHumano(snap.error!)));
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return EmptyState(
            icon: Icons.engineering,
            titulo: 'Sin cobradores',
            descripcion:
                'Invitá al primero — te generamos una contraseña para compartirle por WhatsApp.',
            accion: FilledButton.icon(
              icon: const Icon(Icons.person_add),
              label: const Text('Invitar cobrador'),
              onPressed: () => _abrirInvitar(context),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!ref.watch(soloLecturaProvider)) ...[
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  icon: const Icon(Icons.person_add),
                  label: const Text('Invitar nuevo'),
                  onPressed: () => _abrirInvitar(context),
                ),
              ),
              const SizedBox(height: 16),
            ],
            ...rows.map((r) => _CobradorCard(row: r)),
          ],
        );
      },
    );
  }
}

class _InvitarDialog extends ConsumerStatefulWidget {
  const _InvitarDialog();
  @override
  ConsumerState<_InvitarDialog> createState() => _InvitarDialogState();
}

class _InvitarDialogState extends ConsumerState<_InvitarDialog> {
  final _email = TextEditingController();
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  final _prefijo = TextEditingController();
  String _rol = 'cobrador';
  bool _enviando = false;
  // Mismo patrón que _CrearTenantDialog e InvitarAdminDialog: default OFF
  // por decisión de producto (onboarding sin email).
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
    _prefijo.dispose();
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
    final prefijo = _prefijo.text.trim().toUpperCase();
    // El prefijo aplica a los 3 roles que cobran (cobrador/admin/admin_cobranza).
    final rolCobra = _kRolesQueCobran.contains(_rol);
    if (rolCobra && prefijo.isNotEmpty && !RegExp(r'^[A-Z0-9-]{2,16}$').hasMatch(prefijo)) {
      setState(() => _error = 'Prefijo: [A-Z0-9-]{2,16}');
      return;
    }
    // Auto-generar prefijo si el admin lo dejó vacío: primeras 2 letras
    // del nombre en mayúscula. Evita el caso donde el usuario no puede
    // cobrar porque no tiene prefijo asignado (E2E bug). Aplica a los 3
    // roles que cobran, no sólo a cobrador.
    // Se PLIEGA a ASCII (ñ/acentos → base) y se filtra a [a-z0-9] ANTES de
    // tomar las 2 letras: sin esto un nombre como "Ángel"/"Ñandú" generaba
    // "ÁN"/"ÑA", que la edge function rechaza (^[A-Z0-9-]{2,16}$) → la
    // invitación entera fallaba con un error de un campo que el admin dejó en
    // blanco (audit Fase 3, regla #1d de rango ampliado).
    final autoBase =
        foldBusqueda(nombre).replaceAll(RegExp(r'[^a-z0-9]'), '');
    final prefijoFinal = prefijo.isNotEmpty
        ? prefijo
        : rolCobra && autoBase.length >= 2
            ? autoBase.substring(0, 2).toUpperCase()
            : '';

    // Unicidad de prefijo (fix F0): error claro en vez del rechazo silencioso
    // del sync (23505). El UNIQUE server sigue siendo el backstop duro.
    if (prefijoFinal.isNotEmpty && await _prefijoEnUso(prefijoFinal)) {
      if (!mounted) return;
      setState(() => _error =
          'El prefijo "$prefijoFinal" ya está en uso por otro miembro.');
      return;
    }

    // El `if (!mounted)` de arriba vive DENTRO del bloque del prefijo en uso
    // (y ese bloque retorna), así que por el camino NORMAL —prefijo libre— no
    // cubría nada: el `await _prefijoEnUso(...)` igual se ejecutó y la
    // ejecución caía derecho a las capturas de abajo sin ningún chequeo. Y no
    // es un caso raro: si el admin deja el prefijo en blanco y el rol cobra,
    // se autogenera del nombre, o sea que ese await corre casi siempre.
    //
    // Si el admin cierra el diálogo mientras corre esa consulta, el
    // `Navigator.of(context)` de abajo busca sobre un widget ya muerto. En
    // debug tira "Looking up a deactivated widget's ancestor is unsafe" FUERA
    // del try (que arranca más abajo), o sea excepción async no capturada: la
    // invitación no se manda y el admin no ve nada. En release el lookup suele
    // resolver igual y el `navigator.pop()` termina cerrando la pantalla de
    // cobradores en vez del diálogo. Síntoma distinto según el build, que es
    // lo peor para diagnosticar.
    if (!mounted) return;

    // Capturamos refs al Navigator y ScaffoldMessenger ANTES del await
    // grande (la edge function) para no usar el context del State (que queda
    // desmontado tras el primer pop). Sin esto el showDialog puede no aparecer.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final rootContext = Navigator.of(context, rootNavigator: true).context;

    // Si el super_admin está impersonando un tenant, la Edge Function
    // `invitar-cobrador` exige el `tenant_id` en el body (el caller
    // super_admin no tiene tenant operativo propio). Lo leemos del
    // provider de impersonación; para un admin normal es null y no se
    // manda (el server lo infiere del JWT del caller).
    final tenantImpersonado =
        ref.read(impersonatedTenantIdProvider).valueOrNull;

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
          'rol': _rol,
          if (tenantImpersonado != null) 'tenant_id': tenantImpersonado,
          if (PhoneTextField.sanitized(_telefono) != null)
            'telefono': PhoneTextField.sanitized(_telefono),
          if (prefijoFinal.isNotEmpty) 'prefijo_recibo': prefijoFinal,
          // Password manual (sólo path no-email): si el admin la tipeó,
          // la mandamos. El server la usa en vez de generar una y NO la
          // eco-devuelve (la conocemos local).
          if (!_enviarEmail && _modoManual && _passwordManual != null)
            'password': _passwordManual,
          // Explícito para que el server no asuma default si en el
          // futuro cambia (mismo patrón que crear-tenant).
          'enviar_email': _enviarEmail,
          // ?flow=invite: routea al invitado a /set-password tras
          // clickear el link del email. Sólo aplica al path email
          // (ver _extractAuthFlow en main).
          if (kIsWeb && _enviarEmail)
            'redirect_to': '${Uri.base.origin}/?flow=invite',
        },
      );
      // op_log de alta (fix F0): deja constancia de quién invitó al miembro.
      // Best-effort local: si falla, no rompe la invitación (ya creada server).
      final nuevoId = data['user_id'] as String?;
      final tId = data['tenant_id'] as String?;
      if (nuevoId != null && tId != null) {
        try {
          final me = Supabase.instance.client.auth.currentUser;
          final actor = me != null
              ? await OpLog.actorDeUsuario(ps.db, me.id)
              : const OpLogActor.systemAdmin();
          await ps.dbW.writeTransaction((tx) async {
            await OpLog.escribir(tx,
                tenantId: tId,
                opId: OpLog.nuevoOpId(),
                tipoOp: 'alta_entidad',
                entidad: 'cobradores',
                entidadId: nuevoId,
                accion: 'create',
                diff: {
                  'campos': [
                    {'campo': 'nombre', 'antes': null, 'despues': nombre},
                    {'campo': 'rol', 'antes': null, 'despues': _rol},
                    if (prefijoFinal.isNotEmpty)
                      {
                        'campo': 'prefijo_recibo',
                        'antes': null,
                        'despues': prefijoFinal
                      },
                  ]
                },
                actor: actor,
                ocurridoEn: DateTime.now().toUtc());
          });
        } catch (_) {/* best-effort: la invitación ya tuvo éxito */}
      }
      // Si fue manual, la response trae `nueva_password: null` — usamos la
      // password TIPEADA local. Si fue Generar, usamos la de la response.
      final passwordManualEnviada =
          (!_enviarEmail && _modoManual) ? _passwordManual : null;
      final nuevaPassword =
          passwordManualEnviada ?? (data['nueva_password'] as String?);
      ref.invalidate(_cobradorEmailsProvider);
      if (nuevaPassword != null && nuevaPassword.isNotEmpty) {
        // Path no-email: cerramos este dialog y abrimos el de
        // credenciales — el admin tiene UNA oportunidad de copiar la
        // password antes de que se pierda. Si cierra sin copiar tiene
        // que ir a "Forzar contraseña" en la fila del cobrador.
        navigator.pop();
        await showDialog<bool>(
          // `rootContext` es el context del Navigator RAIZ, capturado antes: vive
          // lo que vive la app y no lo desmonta cerrar este dialogo.
          // ignore: use_build_context_synchronously
          context: rootContext,
          barrierDismissible: false,
          builder: (_) => CredencialesDialog(
            title: 'Credenciales de $nombre',
            email: email,
            password: nuevaPassword,
            intro:
                'Usuario creado. Pasale email + contraseña por canal '
                'seguro — esta es la única vez que la contraseña queda '
                'visible.',
          ),
        );
      } else {
        // Path email: snackbar tradicional + pop.
        navigator.pop();
        messenger.showSnackBar(
          SnackBar(content: Text('Invitación enviada a $email')),
        );
      }
    } catch (e) {
      // El helper invokeEdgeFunction debería lanzar Exception(msg);
      // pelamos el prefijo "Exception: " técnico antes de mostrar al
      // user. Defensive: si por algún motivo el helper no procesó y
      // llega un FunctionException raw, extraemos el campo `error`
      // del toString para no exponer el wrapper técnico.
      if (mounted) {
        setState(() => _error = humanizarEdgeError(e));
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Roles de tickets (Técnico / Admin de tickets) solo si el tenant tiene el
    // módulo tickets habilitado.
    final ticketsOn = ref
            .watch(modulosHabilitadosProvider)
            .valueOrNull
            ?.contains('tickets') ??
        false;
    // Width responsive: 400 en desktop/tablet, 90% del viewport en
    // mobile chico (iPhone SE = 375, no entra el 400 fijo + el switch
    // wrappea feo). Mismo patrón que _CrearTenantDialog.
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;
    return AlertDialog(
      // scrollable: en pantalla corta (móvil) el form + los campos de
      // contraseña no entran y desbordaban sobre los botones. Esto envuelve
      // título+contenido en un scroll.
      scrollable: true,
      title: const Text('Invitar cobrador'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                  ? 'Recibirá un email con link para definir su '
                      'contraseña. Una vez logueado, podrá usar la app.'
                  : 'Se creará el usuario con una contraseña aleatoria '
                      '(no se manda email — la vas a copiar y compartir '
                      'vos).',
              style: TextStyle(color: scheme.outline, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email *'),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              enabled: !_enviando,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nombre,
              enabled: !_enviando,
              decoration: const InputDecoration(labelText: 'Nombre completo *'),
            ),
            const SizedBox(height: 12),
            PhoneTextField(
              controller: _telefono,
              enabled: !_enviando,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _rol,
              decoration: const InputDecoration(labelText: 'Rol'),
              items: [
                const DropdownMenuItem(
                    value: 'cobrador', child: Text('Cobrador')),
                const DropdownMenuItem(
                    value: 'admin_cobranza', child: Text('Admin de cobranza')),
                const DropdownMenuItem(
                    value: 'admin_usuarios', child: Text('Admin de usuarios')),
                const DropdownMenuItem(
                    value: 'admin', child: Text('Administrador')),
                const DropdownMenuItem(
                    value: 'lectura', child: Text('Solo lectura')),
                // tecnico + admin_tickets: roles del módulo tickets, cada uno
                // con su shell propio. Se ofrecen si el módulo está activo.
                if (ticketsOn) ...[
                  const DropdownMenuItem(
                      value: 'tecnico', child: Text('Técnico')),
                  const DropdownMenuItem(
                      value: 'admin_tickets',
                      child: Text('Admin de tickets')),
                  const DropdownMenuItem(
                      value: 'coordinador',
                      child: Text('Coordinador técnico')),
                ],
              ],
              onChanged: _enviando
                  ? null
                  : (v) => setState(() => _rol = v ?? _rol),
            ),
            // Los 3 roles que cobran llevan prefijo de recibo (correlativo
            // propio). Sólo super_admin no lo necesita (no cobra en campo).
            if (_kRolesQueCobran.contains(_rol)) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _prefijo,
                enabled: !_enviando,
                decoration: const InputDecoration(
                  labelText: 'Prefijo de recibo',
                  hintText: 'COB-01',
                  helperText: 'Si lo dejás vacío, se genera automáticamente del nombre',
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                  LengthLimitingTextInputFormatter(16),
                ],
              ),
            ],
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
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        // Label e icono cambian según modo — paralelo a
        // _ReenviarInvitacionDialog: ambos describen el artifact
        // resultante, no el canal de entrega.
        FilledButton.icon(
          onPressed: (_enviando || _passwordIncompleta) ? null : _invitar,
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
                  // Label "Crear usuario" en modo manual (no "generar",
                  // que es engañoso si el admin tipeó la password).
                  : _modoManual
                      ? 'Crear usuario'
                      : 'Generar contraseña'),
        ),
      ],
    );
  }
}

class _CobradorCard extends ConsumerWidget {
  const _CobradorCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final activo = (row['activo'] as int? ?? 1) == 1;
    final rol = row['rol'] as String;
    final prefijo = row['prefijo_recibo'] as String?;
    final clientes = row['clientes_asignados'] as int? ?? 0;
    final cobradoMes = (row['cobrado_mes'] as num? ?? 0).toDouble();
    // Email del miembro (de auth.users vía RPC). Degrada a null si la RPC
    // no respondió (offline / loading / error) — sin romper la fila.
    final email = ref
        .watch(_cobradorEmailsProvider)
        .valueOrNull?[row['id'] as String];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: activo
                    ? _colorRol(rol, scheme).withValues(alpha: 0.15)
                    : scheme.surfaceContainerHighest,
                foregroundColor: activo ? _colorRol(rol, scheme) : scheme.outline,
                child: Text(_initials(row['nombre'] as String)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(row['nombre'] as String,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        _RolChip(rol: rol),
                        if (!activo) ...[
                          const SizedBox(width: 8),
                          Chip(
                            label: const Text('Inactivo'),
                            backgroundColor: scheme.surfaceContainerHighest,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ],
                    ),
                    if (row['telefono'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(row['telefono'] as String,
                            style: TextStyle(color: scheme.outline, fontSize: 12)),
                      ),
                    if (email != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(Icons.mail_outline,
                                size: 12, color: scheme.outline),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                email,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: scheme.outline, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    // Stats (prefijo / clientes / cobrado) para los 3 roles
                    // que cobran — todos llevan prefijo y pueden tener
                    // clientes asignados y cobros del mes.
                    if (_kRolesQueCobran.contains(rol)) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          _Stat(
                            label: 'Prefijo',
                            value: prefijo ?? '— sin asignar —',
                            color: prefijo == null ? scheme.error : null,
                          ),
                          _Stat(label: 'Clientes', value: '$clientes'),
                          _Stat(
                            label: 'Cobrado este mes',
                            value: Fmt.cordobas(cobradoMes),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Historial de cambios (0116, fix #9 del audit): cobradores era
              // la única entidad editable sin rastro — y el prefijo de recibo
              // es numeración de dinero.
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: 'Historial de cambios',
                onPressed: () => _historial(context, row['id'] as String),
              ),
              if (rol == 'admin' && !ref.watch(soloLecturaProvider))
                IconButton(
                  icon: Icon(
                    (row['dashboard_pin_configurado'] as int? ?? 0) == 1
                        ? Icons.lock
                        : Icons.lock_open,
                    size: 20,
                  ),
                  tooltip: 'PIN del dashboard',
                  onPressed: () => _pinDialog(context, ref, row),
                ),
              if (!ref.watch(soloLecturaProvider))
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Editar',
                  onPressed: () => _editar(context, ref, row),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _historial(BuildContext context, String cobradorId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Historial del miembro',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                child: HistorialOpLog(
                  entidad: 'cobradores',
                  entidadId: cobradorId,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pinDialog(BuildContext context, WidgetRef ref, Map<String, dynamic> row) {
    showDialog<void>(
      context: context,
      builder: (_) => _PinManagementDialog(row: row),
    );
  }

  Future<void> _editar(BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _EditarCobradorDialog(row: row),
    );
  }

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  Color _colorRol(String rol, ColorScheme s) => switch (rol) {
        'admin' => s.primary,
        'admin_cobranza' => s.tertiary,
        // Default legible (s.secondary es primary al 10% → iniciales invisibles).
        _ => s.onSurfaceVariant,
      };
}

class _RolChip extends StatelessWidget {
  const _RolChip({required this.rol});
  final String rol;
  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(switch (rol) {
        'admin' => 'Admin',
        'admin_cobranza' => 'Cobranza',
        'admin_usuarios' => 'Usuarios',
        'cobrador' => 'Cobrador',
        'tecnico' => 'Técnico',
        'admin_tickets' => 'Admin tickets',
        'coordinador' => 'Coordinador',
        _ => rol,
      }),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.outline, fontSize: 11)),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: color)),
      ],
    );
  }
}

class _EditarCobradorDialog extends ConsumerStatefulWidget {
  const _EditarCobradorDialog({required this.row});
  final Map<String, dynamic> row;

  @override
  ConsumerState<_EditarCobradorDialog> createState() => _EditarCobradorDialogState();
}

class _EditarCobradorDialogState extends ConsumerState<_EditarCobradorDialog> {
  late TextEditingController _nombreCtrl;
  late TextEditingController _telCtrl;
  late TextEditingController _prefijoCtrl;
  late String _rol;
  late bool _activo;
  // Permiso de cambio de fecha de pago por días (feature C, 0119).
  late bool _puedeCambiarFecha;
  String? _error;
  bool _guardando = false;

  // Estado de la sección "Ver contraseña".
  String? _passwordVisible;
  bool _cargandoPassword = false;

  // El dropdown de rol solo es editable para el super_admin (el backend lo
  // restringe a la RPC super_admin-only vía el trigger cobradores_freeze_rol).
  bool get _puedeCambiarRol =>
      ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;

  // Ver/forzar contraseña: sólo admin o super_admin (NO admin_cobranza), y nunca
  // sobre el propio usuario. El backend (Edge Function) replica estos guards
  // y además limita al admin a su tenant + roles no-admin; acá filtramos la
  // UI para no ofrecer el botón cuando seguro va a fallar.
  bool get _puedeForzarPassword {
    final yo = ref.watch(cobradorActualProvider).valueOrNull;
    if (yo == null) return false;
    if (!(yo.esAdmin || yo.esSuperAdmin)) return false;
    // No sobre uno mismo.
    if (widget.row['id'] == yo.id) return false;
    return true;
  }

  Future<void> _verPassword() async {
    // Pedir la contraseña del admin para autenticarse.
    final adminPass = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        bool obscure = true;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Verificar identidad'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Ingresá tu contraseña de administrador para ver '
                  'la contraseña del usuario.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  obscureText: obscure,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Tu contraseña',
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setDialogState(() => obscure = !obscure),
                    ),
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('Verificar'),
              ),
            ],
          ),
        );
      },
    );
    if (adminPass == null || adminPass.isEmpty || !mounted) return;

    setState(() {
      _cargandoPassword = true;
      _error = null;
    });
    try {
      final data = await invokeEdgeFunction(
        Supabase.instance.client,
        'ver-password-cobrador',
        body: {
          'cobrador_id': widget.row['id'] as String,
          'admin_password': adminPass,
        },
      );
      if (!mounted) return;
      final pw = data['password'] as String?;
      if (pw == null) {
        setState(() => _error =
            'No hay contraseña almacenada para este usuario. '
            'Se almacena a partir del próximo reset.');
      } else {
        setState(() => _passwordVisible = pw);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) setState(() => _cargandoPassword = false);
    }
  }

  Future<void> _forzarPassword() async {
    final nombre = widget.row['nombre'] as String;
    // Reusa el dialog del panel super_admin: pide / genera la password y la
    // devuelve por pop. null/"" = cancelado.
    final nuevaPassword = await showDialog<String>(
      context: context,
      builder: (_) => ForzarPasswordDialog(nombre: nombre),
    );
    if (nuevaPassword == null || nuevaPassword.isEmpty) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    // Email del target para mostrarlo junto a la password (de la RPC de
    // emails); si no está, mostramos un placeholder no-bloqueante.
    final email = ref
            .read(_cobradorEmailsProvider)
            .valueOrNull?[widget.row['id'] as String] ??
        '(email no disponible)';

    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(superAdminRepoProvider).forzarPasswordCobrador(
            cobradorId: widget.row['id'] as String,
            nuevaPassword: nuevaPassword,
          );
      if (!mounted) return;
      // CredencialesDialog SÓLO muestra — la generación/invoke ya ocurrió.
      await showDialog<bool>(
        // Idem: `rootContext` del Navigator raiz, y ademas hay un `if (!mounted)
        // return;` justo antes de esta llamada.
        // ignore: use_build_context_synchronously
        context: rootContext,
        barrierDismissible: false,
        builder: (_) => CredencialesDialog(
          title: 'Contraseña de $nombre',
          email: email,
          password: nuevaPassword,
          intro:
              'Contraseña forzada. Pasale email + contraseña por canal seguro '
              '— el usuario quedó deslogueado y debe entrar con esta nueva.',
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('No se pudo forzar la contraseña: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _nombreCtrl = TextEditingController(text: widget.row['nombre'] as String);
    _telCtrl = TextEditingController(text: widget.row['telefono'] as String? ?? '');
    _prefijoCtrl =
        TextEditingController(text: widget.row['prefijo_recibo'] as String? ?? '');
    _rol = widget.row['rol'] as String;
    _activo = (widget.row['activo'] as int? ?? 1) == 1;
    _puedeCambiarFecha = (widget.row['puede_cambiar_fecha'] as int? ?? 0) == 1;
  }

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _telCtrl.dispose();
    _prefijoCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    final prefijo = _prefijoCtrl.text.trim().toUpperCase();
    if (prefijo.isNotEmpty && !RegExp(r'^[A-Z0-9-]{2,16}$').hasMatch(prefijo)) {
      setState(() => _error =
          'Prefijo: solo letras mayúsculas, números y guiones (2 a 16 chars)');
      return;
    }

    // Confirmar cambios sensibles: rol y desactivación.
    final rolViejo = widget.row['rol'] as String;
    final activoViejo = (widget.row['activo'] as int? ?? 1) == 1;
    final cambiaRol = _rol != rolViejo;
    final desactiva = activoViejo && !_activo;

    if (cambiaRol || desactiva) {
      final msgs = <String>[];
      if (cambiaRol) {
        msgs.add('• Rol: $rolViejo → $_rol');
      }
      if (desactiva) {
        msgs.add('• Desactivás el cobrador (sus cobros pendientes quedan asignados pero no podrá loguearse).');
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirmar cambios'),
          content: Text('${msgs.join('\n')}\n\n¿Continuar?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      // prefijo_recibo aplica a los 3 roles que cobran (cobrador/admin/
      // admin_cobranza); sólo super_admin no lo lleva. Espeja lo que hace
      // la RPC set_cobrador_rol, para que no diverjan.
      final prefijoFinal =
          (_kRolesQueCobran.contains(_rol) && prefijo.isNotEmpty)
              ? prefijo
              : null;
      // Unicidad de prefijo (fix F0): sin esto una edición con prefijo duplicado
      // mostraba éxito y el sync la rechazaba en silencio (divergencia local).
      if (prefijoFinal != null &&
          await _prefijoEnUso(prefijoFinal,
              excluirId: widget.row['id'] as String)) {
        if (mounted) {
          setState(() {
            _error = 'El prefijo "$prefijoFinal" ya está en uso por otro miembro.';
            _guardando = false;
          });
        }
        return;
      }
      // nombre/teléfono/prefijo/activo: UPDATE local directo. NO incluye `rol`:
      // el trigger cobradores_freeze_rol (0066) rechaza el write directo de rol
      // (la UI mostraría éxito falso y el sync se rechazaría). El rol va por RPC.
      //
      // op_log (rework change log): actor + id de intención para registrar la
      // edición del cobrador (1 entrada, diff antes→después curado). El cambio
      // de rol NO se loguea acá: va por RPC (set_cobrador_rol). Nota: tras
      // eliminar audit_log (0140) el cambio de rol no deja rastro en el change
      // log — trade-off forense aceptado (BITACORA 2026-06-21).
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final opId = OpLog.nuevoOpId();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();
      final id = widget.row['id'] as String;
      await ps.dbW.writeTransaction((tx) async {
        final antesRows =
            await tx.getAll('SELECT * FROM cobradores WHERE id = ?', [id]);
        final antes = antesRows.isNotEmpty
            ? antesRows.first
            : const <String, dynamic>{};
        // tenant_id desde el snapshot de la fila (fallback al provider).
        final tenantId =
            (antes['tenant_id'] as String?) ?? ref.read(tenantIdProvider);
        await tx.execute(
          '''
          UPDATE cobradores
             SET nombre = ?, telefono = ?, prefijo_recibo = ?, activo = ?,
                 puede_cambiar_fecha = ?
           WHERE id = ?
          ''',
          [
            _nombreCtrl.text.trim(),
            PhoneTextField.sanitized(_telCtrl),
            prefijoFinal,
            _activo ? 1 : 0,
            _puedeCambiarFecha ? 1 : 0,
            id,
          ],
        );
        if (tenantId != null) {
          final despues =
              (await tx.getAll('SELECT * FROM cobradores WHERE id = ?', [id]))
                  .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'cobradores',
              entidadId: id, antes: antes, despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurridoEn));
        }
      });
      // Cambio de rol (solo super_admin; el dropdown está locked para el
      // resto): server-side vía RPC set_cobrador_rol, que valida el cambio (el
      // rol va congelado por el trigger cobradores_freeze_rol). Sin rastro en el
      // change log tras 0140 (trade-off forense aceptado).
      if (cambiaRol) {
        await ref.read(superAdminRepoProvider).setCobradorRol(
              cobradorId: widget.row['id'] as String,
              nuevoRol: _rol,
            );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = mensajeErrorHumano(e, contexto: 'guardar el cobrador'));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Ancho responsive: 400 en desktop/tablet, 90% del viewport en mobile
    // chico (un 400 fijo desborda el AlertDialog en pantallas ~360px).
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;
    // Roles de tickets: si el tenant tiene el módulo, o si el miembro YA es uno
    // de esos roles (para no romper el dropdown con un value fuera de items).
    final mostrarTickets = (ref
                .watch(modulosHabilitadosProvider)
                .valueOrNull
                ?.contains('tickets') ??
            false) ||
        _rol == 'tecnico' ||
        _rol == 'admin_tickets' ||
        _rol == 'coordinador';
    return AlertDialog(
      title: const Text('Editar cobrador'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: dialogW,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nombreCtrl,
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              const SizedBox(height: 12),
              PhoneTextField(controller: _telCtrl),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _rol,
                decoration: InputDecoration(
                  labelText: 'Rol',
                  helperText: _puedeCambiarRol
                      ? null
                      : 'Solo el super_admin puede cambiar el rol',
                ),
                items: [
                  const DropdownMenuItem(
                      value: 'admin', child: Text('Administrador')),
                  const DropdownMenuItem(
                      value: 'admin_cobranza',
                      child: Text('Admin de cobranza')),
                  const DropdownMenuItem(
                      value: 'admin_usuarios',
                      child: Text('Admin de usuarios')),
                  const DropdownMenuItem(
                      value: 'cobrador', child: Text('Cobrador')),
                  const DropdownMenuItem(
                      value: 'lectura', child: Text('Solo lectura')),
                  if (mostrarTickets) ...[
                    const DropdownMenuItem(
                        value: 'tecnico', child: Text('Técnico')),
                    const DropdownMenuItem(
                        value: 'admin_tickets',
                        child: Text('Admin de tickets')),
                    const DropdownMenuItem(
                        value: 'coordinador',
                        child: Text('Coordinador técnico')),
                  ],
                ],
                onChanged: _puedeCambiarRol
                    ? (v) => setState(() => _rol = v ?? _rol)
                    : null,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _prefijoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Prefijo de recibo',
                  hintText: 'COB-01, PEDRO, ...',
                  helperText:
                      'Para roles que cobran (cobrador / admin / cobranza). Único por empresa.',
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                  LengthLimitingTextInputFormatter(16),
                ],
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _activo,
                onChanged: (v) => setState(() => _activo = v),
                title: Text(_activo ? 'Activo' : 'Inactivo'),
                contentPadding: EdgeInsets.zero,
              ),
              // Permiso de cambio de fecha de pago por días (feature C, 0119):
              // solo si el super_admin habilitó la feature para el tenant, y solo
              // para cobrador/admin_cobranza (el admin siempre puede).
              if (ref.watch(appSettingsProvider).cambioFechaHabilitado &&
                  (_rol == 'cobrador' || _rol == 'admin_cobranza'))
                SwitchListTile(
                  value: _puedeCambiarFecha,
                  onChanged: (v) => setState(() => _puedeCambiarFecha = v),
                  title: const Text('Puede cambiar fecha de pago'),
                  subtitle: const Text(
                      'Cobra los días puente y mueve la fecha de pago del cliente'),
                  contentPadding: EdgeInsets.zero,
                ),
              if (_puedeForzarPassword) ...[
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _passwordVisible != null
                          ? SelectableText(
                              _passwordVisible!,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : Text(
                              '••••••••••',
                              style: TextStyle(
                                fontSize: 15,
                                color: scheme.outline,
                                letterSpacing: 2,
                              ),
                            ),
                    ),
                    if (_cargandoPassword)
                      const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (_passwordVisible != null) ...[
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: 'Copiar contraseña',
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: _passwordVisible!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Contraseña copiada')),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.visibility_off, size: 18),
                        tooltip: 'Ocultar',
                        onPressed: () =>
                            setState(() => _passwordVisible = null),
                      ),
                    ] else
                      TextButton.icon(
                        icon: const Icon(Icons.visibility, size: 18),
                        label: const Text('Ver contraseña'),
                        onPressed: _verPassword,
                      ),
                  ],
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (_puedeForzarPassword)
          TextButton.icon(
            icon: const Icon(Icons.lock_reset, size: 18),
            label: const Text('Forzar contraseña'),
            onPressed: _guardando ? null : _forzarPassword,
          ),
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _guardar,
          child: Text(_guardando ? 'Guardando...' : 'Guardar'),
        ),
      ],
    );
  }
}

class _PinManagementDialog extends ConsumerStatefulWidget {
  const _PinManagementDialog({required this.row});
  final Map<String, dynamic> row;

  @override
  ConsumerState<_PinManagementDialog> createState() =>
      _PinManagementDialogState();
}

/// Gestión del PIN del Resumen desde Personal.
///
/// Reescrito en 0202: ya NO se puede leer el PIN de nadie — ni el ajeno (nunca
/// baja al device) ni para "ayudar". De ahí las dos ramas:
///   · el PROPIO se cambia verificando el actual contra `dashboard_pins`, que
///     es la única fila que este device tiene;
///   · el AJENO solo se puede FORZAR: se borra sin verlo (RPC) y su dueño
///     configura uno nuevo la próxima vez que abra el Resumen.
class _PinManagementDialogState extends ConsumerState<_PinManagementDialog> {
  final _ctrlActual = TextEditingController();
  final _ctrlNuevo = TextEditingController();
  final _ctrlPassword = TextEditingController();
  bool _guardando = false;
  String? _error;
  bool _modoForceReset = false;

  String get _targetId => widget.row['id'] as String;
  String get _nombre => widget.row['nombre'] as String;
  // Lo único que se sabe de un PIN ajeno: si existe. Columna generada (0201).
  bool get _tienePin =>
      (widget.row['dashboard_pin_configurado'] as int? ?? 0) == 1;

  bool get _esMiPin {
    final yo = ref.read(cobradorActualProvider).valueOrNull;
    return yo != null && yo.id == _targetId;
  }

  @override
  void dispose() {
    _ctrlActual.dispose();
    _ctrlNuevo.dispose();
    _ctrlPassword.dispose();
    super.dispose();
  }

  /// El PIN propio: la única fila de `dashboard_pins` que este device tiene.
  Future<String> _miPinLocal() async {
    final rows = await ps.db
        .getAll('SELECT pin FROM dashboard_pins WHERE id = ?', [_targetId]);
    return rows.isEmpty ? '' : (rows.first['pin'] as String? ?? '');
  }

  Future<void> _guardarMiPin() async {
    final nuevo = _ctrlNuevo.text.trim();
    if (nuevo.length != 4) {
      setState(() => _error = 'El PIN debe tener 4 dígitos');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      if (_tienePin && !_modoForceReset) {
        if (_ctrlActual.text.trim() != await _miPinLocal()) {
          if (mounted) {
            setState(() {
              _error = 'El PIN actual es incorrecto';
              _guardando = false;
            });
          }
          return;
        }
      } else if (_modoForceReset && !await _verificarPassword()) {
        if (mounted) setState(() => _guardando = false);
        return;
      }
      await Supabase.instance.client
          .rpc('set_mi_dashboard_pin', params: {'p_pin': nuevo});
      _cerrarCon('PIN actualizado');
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = mensajeErrorHumano(e);
          _guardando = false;
        });
      }
    }
  }

  Future<void> _quitarMiPin() async {
    if (_tienePin && _ctrlActual.text.trim() != await _miPinLocal()) {
      setState(() => _error = 'El PIN actual es incorrecto');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await Supabase.instance.client
          .rpc('set_mi_dashboard_pin', params: {'p_pin': ''});
      _cerrarCon('PIN eliminado');
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = mensajeErrorHumano(e);
          _guardando = false;
        });
      }
    }
  }

  /// Sobre OTRO usuario: se lo borra sin leerlo. Es la única ayuda posible.
  Future<void> _forzarCambioAjeno() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.lock_reset, color: Theme.of(ctx).colorScheme.primary),
        title: const Text('Forzar cambio de PIN'),
        content: Text(
          'Se le borra el PIN a $_nombre. La próxima vez que abra el Resumen '
          'va a tener que configurar uno nuevo.\n\n'
          'No podés ver el PIN actual: nadie puede.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Forzar cambio')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc('forzar_reset_dashboard_pin',
          params: {'p_cobrador_id': _targetId});
      _cerrarCon('$_nombre configura un PIN nuevo la próxima vez');
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = mensajeErrorHumano(e);
          _guardando = false;
        });
      }
    }
  }

  void _cerrarCon(String msg) {
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _verificarPassword() async {
    final password = _ctrlPassword.text.trim();
    if (password.isEmpty) {
      setState(() => _error = 'Ingresá tu contraseña');
      return false;
    }
    final email = Supabase.instance.client.auth.currentUser?.email;
    if (email == null) {
      setState(() => _error = 'No se pudo obtener el email de la sesión');
      return false;
    }
    try {
      await Supabase.instance.client.auth
          .signInWithPassword(email: email, password: password);
      return true;
    } catch (_) {
      if (mounted) setState(() => _error = 'Contraseña incorrecta');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 360.0;

    return AlertDialog(
      icon:
          Icon(_tienePin ? Icons.lock : Icons.lock_open, color: scheme.primary),
      title: Text('PIN — $_nombre'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _tienePin
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _tienePin ? 'PIN configurado' : 'Sin PIN configurado',
                style: TextStyle(
                  color: _tienePin ? scheme.onPrimaryContainer : scheme.outline,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!_esMiPin)
              Text(
                'El PIN de otra persona no se puede ver, ni siquiera para '
                'ayudarla. Lo único posible es forzar el cambio.',
                style: TextStyle(fontSize: 13, color: scheme.outline),
                textAlign: TextAlign.center,
              )
            else ...[
              if (_tienePin && !_modoForceReset) ...[
                TextField(
                  controller: _ctrlActual,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  obscureText: true,
                  autofocus: true,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'PIN actual',
                    counterText: '',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (_modoForceReset) ...[
                TextField(
                  controller: _ctrlPassword,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Tu contraseña de cuenta',
                    border: OutlineInputBorder(),
                    isDense: true,
                    helperText: 'Verificamos tu identidad para resetear el PIN',
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _ctrlNuevo,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                autofocus: !_tienePin && !_modoForceReset,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: _tienePin ? 'Nuevo PIN' : 'PIN (4 dígitos)',
                  hintText: '••••',
                  counterText: '',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (_tienePin && !_modoForceReset)
                TextButton.icon(
                  icon: const Icon(Icons.lock_reset, size: 16),
                  label: const Text('Olvidé mi PIN'),
                  onPressed: () => setState(() {
                    _modoForceReset = true;
                    _error = null;
                    _ctrlActual.clear();
                  }),
                ),
              if (_modoForceReset)
                TextButton(
                  onPressed: () => setState(() {
                    _modoForceReset = false;
                    _error = null;
                    _ctrlPassword.clear();
                  }),
                  child: const Text('Volver a ingresar PIN actual'),
                ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(color: scheme.error, fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        if (_esMiPin && _tienePin && !_modoForceReset)
          TextButton(
            onPressed: _guardando ? null : _quitarMiPin,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Quitar PIN'),
          ),
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        if (_esMiPin)
          FilledButton(
            onPressed: _guardando ? null : _guardarMiPin,
            child: Text(_guardando
                ? 'Guardando…'
                : _tienePin
                    ? 'Cambiar PIN'
                    : 'Guardar PIN'),
          )
        else if (_tienePin)
          FilledButton(
            onPressed: _guardando ? null : _forzarCambioAjeno,
            child: Text(_guardando ? 'Aplicando…' : 'Forzar cambio'),
          ),
      ],
    );
  }
}
