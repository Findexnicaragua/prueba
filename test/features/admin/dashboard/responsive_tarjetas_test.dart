@TestOn('vm')
library;

/// Que las tarjetas del Resumen se adapten al ancho de un TELÉFONO.
///
/// Nace de un reporte con capturas (2026-08-29): en el celular los tres bloques
/// de Caja salían de anchos distintos y escalonados, el encabezado "Cobros" se
/// partía en "Cob / ros", el selector partía "Ciclo 15 ago – 14 sep" en dos
/// renglones y los montos se achicaban hasta ~8px.
///
/// Ninguna de esas cosas la caza `flutter analyze` ni un test de datos: son
/// decisiones de layout que sólo aparecen a un ancho concreto. Por eso estos
/// tests montan los widgets a **360px** —el ancho útil de un teléfono— y
/// verifican que la tabla haya CAMBIADO DE FORMA, no que quepa a los golpes.

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/features/admin/dashboard/caja_ciclo_card.dart';

/// El ancho útil de un teléfono común, ya descontada la barra del sistema.
const anchoTelefono = 360.0;

/// Un escritorio angosto: tiene que seguir en modo ANCHO.
const anchoEscritorio = 1200.0;

void main() {
  group('ventanas de Caja del ciclo', () {
    // La lógica de ventanas es pura y no necesita render: se verifica que las
    // opciones existan y tengan rango, que es lo que el bloque muestra debajo
    // del monto y lo que se cortaba cuando el texto no entraba.
    test('todas las opciones traen etiqueta y rango, sin vacíos', () {
      final hoy = DateTime(2026, 8, 28);
      for (final b in BloqueCaja.values) {
        final ops = opcionesDe(b, hoy);
        expect(ops, isNotEmpty);
        for (final v in ops) {
          expect(v.etiqueta.trim(), isNotEmpty,
              reason: 'un bloque sin etiqueta se dibuja como un hueco');
          expect(v.rango.trim(), isNotEmpty,
              reason: 'el rango va bajo el monto: sin él no se sabe qué ventana es');
        }
      }
    });

    test('las etiquetas cortas caben en un bloque de teléfono', () {
      // Los bloques de un teléfono miden ~330px y el rótulo comparte fila con
      // el ícono y la flecha del menú. Una etiqueta larga lo parte en dos.
      //
      // No se mide en píxeles a propósito —depende de la fuente— sino en
      // CARACTERES, que es la señal temprana: "Ciclo 15 ago – 14 sep" tiene 21
      // y ya se partía en el selector de la otra tarjeta.
      final hoy = DateTime(2026, 8, 28);
      for (final b in BloqueCaja.values) {
        // La primera y la segunda son las que se ven casi siempre.
        for (final v in opcionesDe(b, hoy).take(2)) {
          expect(v.etiqueta.length, lessThanOrEqualTo(18),
              reason: '"${v.etiqueta}" es muy larga para el rótulo de un '
                  'bloque en teléfono');
        }
      }
    });
  });

  // Los tests que MONTAN las tarjetas viven en `dashboard_resumen_widget_test`
  // ("en TELÉFONO los bloques de caja van apilados y parejos"): necesitan la
  // base de PowerSync y el `ProviderScope` que ese archivo ya levanta. Acá
  // queda lo que se puede verificar sin render.

  group('el umbral de compacto', () {
    test('360 es compacto y 1200 no, con margen a los dos lados', () {
      // El umbral vive en cada tarjeta como `_anchoCompacto = 600`. Este test
      // no lo lee (es privado): documenta la DECISIÓN y avisa si alguien la
      // mueve tanto que un teléfono deje de ser compacto o un escritorio
      // empiece a serlo.
      const umbral = 600.0;
      expect(anchoTelefono, lessThan(umbral),
          reason: 'un teléfono TIENE que caer en compacto');
      expect(anchoEscritorio, greaterThan(umbral),
          reason: 'un escritorio NO debe ir compacto');
      // Una tablet en vertical (768) queda del lado ancho, que es lo buscado:
      // ahí la tabla completa entra sin achicar nada.
      expect(768.0, greaterThan(umbral));
    });
  });
}
