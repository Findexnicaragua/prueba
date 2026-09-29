@TestOn('vm')
library;

/// El orden configurable de las tarjetas del Resumen (migración 0263).
///
/// Lo que se prueba acá es el FALLBACK, que es donde estas cosas fallan feo:
/// un ajuste guardado hace meses no puede dejar invisible una tarjeta que se
/// agregó ayer, ni romper la pantalla porque nombra una que ya no existe.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/dashboard_tarjetas.dart';

void main() {
  group('leerOrdenTarjetas — fallbacks', () {
    test('sin ajuste devuelve el orden por defecto completo', () {
      final r = leerOrdenTarjetas(null);
      expect(r.length, kTarjetasResumen.length);
      expect(r.map((f) => f.id).toList(),
          kTarjetasResumen.map((t) => t.id).toList());
      expect(r.where((f) => f.encendida).length, 8,
          reason: 'las seis que el dueño dejó vivas el 2026-08-29, más '
              '"Estado actual" (volvió el 2026-09-01) y "Distribución de '
              'cuotas" (volvió el 2026-09-02, con tarjeta propia)');
      // Las tres que siguen apagadas, nombradas: si mañana alguien prende una
      // sin querer, el conteo de arriba lo caza pero no dice CUÁL.
      expect(r.where((f) => !f.encendida).map((f) => f.id).toList(),
          const ['recaudo_mora', 'consultar_periodo', 'sparkline']);
    });

    test('un ajuste ROTO no deja el Resumen en blanco', () {
      // Un JSON corrupto (sync a medias, edición manual en la base) tiene que
      // caer al default entero. Mostrar "algunas tarjetas en un orden
      // arbitrario" sería peor que ignorarlo.
      for (final basura in ['no soy json', '{}', '[', '', '   ', '42']) {
        final r = leerOrdenTarjetas(basura);
        expect(r.map((f) => f.id).toList(),
            kTarjetasResumen.map((t) => t.id).toList(),
            reason: 'con "$basura" tendría que caer al default');
      }
    });

    test('una tarjeta NUEVA que el ajuste no nombra aparece al final, ENCENDIDA',
        () {
      // ESTE es el modo de falla que el fallback existe para evitar: se agrega
      // una tarjeta al código, y los tenants que ya tenían un ajuste guardado
      // no la verían nunca sin que nada avise.
      final viejo = jsonEncode([
        {'id': 'cobertura', 'on': true},
        {'id': 'mora_ciclo', 'on': false},
      ]);
      final r = leerOrdenTarjetas(viejo);

      expect(r.length, kTarjetasResumen.length,
          reason: 'todas las del código tienen que estar');
      expect(r[0].id, 'cobertura');
      expect(r[1].id, 'mora_ciclo');
      expect(r[1].encendida, isFalse, reason: 'el ajuste dijo que no');

      // Las que el ajuste no nombraba, al final y prendidas.
      for (final f in r.skip(2)) {
        expect(f.encendida, isTrue,
            reason: '"${f.id}" no estaba en el ajuste: nace encendida');
      }
    });

    test('un id que el CÓDIGO ya no conoce se ignora', () {
      // Una tarjeta retirada del código no puede romper la pantalla de los
      // tenants que la tenían guardada.
      final r = leerOrdenTarjetas(jsonEncode([
        {'id': 'tarjeta_que_ya_no_existe', 'on': true},
        {'id': 'caja', 'on': true},
      ]));
      expect(r.map((f) => f.id), isNot(contains('tarjeta_que_ya_no_existe')));
      expect(r.first.id, 'caja');
      expect(r.length, kTarjetasResumen.length);
    });

    test('un id repetido se toma una sola vez', () {
      final r = leerOrdenTarjetas(jsonEncode([
        {'id': 'caja', 'on': true},
        {'id': 'caja', 'on': false},
      ]));
      expect(r.where((f) => f.id == 'caja').length, 1);
      expect(r.first.encendida, isTrue, reason: 'gana la primera aparición');
    });

    test('el "on" aguanta venir como string', () {
      // PowerSync puede entregar un booleano de JSONB como "true"/"false" —
      // mismo cuidado que `settingValue` tiene para los toggles.
      final r = leerOrdenTarjetas(jsonEncode([
        {'id': 'caja', 'on': 'false'},
        {'id': 'cobertura', 'on': 'true'},
      ]));
      expect(r.firstWhere((f) => f.id == 'caja').encendida, isFalse);
      expect(r.firstWhere((f) => f.id == 'cobertura').encendida, isTrue);
    });

    test('respeta el orden guardado, no el del catálogo', () {
      final r = leerOrdenTarjetas(jsonEncode([
        {'id': 'quien_cobro', 'on': true},
        {'id': 'caja', 'on': true},
      ]));
      expect(r[0].id, 'quien_cobro');
      expect(r[1].id, 'caja');
    });
  });

  group('ida y vuelta', () {
    test('escribir y volver a leer da lo mismo', () {
      final original = ordenPorDefecto;
      final r = leerOrdenTarjetas(escribirOrdenTarjetas(original));
      expect(r.map((f) => '${f.id}:${f.encendida}').toList(),
          original.map((f) => '${f.id}:${f.encendida}').toList());
    });

    // El bug que hacia que la pantalla de tarjetas no guardara nada
    // (2026-09-01). `settingsRepo.update` serializa el valor que recibe, asi
    // que la pantalla le pasaba un String YA serializado y quedaba
    // `"[{\"id\":..}]"` guardado. Al leerlo, `jsonDecode` devolvia un String
    // —no una List— y todo caia al orden por defecto, en silencio: guardabas,
    // decia "guardado", y el Resumen seguia igual.
    test('un ajuste guardado DOS veces codificado igual se aplica', () {
      final mezcla = [
        const TarjetaConfig(TarjetaResumen('mora_zona', 'x'), false),
        const TarjetaConfig(TarjetaResumen('caja', 'y'), true),
      ];
      // Exactamente lo que quedo en la base del Test Tenant.
      final dobleCodificado = jsonEncode(escribirOrdenTarjetas(mezcla));
      final r = leerOrdenTarjetas(dobleCodificado);

      expect(r[0].id, 'mora_zona');
      expect(r[0].encendida, isFalse,
          reason: 'si cae al default, "mora_zona" viene ENCENDIDA y primera '
              'queda "caja": eso es lo que pasaba');
      expect(r[1].id, 'caja');
    });

    // La otra mitad del mismo fix: lo que la pantalla le pasa a `update` tiene
    // que ser la estructura, no el texto. Si esto vuelve a ser un String, el
    // `jsonEncode` de `update` lo envuelve otra vez y volvemos al bug — con la
    // diferencia de que ahora el lector lo tolera y NO se nota.
    test('lo que se guarda es una lista, no un texto', () {
      final crudo = ordenTarjetasCrudo(ordenPorDefecto);
      expect(crudo, isA<List<Map<String, Object>>>());
      expect(crudo.first['id'], kTarjetasResumen.first.id);
      // Y serializado por `update` da un array, que es lo que el lector espera
      // sin desenvolver nada.
      expect(jsonDecode(jsonEncode(crudo)), isA<List<dynamic>>());
    });

    test('un orden reordenado y apagado sobrevive el viaje', () {
      final mezcla = [
        const TarjetaConfig(TarjetaResumen('mora_zona', 'x'), false),
        const TarjetaConfig(TarjetaResumen('caja', 'y'), true),
      ];
      final r = leerOrdenTarjetas(escribirOrdenTarjetas(mezcla));
      expect(r[0].id, 'mora_zona');
      expect(r[0].encendida, isFalse);
      expect(r[1].id, 'caja');
      expect(r[1].encendida, isTrue);
    });
  });

  test('el default de Dart espeja el que siembra la ÚLTIMA migración', () {
    // Si los dos se separan, un tenant NUEVO abre el Resumen distinto de uno
    // viejo y nadie entiende por qué. Este test lee la migración de verdad.
    //
    // Y lee la ÚLTIMA que toca el seed, no una escrita a mano acá. Estaba
    // clavado en `0263` y eso tiene un modo de falla feo: al cambiar el default
    // en una migración NUEVA (0266), el test seguía comparando contra la vieja
    // y habría dado verde con los dos lados separados — que es exactamente lo
    // que este test existe para impedir.
    final dir = Directory('supabase/migrations');
    if (!dir.existsSync()) {
      markTestSkipped('las migraciones no están en este worktree');
      return;
    }
    final conSeed = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .where((f) => f.readAsStringSync().contains(
            'function public.seed_settings_dashboard_orden_0263'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(conSeed, isNotEmpty,
        reason: 'ninguna migración define el seed del orden de tarjetas');
    final f = conSeed.last;
    final sql = f.readAsStringSync();

    // El array JSON del `insert`, con los saltos de línea del SQL sacados.
    final m = RegExp(r"'(\[\s*\{.*?\}\s*\])'", dotAll: true).firstMatch(sql);
    expect(m, isNotNull,
        reason: 'no encontré el array en ${f.path}');
    final lista = (jsonDecode(m!.group(1)!.replaceAll(RegExp(r'\s+'), ' '))
        as List)
        .cast<Map<String, dynamic>>();

    final enDart = ordenPorDefecto;
    expect(lista.length, enDart.length,
        reason: '${f.path} siembra ${lista.length} tarjetas y Dart tiene '
            '${enDart.length}');
    for (var i = 0; i < lista.length; i++) {
      expect(lista[i]['id'], enDart[i].id,
          reason: 'la posición $i difiere entre la migración y Dart');
      expect(lista[i]['on'], enDart[i].encendida,
          reason: '"${enDart[i].id}" arranca distinto en cada lado');
    }
  });

  test('los ids son únicos y no cambian por accidente', () {
    // Los ids viajan en el ajuste guardado de los tres tenants: renombrar uno
    // deja huérfana su configuración. Esta lista es un candado.
    final ids = kTarjetasResumen.map((t) => t.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'hay ids repetidos');
    expect(ids, const [
      'caja',
      'cobertura',
      'mora_ciclo',
      'proyeccion',
      'mora_zona',
      'quien_cobro',
      'recaudo_mora',
      'consultar_periodo',
      'sparkline',
      'operativo',
      'distribucion',
    ]);
  });
}
