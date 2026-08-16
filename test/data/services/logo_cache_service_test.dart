import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/services/logo_cache_service.dart';

/// Guard que corta la fuga de egress del logo (35-62 GB/DÍA, 2026-07-27).
///
/// Historia: `refrescarLogo` bajaba el logo INCONDICIONALMENTE y colgaba del
/// listener de `ps.db.statusStream`, evaluado en `if (status.connected)`. Eso
/// no es "se conectó" sino "está conectado", y PowerSync lo re-emite ~25 veces
/// por minuto → ~12.000 descargas de 567 KB por equipo por jornada.
///
/// El primer parche (un flag en memoria por corrida) bajó la fuga a una
/// descarga por arranque, pero NO cubría dos casos reales:
///   1. reiniciar la app volvía a bajar (el flag vivía en memoria);
///   2. `logoEmpresaBytesProvider` bajaba por su cuenta en cada recibo cuando
///      el disco estaba vacío, salteándose el cache entero.
///
/// El diseño definitivo versiona el archivo contra la fila que sincroniza
/// PowerSync (`path|updated_at`) y persiste esa versión EN DISCO, así el
/// "¿hace falta bajar?" sobrevive reinicios. Acá se prueban las dos funciones
/// puras que sostienen la decisión — sin Supabase ni filesystem.
void main() {
  group('token de versión del logo', () {
    test('el path solo NO alcanza: el archivo se pisa en la misma ruta', () {
      // El caso que rompía: el admin sube un logo nuevo a `{tenant}/logo.png`.
      // Mismo path, contenido distinto. Si la versión fuera el path, el
      // cliente se quedaría con el logo viejo para siempre.
      final antes = LogoCacheService.tokenDe('t1/logo.png', '2026-01-01');
      final despues = LogoCacheService.tokenDe('t1/logo.png', '2026-07-29');
      expect(antes, isNot(despues));
    });

    test('mismo path y misma fecha dan el mismo token', () {
      expect(LogoCacheService.tokenDe('t1/logo.png', '2026-01-01'),
          LogoCacheService.tokenDe('t1/logo.png', '2026-01-01'));
    });

    test('cambiar de archivo también cambia el token', () {
      expect(LogoCacheService.tokenDe('t1/logo.png', 'x'),
          isNot(LogoCacheService.tokenDe('t1/otro.png', 'x')));
    });

    test('sin updated_at el token sigue siendo estable', () {
      // Tenant migrado desde una versión vieja: la fila puede no traer fecha.
      // No debe explotar ni generar un token distinto en cada llamada.
      expect(LogoCacheService.tokenDe('t1/logo.png', null),
          LogoCacheService.tokenDe('t1/logo.png', null));
    });
  });

  group('el guard que decide si se toca la red', () {
    const token = 't1/logo.png|2026-07-29';

    test('mismo token y bytes en disco: el cache alcanza, no se toca la red',
        () {
      expect(
          LogoCacheService.sirveCache(
              tokenGuardado: token, tokenPedido: token, hayBytes: true),
          isTrue);
    });

    test('la ráfaga del observador NO vuelve a bajar', () {
      // El escenario exacto de la fuga: el disparador emitiendo sin parar.
      // Cada emisión tiene que resolverse local y gratis.
      for (var i = 0; i < 500; i++) {
        expect(
            LogoCacheService.sirveCache(
                tokenGuardado: token, tokenPedido: token, hayBytes: true),
            isTrue,
            reason: 'la emisión $i habría salido a la red');
      }
    });

    test('el admin cambió el logo: hay que bajar', () {
      expect(
          LogoCacheService.sirveCache(
              tokenGuardado: 't1/logo.png|2026-01-01',
              tokenPedido: token,
              hayBytes: true),
          isFalse);
    });

    test('versión al día pero SIN archivo: hay que bajar', () {
      // Cubre el marcador huérfano (alguien borró el png, el disco se llenó,
      // el save falló). Sin este caso se serviría un logo que no existe.
      expect(
          LogoCacheService.sirveCache(
              tokenGuardado: token, tokenPedido: token, hayBytes: false),
          isFalse);
    });

    test('archivo sin marcador de versión: hay que bajar', () {
      // App actualizada desde una versión anterior: el png está en disco pero
      // nadie anotó de qué versión es. No se puede asumir que está al día.
      expect(
          LogoCacheService.sirveCache(
              tokenGuardado: null, tokenPedido: token, hayBytes: true),
          isFalse);
    });
  });
}
