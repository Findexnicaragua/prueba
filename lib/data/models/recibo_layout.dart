// Modelo del LAYOUT configurable del recibo — "diseñador de recibo" (rework).
//
// El recibo se renderiza como una LISTA ORDENADA de bloques; cada bloque tiene
// visibilidad y tamaño de letra. Los 3 renderers (pantalla / PDF / Bluetooth)
// iteran exactamente la misma lista para salir consistentes. Granularidad por
// BLOQUE (Opción A): un dataset (cliente, cuota, etc.) es una unidad.

/// Tamaño de letra de un bloque. Enum de 3 niveles a propósito: la térmica
/// ESC/POS solo soporta ~3 tamaños reales (normal / doble), así que pantalla y
/// PDF mapean estos 3 a px y la térmica al tamaño ESC/POS más cercano.
/// `extraGrande`/`gigante` son SOLO para el logo (2 tamaños más allá de grande);
/// en bloques de TEXTO los renderers los topan en `grande` (el editor no los
/// ofrece para texto). Ver `_logoScale`/`_pdfLogoScale`.
enum ReciboTextoSize { chico, normal, grande, extraGrande, gigante }

ReciboTextoSize reciboSizeFromString(String? s) => switch (s) {
      'chico' => ReciboTextoSize.chico,
      'grande' => ReciboTextoSize.grande,
      'extraGrande' => ReciboTextoSize.extraGrande,
      'gigante' => ReciboTextoSize.gigante,
      _ => ReciboTextoSize.normal,
    };

/// Espacio vertical ANTES de un bloque = el hueco ENTRE SEGMENTOS que controla
/// el admin. 4 niveles; cada renderer lo escala a su medio: pantalla/PDF con
/// `reciboEspacioPx` (no lineal — amplio bien aireado), la térmica de TEXTO con
/// `reciboEspacioFeed` (líneas). El MISMO valor de config sale parejo (no
/// idéntico al px) en los 3 modos.
enum ReciboEspacio { ninguno, chico, normal, amplio }

ReciboEspacio reciboEspacioFromString(String? s) => switch (s) {
      'ninguno' => ReciboEspacio.ninguno,
      'chico' => ReciboEspacio.chico,
      'amplio' => ReciboEspacio.amplio,
      _ => ReciboEspacio.normal,
    };

/// Alto del hueco para PANTALLA/PDF: pantalla usa `px * baseFont`, PDF `px * 0.6`
/// (pt). NO lineal a propósito: 'chico' queda pegado (líneas del MISMO segmento)
/// y 'amplio' queda BIEN aireado (separación ENTRE segmentos). El paso amplio se
/// agrandó tras el test en campo (2026-07-12: con 6·baseFont ≈ 1.4mm se veía
/// pegado). ninguno=0, chico=3, normal=10, amplio=22 (amplio ≈ 5mm en 80mm).
double reciboEspacioPx(ReciboEspacio e) => switch (e) {
      ReciboEspacio.ninguno => 0,
      ReciboEspacio.chico => 3,
      ReciboEspacio.normal => 10,
      ReciboEspacio.amplio => 22,
    };

/// Líneas de `feed` para la TÉRMICA DE TEXTO (modo compatible). La térmica no
/// tiene sub-renglón: un feed es una línea ENTERA (~3.5 mm), así que se
/// AMORTIGUA respecto del peso px para no inflar el papel (con el mapeo 1:1,
/// 'amplio'=3 líneas casi duplicaba el largo del recibo — audit 2026-07-11).
/// ninguno/chico = pegado (0), normal = 1 renglón, amplio = 2.
int reciboEspacioFeed(ReciboEspacio e) => switch (e) {
      ReciboEspacio.ninguno => 0,
      ReciboEspacio.chico => 0,
      ReciboEspacio.normal => 1,
      ReciboEspacio.amplio => 2,
    };

/// Zona del recibo. Es solo agrupación VISUAL en el editor (header/body/footer);
/// el render por debajo es una sola lista lineal de arriba hacia abajo.
enum ReciboZona { header, body, footer }

ReciboZona? reciboZonaFromString(String? s) => switch (s) {
      'header' => ReciboZona.header,
      'body' => ReciboZona.body,
      'footer' => ReciboZona.footer,
      _ => null,
    };

/// Un CAMPO dentro de un bloque de info (nivel-campo del diseñador): su id y si
/// se muestra. El ORDEN en la lista `ReciboBloque.campos` = orden de impresión.
class ReciboCampo {
  const ReciboCampo({required this.id, this.visible = true});
  final String id;
  final bool visible;

  ReciboCampo copyWith({bool? visible}) =>
      ReciboCampo(id: id, visible: visible ?? this.visible);

  Map<String, dynamic> toJson() => {'id': id, 'visible': visible};

  factory ReciboCampo.fromJson(Map<String, dynamic> j) =>
      ReciboCampo(id: j['id'] as String, visible: j['visible'] as bool? ?? true);
}

/// Metadata de un campo del catálogo: id canónico, label legible (para el
/// EDITOR — el texto IMPRESO lo pone el renderer) y visibilidad por defecto.
class ReciboCampoInfo {
  const ReciboCampoInfo(this.id, this.label, {this.defaultVisible = true});
  final String id;
  final String label;
  final bool defaultVisible;
}

/// Catálogo de CAMPOS por bloque, SOLO para los bloques de info que son listas
/// de campos (empresa, meta, cliente, servicio, metodo). Los demás bloques NO
/// están acá → se renderizan monolíticos (sin nivel-campo). El ORDEN de cada
/// lista = orden por defecto. `meta.hora` nace oculto (el template no la muestra);
/// `cliente.id`/`cliente.cedula`/`meta.hora` además se siembran del setting viejo
/// (recibo.mostrar_*) al migrar — ver ReciboLayout.fromRaw.
const kReciboCamposCatalogo = <String, List<ReciboCampoInfo>>{
  'empresa': [
    ReciboCampoInfo('empresa.nombre', 'Nombre de la empresa'),
    ReciboCampoInfo('empresa.direccion', 'Dirección'),
    ReciboCampoInfo('empresa.telefono', 'Teléfono'),
    ReciboCampoInfo('empresa.ruc', 'RUC'),
  ],
  'meta': [
    ReciboCampoInfo('meta.numero', 'N° de recibo'),
    ReciboCampoInfo('meta.fecha', 'Fecha'),
    ReciboCampoInfo('meta.hora', 'Hora', defaultVisible: false),
    ReciboCampoInfo('meta.cobrador', 'Colector'),
  ],
  'cliente': [
    ReciboCampoInfo('cliente.nombre', 'Nombre'),
    ReciboCampoInfo('cliente.id', 'ID'),
    ReciboCampoInfo('cliente.cedula', 'Cédula'),
  ],
  'servicio': [
    ReciboCampoInfo('servicio.servicio', 'Servicio'),
    ReciboCampoInfo('servicio.ticket', 'Ticket'),
    ReciboCampoInfo('servicio.periodo', 'Período'),
  ],
  'metodo': [
    ReciboCampoInfo('metodo.metodo', 'Método'),
    ReciboCampoInfo('metodo.referencia', 'Referencia'),
    ReciboCampoInfo('metodo.recibido', 'Recibido (USD)'),
  ],
};

/// Campos del catálogo para un bloque, o null si el bloque NO es nivel-campo.
List<ReciboCampoInfo>? reciboCamposCatalogo(String bloqueId) =>
    kReciboCamposCatalogo[bloqueId];

ReciboCampoInfo? reciboCampoInfo(String bloqueId, String campoId) {
  for (final c in kReciboCamposCatalogo[bloqueId] ?? const <ReciboCampoInfo>[]) {
    if (c.id == campoId) return c;
  }
  return null;
}

/// Un bloque del layout: qué bloque es (id), si se muestra, y su tamaño.
class ReciboBloque {
  const ReciboBloque({
    required this.id,
    this.visible = true,
    this.size = ReciboTextoSize.normal,
    this.zona,
    this.espacioAntes = ReciboEspacio.normal,
    this.campos = const [],
  });

  final String id;
  final bool visible;
  final ReciboTextoSize size;

  /// Zona elegida por el usuario (override del default del catálogo). null =
  /// usar la zona del catálogo. Permite mover un bloque entre encabezado/cuerpo/
  /// pie desde el editor (menú "Mover a zona").
  final ReciboZona? zona;

  /// Hueco vertical ANTES de este bloque (separación con el segmento anterior).
  /// Lo elige el admin en el editor; los 3 renderers lo respetan por igual.
  final ReciboEspacio espacioAntes;

  /// Campos ORDENADOS del bloque (solo bloques de info; ver kReciboCamposCatalogo).
  /// El orden = orden de impresión; cada campo con su visibilidad. Bloques que
  /// NO son nivel-campo → lista vacía (se renderizan monolíticos).
  final List<ReciboCampo> campos;

  ReciboBloque copyWith({
    bool? visible,
    ReciboTextoSize? size,
    ReciboZona? zona,
    ReciboEspacio? espacioAntes,
    List<ReciboCampo>? campos,
  }) =>
      ReciboBloque(
        id: id,
        visible: visible ?? this.visible,
        size: size ?? this.size,
        zona: zona ?? this.zona,
        espacioAntes: espacioAntes ?? this.espacioAntes,
        campos: campos ?? this.campos,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'visible': visible,
        'size': size.name,
        if (zona != null) 'zona': zona!.name,
        'espacioAntes': espacioAntes.name,
        if (campos.isNotEmpty)
          'campos': campos.map((c) => c.toJson()).toList(),
      };

  factory ReciboBloque.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String;
    // Fallback CLAVE: si el layout guardado NO trae 'espacioAntes' (tenants
    // previos a esta feature, y el seed viejo), se toma el default del CATÁLOGO
    // por bloque — así los segmentos ya salen bien espaciados sin migración.
    final espacio = j.containsKey('espacioAntes')
        ? reciboEspacioFromString(j['espacioAntes'] as String?)
        : (reciboBloqueInfo(id)?.espacioAntes ?? ReciboEspacio.normal);
    // Campos: se parsean tal cual vienen; el saneo/completado contra el catálogo
    // (y el seed de hora/código/cédula) lo hace ReciboLayout.fromRaw.
    final campos = (j['campos'] is List)
        ? [
            // Skip de items corruptos (JSON editado a mano por SQL sin 'id') —
            // igual que el parseo a nivel-bloque; no tumba todo el layout.
            for (final c in j['campos'] as List)
              if (c is Map && c['id'] is String)
                ReciboCampo.fromJson(Map<String, dynamic>.from(c))
          ]
        : const <ReciboCampo>[];
    return ReciboBloque(
      id: id,
      visible: j['visible'] as bool? ?? true,
      size: reciboSizeFromString(j['size'] as String?),
      zona: reciboZonaFromString(j['zona'] as String?),
      espacioAntes: espacio,
      campos: campos,
    );
  }
}

/// Metadata de cada bloque disponible: label legible, zona, y si se puede
/// ocultar. El bloque de TOTALES (dinero) NO es ocultable (es la razón de ser
/// del comprobante) — decisión de producto confirmada.
class ReciboBloqueInfo {
  const ReciboBloqueInfo(this.id, this.label, this.zona,
      {this.hideable = true,
      this.espacioAntes = ReciboEspacio.normal,
      this.visibleDefault = true});
  final String id;
  final String label;
  final ReciboZona zona;
  final bool hideable;

  /// Hueco por defecto ANTES del bloque. Arma los segmentos A-E: 'amplio' al
  /// empezar un grupo nuevo, 'chico' para las líneas que continúan el grupo.
  final ReciboEspacio espacioAntes;

  /// Visible por defecto. 'cuota' (desglose Cuota base / Saldo) nace OCULTO: el
  /// default muestra solo Monto/letras/método; el admin lo habilita en los
  /// ajustes del recibo.
  final bool visibleDefault;
}

/// Catálogo COMPLETO de bloques. El ORDEN de esta lista es el orden por
/// defecto del recibo (coincide con el layout actual de la app).
const kReciboBloquesCatalogo = <ReciboBloqueInfo>[
  // ORDEN por defecto = el template pedido (2026-07-11, logo arriba).
  // espacioAntes arma los segmentos ('amplio' abre grupo, 'chico' sigue); el
  // hueco del PRIMER bloque no se dibuja. 'cuota' nace OCULTO (visibleDefault).
  // ── Encabezado ──
  ReciboBloqueInfo('logo', 'Logo', ReciboZona.header,
      espacioAntes: ReciboEspacio.ninguno),
  ReciboBloqueInfo('empresa', 'Datos de la empresa', ReciboZona.header,
      espacioAntes: ReciboEspacio.chico),
  ReciboBloqueInfo('titulo', 'Título', ReciboZona.header,
      espacioAntes: ReciboEspacio.chico),
  // ── A: datos del recibo ──
  ReciboBloqueInfo('meta', 'Datos del recibo (N°, fecha, colector)', ReciboZona.body,
      espacioAntes: ReciboEspacio.amplio),
  // ── B: cliente y servicio ──
  ReciboBloqueInfo('cliente', 'Cliente', ReciboZona.body,
      espacioAntes: ReciboEspacio.amplio),
  ReciboBloqueInfo('servicio', 'Servicio y período', ReciboZona.body,
      espacioAntes: ReciboEspacio.chico),
  // ── C: pago (Monto → letras → método). 'cuota' oculto por defecto ──
  ReciboBloqueInfo('cuota', 'Montos de la cuota (desglose)', ReciboZona.body,
      espacioAntes: ReciboEspacio.chico, visibleDefault: false),
  ReciboBloqueInfo('totales', 'Monto (cobrado / vuelto / pagado)', ReciboZona.body,
      hideable: false, espacioAntes: ReciboEspacio.amplio),
  ReciboBloqueInfo('letras', 'Monto en letras', ReciboZona.body,
      espacioAntes: ReciboEspacio.chico),
  ReciboBloqueInfo('metodo', 'Método de pago', ReciboZona.body,
      espacioAntes: ReciboEspacio.chico),
  // ── D: mora ──
  ReciboBloqueInfo('mora', 'Detalle de mora', ReciboZona.body,
      espacioAntes: ReciboEspacio.amplio),
  // ── E: pie (WhatsApp + eslogan) ──
  ReciboBloqueInfo('whatsapp', 'WhatsApp', ReciboZona.footer,
      espacioAntes: ReciboEspacio.amplio),
  ReciboBloqueInfo('pie', 'Pie libre', ReciboZona.footer,
      espacioAntes: ReciboEspacio.chico),
];

ReciboBloqueInfo? reciboBloqueInfo(String id) {
  for (final b in kReciboBloquesCatalogo) {
    if (b.id == id) return b;
  }
  return null;
}

/// Zona EFECTIVA de un bloque: la elegida por el usuario (`bloque.zona`) o, si
/// no eligió, la del catálogo.
ReciboZona zonaEfectiva(ReciboBloque b) =>
    b.zona ?? reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;

/// Helpers de parseo/saneo del layout (robusto a versiones viejas y datos
/// corruptos — nunca se "pierde" un bloque ni se muestra un recibo sin totales).
class ReciboLayout {
  /// Layout por defecto: orden del catálogo, visibilidad por-bloque
  /// (`visibleDefault` — 'cuota' oculto), tamaño normal, y el espaciado
  /// por-segmento del catálogo (huecos A-E).
  static List<ReciboBloque> get porDefecto => kReciboBloquesCatalogo
      .map((b) => ReciboBloque(
          id: b.id,
          visible: b.visibleDefault,
          espacioAntes: b.espacioAntes,
          campos: _saneaCampos(b.id, const [], const {})))
      .toList();

  /// Completa/sanea los CAMPOS de un bloque contra el catálogo: preserva los
  /// guardados (en su orden, descartando ids desconocidos/duplicados) y agrega
  /// al final los del catálogo que falten. Cuando el bloque viene SIN campos
  /// (legacy) y el campo tiene semilla (hora/código/cédula del setting viejo),
  /// usa esa semilla; si no, su defaultVisible. Bloque no nivel-campo → [].
  static List<ReciboCampo> _saneaCampos(String bloqueId,
      List<ReciboCampo> guardados, Map<String, bool> semillas) {
    final catalogo = reciboCamposCatalogo(bloqueId);
    if (catalogo == null) return const [];
    final legacy = guardados.isEmpty;
    final validos = {for (final info in catalogo) info.id};
    final out = <ReciboCampo>[];
    final vistos = <String>{};
    for (final c in guardados) {
      if (!validos.contains(c.id) || vistos.contains(c.id)) continue;
      vistos.add(c.id);
      out.add(c);
    }
    for (final info in catalogo) {
      if (vistos.contains(info.id)) continue;
      final visible = (legacy && semillas.containsKey(info.id))
          ? semillas[info.id]!
          : info.defaultVisible;
      out.add(ReciboCampo(id: info.id, visible: visible));
    }
    return out;
  }

  /// Parsea el `valor` crudo del setting `recibo.layout` (un array JSON ya
  /// decodificado por `Setting.fromRow`). Reglas defensivas:
  ///  - null / formato inválido → layout por defecto.
  ///  - descarta ids desconocidos (catálogo viejo) y duplicados.
  ///  - agrega AL FINAL los bloques del catálogo que falten (un bloque nuevo en
  ///    una versión futura aparece solo, nunca desaparece).
  ///  - fuerza visible=true en los bloques NO ocultables (totales).
  static List<ReciboBloque> fromRaw(dynamic raw,
      {Map<String, bool> semillasCampos = const {}}) {
    final out = <ReciboBloque>[];
    final vistos = <String>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final id = item['id'] as String?;
        if (id == null) continue;
        final info = reciboBloqueInfo(id);
        if (info == null || vistos.contains(id)) continue;
        vistos.add(id);
        var b = ReciboBloque.fromJson(Map<String, dynamic>.from(item));
        if (!info.hideable) b = b.copyWith(visible: true);
        b = b.copyWith(campos: _saneaCampos(b.id, b.campos, semillasCampos));
        out.add(b);
      }
    }
    for (final info in kReciboBloquesCatalogo) {
      // Los faltantes heredan visibilidad + hueco de segmento del catálogo
      // (igual que porDefecto y el fallback de fromJson) — un bloque nuevo
      // aparece con su default pensado, no con 'visible+normal' ciego.
      if (!vistos.contains(info.id)) {
        out.add(ReciboBloque(
            id: info.id,
            visible: info.visibleDefault,
            espacioAntes: info.espacioAntes,
            campos: _saneaCampos(info.id, const [], semillasCampos)));
      }
    }
    if (out.isEmpty) return porDefecto;
    // Orden FINAL agrupado por zona EFECTIVA (header → body → footer),
    // preservando el orden dentro de cada zona. Es el orden que iteran los 3
    // renderers y el que muestra/guarda el editor, así un bloque movido de zona
    // (ej. WhatsApp al encabezado) se refleja en el recibo impreso.
    final porZona = <ReciboZona, List<ReciboBloque>>{
      ReciboZona.header: [],
      ReciboZona.body: [],
      ReciboZona.footer: [],
    };
    for (final b in out) {
      porZona[zonaEfectiva(b)]!.add(b);
    }
    return [
      ...porZona[ReciboZona.header]!,
      ...porZona[ReciboZona.body]!,
      ...porZona[ReciboZona.footer]!,
    ];
  }

  static List<Map<String, dynamic>> toJson(List<ReciboBloque> layout) =>
      layout.map((b) => b.toJson()).toList();
}
