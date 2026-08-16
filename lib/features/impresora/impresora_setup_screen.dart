import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/providers/impresora_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/impresora/impresora_service.dart';
import '../../data/utils/errores.dart';
import '../shared/widgets/empty_state.dart';
import 'impresora_sistema_setup.dart';

/// Pantalla de configuración de impresora Bluetooth.
/// - Lista impresoras pareadas en el sistema operativo.
/// - Permite elegir una como favorita (persistida con shared_preferences).
/// - Botón 'Imprimir prueba' para validar conexión + papel.
class ImpresoraSetupScreen extends ConsumerStatefulWidget {
  const ImpresoraSetupScreen({super.key});

  @override
  ConsumerState<ImpresoraSetupScreen> createState() =>
      _ImpresoraSetupScreenState();
}

class _ImpresoraSetupScreenState extends ConsumerState<ImpresoraSetupScreen> {
  bool _cargando = true;
  bool _btEnabled = false;
  bool _permisosOk = false;
  List<ImpresoraBT> _pareadas = const [];
  String? _error;
  // Lock para prevenir doble-tap en imprimir prueba.
  final Set<String> _probandoMacs = {};

  @override
  void initState() {
    super.initState();
    _refrescar();
  }

  /// Pide permisos de Bluetooth en Android 12+. En iOS los pide el SO al
  /// primer uso. En web no aplica.
  Future<bool> _pedirPermisos() async {
    if (kIsWeb) return true;
    try {
      final connect = await Permission.bluetoothConnect.request();
      final scan = await Permission.bluetoothScan.request();
      // En Android 11- estos permisos no existen y devuelven granted.
      return connect.isGranted && scan.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refrescar() async {
    setState(() {
      _cargando = true;
      _error = null;
      _pareadas = const [];
    });
    try {
      _permisosOk = await _pedirPermisos();
      if (!_permisosOk) {
        setState(() => _cargando = false);
        return;
      }
      final service = ref.read(impresoraServiceProvider);
      _btEnabled = await service.isBluetoothEnabled();
      if (!_btEnabled) {
        setState(() => _cargando = false);
        return;
      }
      _pareadas = await service.listarPareadas();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _seleccionar(ImpresoraBT bt) async {
    await ref
        .read(impresoraFavoritaProvider.notifier)
        .guardar(bt.mac, bt.nombre);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impresora "${bt.nombre}" guardada')),
      );
    }
  }

  Future<void> _imprimirPrueba(ImpresoraBT bt) async {
    // Guard contra doble-tap (otra impresión en curso a la misma MAC).
    if (_probandoMacs.contains(bt.mac)) return;
    setState(() {
      _probandoMacs.add(bt.mac);
      _error = null;
    });
    final ancho = ref.read(appSettingsProvider).formatoReciboMm;
    final service = ref.read(impresoraServiceProvider);
    try {
      final ok = await service.imprimirPrueba(
        macImpresora: bt.mac,
        anchoMm: ancho,
        envioLento: ref.read(impresoraEnvioLentoProvider).valueOrNull ?? false,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? 'Prueba enviada' : 'No se pudo conectar')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _probandoMacs.remove(bt.mac));
    }
  }

  @override
  Widget build(BuildContext context) {
    // DESKTOP (Windows): impresoras del SISTEMA (USB/red), no Bluetooth. El
    // camino BT de abajo queda SOLO para mobile.
    if (impresionPorSistema) {
      return const ImpresoraSistemaSetup();
    }

    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text('Impresora')),
        body: const EmptyState(
          icon: Icons.print_disabled,
          titulo: 'Sólo disponible en mobile',
          descripcion: 'La impresión Bluetooth térmica requiere la app móvil.',
        ),
      );
    }

    final favoritaAsync = ref.watch(impresoraFavoritaProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Impresora térmica'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Buscar impresoras', onPressed: _refrescar),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                favoritaAsync.when(
                  data: (f) => f == null
                      ? _FavoritaEmpty()
                      : _FavoritaCard(
                          favorita: f,
                          onLimpiar: () => ref
                              .read(impresoraFavoritaProvider.notifier)
                              .limpiar(),
                          onProbar: () => _imprimirPrueba(
                              ImpresoraBT(nombre: f.nombre, mac: f.mac)),
                        ),
                  loading: () => const SizedBox.shrink(),
                  error: (e, _) => Text(mensajeErrorHumano(e)),
                ),
                const SizedBox(height: 16),
                const _ModoImpresionSelector(),
                const SizedBox(height: 16),
                const _EnvioLentoToggle(),
                if (!_permisosOk)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.no_encryption),
                              SizedBox(width: 12),
                              Expanded(child: Text(
                                  'Permisos de Bluetooth denegados')),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                              'La app necesita permiso de Bluetooth para ver '
                              'las impresoras emparejadas. Activalo en '
                              'Ajustes del teléfono.'),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.settings),
                            label: const Text('Abrir ajustes'),
                            onPressed: () => openAppSettings(),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (!_btEnabled)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(Icons.bluetooth_disabled),
                          SizedBox(width: 12),
                          Expanded(child: Text(
                              'Bluetooth desactivado. Encendelo y refrescá.')),
                        ],
                      ),
                    ),
                  )
                else ...[
                  Text('Impresoras pareadas',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_pareadas.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                                'No hay impresoras pareadas en este dispositivo.'),
                            const SizedBox(height: 8),
                            Text(
                              'Andá a Ajustes → Bluetooth del sistema y pareá '
                              'la impresora primero. Después tocá refrescar aquí.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ..._pareadas.map((bt) => Card(
                          child: ListTile(
                            leading: const Icon(Icons.print),
                            title: Text(bt.nombre),
                            subtitle: Text(bt.mac,
                                style: const TextStyle(
                                    fontSize: 11, fontFamily: 'monospace')),
                            trailing: PopupMenuButton<String>(
                              onSelected: (a) {
                                if (a == 'fav') _seleccionar(bt);
                                if (a == 'test') _imprimirPrueba(bt);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'fav',
                                  child: Text('Usar como predeterminada'),
                                ),
                                PopupMenuItem(
                                  value: 'test',
                                  child: Text('Imprimir prueba'),
                                ),
                              ],
                            ),
                          ),
                        )),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// Selector del MODO de impresión de ESTE dispositivo (por-dispositivo). Solo
/// aparece si el super_admin habilitó AMBOS modos en el tenant; si no, se usa el
/// único disponible (Imagen por defecto) y no hay nada que elegir.
class _ModoImpresionSelector extends ConsumerWidget {
  const _ModoImpresionSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appSettingsProvider);
    // Sin Compatible habilitado por el super_admin no hay nada que elegir.
    if (!s.modoCompatibleHabilitado) return const SizedBox.shrink();
    final ambos = s.modoImagenHabilitado && s.modoCompatibleHabilitado;
    final modo = ref.watch(impresoraModoProvider).valueOrNull ?? 'imagen';
    // Modo EFECTIVO (espeja el dispatch de recibo_screen): Compatible corre si
    // es el único habilitado o si este dispositivo lo eligió.
    final efectivoCompatible =
        s.modoCompatibleHabilitado && (!s.modoImagenHabilitado || modo == 'compatible');
    final tildesModo =
        ref.watch(impresoraTildesModoProvider).valueOrNull ?? 'cp850';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Modo de impresión',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Cómo se manda el recibo a esta impresora.',
                style: Theme.of(context).textTheme.bodySmall),
            if (ambos) ...[
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'imagen',
                      label: Text('Imagen'),
                      icon: Icon(Icons.photo)),
                  ButtonSegment(
                      value: 'compatible',
                      label: Text('Compatible'),
                      icon: Icon(Icons.text_fields)),
                ],
                selected: {modo},
                onSelectionChanged: (sel) => ref
                    .read(impresoraModoProvider.notifier)
                    .guardar(sel.first),
              ),
              const SizedBox(height: 8),
              Text(
                modo == 'compatible'
                    ? 'Texto nativo, más liviano. Para impresoras que imprimen '
                        'basura o caracteres chinos.'
                    : 'Fidelidad perfecta (diseño + logo). Para impresoras que '
                        'andan bien.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            // Estrategia de tildes por-dispositivo del modo compatible. Tres
            // niveles según qué tan roto esté el firmware: Normal (CP850) →
            // China (pares GBK nativos) → Sin tildes (ASCII infalible).
            if (efectivoCompatible) ...[
              const SizedBox(height: 16),
              const Text('Tildes (acentos)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'cp850', label: Text('Estándar')),
                  ButtonSegment(value: 'latin1', label: Text('Occidental')),
                  ButtonSegment(value: 'gbk', label: Text('Alternativo')),
                  // "Sin tildes" (no "Simplificado"): mismo rótulo que la
                  // pantalla de Windows — es el MISMO provider por-dispositivo,
                  // dos nombres para el mismo ajuste confundían.
                  ButtonSegment(value: 'ascii', label: Text('Sin tildes')),
                ],
                selected: {tildesModo},
                onSelectionChanged: (sel) => ref
                    .read(impresoraTildesModoProvider.notifier)
                    .guardar(sel.first),
              ),
              const SizedBox(height: 8),
              Text(
                switch (tildesModo) {
                  'latin1' =>
                    'Igual que Estándar pero con la tabla occidental de '
                        'Windows. Para modelos que no traen la Estándar.',
                  'gbk' =>
                    'Acentos y eñes mediante el juego de caracteres interno '
                        'de la impresora. Para modelos que muestran símbolos '
                        'extraños en el modo Estándar. Las vocales acentuadas '
                        'salen levemente más anchas.',
                  'ascii' =>
                    'Imprime sin acentos (a, e, i, o, u, n). Máxima '
                        'compatibilidad con cualquier impresora.',
                  _ => 'Acentos mediante la tabla de caracteres internacional. '
                      'Recomendado. Si la impresora muestra símbolos extraños '
                      'en las tildes, probá "Alternativo".',
                },
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Toggle de ENVÍO LENTO de ESTE dispositivo (opt-in, default OFF). Para
/// impresoras lentas/baratas que cortan el FINAL del recibo (el pie sale en
/// blanco): manda los datos en tandas con pausas y espera antes de desconectar.
/// Con OFF el envío es idéntico al de siempre — las impresoras que ya andan
/// bien no se tocan.
class _EnvioLentoToggle extends ConsumerWidget {
  const _EnvioLentoToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activo = ref.watch(impresoraEnvioLentoProvider).valueOrNull ?? false;
    return Card(
      child: SwitchListTile(
        title: const Text('Envío lento',
            style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          activo
              ? 'Se espera unos segundos antes de desconectar, para que la '
                  'impresora reciba el trabajo completo.'
              : 'Activalo si esta impresora corta el final del recibo '
                  '(el pie sale en blanco). No afecta a otros dispositivos.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        value: activo,
        onChanged: (v) =>
            ref.read(impresoraEnvioLentoProvider.notifier).guardar(v),
      ),
    );
  }
}

class _FavoritaEmpty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.info_outline),
            SizedBox(width: 12),
            Expanded(child: Text(
                'Sin impresora predeterminada. Elegí una de la lista de abajo.')),
          ],
        ),
      ),
    );
  }
}

class _FavoritaCard extends StatelessWidget {
  const _FavoritaCard({
    required this.favorita,
    required this.onLimpiar,
    required this.onProbar,
  });
  final ImpresoraFavorita favorita;
  final VoidCallback onLimpiar;
  final VoidCallback onProbar;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Impresora predeterminada',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.check_circle),
                const SizedBox(width: 8),
                Expanded(child: Text(favorita.nombre)),
              ],
            ),
            const SizedBox(height: 4),
            Text(favorita.mac,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.print),
                    label: const Text('Prueba'),
                    onPressed: onProbar,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.link_off),
                    label: const Text('Quitar'),
                    onPressed: onLimpiar,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
