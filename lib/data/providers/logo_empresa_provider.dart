import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../repositories/settings_repo.dart';
import '../services/logo_cache_service.dart';
import '../services/logo_empresa_service.dart';
import 'cobrador_provider.dart';

/// Servicio singleton de logo (usa el SupabaseClient global).
final logoEmpresaServiceProvider = Provider<LogoEmpresaService>((ref) {
  return LogoEmpresaService(Supabase.instance.client);
});

/// URL firmada del logo de la empresa. Se refresca cuando cambia
/// `empresa.logo_path` en settings (reactivo vía settingsMapProvider).
///
/// Retorna null si no hay logo configurado o si la firma falla.
/// TTL de la URL: 1h (el provider se invalida antes si el setting cambia).
final logoEmpresaUrlProvider = FutureProvider<String?>((ref) async {
  final settings = ref.watch(appSettingsProvider);
  final path = settings.empresaLogoPath;

  if (path.isEmpty) return null;

  final service = ref.read(logoEmpresaServiceProvider);
  return service.urlFirmada(path);
});

/// BYTES del logo de la empresa (PNG/JPG) o null si no hay logo.
///
/// Es la fuente del logo para `ReciboTicket` (preview + impresión térmica) —
/// el widget se captura a imagen offline, así que necesita BYTES, no una URL.
///
/// Delega TODO en `LogoCacheService.obtenerLogo`, que es la única puerta al
/// bucket: decide contra la versión en disco si hace falta red, y si hay algo
/// servible lo devuelve sin esperarla.
///
/// ⚠️ Antes este provider bajaba del bucket POR SU CUENTA cuando el disco
/// estaba vacío (`storage.download` inline). Como corre en cada recibo y en el
/// header de cada reporte, eso era una segunda fuga de egress: con el cache de
/// disco vacío, cada impresión se bajaba el logo entero. La regla que lo
/// prohíbe está en `AUDIT-PROFUNDO.md` — ninguna pantalla habla con Storage
/// directo; se pide por el servicio, que es quien sabe si hace falta.
///
/// Reactivo: se refresca cuando cambia `empresa.logo_path` O su `updated_at`
/// (el path es siempre el mismo archivo, así que la versión es lo que importa).
final logoEmpresaBytesProvider = FutureProvider<Uint8List?>((ref) async {
  final settings = ref.watch(appSettingsProvider);
  final path = settings.empresaLogoPath;
  if (path.isEmpty) return null;

  final tenantId = ref.watch(tenantIdProvider);
  if (tenantId == null || tenantId.isEmpty) return null;

  return LogoCacheService().obtenerLogo(
    tenantId: tenantId,
    logoPath: path,
    version: settings.empresaLogoVersion,
  );
});
