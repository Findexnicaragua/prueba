import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../../data/utils/errores.dart';

/// Pad de firma simple, SIN dependencias: se dibuja con el dedo (Android) o el
/// mouse (Windows) sobre un canvas blanco; "Guardar" exporta a PNG vía
/// `RepaintBoundary.toImage`. Devuelve los bytes PNG, o null si se canceló /
/// no se firmó nada.
///
/// Se usa para la firma del cliente al resolver un ticket; el PNG se sube como un
/// `ticket_adjunto` (reusa el bucket/sync/RLS de adjuntos). Requiere conexión para
/// subir, igual que las fotos del ticket (limitación heredada, no nueva).
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key, this.titulo = 'Firma del cliente'});
  final String titulo;

  /// Abre el pad full-screen y devuelve los bytes PNG (o null).
  static Future<Uint8List?> capturar(BuildContext context,
          {String titulo = 'Firma del cliente'}) =>
      showDialog<Uint8List>(
        context: context,
        useSafeArea: false,
        builder: (_) => Dialog.fullscreen(child: SignaturePad(titulo: titulo)),
      );

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<SignaturePad> {
  final _boundaryKey = GlobalKey();
  // Trazos: cada trazo es una lista de puntos. Levantar el dedo empieza un trazo
  // nuevo, así no se unen con una línea.
  final List<List<Offset>> _trazos = [];
  bool _guardando = false;

  Future<void> _guardar() async {
    if (_trazos.isEmpty) {
      Navigator.pop(context); // sin firma → cancela (devuelve null)
      return;
    }
    setState(() => _guardando = true);
    try {
      final boundary = _boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted) return;
      Navigator.pop(context, data?.buffer.asUint8List());
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.titulo),
        leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context)),
        actions: [
          TextButton(
            onPressed:
                _trazos.isEmpty ? null : () => setState(() => _trazos.clear()),
            child: const Text('Borrar'),
          ),
          TextButton(
            onPressed: _guardando ? null : _guardar,
            child: const Text('Guardar'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Firmá en el recuadro', style: TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: RepaintBoundary(
                key: _boundaryKey,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: GestureDetector(
                    onPanStart: (d) =>
                        setState(() => _trazos.add([d.localPosition])),
                    onPanUpdate: (d) => setState(() {
                      if (_trazos.isNotEmpty) _trazos.last.add(d.localPosition);
                    }),
                    child: CustomPaint(
                      painter: _FirmaPainter(_trazos),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FirmaPainter extends CustomPainter {
  _FirmaPainter(this.trazos);
  final List<List<Offset>> trazos;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final trazo in trazos) {
      for (var i = 0; i < trazo.length - 1; i++) {
        canvas.drawLine(trazo[i], trazo[i + 1], paint);
      }
      if (trazo.length == 1) {
        canvas.drawPoints(ui.PointMode.points, trazo, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_FirmaPainter old) => true;
}
