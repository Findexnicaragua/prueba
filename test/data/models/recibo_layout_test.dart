import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/recibo_layout.dart';

/// Tests del parseo robusto del layout del recibo. `fromRaw` es la fundación
/// del "diseñador de recibo": tiene que sanear datos viejos/corruptos sin
/// perder bloques ni dejar un recibo sin totales.
void main() {
  final catalogoIds = kReciboBloquesCatalogo.map((b) => b.id).toList();

  group('ReciboLayout.fromRaw — defaults y null', () {
    test('null → layout por defecto (todos los bloques, en orden)', () {
      final l = ReciboLayout.fromRaw(null);
      expect(l.map((b) => b.id).toList(), catalogoIds);
      // 'cuota' (desglose) nace OCULTO por defecto; el resto visible.
      expect(l.where((b) => !b.visible).map((b) => b.id).toList(), ['cuota']);
      expect(l.every((b) => b.size == ReciboTextoSize.normal), isTrue);
    });

    test('el default pone WhatsApp en el PIE y cuota oculto (template pedido)',
        () {
      final l = ReciboLayout.fromRaw(null);
      final ids = l.map((b) => b.id).toList();
      // WhatsApp al pie (después de mora), y el orden de pago Monto→letras→método.
      expect(ids.indexOf('whatsapp'), greaterThan(ids.indexOf('mora')));
      expect(ids.indexOf('totales'), lessThan(ids.indexOf('letras')));
      expect(ids.indexOf('letras'), lessThan(ids.indexOf('metodo')));
      expect(ids.last, 'pie');
      expect(l.firstWhere((b) => b.id == 'cuota').visible, isFalse);
    });

    test('valor no-lista (corrupto) → por defecto', () {
      expect(ReciboLayout.fromRaw('basura').map((b) => b.id), catalogoIds);
      expect(ReciboLayout.fromRaw(42).length, catalogoIds.length);
    });
  });

  group('ReciboLayout.fromRaw — saneo', () {
    test('descarta ids desconocidos', () {
      final raw = [
        {'id': 'logo', 'visible': true, 'size': 'normal'},
        {'id': 'inexistente', 'visible': true, 'size': 'normal'},
      ];
      final l = ReciboLayout.fromRaw(raw);
      expect(l.any((b) => b.id == 'inexistente'), isFalse);
      // logo queda primero; el resto del catálogo se completa al final.
      expect(l.first.id, 'logo');
      expect(l.map((b) => b.id).toSet(), catalogoIds.toSet());
    });

    test('deduplica ids repetidos (gana el primero)', () {
      final raw = [
        {'id': 'logo', 'visible': false, 'size': 'grande'},
        {'id': 'logo', 'visible': true, 'size': 'chico'},
      ];
      final l = ReciboLayout.fromRaw(raw);
      expect(l.where((b) => b.id == 'logo').length, 1);
      final logo = l.firstWhere((b) => b.id == 'logo');
      expect(logo.visible, isFalse); // el primero
      expect(logo.size, ReciboTextoSize.grande);
    });

    test('completa los faltantes sin perder ninguno, agrupando por zona '
        '(header → body → footer) y preservando el orden DENTRO de la zona',
        () {
      // 'totales', 'mora' y 'cliente' son de body, pedidos en orden distinto
      // al del catálogo; 'logo' es de header pero viene ÚLTIMO en el raw.
      final raw = [
        {'id': 'totales', 'visible': true, 'size': 'grande'},
        {'id': 'mora', 'visible': true, 'size': 'normal'},
        {'id': 'cliente', 'visible': true, 'size': 'normal'},
        {'id': 'logo', 'visible': true, 'size': 'normal'},
      ];
      final l = ReciboLayout.fromRaw(raw);
      final ids = l.map((b) => b.id).toList();

      // Ninguno del catálogo se pierde.
      expect(ids.toSet(), catalogoIds.toSet());
      expect(l.length, catalogoIds.length);

      // Desde 954b624 el saneo devuelve el orden agrupado por zona EFECTIVA
      // (el que iteran los 3 renderers y el editor): 'logo' (header) sale
      // antes que 'totales' (body) aunque en el raw estaba después, y el
      // footer ('pie') cierra el recibo.
      expect(ids.indexOf('logo'), lessThan(ids.indexOf('totales')));
      expect(ids.last, 'pie');

      // DENTRO de body se preserva el orden pedido (totales → mora →
      // cliente, aunque el catálogo diga otro) y los faltantes del catálogo
      // se completan DESPUÉS de los pedidos de su zona.
      expect(ids.indexOf('totales'), lessThan(ids.indexOf('mora')));
      expect(ids.indexOf('mora'), lessThan(ids.indexOf('cliente')));
      expect(ids.indexOf('cliente'), lessThan(ids.indexOf('meta')),
          reason: 'los faltantes van después de los pedidos de su zona');

      // La config pedida se conserva tras el saneo.
      expect(l.firstWhere((b) => b.id == 'totales').size,
          ReciboTextoSize.grande);
    });
  });

  group('ReciboLayout.fromRaw — totales no ocultable', () {
    test('totales con visible=false se fuerza a visible=true', () {
      final raw = [
        {'id': 'totales', 'visible': false, 'size': 'normal'},
      ];
      final l = ReciboLayout.fromRaw(raw);
      final totales = l.firstWhere((b) => b.id == 'totales');
      expect(totales.visible, isTrue, reason: 'el dinero no se puede ocultar');
    });

    test('el catálogo marca totales como no ocultable', () {
      expect(reciboBloqueInfo('totales')!.hideable, isFalse);
      // todos los demás sí son ocultables.
      for (final b in kReciboBloquesCatalogo) {
        if (b.id != 'totales') {
          expect(b.hideable, isTrue, reason: '${b.id} debería ser ocultable');
        }
      }
    });
  });

  group('ReciboLayout — round-trip', () {
    test('toJson → fromRaw preserva orden/visibilidad/tamaño', () {
      final original = [
        const ReciboBloque(id: 'empresa', visible: false, size: ReciboTextoSize.grande),
        const ReciboBloque(id: 'logo', visible: true, size: ReciboTextoSize.chico),
      ];
      final json = ReciboLayout.toJson(original);
      final back = ReciboLayout.fromRaw(json);
      expect(back[0].id, 'empresa');
      expect(back[0].visible, isFalse);
      expect(back[0].size, ReciboTextoSize.grande);
      expect(back[1].id, 'logo');
      expect(back[1].size, ReciboTextoSize.chico);
    });
  });

  group('ReciboLayout — espacioAntes (espaciado entre segmentos)', () {
    test('fromJson SIN espacioAntes toma el default del catálogo (no "normal" '
        'ciego) → segmentos bien espaciados sin migración', () {
      // Un layout guardado por una versión previa a la feature no trae la clave.
      final l = ReciboLayout.fromRaw([
        {'id': 'meta', 'visible': true, 'size': 'normal'},
        {'id': 'servicio', 'visible': true, 'size': 'normal'},
      ]);
      // 'meta' abre segmento (amplio); 'servicio' continúa el grupo (chico).
      expect(l.firstWhere((b) => b.id == 'meta').espacioAntes,
          ReciboEspacio.amplio);
      expect(l.firstWhere((b) => b.id == 'servicio').espacioAntes,
          ReciboEspacio.chico);
    });

    test('round-trip preserva el espacioAntes elegido por el usuario', () {
      final original = [
        const ReciboBloque(id: 'meta', espacioAntes: ReciboEspacio.ninguno),
        const ReciboBloque(id: 'cliente', espacioAntes: ReciboEspacio.amplio),
      ];
      final back = ReciboLayout.fromRaw(ReciboLayout.toJson(original));
      expect(back.firstWhere((b) => b.id == 'meta').espacioAntes,
          ReciboEspacio.ninguno);
      expect(back.firstWhere((b) => b.id == 'cliente').espacioAntes,
          ReciboEspacio.amplio);
    });

    test('porDefecto trae los huecos de segmento del catálogo', () {
      final def = ReciboLayout.porDefecto;
      expect(def.firstWhere((b) => b.id == 'meta').espacioAntes,
          ReciboEspacio.amplio);
      expect(def.firstWhere((b) => b.id == 'mora').espacioAntes,
          ReciboEspacio.amplio);
    });

    test('reciboEspacioPx (pantalla/PDF) es no lineal: amplio bien aireado, '
        'chico pegado', () {
      expect(reciboEspacioPx(ReciboEspacio.ninguno), 0);
      expect(reciboEspacioPx(ReciboEspacio.chico), 3);
      expect(reciboEspacioPx(ReciboEspacio.normal), 10);
      expect(reciboEspacioPx(ReciboEspacio.amplio), 22);
      // amplio bastante más grande que chico (feedback de campo 2026-07-12).
      expect(reciboEspacioPx(ReciboEspacio.amplio),
          greaterThan(reciboEspacioPx(ReciboEspacio.chico) * 3));
    });

    test('reciboEspacioFeed (térmica compatible) amortiza: amplio=2 líneas '
        '(no 3) para no inflar el papel', () {
      expect(reciboEspacioFeed(ReciboEspacio.ninguno), 0);
      expect(reciboEspacioFeed(ReciboEspacio.chico), 0);
      expect(reciboEspacioFeed(ReciboEspacio.normal), 1);
      expect(reciboEspacioFeed(ReciboEspacio.amplio), 2);
    });
  });

  group('ReciboLayout — campos (nivel-campo de bloques de info)', () {
    test('fromRaw completa los campos del catálogo; meta.hora oculto por defecto '
        'y bloque monolítico sin campos', () {
      final l = ReciboLayout.fromRaw(null);
      final cliente = l.firstWhere((b) => b.id == 'cliente');
      expect(cliente.campos.map((c) => c.id).toList(),
          ['cliente.nombre', 'cliente.id', 'cliente.cedula']);
      final meta = l.firstWhere((b) => b.id == 'meta');
      expect(
          meta.campos.firstWhere((c) => c.id == 'meta.hora').visible, isFalse);
      expect(l.firstWhere((b) => b.id == 'letras').campos, isEmpty);
    });

    test('las semillas (mostrar_*) siembran la visibilidad SOLO en layout legacy',
        () {
      final l = ReciboLayout.fromRaw(null,
          semillasCampos: {'meta.hora': true, 'cliente.id': false});
      final meta = l.firstWhere((b) => b.id == 'meta');
      expect(meta.campos.firstWhere((c) => c.id == 'meta.hora').visible, isTrue);
      final cliente = l.firstWhere((b) => b.id == 'cliente');
      expect(cliente.campos.firstWhere((c) => c.id == 'cliente.id').visible,
          isFalse);
    });

    test('round-trip preserva el orden + visibilidad de campos (ID arriba del '
        'nombre) y completa los faltantes', () {
      final raw = [
        {
          'id': 'cliente',
          'visible': true,
          'campos': [
            {'id': 'cliente.id', 'visible': true},
            {'id': 'cliente.nombre', 'visible': true},
          ],
        },
      ];
      final back =
          ReciboLayout.fromRaw(ReciboLayout.toJson(ReciboLayout.fromRaw(raw)));
      final cliente = back.firstWhere((b) => b.id == 'cliente');
      expect(cliente.campos.map((c) => c.id).toList(),
          ['cliente.id', 'cliente.nombre', 'cliente.cedula']);
    });
  });
}
