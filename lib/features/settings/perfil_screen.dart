import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/providers/cobrador_provider.dart';
import '../shared/utils/sign_out_helper.dart';
import '../../data/providers/crud_error_provider.dart';
import '../../data/providers/foto_comprobante_provider.dart';
import '../../data/services/rechazos_sync_service.dart';
import '../../data/providers/impresora_provider.dart';
import '../../data/providers/sync_status_provider.dart';
import '../../data/services/map_tile_cache.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../auth/cambiar_password_dialog.dart';
import '../shared/widgets/app_version_label.dart';
import '../shared/widgets/empty_state.dart';

class PerfilScreen extends ConsumerWidget {
  const PerfilScreen({super.key, this.tecnicoMode = false});

  /// Vista del técnico (Fase 3B): oculta lo específico del cobrador (prefijo de
  /// recibo, historial de cobros, fotos de comprobantes pendientes). Mantiene
  /// sync, impresora, caché de mapa, cambiar contraseña y cerrar sesión.
  final bool tecnicoMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final email = Supabase.instance.client.auth.currentUser?.email;

    if (cobrador == null) {
      return const EmptyState(
        icon: Icons.person_off,
        titulo: 'No hay datos de tu perfil aún',
        descripcion: 'Esperando primera sincronización.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Text(
                    _initials(cobrador.nombre),
                    style: TextStyle(
                      fontSize: 28,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(cobrador.nombre,
                    style: Theme.of(context).textTheme.titleLarge),
                Text(_rolDisplay(cobrador.rol)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _InfoCard([
          if (email != null) (null, 'Email', email),
          (Icons.phone, 'Teléfono', cobrador.telefono ?? '—'),
          // El prefijo de recibo sólo aplica al cobrador.
          if (!tecnicoMode)
            (Icons.receipt, 'Prefijo recibo', cobrador.prefijoRecibo ?? 'No asignado'),
        ]),
        const SizedBox(height: 12),
        if (!tecnicoMode) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Historial de cobros'),
              subtitle: const Text('Tus cobros anteriores'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/historial'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        const _SyncCard(),
        // Rechazos de sync persistidos: visible SOLO si hay (audit #5).
        const _RechazosSyncCard(),
        if (!kIsWeb) ...[
          const SizedBox(height: 12),
          const _ImpresoraCard(),
        ],
        // Las fotos de comprobantes son del flujo de cobro (sólo cobrador).
        if (!tecnicoMode) ...[
          const SizedBox(height: 12),
          const _FotosPendientesCard(),
        ],
        if (!kIsWeb) ...[
          const SizedBox(height: 12),
          const _MapaCacheCard(),
        ],
        const SizedBox(height: 24),
        OutlinedButton.icon(
          icon: const Icon(Icons.lock_outline),
          label: const Text('Cambiar contraseña'),
          onPressed: () => mostrarCambiarPasswordDialog(context),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.logout),
          label: const Text('Cerrar sesión'),
          onPressed: () => confirmarSignOut(context),
        ),
        const SizedBox(height: 16),
        const AppVersionLabel(),
      ],
    );
  }

  String _initials(String nombre) {
    final parts = nombre.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  String _rolDisplay(String rol) => switch (rol) {
        'admin' => 'Administrador',
        'admin_cobranza' => 'Admin de cobranza',
        'admin_usuarios' => 'Admin de usuarios',
        'admin_tickets' => 'Admin de tickets',
        'coordinador' => 'Coordinador técnico',
      'lectura' => 'Solo lectura',
        'cobrador' => 'Cobrador',
        'tecnico' => 'Técnico',
        'super_admin' => 'Dev',
        _ => rol,
      };
}

class _InfoCard extends StatelessWidget {
  const _InfoCard(this.filas);
  final List<(IconData?, String, String)> filas;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: filas
              .map((f) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        if (f.$1 != null)
                          Icon(f.$1, size: 18, color: scheme.outline),
                        const SizedBox(width: 12),
                        SizedBox(
                            width: 120,
                            child: Text(f.$2,
                                style: TextStyle(color: scheme.outline))),
                        Expanded(child: Text(f.$3)),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _ImpresoraCard extends ConsumerWidget {
  const _ImpresoraCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fav = ref.watch(impresoraFavoritaProvider).valueOrNull;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.print),
        title: const Text('Impresora térmica'),
        subtitle: Text(fav == null
            ? 'Sin configurar'
            : fav.nombre,
            style: fav == null
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/perfil/impresora'),
      ),
    );
  }
}

class _FotosPendientesCard extends ConsumerStatefulWidget {
  const _FotosPendientesCard();
  @override
  ConsumerState<_FotosPendientesCard> createState() =>
      _FotosPendientesCardState();
}

class _FotosPendientesCardState extends ConsumerState<_FotosPendientesCard> {
  bool _ejecutando = false;

  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  // La query no tiene parámetros dinámicos, así que late final alcanza.
  late final Stream<List<Map<String, dynamic>>> _pendientesStream;

  @override
  void initState() {
    super.initState();
    _pendientesStream = ps.db.watch(
      'SELECT COUNT(*) AS n FROM pagos '
      "WHERE foto_comprobante_path LIKE 'local://%' AND anulado = 0",
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _pendientesStream,
      initialData: const [],
      builder: (context, snap) {
        final pendientes = snap.data!.isEmpty
            ? 0
            : (snap.data!.first['n'] as num).toInt();
        if (pendientes == 0 && !_ejecutando) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        return Card(
          color: scheme.tertiaryContainer.withValues(alpha: 0.4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_upload, color: scheme.tertiary),
                    const SizedBox(width: 8),
                    Text('Fotos pendientes de subir',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 8),
                Text('$pendientes foto(s) están guardadas en este teléfono y '
                    'se subirán automáticamente cuando haya conexión.'),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    icon: _ejecutando
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                    label: Text(_ejecutando ? 'Subiendo...' : 'Intentar ahora'),
                    onPressed: _ejecutando ? null : _intentar,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _intentar() async {
    setState(() => _ejecutando = true);
    try {
      final n = await ref
          .read(fotoComprobanteServiceProvider)
          .sincronizarPendientes(forzar: true);
      if (mounted) {
        // Mostramos sólo el feedback positivo. Los errores de upload
        // los surfacea el listener global en app.dart (R8) — sino
        // mostraríamos dos SnackBars solapados con mensajes
        // contradictorios cuando la corrida es parcial.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(n == 0
              ? 'No hay fotos elegibles para subir ahora.'
              : '$n foto(s) subidas')),
        );
      }
    } catch (e) {
      // sincronizarPendientes captura sus propios errores de upload
      // y los emite por el stream. Si llegamos acá es algo inesperado
      // (provider disposed, etc.) — logueamos sin molestar al user.
      if (kDebugMode) debugPrint('_intentar: error inesperado: $e');
    } finally {
      if (mounted) setState(() => _ejecutando = false);
    }
  }
}

/// Tarjeta del mapa offline: muestra cuánto ocupa la caché de tiles en disco
/// y permite borrarla. Es la "válvula de seguridad" del modo sin-tope: el
/// disco crece sin techo mientras el cobrador navega, y desde acá puede ver
/// el peso y liberarlo manualmente. Solo se monta en nativo (gate kIsWeb en
/// el padre) porque en web la caché de disco no aplica.
class _MapaCacheCard extends StatefulWidget {
  const _MapaCacheCard();

  @override
  State<_MapaCacheCard> createState() => _MapaCacheCardState();
}

class _MapaCacheCardState extends State<_MapaCacheCard> {
  int? _bytes; // null = midiendo
  bool _borrando = false;

  @override
  void initState() {
    super.initState();
    _medir();
  }

  Future<void> _medir() async {
    final b = await MapTileCache.instance.cacheSizeBytes();
    if (mounted) setState(() => _bytes = b);
  }

  Future<void> _borrar() async {
    setState(() => _borrando = true);
    try {
      await MapTileCache.instance.clear();
      await _medir();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Caché del mapa borrada')),
        );
      }
    } finally {
      if (mounted) setState(() => _borrando = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vacio = (_bytes ?? 0) == 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.map_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                Text('Mapa offline',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _bytes == null
                  ? 'Calculando tamaño…'
                  : vacio
                      ? 'Sin tiles guardados todavía. El mapa se va guardando '
                          'en este dispositivo a medida que lo navegás con señal.'
                      : 'Ocupa ${_formatBytes(_bytes!)} en este dispositivo. '
                          'Son los tiles del mapa que navegaste, guardados para '
                          'verlos sin conexión.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                icon: _borrando
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.delete_outline),
                label: Text(_borrando ? 'Borrando…' : 'Borrar caché del mapa'),
                onPressed: (_borrando || vacio) ? null : _borrar,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncCard extends ConsumerWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sincronización',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            status.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(mensajeErrorHumano(e)),
              data: (s) {
                final connected = s?.connected ?? false;
                final last = s?.lastSyncedAt;
                // Audit F4 Sprint 1: si una subida está fallando y
                // reintentando, la UI se veía "sana" — única pista visible.
                final subiendoConError = s?.uploadError != null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(connected ? Icons.cloud_done : Icons.cloud_off,
                            color: connected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error),
                        const SizedBox(width: 8),
                        Text(connected ? 'Conectado' : 'Sin conexión'),
                      ],
                    ),
                    if (last != null) ...[
                      const SizedBox(height: 4),
                      Text(
                          'Última sincronización: ${Fmt.fechaCorta(last)} ${Fmt.hora(last)}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                    if (subiendoConError) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Hay cambios reintentando subirse. Si persiste, '
                        'avisale al administrador.',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Card "Cambios sin sincronizar": rechazos PERMANENTES del server que el
/// connector descartó de la cola (audit 2026-06-11, finding #5). Antes el
/// único rastro era un SnackBar de 6 segundos; ahora el aviso persiste acá
/// hasta que el usuario lo descarta a propósito. Si no hay rechazos, no
/// renderiza nada.
class _RechazosSyncCard extends ConsumerWidget {
  const _RechazosSyncCard();

  /// `fechaUtcIso` viene en UTC; se muestra en hora Nicaragua (UTC−6 sin
  /// DST). No usar `Fmt.fechaHoraNi` acá: ese helper es para timestamps
  /// local-naive (fecha_pago) y formatea sin shift.
  static String _fechaHoraNicaragua(String isoUtc) {
    final dt = DateTime.tryParse(isoUtc);
    if (dt == null) return isoUtc;
    final ni = dt.toUtc().subtract(const Duration(hours: 6));
    String dos(int v) => v.toString().padLeft(2, '0');
    return '${dos(ni.day)}/${dos(ni.month)}/${ni.year} '
        '${dos(ni.hour)}:${dos(ni.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rechazos = ref.watch(rechazosSyncProvider).valueOrNull ?? const [];
    if (rechazos.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final onColor = scheme.onErrorContainer;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sync_problem, color: onColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Cambios sin sincronizar (${rechazos.length})',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: onColor),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'El servidor rechazó estos cambios: lo que ves en este '
                'dispositivo puede NO coincidir con el servidor. Si es un '
                'cobro, avisale al administrador antes de descartar el aviso.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: onColor),
              ),
              const SizedBox(height: 4),
              for (final r in rechazos)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${r.tablaLabel} · ${r.opLabel}',
                    style: TextStyle(
                        color: onColor, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${r.mensajeHumano}\n${_fechaHoraNicaragua(r.fechaUtcIso)}',
                    style: TextStyle(color: onColor),
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.close, color: onColor),
                    tooltip: 'Descartar aviso',
                    onPressed: () =>
                        RechazosSyncService.instance.descartar(r.id),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('¿Descartar todos los avisos?'),
                        content: const Text(
                            'Los datos divergentes quedan como están; '
                            'esto solo borra los avisos.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancelar'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Descartar todos'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await RechazosSyncService.instance.limpiar();
                    }
                  },
                  child: Text('Descartar todos',
                      style: TextStyle(color: onColor)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

