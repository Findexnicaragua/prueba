import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/foto_comprobante_provider.dart';

/// Renderiza una foto del comprobante manejando ambos casos del path:
///   - `local://*` → carga bytes desde storage local (mobile)
///   - cualquier otro string → URL firmada del bucket Storage (cross-platform)
///
/// En web, las fotos `local://*` no son visibles (sólo existen en el
/// teléfono que las capturó); se muestra un placeholder.
class FotoComprobanteView extends ConsumerStatefulWidget {
  const FotoComprobanteView({
    super.key,
    required this.path,
    this.height = 200,
    this.borderRadius = 12,
  });

  final String? path;
  final double height;
  final double borderRadius;

  @override
  ConsumerState<FotoComprobanteView> createState() =>
      _FotoComprobanteViewState();
}

class _FotoComprobanteViewState extends ConsumerState<FotoComprobanteView> {
  Uint8List? _bytes;
  String? _urlFirmada;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _resolver();
  }

  @override
  void didUpdateWidget(covariant FotoComprobanteView old) {
    super.didUpdateWidget(old);
    if (widget.path != old.path) _resolver();
  }

  Future<void> _resolver() async {
    if (widget.path == null) {
      if (mounted) {
        setState(() {
          _bytes = null;
          _urlFirmada = null;
          _cargando = false;
        });
      }
      return;
    }
    setState(() => _cargando = true);
    final service = ref.read(fotoComprobanteServiceProvider);
    if (widget.path!.startsWith('local://')) {
      final b = await service.bytesLocal(widget.path!);
      if (mounted) {
        setState(() {
          _bytes = b;
          _urlFirmada = null;
          _cargando = false;
        });
      }
    } else {
      final url = await service.urlFirmada(widget.path!);
      if (mounted) {
        setState(() {
          _bytes = null;
          _urlFirmada = url;
          _cargando = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.path == null) return const SizedBox.shrink();
    if (_cargando) {
      return SizedBox(
        height: widget.height,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final radius = BorderRadius.circular(widget.borderRadius);
    final pendiente = widget.path!.startsWith('local://');

    Widget img;
    if (_bytes != null) {
      img = Image.memory(_bytes!, height: widget.height, fit: BoxFit.cover);
    } else if (_urlFirmada != null) {
      img = Image.network(
        _urlFirmada!,
        height: widget.height,
        fit: BoxFit.cover,
        // Si la URL expira o falla red, retry obteniendo nueva URL firmada.
        errorBuilder: (_, __, ___) => _placeholderError(context, 'Sin acceso'),
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return SizedBox(
            height: widget.height,
            child: const Center(child: CircularProgressIndicator()),
          );
        },
      );
    } else {
      // Path local pero estamos en web, o el archivo no existe en este dispositivo.
      return _placeholderError(
        context,
        pendiente ? 'Foto sólo en el dispositivo del cobrador' : 'No se pudo cargar',
      );
    }

    return Stack(
      children: [
        ClipRRect(borderRadius: radius, child: img),
        if (pendiente)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_upload,
                      size: 14,
                      color: Theme.of(context).colorScheme.onTertiary),
                  const SizedBox(width: 4),
                  Text(
                    'Pendiente de subir',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onTertiary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _placeholderError(BuildContext context, String mensaje) {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off,
                size: 32, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 4),
            Text(mensaje,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.outline, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
