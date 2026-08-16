import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/modulo.dart';
import '../../data/models/tenant_admin.dart';
import '../../data/providers/auth_identity_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/services/impersonation_service.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/cobrador_helpers.dart';
import '../shared/widgets/animated_list_entry.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/skeleton.dart';
import 'tenant_dialogs_invitar.dart';
import 'tenant_miembro_card.dart';
import '../../data/utils/errores.dart';

/// Detalle de un tenant: toggles de módulos. Cada switch llama
/// set_tenant_modulo() vía RPC y refresca la lista global.
class TenantModulosScreen extends ConsumerWidget {
  const TenantModulosScreen({super.key, required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenantsAsync = ref.watch(tenantsAdminProvider);
    final modulosAsync = ref.watch(modulosProvider);

    if (tenantsAsync.isLoading || modulosAsync.isLoading) {
      // Skeleton de header + módulos + miembros para preservar el layout
      // mientras viene la data (en vez del spinner que flasheaba antes).
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          SkeletonCard(hasAvatar: true, hasChip: false, marginBottom: 16),
          SizedBox(height: 8),
          SkeletonList(count: 2, hasAvatar: false, hasChip: false),
          SizedBox(height: 16),
          SkeletonList(count: 2, hasAvatar: true, hasChip: true),
        ],
      );
    }
    if (tenantsAsync.hasError) {
      return Center(child: Text('Error: ${tenantsAsync.error}'));
    }
    if (modulosAsync.hasError) {
      return Center(child: Text('Error: ${modulosAsync.error}'));
    }

    // Guard defensivo: si el value es null en un estado transitorio (ej.
    // provider invalidado post-toggle de módulo), mostramos skeleton en
    // vez de NPE en `.value!`. El `isLoading` de arriba no cubre este
    // caso porque Riverpod puede tener `isLoading=false` + `value=null`
    // brevemente durante invalidación.
    final tenants = tenantsAsync.valueOrNull;
    final modulos = modulosAsync.valueOrNull;
    if (tenants == null || modulos == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          SkeletonCard(hasAvatar: true, hasChip: false, marginBottom: 16),
          SizedBox(height: 8),
          SkeletonList(count: 2, hasAvatar: false, hasChip: false),
        ],
      );
    }

    final tenant = tenants.where((t) => t.id == tenantId).firstOrNull;

    if (tenant == null) {
      return const Center(child: Text('Tenant no encontrado'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Header(tenant: tenant),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _EntrarTenantButton(
              tenantId: tenant.id,
              tenantNombre: tenant.nombre,
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.person_add),
              label: const Text('Invitar admin a este tenant'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => InvitarAdminDialog(tenant: tenant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Módulos',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Activá las funcionalidades que este tenant tiene contratadas.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 16),
        ...modulos.map((m) => _ModuloTile(
              tenant: tenant,
              modulo: m,
            )),
        const SizedBox(height: 32),
        Text('Miembros del tenant',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Usuarios con acceso a este tenant.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 16),
        _MiembrosList(tenantId: tenant.id),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.tenant});
  final TenantAdmin tenant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              radius: 28,
              child: Text(
                initialsFromName(tenant.nombre),
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tenant.nombre,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '${tenant.cobradoresCount} cobradores activos',
                    style: TextStyle(color: scheme.outline),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    tenant.id,
                    style: TextStyle(
                      color: scheme.outline,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuloTile extends ConsumerStatefulWidget {
  const _ModuloTile({required this.tenant, required this.modulo});

  final TenantAdmin tenant;
  final Modulo modulo;

  @override
  ConsumerState<_ModuloTile> createState() => _ModuloTileState();
}

class _ModuloTileState extends ConsumerState<_ModuloTile> {
  bool _saving = false;

  Future<void> _toggle(bool value) async {
    setState(() => _saving = true);
    try {
      await ref.read(superAdminRepoProvider).setTenantModulo(
            tenantId: widget.tenant.id,
            modulo: widget.modulo.codigo,
            habilitado: value,
          );
      ref.invalidate(tenantsAdminProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Módulo ${widget.modulo.nombre} ${value ? "habilitado" : "deshabilitado"}'),
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(mensajeErrorHumano(e)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.modulo;
    final habilitado = widget.tenant.tieneModulo(m.codigo);
    final scheme = Theme.of(context).colorScheme;
    final esBase = m.esBase;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(m.nombre,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      if (esBase) ...[
                        const SizedBox(width: 8),
                        Chip(
                          label: const Text('Base',
                              style: TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: scheme.tertiaryContainer,
                          labelStyle: TextStyle(
                            color: scheme.onTertiaryContainer,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (m.descripcion != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      m.descripcion!,
                      style: TextStyle(
                          color: scheme.outline, fontSize: 13),
                    ),
                  ],
                  if (esBase) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Módulo base, no se puede deshabilitar.',
                      style: TextStyle(
                          color: scheme.outline,
                          fontSize: 12,
                          fontStyle: FontStyle.italic),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (_saving)
              const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              Switch.adaptive(
                value: habilitado,
                onChanged: esBase || _saving ? null : _toggle,
              ),
          ],
        ),
      ),
    );
  }
}

/// Lista de miembros (cobradores) de un tenant. Lee de la RPC
/// `list_cobradores_tenant`.
class _MiembrosList extends ConsumerWidget {
  const _MiembrosList({required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(cobradoresTenantProvider(tenantId));
    return async.when(
      // Skeleton: 2 cards mientras carga — preserva el layout y le da al
      // user la sensación de "ya está viniendo data".
      loading: () => const SkeletonList(
        count: 2,
        hasAvatar: true,
        hasChip: true,
      ),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 8),
              const Text('No se pudo cargar la lista de miembros',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
                onPressed: () =>
                    ref.invalidate(cobradoresTenantProvider(tenantId)),
              ),
            ],
          ),
        ),
      ),
      data: (miembros) {
        if (miembros.isEmpty) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: EmptyState(
                icon: Icons.person_off,
                titulo: 'Sin miembros',
                descripcion:
                    'Usá "Invitar admin a este tenant" para agregar el primero.',
              ),
            ),
          );
        }
        return Column(
          children: miembros
              .asMap()
              .entries
              .map((e) => AnimatedListEntry(
                    // Key estable por id para que list shrink/grow no
                    // re-anime los items existentes.
                    key: ValueKey(e.value.id),
                    index: e.key,
                    child:
                        MiembroCard(cobrador: e.value, tenantId: tenantId),
                  ))
              .toList(),
        );
      },
    );
  }
}

/// Botón "Entrar al tenant" que inicia la impersonación. Al completar,
/// navega a /admin donde el AdminShell muestra el panel con la data del
/// tenant impersonado y el banner de impersonación.
class _EntrarTenantButton extends ConsumerStatefulWidget {
  const _EntrarTenantButton({
    required this.tenantId,
    required this.tenantNombre,
  });
  final String tenantId;
  final String tenantNombre;

  @override
  ConsumerState<_EntrarTenantButton> createState() =>
      _EntrarTenantButtonState();
}

class _EntrarTenantButtonState extends ConsumerState<_EntrarTenantButton> {
  bool _busy = false;

  Future<void> _entrar() async {
    setState(() => _busy = true);
    try {
      await ImpersonationService(Supabase.instance.client).enter(
        tenantId: widget.tenantId,
        tenantNombre: widget.tenantNombre,
      );
      if (!mounted) return;
      // Re-armar el sync gate: no mostrar data del tenant anterior hasta que
      // PowerSync baje la del tenant nuevo (#9 / S2).
      ref.read(authIdentityProvider.notifier).onImpersonationChanged();
      // Estado optimista: impersonando=true YA (sin esperar la fila local).
      ref.read(pendingImpersonacionProvider.notifier).state =
          PendingImpersonacion.entrando(widget.tenantId);
      context.go('/admin');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al entrar al tenant: $e')),
      );
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      icon: _busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            )
          : const Icon(Icons.login),
      label: Text(_busy ? 'Entrando…' : 'Entrar al tenant'),
      onPressed: _busy ? null : _entrar,
    );
  }
}
