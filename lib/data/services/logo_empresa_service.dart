import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'imagen_compresion.dart';

/// Servicio para subir y obtener el logo de la empresa (tenant).
///
/// Bucket: `logos-empresa`, path `{tenant_id}/logo.{ext}`.
/// El admin sube el logo desde /admin/settings (tab Empresa).
/// El logo se muestra en el recibo y opcionalmente en el shell.
///
/// Patrón similar a `FotoClienteService`: subida síncrona (admin
/// trabaja online), URL firmada para visualización.
class LogoEmpresaService {
  LogoEmpresaService(this._supabase);
  final SupabaseClient _supabase;
  final _picker = ImagePicker();
  static const _bucket = 'logos-empresa';

  /// Abre el picker de imágenes y sube el logo al Storage.
  /// Devuelve el path remoto (`{tenantId}/logo.png`) o null si el
  /// usuario canceló. Lanza si Storage rechaza.
  Future<String?> pickYSubir({required String tenantId}) async {
    final raw = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 800,
      maxHeight: 800,
    );
    if (raw == null) return null;

    final bytes = await raw.readAsBytes();
    return subirBytes(bytes: bytes, tenantId: tenantId);
  }

  /// Sube bytes ya obtenidos (útil si el caller ya tiene los bytes,
  /// ej. desde un crop widget futuro).
  Future<String> subirBytes({
    required Uint8List bytes,
    required String tenantId,
  }) async {
    // Compresión client-side: garantiza 800px máx también en Windows (el
    // picker ahí ignora maxWidth/imageQuality) y que el archivo sea PNG
    // REAL (antes un JPEG elegido subía con nombre .png). Bucket de 1 MB.
    final comp = await comprimirImagen(bytes,
        maxLado: 800, calidad: 85, mantenerPng: true, maxBytes: 950 * 1024);
    // Siempre guardamos como .png para consistencia.
    final path = '$tenantId/logo.png';
    await _supabase.storage.from(_bucket).uploadBinary(
          path,
          comp.bytes,
          fileOptions:
              const FileOptions(upsert: true, contentType: 'image/png'),
        );
    return path;
  }

  /// URL firmada del logo (TTL 1h) para mostrar en UI.
  /// Retorna null si no hay logo o si falla.
  Future<String?> urlFirmada(String pathRemoto) async {
    try {
      return await _supabase.storage
          .from(_bucket)
          .createSignedUrl(pathRemoto, 3600);
    } catch (e) {
      if (kDebugMode) debugPrint('LogoEmpresa urlFirmada: $e');
      return null;
    }
  }

  /// Elimina el logo del Storage. Retorna true si se eliminó.
  Future<bool> eliminar(String pathRemoto) async {
    try {
      await _supabase.storage.from(_bucket).remove([pathRemoto]);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('LogoEmpresa eliminar: $e');
      return false;
    }
  }
}
