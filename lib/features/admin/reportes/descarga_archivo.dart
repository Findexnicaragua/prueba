import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Guarda [bytes] en disco ofreciendo el diálogo nativo de guardado, para que
/// TODOS los exports de reportes (Excel y PDF) se comporten igual:
///   - Windows (y demás desktop): diálogo "Guardar como". file_picker devuelve
///     la ruta pero NO escribe el contenido, así que lo escribimos nosotros.
///   - Android: file_picker abre el selector de ubicación del sistema y guarda
///     el archivo con `bytes:`; devuelve la ruta (puede ser un content URI no
///     escribible por dart:io, por eso ahí NO reescribimos). No requiere
///     permisos de almacenamiento (el usuario elige la ubicación).
///   - Web: file_picker.saveFile no existe en la línea 8.x; como web no es un
///     target del producto, avisamos con un mensaje claro.
///
/// [fileName] debe incluir la extensión (ej. 'cobros_2026_06.pdf'); [extension]
/// es solo la extensión sin punto (ej. 'pdf' / 'xlsx') para el filtro del
/// diálogo. Devuelve la ruta donde se guardó, o `null` si el usuario canceló.
Future<String?> guardarArchivo({
  required String fileName,
  required List<int> bytes,
  required String extension,
}) async {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  if (kIsWeb) {
    throw UnsupportedError(
      'La descarga de archivos está disponible en la app de Windows o Android, '
      'no en la versión web.',
    );
  }

  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Guardar reporte',
    fileName: _conTimestamp(fileName),
    type: FileType.custom,
    allowedExtensions: [extension],
    // En Android/iOS file_picker escribe el archivo con estos bytes; en
    // desktop solo abre el diálogo (los bytes los escribimos abajo).
    bytes: data,
  );
  if (path == null) return null; // el usuario canceló el diálogo

  // En desktop file_picker devuelve la ruta pero NO escribe el contenido →
  // lo hacemos nosotros. En Android ya quedó escrito por el `bytes:` de arriba.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await File(path).writeAsBytes(data, flush: true);
  }
  return path;
}

/// Guarda un PDF de reporte vía [guardarArchivo] y, si el usuario no canceló,
/// muestra un SnackBar de confirmación (B9 — antes los PDF no avisaban del
/// guardado exitoso, solo de los errores; el Excel sí avisaba). Las excepciones
/// (ej. web `UnsupportedError`) se propagan para que el caller las muestre.
Future<void> guardarPdfConAviso(
  BuildContext context, {
  required String fileName,
  required List<int> bytes,
  String mensaje = 'Reporte PDF guardado',
}) async {
  final ruta = await guardarArchivo(
    fileName: fileName,
    bytes: bytes,
    extension: 'pdf',
  );
  if (ruta != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensaje)),
    );
  }
}

/// Inserta un timestamp (fecha + hora local) ANTES de la extensión para que
/// cada generación/reimpresión produzca un nombre DISTINTO (no se pisan ni se
/// confunden al reimprimir). Ej: 'clientes_2026_6.pdf' →
/// 'clientes_2026_6_2026-06-16_144237.pdf'. Aplica a TODO lo que pase por
/// [guardarArchivo] (reportes PDF + Excel + deuda de suspensión).
String _conTimestamp(String fileName) {
  final now = DateTime.now();
  String p2(int n) => n.toString().padLeft(2, '0');
  final ts = '${now.year}-${p2(now.month)}-${p2(now.day)}_'
      '${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
  final dot = fileName.lastIndexOf('.');
  return dot <= 0
      ? '${fileName}_$ts'
      : '${fileName.substring(0, dot)}_$ts${fileName.substring(dot)}';
}
