import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/recibo_layout.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import 'recibo_preview.dart';

/// Diseñador del recibo (rework). Dos columnas:
///  - IZQUIERDA: ajustes generales (ancho, título, pie) + los bloques del
///    recibo SEGMENTADOS por Encabezado / Cuerpo / Pie. Cada bloque se arrastra
///    para reordenar (dentro de su segmento), se prende/apaga y se le elige el
///    tamaño de letra. Sub-opciones (cédula, saldo) viven dentro de su bloque.
///  - DERECHA: vista previa en vivo, siempre visible mientras editás.
///
/// Ocupa toda la tab Recibos (la pantalla de settings le da altura completa, no
/// va dentro del ListView de tiles genéricos).
class ReciboLayoutEditor extends ConsumerWidget {
  const ReciboLayoutEditor({super.key, required this.tenantId});

  final String tenantId;

  static const _zonas = [
    (ReciboZona.header, 'Encabezado', Icons.vertical_align_top),
    (ReciboZona.body, 'Cuerpo', Icons.notes),
    (ReciboZona.footer, 'Pie', Icons.vertical_align_bottom),
  ];

  void _save(WidgetRef ref, List<ReciboBloque> layout) {
    // upsert (no update): los tenants creados DESPUÉS de la migración 0080 no
    // tienen la fila `recibo.layout` sembrada (el trigger de alta llama
    // seed_settings_default, que no la incluye). Con un UPDATE puro el toggle
    // no afectaba ninguna fila y "rebotaba". upsert la inserta si falta.
    ref.read(settingsRepoProvider).upsert(
          tenantId,
          'recibo.layout',
          ReciboLayout.toJson(layout),
          tipo: 'json',
          categoria: 'recibos',
          usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
        );
  }

  Future<void> _resetLayout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restaurar layout'),
        content: const Text(
            'Vuelve el recibo al orden y las zonas por defecto (incluye WhatsApp '
            'en el encabezado). ¿Continuar?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restaurar')),
        ],
      ),
    );
    if (ok == true) _save(ref, ReciboLayout.porDefecto);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final layout = settings.reciboLayout;
    // SOLO el super_admin ve/edita qué MODOS de impresión están disponibles.
    final esSuperAdmin =
        ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;

    // Agrupar por zona del catálogo, preservando el orden flat de cada zona.
    final grupos = <ReciboZona, List<ReciboBloque>>{
      ReciboZona.header: [],
      ReciboZona.body: [],
      ReciboZona.footer: [],
    };
    for (final b in layout) {
      grupos[zonaEfectiva(b)]!.add(b);
    }

    // Reconstruye el layout flat SIEMPRE zona-agrupado (header → body → footer),
    // que es justo el orden que iteran los renderers. Así lo que ves en los
    // segmentos coincide exacto con cómo se imprime.
    List<ReciboBloque> rebuild() => [
          ...grupos[ReciboZona.header]!,
          ...grupos[ReciboZona.body]!,
          ...grupos[ReciboZona.footer]!,
        ];

    void reordenar(ReciboZona zona, int oldIndex, int newIndex) {
      final list = grupos[zona]!;
      if (newIndex > oldIndex) newIndex -= 1;
      list.insert(newIndex, list.removeAt(oldIndex));
      _save(ref, rebuild());
    }

    void actualizar(ReciboZona zona, int i, ReciboBloque nuevo) {
      grupos[zona]![i] = nuevo;
      _save(ref, rebuild());
    }

    // Mueve un bloque de una zona a otra (lo agrega al final de la destino con
    // su override `zona` seteado). El orden por zona lo reconstruye `rebuild()`.
    void moverAZona(ReciboZona origen, int i, ReciboZona destino) {
      if (origen == destino) return;
      final b = grupos[origen]!.removeAt(i);
      grupos[destino]!.add(b.copyWith(zona: destino));
      _save(ref, rebuild());
    }

    final editorChildren = <Widget>[
      if (esSuperAdmin) ...[
        _ModosImpresionCard(tenantId: tenantId),
        const SizedBox(height: 12),
      ],
      _AjustesGenerales(tenantId: tenantId),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.restart_alt, size: 18),
          label: const Text('Restaurar layout por defecto'),
          onPressed: () => _resetLayout(context, ref),
        ),
      ),
      const SizedBox(height: 8),
      for (final (zona, label, icon) in _zonas)
        _Segmento(
          label: label,
          icon: icon,
          zona: zona,
          bloques: grupos[zona]!,
          onReorder: (o, n) => reordenar(zona, o, n),
          onVisible: (i, v) =>
              actualizar(zona, i, grupos[zona]![i].copyWith(visible: v)),
          onSize: (i, s) =>
              actualizar(zona, i, grupos[zona]![i].copyWith(size: s)),
          onEspacio: (i, e) =>
              actualizar(zona, i, grupos[zona]![i].copyWith(espacioAntes: e)),
          onMover: (i, destino) => moverAZona(zona, i, destino),
          onCampoVisible: (i, campoId, v) => actualizar(zona, i,
              grupos[zona]![i].copyWith(
                  campos: _conCampoToggle(grupos[zona]![i].campos, campoId, v))),
          onCampoMover: (i, fi, arriba) => actualizar(zona, i,
              grupos[zona]![i].copyWith(
                  campos: _conCampoMovido(grupos[zona]![i].campos, fi, arriba))),
          tenantId: tenantId,
        ),
    ];

    // Preview a la derecha (siempre visible) en pantalla ancha; apilado arriba
    // en angosta. Los hijos del editor van DIRECTO en un único ListView (no
    // anidado) para no romper el scroll por altura sin límite.
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 900) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const ReciboPreview(),
              const SizedBox(height: 20),
              ...editorChildren,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: editorChildren,
              ),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 360,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: const [ReciboPreview()],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Modos de impresión disponibles (SOLO super_admin). Imagen es el default y
// siempre queda ≥1. Si ambos, el cobrador elige por-dispositivo.
// ───────────────────────────────────────────────────────────────────────
class _ModosImpresionCard extends ConsumerWidget {
  const _ModosImpresionCard({required this.tenantId});
  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appSettingsProvider);
    final imagen = s.modoImagenHabilitado;
    final compat = s.modoCompatibleHabilitado;

    Future<void> guardar(String clave, bool v) =>
        ref.read(settingsRepoProvider).upsert(
              tenantId,
              clave,
              v,
              tipo: 'boolean',
              categoria: 'recibos',
              usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
            );

    void alMenosUno() => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Debe quedar al menos un modo habilitado')));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.print, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text('Modos de impresión disponibles',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
                'Solo el Dev. Si habilitás ambos, cada cobrador elige en su '
                'dispositivo (config de impresora del celular).',
                style: Theme.of(context).textTheme.bodySmall),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Imagen'),
              subtitle: const Text(
                  'Fidelidad perfecta (default). Para impresoras que andan bien.'),
              value: imagen,
              onChanged: (v) {
                if (!v && !compat) {
                  alMenosUno();
                  return;
                }
                guardar('recibo.modo_imagen_habilitado', v);
              },
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Compatible'),
              subtitle: const Text(
                  'Texto nativo, más liviano. Para impresoras baratas que dan '
                  'basura o caracteres chinos.'),
              value: compat,
              onChanged: (v) {
                if (!v && !imagen) {
                  alMenosUno();
                  return;
                }
                guardar('recibo.modo_compatible_habilitado', v);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Ajustes generales (ancho de papel, título, pie). StatefulWidget por los
// controllers de texto (no se pisan en rebuilds).
// ───────────────────────────────────────────────────────────────────────
class _AjustesGenerales extends ConsumerStatefulWidget {
  const _AjustesGenerales({required this.tenantId});
  final String tenantId;
  @override
  ConsumerState<_AjustesGenerales> createState() => _AjustesGeneralesState();
}

class _AjustesGeneralesState extends ConsumerState<_AjustesGenerales> {
  late final TextEditingController _titulo;
  late final TextEditingController _pie;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appSettingsProvider);
    _titulo = TextEditingController(text: s.reciboTitulo);
    _pie = TextEditingController(text: s.pieRecibo);
  }

  @override
  void dispose() {
    _titulo.dispose();
    _pie.dispose();
    super.dispose();
  }

  // upsert (no update): mismas claves de recibo pueden no estar sembradas en
  // tenants nuevos (ver nota en ReciboLayoutEditor._save). upsert la crea si
  // falta. `tipo` por clave para que la fila nueva quede bien tipada.
  void _save(String clave, dynamic valor, {String tipo = 'string'}) {
    ref.read(settingsRepoProvider).upsert(
          widget.tenantId,
          clave,
          valor,
          tipo: tipo,
          categoria: 'recibos',
          usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
        );
  }

  @override
  Widget build(BuildContext context) {
    final ancho = ref.watch(appSettingsProvider).formatoReciboMm;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _TituloSeccion('Ajustes generales', Icons.tune),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 90, child: Text('Ancho de papel')),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: ancho == 80 ? 80 : 58,
                  onChanged: (v) {
                    if (v != null) {
                      _save('recibo.formato_default_mm', v, tipo: 'number');
                    }
                  },
                  items: const [
                    DropdownMenuItem(value: 80, child: Text('80 mm (estándar)')),
                    DropdownMenuItem(value: 58, child: Text('58 mm')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titulo,
              decoration: const InputDecoration(
                labelText: 'Título del recibo',
                hintText: 'RECIBO, COBRO…',
                isDense: true,
              ),
              textCapitalization: TextCapitalization.characters,
              onSubmitted: (v) => _save('recibo.titulo', v.trim()),
              onTapOutside: (_) => _save('recibo.titulo', _titulo.text.trim()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pie,
              decoration: const InputDecoration(
                labelText: 'Pie del recibo',
                hintText: '¡Gracias por su pago!',
                isDense: true,
              ),
              minLines: 1,
              maxLines: 3,
              onSubmitted: (v) => _save('recibo.pie_libre', v.trim()),
              onTapOutside: (_) => _save('recibo.pie_libre', _pie.text.trim()),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Un segmento (Encabezado / Cuerpo / Pie) con sus bloques reordenables.
// ───────────────────────────────────────────────────────────────────────
class _Segmento extends StatelessWidget {
  const _Segmento({
    required this.label,
    required this.icon,
    required this.zona,
    required this.bloques,
    required this.onReorder,
    required this.onVisible,
    required this.onSize,
    required this.onEspacio,
    required this.onMover,
    required this.onCampoVisible,
    required this.onCampoMover,
    required this.tenantId,
  });

  final String label;
  final IconData icon;
  final ReciboZona zona;
  final List<ReciboBloque> bloques;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int index, bool visible) onVisible;
  final void Function(int index, ReciboTextoSize size) onSize;
  final void Function(int index, ReciboEspacio espacio) onEspacio;
  final void Function(int index, ReciboZona destino) onMover;
  final void Function(int bloqueIndex, String campoId, bool visible)
      onCampoVisible;
  final void Function(int bloqueIndex, int campoIndex, bool arriba) onCampoMover;
  final String tenantId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TituloSeccion(label, icon),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: bloques.length,
              onReorder: onReorder,
              itemBuilder: (ctx, i) => _BloqueRow(
                key: ValueKey(bloques[i].id),
                index: i,
                bloque: bloques[i],
                info: reciboBloqueInfo(bloques[i].id),
                tenantId: tenantId,
                zonaActual: zona,
                onVisible: (v) => onVisible(i, v),
                onSize: (s) => onSize(i, s),
                onEspacio: (e) => onEspacio(i, e),
                onMover: (destino) => onMover(i, destino),
                onCampoVisible: (campoId, v) => onCampoVisible(i, campoId, v),
                onCampoMover: (fi, arriba) => onCampoMover(i, fi, arriba),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TituloSeccion extends StatelessWidget {
  const _TituloSeccion(this.label, this.icon);
  final String label;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: 8),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
            letterSpacing: 0.8,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Fila de un bloque: drag + nombre + tamaño + visibilidad (+ sub-toggle).
// ───────────────────────────────────────────────────────────────────────
class _BloqueRow extends ConsumerWidget {
  const _BloqueRow({
    required super.key,
    required this.index,
    required this.bloque,
    required this.info,
    required this.tenantId,
    required this.zonaActual,
    required this.onVisible,
    required this.onSize,
    required this.onEspacio,
    required this.onMover,
    required this.onCampoVisible,
    required this.onCampoMover,
  });

  final int index;
  final ReciboBloque bloque;
  final ReciboBloqueInfo? info;
  final String tenantId;
  final ReciboZona zonaActual;
  final ValueChanged<bool> onVisible;
  final ValueChanged<ReciboTextoSize> onSize;
  final ValueChanged<ReciboEspacio> onEspacio;
  final ValueChanged<ReciboZona> onMover;

  /// Callbacks de CAMPO (nivel-campo): togglear la visibilidad de un campo, y
  /// moverlo ↑/↓ dentro del bloque (arriba=true sube).
  final void Function(String campoId, bool visible) onCampoVisible;
  final void Function(int campoIndex, bool arriba) onCampoMover;

  // Sub-toggles booleanos que quedan (solo `cuota`: saldo + desglose de
  // descuentos/cargos + motivos). Los de meta/cliente (hora/código/cédula)
  // pasaron a ser CAMPOS reordenables (ver la sub-lista de campos abajo).
  List<(String, String)> get _subOpciones => switch (bloque.id) {
        'cuota' => const [
            ('recibo.mostrar_adeudado', 'Mostrar saldo pendiente'),
            ('recibo.mostrar_descuentos', 'Mostrar descuentos y cargos'),
            ('recibo.mostrar_motivo_descuentos', 'Mostrar motivos'),
          ],
        _ => const [],
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hideable = info?.hideable ?? true;
    final off = !bloque.visible;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.drag_indicator,
                      size: 22, color: scheme.outline),
                ),
              ),
              Expanded(
                child: Text(
                  info?.label ?? bloque.id,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: off ? scheme.outline : null,
                  ),
                ),
              ),
              // Tamaño (solo si el bloque está visible).
              if (!off) ...[
                _SelectorTamano(
                    size: bloque.size,
                    onSize: onSize,
                    conExtras: bloque.id == 'logo'),
                const SizedBox(width: 12),
              ],
              // Visibilidad. El bloque de totales no se puede ocultar.
              if (hideable)
                Switch(value: bloque.visible, onChanged: onVisible)
              else
                Tooltip(
                  message: 'El total no se puede ocultar',
                  child: Icon(Icons.lock, size: 20, color: scheme.outline),
                ),
              // Menú "Mover a zona": reubica el bloque entre encabezado / cuerpo
              // / pie (además del drag para reordenar dentro de la zona).
              PopupMenuButton<ReciboZona>(
                icon: Icon(Icons.more_vert, size: 20, color: scheme.outline),
                tooltip: 'Mover a zona',
                onSelected: onMover,
                itemBuilder: (_) => [
                  for (final (z, etiqueta) in const [
                    (ReciboZona.header, 'Mover a Encabezado'),
                    (ReciboZona.body, 'Mover a Cuerpo'),
                    (ReciboZona.footer, 'Mover a Pie'),
                  ])
                    if (z != zonaActual)
                      PopupMenuItem(value: z, child: Text(etiqueta)),
                ],
              ),
            ],
          ),
        ),
        // Espacio ANTES del bloque = separación con el segmento anterior.
        // (Aplica igual en modo imagen, compatible y PDF.)
        if (!off)
          Padding(
            padding: const EdgeInsets.only(left: 42, right: 12, bottom: 2),
            child: Row(
              children: [
                Icon(Icons.unfold_more, size: 16, color: scheme.outline),
                const SizedBox(width: 4),
                Text('Espacio antes',
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
                const Spacer(),
                _SelectorEspacio(
                    espacio: bloque.espacioAntes, onEspacio: onEspacio),
              ],
            ),
          ),
        // Campos del bloque (nivel-campo): reordenar con ↑/↓ y togglear cada
        // uno. Solo bloques de info (empresa/meta/cliente/servicio/metodo).
        if (!off && reciboCamposCatalogo(bloque.id) != null)
          for (var fi = 0; fi < bloque.campos.length; fi++)
            _CampoRow(
              campo: bloque.campos[fi],
              bloqueId: bloque.id,
              esPrimero: fi == 0,
              esUltimo: fi == bloque.campos.length - 1,
              onVisible: (v) => onCampoVisible(bloque.campos[fi].id, v),
              onArriba: () => onCampoMover(fi, true),
              onAbajo: () => onCampoMover(fi, false),
            ),
        // Sub-toggles dentro del bloque (cédula / saldo / descuentos),
        // indentados. Los de descuentos solo aparecen si algún feature de
        // descuentos/cargos está prendido (decisión Rubén 2026-06-12: no
        // configurar lo que no está habilitado; la data YA aplicada se
        // sigue mostrando en el recibo — queda como historial visible).
        // "Mostrar motivos" además exige el desglose ON.
        if (!off)
          for (final (subClave, subLabel) in _subOpciones)
            if (_subVisible(ref, subClave))
              Padding(
                padding: const EdgeInsets.only(left: 42, bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.subdirectory_arrow_right,
                        size: 16, color: scheme.outline),
                    const SizedBox(width: 4),
                    Text(subLabel,
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant)),
                    const Spacer(),
                    Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: _subValor(ref, subClave),
                        // upsert: el sub-toggle puede no tener su fila en
                        // tenants nuevos. Lo crea si falta.
                        onChanged: (v) =>
                            ref.read(settingsRepoProvider).upsert(
                                  tenantId,
                                  subClave,
                                  v,
                                  tipo: 'boolean',
                                  categoria: 'recibos',
                                  usuarioId: ref
                                      .read(cobradorActualProvider)
                                      .valueOrNull
                                      ?.id,
                                ),
                      ),
                    ),
                  ],
                ),
              ),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ],
    );
  }

  bool _subValor(WidgetRef ref, String clave) {
    final s = ref.watch(appSettingsProvider);
    return switch (clave) {
      // Solo se invoca con claves de 'cuota' (los toggles de meta/cliente
      // pasaron a ser CAMPOS reordenables). mostrar_adeudado cae al default.
      'recibo.mostrar_descuentos' => s.reciboMostrarDescuentos,
      'recibo.mostrar_motivo_descuentos' => s.reciboMostrarMotivoDescuentos,
      _ => s.reciboMostrarAdeudado,
    };
  }

  bool _subVisible(WidgetRef ref, String clave) {
    if (clave == 'recibo.mostrar_descuentos' ||
        clave == 'recibo.mostrar_motivo_descuentos') {
      final s = ref.watch(appSettingsProvider);
      final featuresOn = s.ajustesHabilitados ||
          s.reconexionHabilitada ||
          s.descuentoProntoPago > 0;
      if (!featuresOn) return false;
      if (clave == 'recibo.mostrar_motivo_descuentos') {
        return _subValor(ref, 'recibo.mostrar_descuentos');
      }
    }
    return true;
  }
}

/// Devuelve la lista de campos con `campoId` toggleado a `v`.
List<ReciboCampo> _conCampoToggle(
        List<ReciboCampo> campos, String campoId, bool v) =>
    [for (final c in campos) c.id == campoId ? c.copyWith(visible: v) : c];

/// Devuelve la lista con el campo en `index` movido una posición (arriba/abajo).
List<ReciboCampo> _conCampoMovido(
    List<ReciboCampo> campos, int index, bool arriba) {
  final destino = index + (arriba ? -1 : 1);
  if (index < 0 ||
      index >= campos.length ||
      destino < 0 ||
      destino >= campos.length) {
    return campos;
  }
  final lista = [...campos];
  final tmp = lista[index];
  lista[index] = lista[destino];
  lista[destino] = tmp;
  return lista;
}

/// Fila de un CAMPO dentro de un bloque de info: label + reordenar (↑/↓) +
/// toggle de visibilidad. Reordenar por FLECHAS (no drag anidado) para evitar
/// conflicto de gestos con el reorderable de bloques (regla #7/#11) — confiable
/// sin depender de test en vivo.
class _CampoRow extends StatelessWidget {
  const _CampoRow({
    required this.campo,
    required this.bloqueId,
    required this.esPrimero,
    required this.esUltimo,
    required this.onVisible,
    required this.onArriba,
    required this.onAbajo,
  });
  final ReciboCampo campo;
  final String bloqueId;
  final bool esPrimero;
  final bool esUltimo;
  final ValueChanged<bool> onVisible;
  final VoidCallback onArriba;
  final VoidCallback onAbajo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = reciboCampoInfo(bloqueId, campo.id)?.label ?? campo.id;
    return Padding(
      padding: const EdgeInsets.only(left: 42, right: 4, bottom: 2),
      child: Row(
        children: [
          Icon(Icons.subdirectory_arrow_right, size: 16, color: scheme.outline),
          const SizedBox(width: 4),
          Expanded(
            child: Text(label,
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            visualDensity: VisualDensity.compact,
            tooltip: 'Subir',
            onPressed: esPrimero ? null : onArriba,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            visualDensity: VisualDensity.compact,
            tooltip: 'Bajar',
            onPressed: esUltimo ? null : onAbajo,
          ),
          Transform.scale(
            scale: 0.8,
            child: Switch(value: campo.visible, onChanged: onVisible),
          ),
        ],
      ),
    );
  }
}

/// Selector de tamaño de letra compacto: tres "A" de distinto tamaño.
class _SelectorTamano extends StatelessWidget {
  const _SelectorTamano(
      {required this.size, required this.onSize, this.conExtras = false});
  final ReciboTextoSize size;
  /// Si es true (solo el bloque logo), agrega 2 tamaños más allá de grande.
  final bool conExtras;
  final ValueChanged<ReciboTextoSize> onSize;

  @override
  Widget build(BuildContext context) {
    // Con las 2 opciones extra (logo) el 5º label ya no entra como "A" — uso
    // ícono de imagen para los tamaños grandes del logo. Clampeo el valor
    // seleccionado a los segmentos disponibles (defensa: texto nunca extra).
    final sel = conExtras ||
            (size != ReciboTextoSize.extraGrande &&
                size != ReciboTextoSize.gigante)
        ? size
        : ReciboTextoSize.grande;
    return SegmentedButton<ReciboTextoSize>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: [
        const ButtonSegment(
          value: ReciboTextoSize.chico,
          label: Text('A', style: TextStyle(fontSize: 11)),
          tooltip: 'Chico',
        ),
        const ButtonSegment(
          value: ReciboTextoSize.normal,
          label: Text('A', style: TextStyle(fontSize: 14)),
          tooltip: 'Normal',
        ),
        const ButtonSegment(
          value: ReciboTextoSize.grande,
          label: Text('A', style: TextStyle(fontSize: 17)),
          tooltip: 'Grande',
        ),
        if (conExtras) ...const [
          ButtonSegment(
            value: ReciboTextoSize.extraGrande,
            icon: Icon(Icons.photo_size_select_large, size: 16),
            tooltip: 'Muy grande',
          ),
          ButtonSegment(
            value: ReciboTextoSize.gigante,
            icon: Icon(Icons.photo_size_select_actual, size: 18),
            tooltip: 'Gigante',
          ),
        ],
      ],
      selected: {sel},
      onSelectionChanged: (s) => onSize(s.first),
    );
  }
}

/// Selector del espacio ANTES del bloque (hueco entre segmentos). Dropdown
/// compacto — 4 niveles fijos; va en pantalla full-screen (no diálogo), así que
/// commitea sin el problema de dropdown-en-diálogo (regla #10). El MISMO valor
/// lo respetan los 3 renderers (`reciboEspacioPx` en pantalla/PDF,
/// `reciboEspacioFeed` en el compatible).
class _SelectorEspacio extends StatelessWidget {
  const _SelectorEspacio({required this.espacio, required this.onEspacio});
  final ReciboEspacio espacio;
  final ValueChanged<ReciboEspacio> onEspacio;

  static const _labels = {
    ReciboEspacio.ninguno: 'Ninguno',
    ReciboEspacio.chico: 'Chico',
    ReciboEspacio.normal: 'Normal',
    ReciboEspacio.amplio: 'Amplio',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropdownButton<ReciboEspacio>(
      value: espacio,
      isDense: true,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(8),
      style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
      items: [
        for (final e in ReciboEspacio.values)
          DropdownMenuItem(value: e, child: Text(_labels[e]!)),
      ],
      onChanged: (e) {
        if (e != null) onEspacio(e);
      },
    );
  }
}
