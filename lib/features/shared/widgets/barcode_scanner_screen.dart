import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Pantalla full-screen para escanear un código de barras / QR (mobile_scanner).
/// Devuelve el primer código leído (String) o null si se canceló.
///
/// SOLO se usa en Android/iOS: el caller gatea por plataforma (en Windows/web el
/// botón de escanear ni se muestra), así que esta pantalla nunca se abre ahí.
class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  /// Abre el scanner y devuelve el código leído (o null).
  static Future<String?> escanear(BuildContext context) =>
      Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => const BarcodeScannerScreen(),
        fullscreenDialog: true,
      ));

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final _controller = MobileScannerController();
  bool _devuelto = false; // evita devolver dos veces (detecciones repetidas)

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_devuelto) return;
    String? code;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        code = v.trim();
        break;
      }
    }
    if (code == null || !mounted) return;
    _devuelto = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear código'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            tooltip: 'Linterna',
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Guía visual del recuadro de lectura.
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const Positioned(
            bottom: 40,
            child: Text('Apuntá al código de barras / QR',
                style: TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
