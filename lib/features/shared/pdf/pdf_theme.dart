import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

// ---------------------------------------------------------------------------
// Tema compartido de PDF — embebe NotoSans (Regular + Bold) en TODOS los
// PDFs (recibos + reportes).
//
// El paquete `pdf` por defecto usa una Helvetica interna SIN glifos para
// varios símbolos que la app sí emite (— – · • €), que salían como ⊠ (tofu).
// NotoSans cubre tildes, ñ, ¿ ¡ ü, em/en-dash, middot, bullet y euro.
//
// Las 2 fuentes vienen bundleadas como assets (declaradas en pubspec):
//   assets/fonts/NotoSans-Regular.ttf
//   assets/fonts/NotoSans-Bold.ttf
// ---------------------------------------------------------------------------

/// Cache memoizado: las fuentes se cargan UNA sola vez por sesión.
/// Se guarda el `Future` (no el `ThemeData` resuelto) para que llamadas
/// concurrentes durante la primera carga compartan el mismo `rootBundle.load`
/// en vuelo en lugar de dispararlo dos veces (reentrante/seguro).
Future<pw.ThemeData>? _temaFuture;

/// Devuelve el `ThemeData` con NotoSans embebido. Cachea el resultado:
/// el asset se lee del bundle solo en la primera invocación.
Future<pw.ThemeData> pdfTheme() {
  return _temaFuture ??= _cargarTema();
}

Future<pw.ThemeData> _cargarTema() async {
  final regular = pw.Font.ttf(
    await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
  );
  final bold = pw.Font.ttf(
    await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
  );
  return pw.ThemeData.withFont(base: regular, bold: bold);
}
