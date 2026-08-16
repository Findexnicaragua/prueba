/// Tests de `RechazosSyncService` — persistencia y humanización de los
/// writes rechazados por el server (audit 2026-06-11, finding #5).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/services/rechazos_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

RechazoSync _rechazo(String id, {String tabla = 'pagos'}) => RechazoSync(
      id: id,
      tabla: tabla,
      registroId: 'reg-$id',
      op: 'put',
      codigo: '23505',
      mensaje: 'duplicate key value violates unique constraint',
      fechaUtcIso: DateTime.now().toUtc().toIso8601String(),
      data: const {'monto_cordobas': 500},
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('humanizarRechazoSync', () {
    test('P0001 (trigger de negocio): pasa el mensaje del server tal cual '
        '(ya viene en español)', () {
      expect(
        humanizarRechazoSync('P0001', 'Transición de estado inválida: a → b'),
        'Transición de estado inválida: a → b',
      );
    });
    test('códigos comunes traducidos', () {
      expect(humanizarRechazoSync('23505', 'x'), contains('duplicado'));
      expect(humanizarRechazoSync('23503', 'x'), contains('ya no existen'));
      expect(humanizarRechazoSync('23502', 'x'), contains('obligatorio'));
      expect(humanizarRechazoSync('42501', 'x'), contains('Sin permiso'));
      expect(humanizarRechazoSync('22P02', 'x'), contains('formato'));
    });
    test('mensaje de RLS sin código 42501 también se traduce', () {
      expect(
        humanizarRechazoSync(
            null, 'new row violates row-level security policy for "pagos"'),
        contains('Sin permiso'),
      );
    });
    test('HTTP 422 (3 chars) NO matchea la clase 22', () {
      expect(humanizarRechazoSync('422', 'Unprocessable'),
          'El servidor rechazó el cambio (código 422).');
    });
    test('fallback sin código', () {
      expect(humanizarRechazoSync(null, 'algo raro'),
          'El servidor rechazó el cambio.');
    });
  });

  group('etiquetaTablaSync', () {
    test('usa los labels del change log y cae al nombre crudo', () {
      expect(etiquetaTablaSync('pagos'), 'Pagos');
      expect(etiquetaTablaSync('inv_seriales'), 'Equipos serializados');
      expect(etiquetaTablaSync('tabla_rara'), 'tabla_rara');
    });
  });

  group('persistencia', () {
    test('registrar + listar: el más nuevo primero y sobrevive el roundtrip '
        'JSON (incluye opData)', () async {
      final svc = RechazosSyncService.instance;
      await svc.registrar(_rechazo('a'));
      await svc.registrar(_rechazo('b'));

      final lista = await svc.listar();
      expect(lista.map((r) => r.id).toList(), ['b', 'a']);
      expect(lista.first.tablaLabel, 'Pagos');
      expect(lista.first.data, {'monto_cordobas': 500});
      expect(lista.first.mensajeHumano, contains('duplicado'));
    });

    test('tope de 50: los más viejos se descartan', () async {
      final svc = RechazosSyncService.instance;
      for (var i = 0; i < 55; i++) {
        await svc.registrar(_rechazo('r$i'));
      }
      final lista = await svc.listar();
      expect(lista, hasLength(50));
      expect(lista.first.id, 'r54'); // el más nuevo
      expect(lista.last.id, 'r5'); // r0..r4 cayeron
    });

    test('descartar borra solo ese aviso; limpiar borra todos', () async {
      final svc = RechazosSyncService.instance;
      await svc.registrar(_rechazo('a'));
      await svc.registrar(_rechazo('b'));

      await svc.descartar('a');
      expect((await svc.listar()).map((r) => r.id), ['b']);

      await svc.limpiar();
      expect(await svc.listar(), isEmpty);
    });

    test('entrada corrupta en prefs se saltea sin romper el resto', () async {
      SharedPreferences.setMockInitialValues({
        'rechazos_sync_v1': <String>['{esto no es json'],
      });
      final svc = RechazosSyncService.instance;
      expect(await svc.listar(), isEmpty);

      await svc.registrar(_rechazo('a'));
      expect((await svc.listar()).map((r) => r.id), ['a']);
    });

    test('dedupe: re-descartar la misma op (retry del batch) REEMPLAZA el '
        'aviso en vez de apilarlo', () async {
      final svc = RechazosSyncService.instance;
      RechazoSync intento(String id, String fecha) => RechazoSync(
            id: id,
            tabla: 'pagos',
            registroId: 'reg-fijo',
            op: 'put',
            codigo: '23505',
            mensaje: 'duplicate key',
            fechaUtcIso: fecha,
          );

      await svc.registrar(intento('a', '2026-06-11T10:00:00Z'));
      await svc.registrar(_rechazo('otro')); // registro distinto en el medio
      await svc.registrar(intento('b', '2026-06-11T10:05:00Z'));

      final lista = await svc.listar();
      expect(lista, hasLength(2));
      expect(lista.first.id, 'b'); // reemplazó al 'a' y subió al tope
      expect(lista.map((r) => r.id), isNot(contains('a')));
    });

    test('registrar concurrente (unawaited, como llega del connector) no '
        'pierde avisos', () async {
      final svc = RechazosSyncService.instance;
      await Future.wait(
          [for (var i = 0; i < 10; i++) svc.registrar(_rechazo('c$i'))]);
      expect(await svc.listar(), hasLength(10));
    });
  });
}
