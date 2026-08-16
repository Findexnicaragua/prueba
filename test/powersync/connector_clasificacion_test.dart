/// Tests de `esCodigoNoRetryable` — la clasificación de errores del upload
/// de la CRUD queue (audit 2026-06-11, finding #1 CRITICAL).
///
/// La regla que blindan: descartar un write es PERDERLO para siempre en el
/// server (el cobro queda solo en el SQLite del cobrador), así que solo se
/// descartan errores PERMANENTES de cliente (allowlist SQLSTATE). Todo lo
/// transitorio o desconocido se reintenta.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/powersync/connector.dart';

void main() {
  group('esCodigoNoRetryable — permanentes (se descartan con aviso)', () {
    test('P0001 raise_exception de triggers de negocio', () {
      expect(esCodigoNoRetryable('P0001'), isTrue);
    });
    test('23xxx integrity constraint (unique/FK/not-null/check)', () {
      expect(esCodigoNoRetryable('23505'), isTrue); // unique_violation
      expect(esCodigoNoRetryable('23503'), isTrue); // foreign_key_violation
      expect(esCodigoNoRetryable('23502'), isTrue); // not_null_violation
      expect(esCodigoNoRetryable('23514'), isTrue); // check_violation
    });
    test('42xxx schema/permiso (RLS denied, columna inexistente)', () {
      expect(esCodigoNoRetryable('42501'), isTrue); // insufficient_privilege
      expect(esCodigoNoRetryable('42P01'), isTrue); // undefined_table
      expect(esCodigoNoRetryable('42703'), isTrue); // undefined_column
    });
    test('22xxx formato de dato inválido', () {
      expect(esCodigoNoRetryable('22P02'), isTrue); // invalid_text_representation
      expect(esCodigoNoRetryable('22001'), isTrue); // string_data_right_truncation
    });
  });

  group('esCodigoNoRetryable — transitorios (se REINTENTAN, nunca se pierden)',
      () {
    test('PGRST301 JWT expirado (el bug del audit: cobro offline + token '
        'vencido al recuperar señal)', () {
      expect(esCodigoNoRetryable('PGRST301'), isFalse);
    });
    test('PGRST000/PGRST002 DB no disponible / schema cache cargando', () {
      expect(esCodigoNoRetryable('PGRST000'), isFalse);
      expect(esCodigoNoRetryable('PGRST002'), isFalse);
    });
    test('PGRST204 columna desconocida: bloquea la cola hasta la migración '
        '(decisión: preservar el dato, no descartarlo)', () {
      expect(esCodigoNoRetryable('PGRST204'), isFalse);
    });
    test('clase 40 transaction rollback (serialization/deadlock)', () {
      expect(esCodigoNoRetryable('40001'), isFalse);
      expect(esCodigoNoRetryable('40P01'), isFalse);
      expect(esCodigoNoRetryable('40003'), isFalse);
    });
    test('códigos HTTP string (3 chars) nunca matchean la allowlist SQLSTATE',
        () {
      expect(esCodigoNoRetryable('408'), isFalse); // request timeout
      expect(esCodigoNoRetryable('429'), isFalse); // rate limit (¡empieza con 42!)
      expect(esCodigoNoRetryable('404'), isFalse);
      expect(esCodigoNoRetryable('422'), isFalse); // ¡empieza con 22!
      expect(esCodigoNoRetryable('500'), isFalse);
      expect(esCodigoNoRetryable('502'), isFalse);
    });
    test('null / vacío / desconocidos → retryable', () {
      expect(esCodigoNoRetryable(null), isFalse);
      expect(esCodigoNoRetryable(''), isFalse);
      expect(esCodigoNoRetryable('23'), isFalse); // truncado, no es SQLSTATE
      expect(esCodigoNoRetryable('XX000'), isFalse); // internal_error: transitorio
      expect(esCodigoNoRetryable('57014'), isFalse); // query_canceled (timeout)
      expect(esCodigoNoRetryable('P0002'), isFalse); // no_data_found: no es P0001
    });
  });

  // ── Choque de correlativo de recibo ───────────────────────────────────────
  // 23505 sigue siendo "permanente" en la clasificación general, pero el
  // connector lo intercepta ANTES para el caso `recibos` y lo reintenta con el
  // próximo número. Este grupo fija la premisa de esa rama: si alguien cambiara
  // la clasificación de 23505, el reintento dejaría de tener sentido.
  group('correlativo de recibo (23505)', () {
    test('sigue clasificado como permanente', () {
      // Si esto pasa a false, el batch reintentaría solo y en bucle: el
      // reintento con número nuevo del connector es lo que lo resuelve.
      expect(esCodigoNoRetryable('23505'), isTrue);
    });

    test('el resto de la clase 23 también es permanente', () {
      for (final c in ['23502', '23503', '23514']) {
        expect(esCodigoNoRetryable(c), isTrue, reason: c);
      }
    });
  });
}
