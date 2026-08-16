import 'package:flutter/foundation.dart';
import '../../powersync/db.dart' as ps;

/// Mensaje humano para errores inesperados de cara al usuario (M14, audit
/// 2026-06-11): ~15 pantallas interpolaban `Error: $e` crudo (SQLite/
/// Postgres en inglés). El detalle técnico va a debugPrint; el usuario ve
/// español accionable. NO usar para errores ya humanizados.
///
/// Heurística (documentada — trade-off asumido):
///  1. Marcadores técnicos inequívocos (clases de excepción SQLite/Postgrest/
///     red, fragmentos de runtime) → mensaje genérico en español.
///  2. Sin caracteres del español (ñ/tildes/¿¡) y >80 chars → es inglés de
///     librería → genérico.
///  3. Contiene áéíóúñ¿¡ → ya viene humanizado por un throw del repo
///     ('El ajuste…', 'No se puede editar…', 'El ticket cambió…') → tal cual.
///  4. Sin tildes pero corto (<120) y empieza como oración (mayúscula) →
///     muy probablemente un throw nuestro sin tildes → tal cual. Un mensaje
///     corto de librería capitalizado se puede colar, pero es preferible a
///     tragarnos un throw propio legible.
///  5. Cualquier otra cosa → genérico.
String mensajeErrorHumano(Object error, {String? contexto}) {
  // Detalle técnico completo a consola para diagnóstico; nunca al usuario.
  debugPrint('mensajeErrorHumano: $error');

  // Guardia de solo lectura (0198): su toString ya es el mensaje final para el
  // usuario y no debe llevar el "no se pudo <contexto>" que arma el genérico —
  // no es que la operación falló, es que su rol no la permite.
  if (error is ps.SoloLecturaException) return error.toString();

  // `Exception:` y `Bad state:` (prefijo de StateError.toString()) son ruido de
  // Dart — el throw del repo ya trae el mensaje en español; mostramos solo eso.
  // ANCLADO al PREFIJO (`^`): si no, `replaceFirst('Exception: ')` cortaba en
  // cualquier posición y manglaba "SocketException: ..." → "SocketConnection..."
  // (perdía el marcador técnico y mostraba el garabato en vez del genérico).
  final raw = error
      .toString()
      .replaceFirst(RegExp(r'^(Exception|Bad state): '), '')
      .trim();
  final generico = 'Algo salió mal${contexto != null ? ' al $contexto' : ''}. '
      'Reintentá; si persiste, avisale al administrador.';
  if (raw.isEmpty) return generico;

  const marcadoresTecnicos = [
    'SqliteException',
    'PostgrestException',
    'SocketException',
    'TimeoutException',
    'no such column',
    'null check',
    'RangeError',
  ];
  if (marcadoresTecnicos.any(raw.contains) ||
      raw.toLowerCase().contains('database')) {
    return generico;
  }

  final tieneEspanol = RegExp('[áéíóúñÁÉÍÓÚÑ¿¡]').hasMatch(raw);
  if (!tieneEspanol && raw.length > 80) return generico;
  if (tieneEspanol) return raw;
  if (RegExp(r'^[A-Z]').hasMatch(raw) && raw.length < 120) return raw;
  return generico;
}
