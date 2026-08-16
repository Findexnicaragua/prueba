import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Invoca una Edge Function de Supabase y devuelve el body parseado
/// con manejo unificado de errores (R14).
///
/// Convención del proyecto: las Edge Functions devuelven
/// `{ok: bool, error?: String, ...}`. Este helper extrae el mensaje
/// real del campo `error` tanto en respuestas 200-ok=false como en
/// `FunctionException` (status != 200), evitando que el caller vea
/// el wrapper técnico `'FunctionException(status: 409, details:…)'`.
///
/// - Lanza `Exception(<mensaje legible>)` en caso de error.
/// - Retorna `Map<String, dynamic>` en caso de éxito (con `ok: true`
///   garantizado).
Future<Map<String, dynamic>> invokeEdgeFunction(
  SupabaseClient client,
  String name, {
  Map<String, dynamic>? body,
}) async {
  try {
    final res = await client.functions.invoke(name, body: body);
    final data = res.data as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('Sin respuesta del servidor');
    }
    if (data['ok'] != true) {
      throw Exception(
          (data['error'] as String?) ?? 'Error desconocido');
    }
    return data;
  } on FunctionException catch (e) {
    // Edge Function devolvió 4xx/5xx — el body parseado vive en
    // e.details. Extraemos el campo 'error' si está; sino fallback al
    // status para no mostrar string vacío.
    if (kDebugMode) {
      debugPrint(
          '[invokeEdgeFunction] FunctionException matched. status=${e.status}, details=${e.details}');
    }
    final det = e.details;
    String? mensaje;
    if (det is Map && det['error'] != null) {
      mensaje = det['error'].toString();
    }
    throw Exception(mensaje ?? 'Error ${e.status}');
  } catch (e) {
    // Defensive: si por algún motivo el `on FunctionException` no
    // capturó (versión del SDK que expone el tipo desde un namespace
    // distinto al re-exportado, wrap en otra exception, etc.), tratamos
    // de extraer el mensaje del toString. Sin esto el caller ve el
    // string completo `FunctionException(status: 400, details: {...})`
    // que era exactamente lo que R14 quería evitar.
    if (kDebugMode) {
      debugPrint(
          '[invokeEdgeFunction] generic catch. type=${e.runtimeType}, toString=$e');
    }
    final s = e.toString();
    if (s.contains('FunctionException')) {
      // Regex permisivo: cualquier cosa entre "error:" y el primer `}`.
      final match = RegExp(r'error:\s*([^}]+)').firstMatch(s);
      if (match != null) {
        final extracted = match.group(1)?.trim();
        if (extracted != null && extracted.isNotEmpty) {
          throw Exception(extracted);
        }
      }
    }
    rethrow;
  }
}

/// Convierte una excepción de una Edge Function en un mensaje legible para
/// mostrar al usuario. Cubre tres casos:
///   - `Exception("msg")` lanzado por [invokeEdgeFunction] → pela "Exception: ".
///   - `FunctionException` raw que se escapó (type mismatch en algunas versiones
///     del SDK) → extrae el campo `error` del toString con regex.
///   - Cualquier otra excepción → toString tal cual.
///
/// Helper único (B12): antes estaba copy-pasteado en varias pantallas.
String humanizarEdgeError(Object e) {
  final raw = e.toString();
  if (raw.startsWith('FunctionException')) {
    final match = RegExp(r'error:\s*([^}]+)').firstMatch(raw);
    if (match != null) {
      final extracted = match.group(1)?.trim();
      if (extracted != null && extracted.isNotEmpty) return extracted;
    }
  }
  return raw.replaceFirst('Exception: ', '');
}
