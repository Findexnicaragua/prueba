import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/providers/update_provider.dart';
import '../../../data/services/update_service.dart';

/// Banner que aparece en la parte superior de cualquier shell cuando
/// hay una actualización disponible. Muestra versión + release notes
/// + botón "Actualizar" que descarga e instala IN-APP (2026-06-09):
///
///   1. Descarga el binario DENTRO de la app con barra de progreso
///      (antes se delegaba a Chrome/browser y en Android la descarga
///      moría en las redirecciones de GitHub).
///   2. Al terminar lanza el instalador del sistema (Android: diálogo
///      "¿Instalar?"; Windows: App Installer del .msix).
///
/// En web (sin filesystem) mantiene el fallback de abrir el link en el
/// browser. Si la descarga in-app falla, ofrece reintentar o abrir en el
/// navegador como plan B.
///
/// Se oculta si no hay update, si el check falló, o si el user lo
/// descartó (dismiss por sesión, reaparece al reiniciar la app). El
/// dismiss se bloquea mientras descarga (evita una descarga huérfana).
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  bool _dismissed = false;
  bool _descargando = false;
  bool _instalando = false; // lanzando el instalador del sistema / pidiendo permiso
  double? _progreso; // null mientras descarga = indeterminado
  String? _error;

  // Ocupado = sin botones ni dismiss (evita doble-descarga / abandono a medias).
  bool get _ocupado => _descargando || _instalando;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final updateAsync = ref.watch(updateAvailableProvider);

    return updateAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (update) {
        if (update == null) return const SizedBox.shrink();

        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.primary,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.system_update,
                        size: 20, color: scheme.onPrimary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _descargando
                                ? 'Descargando v${update.version}…'
                                : _instalando
                                    ? 'Abriendo instalador…'
                                    : 'Actualización disponible v${update.version}',
                            style: TextStyle(
                              color: scheme.onPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          if (_error != null)
                            Text(
                              _error!,
                              style: TextStyle(
                                color: scheme.onPrimary,
                                fontSize: 11,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    if (!_ocupado) ...[
                      TextButton(
                        onPressed: () => _actualizar(update),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.onPrimary,
                        ),
                        child: Text(_error == null ? 'Actualizar' : 'Reintentar'),
                      ),
                      // Plan B tras un error: descarga clásica por browser.
                      if (_error != null)
                        TextButton(
                          onPressed: () => _abrirEnNavegador(update.downloadUrl),
                          style: TextButton.styleFrom(
                            foregroundColor:
                                scheme.onPrimary.withValues(alpha: 0.8),
                          ),
                          child: const Text('Navegador'),
                        ),
                      IconButton(
                        icon: Icon(Icons.close,
                            size: 18,
                            color: scheme.onPrimary.withValues(alpha: 0.8)),
                        onPressed: () => setState(() => _dismissed = true),
                        tooltip: 'Cerrar',
                      ),
                    ] else if (_descargando && _progreso != null)
                      Text(
                        '${(_progreso!.clamp(0.0, 1.0) * 100).round()}%',
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
                if (_descargando) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: _progreso, // null = indeterminado
                    backgroundColor: scheme.onPrimary.withValues(alpha: 0.25),
                    color: scheme.onPrimary,
                    minHeight: 4,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _actualizar(AppUpdate update) async {
    // Web: sin filesystem → descarga clásica del browser (única opción).
    if (kIsWeb) {
      await _abrirEnNavegador(update.downloadUrl);
      return;
    }

    setState(() {
      _descargando = true;
      _progreso = null;
      _error = null;
    });

    try {
      final archivo = await UpdateService.descargarActualizacion(
        update,
        onProgress: (p) {
          if (mounted) setState(() => _progreso = p);
        },
      );
      if (!mounted) return;
      // Sigue OCUPADO durante la instalación: en Android el permiso manda al
      // user a Ajustes (minutos) y no queremos que un segundo tap dispare otra
      // descarga en paralelo. El botón reaparece solo si instalar() falla.
      setState(() {
        _descargando = false;
        _instalando = true;
      });

      final error = await UpdateService.instalar(archivo);
      if (!mounted) return;
      setState(() {
        _instalando = false;
        _error = error; // null si se lanzó OK
      });
      // Si se lanzó OK, el instalador del sistema toma el control (en
      // Android la app pasa a background; en Windows se abre App Installer).
      // El banner queda como está — si el user cancela la instalación,
      // puede tocar Actualizar de nuevo (la re-descarga pisa el archivo).
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _descargando = false;
        _instalando = false;
        _error = e is Exception
            ? e.toString().replaceFirst('Exception: ', '')
            : 'La descarga falló. Verificá tu conexión y reintentá.';
      });
    }
  }

  Future<void> _abrirEnNavegador(String url) async {
    final uri = Uri.parse(url);
    // No usar canLaunchUrl — en Android 11+ requiere <queries>
    // en AndroidManifest y retorna false sin ellas. launchUrl
    // funciona directo sin esa declaración.
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
