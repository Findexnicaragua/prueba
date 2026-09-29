import 'dart:convert';

/// # El catálogo de tarjetas del Resumen y su orden configurable
///
/// Pedido de Rubén (2026-08-29): poder habilitar, deshabilitar y mover las
/// tarjetas desde Ajustes → Avanzado, por empresa.
///
/// ## Por qué UNA lista y no un toggle por tarjeta
///
/// Antes cada tarjeta tenía su clave (`dashboard.cobros_visible`, etc.) y el
/// ORDEN vivía escrito a mano en `dashboard_admin_screen.dart`. Con toggles
/// sueltos el orden no se puede expresar, y cada tarjeta nueva pedía una clave
/// nueva más su migración. Peor: tres de esos toggles habían quedado sin efecto
/// —sus getters se retiraron el 2026-08-28— y la pantalla de Ajustes los seguía
/// ofreciendo. Un interruptor que no mueve nada es peor que no tenerlo.
///
/// ## La regla que evita que una tarjeta desaparezca
///
/// El ajuste guardado NO es la autoridad sobre QUÉ tarjetas existen: eso lo
/// dice [kTarjetasResumen], que vive en el código. El ajuste sólo dice orden y
/// encendido. Entonces:
///
///   · un id guardado que el código ya no conoce **se ignora**;
///   · una tarjeta del código que el ajuste no nombra **se agrega al final,
///     ENCENDIDA**.
///
/// Esa segunda regla es la importante: sin ella, agregar una tarjeta nueva la
/// dejaría invisible en todos los tenants que ya tuvieran un ajuste guardado, y
/// nadie entendería por qué.

/// Una tarjeta del Resumen, tal como la conoce el CÓDIGO.
class TarjetaResumen {
  const TarjetaResumen(this.id, this.nombre, {this.soloAdmin = false});

  /// El id que viaja en el ajuste. **No se cambia nunca**: renombrarlo deja
  /// huérfano lo que ya está guardado en los tres tenants.
  final String id;

  /// Como se lee en la pantalla de configuración.
  final String nombre;

  /// La tarjeta muestra montos COBRADOS y `admin_cobranza` no los ve. El gate
  /// de rol manda sobre el ajuste: encenderla acá no se la muestra igual.
  final bool soloAdmin;
}

/// TODAS las tarjetas que el Resumen sabe dibujar, en el orden por DEFECTO —el
/// que Rubén eligió al trabajarlas una por una (2026-08-27 a 2026-08-29).
///
/// Este orden es el que usa un tenant sin ajuste guardado, y el que repone el
/// botón "Restablecer" de la pantalla de configuración.
const kTarjetasResumen = <TarjetaResumen>[
  TarjetaResumen('caja', 'Caja del ciclo', soloAdmin: true),
  TarjetaResumen('cobertura', 'Cobertura del ciclo'),
  TarjetaResumen('mora_ciclo', 'Mora del ciclo'),
  TarjetaResumen('proyeccion', 'Proyección de cobros'),
  // El id sigue siendo `mora_zona` A PROPOSITO aunque el rotulo diga
  // "Recuperación": cambiarlo dejaría huérfano el ajuste guardado en los tres
  // tenants (regla del doc de arriba). El id es una llave, no un nombre.
  TarjetaResumen('mora_zona', 'Recuperación por cobrador y comunidad'),
  TarjetaResumen('quien_cobro', 'Quién cobró', soloAdmin: true),
  // ── Las que quedaron fuera del Resumen de 2026-08-27 ──
  // Se conservan enteras y apagadas: el dueño puede volver a prenderlas sin
  // que nadie toque código.
  TarjetaResumen('recaudo_mora', 'Recaudo y mora'),
  TarjetaResumen('consultar_periodo', 'Consultar período', soloAdmin: true),
  TarjetaResumen('sparkline', 'Cobros últimos 7 días', soloAdmin: true),
  TarjetaResumen('operativo', 'Estado actual'),
  // VUELVE ENCENDIDA el 2026-09-02, y con tarjeta propia
  // (`distribucion_cuotas_card.dart`). Estuvo apagada desde el 2026-09-01,
  // cuando "Estado actual" se la comió con el argumento de que contaban la
  // misma partición. El argumento sigue siendo cierto —Al día + En gracia +
  // Vencidas = "Cuotas por cobrar", y Vencidas = "En mora"— y el dueño lo sabe:
  // se le mostró con sus propios números (20.065 + 746 + 2.563 = 23.374) y
  // eligió las dos igual, porque ésta aporta el corte al día/en gracia y el
  // conteo de "Pagadas", que la otra no tiene.
  TarjetaResumen('distribucion', 'Distribución de cuotas'),
];

/// Una fila de la configuración: qué tarjeta, y si está encendida.
class TarjetaConfig {
  const TarjetaConfig(this.tarjeta, this.encendida);
  final TarjetaResumen tarjeta;
  final bool encendida;

  String get id => tarjeta.id;
  String get nombre => tarjeta.nombre;

  TarjetaConfig conEncendida(bool v) => TarjetaConfig(tarjeta, v);
}

/// El orden por defecto: todo el catálogo, con las seis primeras encendidas.
///
/// Espeja el valor que siembra la migración 0263. Si los dos se separan, un
/// tenant nuevo abre el Resumen distinto de uno viejo — por eso el test
/// `dashboard_orden_test.dart` compara los dos lados.
List<TarjetaConfig> get ordenPorDefecto => [
      for (final t in kTarjetasResumen)
        TarjetaConfig(t, !_apagadasPorDefecto.contains(t.id)),
    ];

const _apagadasPorDefecto = {
  'recaudo_mora',
  'consultar_periodo',
  'sparkline',
  // `operativo` (Estado actual) VUELVE ENCENDIDA el 2026-09-01: el dueno pidio
  // que todo lo que mostraba el Resumen viejo apareciera en el nuevo.
  //
  // Y `distribucion` VUELVE ENCENDIDA el 2026-09-02, por el mismo motivo y con
  // tarjeta propia: el dueno la nombro entre las cuatro que tenian que
  // "regresar al estilo anterior y habilitadas". O sea que hoy no queda
  // ninguna de las del Resumen viejo apagada por defecto.
};

/// Lee el ajuste `dashboard.tarjetas` y lo cruza con el catálogo del código.
///
/// [crudo] es lo que guarda el setting: un array JSON `[{"id":..,"on":..}]`, o
/// null si el tenant no lo tiene. Cualquier cosa que no se pueda parsear cae al
/// orden por defecto: un ajuste corrupto no puede dejar el Resumen en blanco.
List<TarjetaConfig> leerOrdenTarjetas(Object? crudo) {
  if (crudo == null) return ordenPorDefecto;

  List<dynamic>? lista;
  try {
    if (crudo is List) {
      lista = crudo;
    } else if (crudo is String && crudo.trim().isNotEmpty) {
      var d = jsonDecode(crudo);
      // DOS productores escriben esta clave y no coinciden: el seed SQL guarda
      // un array y la pantalla guardaba un string JSON (bug de doble
      // codificación, arreglado el 2026-09-01 en `ordenTarjetasCrudo`). Los
      // valores viejos siguen en la base, así que acá se aceptan los dos: un
      // ajuste que el usuario guardó no puede evaporarse porque quien lo
      // escribió le puso una capa de comillas de más.
      if (d is String) d = jsonDecode(d);
      if (d is List) lista = d;
    }
  } catch (_) {
    // JSON roto: se ignora y se sigue con el default. No hay nada que "medio
    // aplicar" — mostrar algunas tarjetas en un orden arbitrario seria peor.
    lista = null;
  }
  if (lista == null || lista.isEmpty) return ordenPorDefecto;

  final porId = {for (final t in kTarjetasResumen) t.id: t};
  final out = <TarjetaConfig>[];
  final vistos = <String>{};

  for (final e in lista) {
    if (e is! Map) continue;
    final id = '${e['id']}';
    final t = porId[id];
    // Un id que el codigo ya no conoce se IGNORA: una tarjeta retirada no
    // rompe la pantalla de los tenants que la tenian guardada.
    if (t == null || !vistos.add(id)) continue;
    final on = e['on'];
    out.add(TarjetaConfig(
        t, on is bool ? on : '$on'.toLowerCase() == 'true'));
  }

  // Lo que el codigo tiene y el ajuste NO nombra va al final, ENCENDIDO. Es la
  // regla que evita que una tarjeta nueva nazca invisible en los tenants que ya
  // tenian un ajuste guardado.
  for (final t in kTarjetasResumen) {
    if (!vistos.contains(t.id)) out.add(TarjetaConfig(t, true));
  }
  return out;
}

/// La lista tal cual va al setting, SIN serializar. El orden de la lista ES el
/// orden de la pantalla.
///
/// Es lo que hay que pasarle a `settingsRepo.update`, **que serializa él**.
/// Pasarle el String de [escribirOrdenTarjetas] lo codifica DOS veces y guarda
/// `"[{\"id\":..}]"` — un string JSON en vez de un array. Ese valor pasa por
/// [leerOrdenTarjetas] sin romper nada y sin aplicarse: `jsonDecode` devuelve un
/// String, no una List, y la función cae al orden por defecto. O sea que la
/// pantalla de tarjetas guardaba, decía "guardado", y el Resumen seguía igual.
/// Encontrado el 2026-09-01 en el único tenant donde alguien usó la pantalla.
List<Map<String, Object>> ordenTarjetasCrudo(List<TarjetaConfig> filas) => [
      for (final f in filas) {'id': f.id, 'on': f.encendida},
    ];

/// Lo mismo, ya serializado. Sirve para COMPARAR (¿hay cambios sin guardar?),
/// no para guardar — ver [ordenTarjetasCrudo].
String escribirOrdenTarjetas(List<TarjetaConfig> filas) =>
    jsonEncode(ordenTarjetasCrudo(filas));
