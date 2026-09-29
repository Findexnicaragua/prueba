import 'package:flutter/material.dart';

import '../../../data/utils/busqueda_cliente.dart';

const _verde = Color(0xFF1D9E75);

/// Una opción de filtro. `grupo` opcional habilita la jerarquía (ej. Zona:
/// `grupo` = municipio, la opción = comunidad). `subtitulo` para una 2da línea.
class FiltroOpcion {
  const FiltroOpcion({
    required this.id,
    required this.label,
    this.grupo,
    this.subtitulo,
  });

  final String id;
  final String label;
  final String? grupo;
  final String? subtitulo;
}

/// Chip de filtro **multi-selección** con **búsqueda** y **jerarquía** opcional.
/// Reemplaza a `DropdownFiltro` (single-select). El MISMO componente para
/// Estado/Cobrador/Zona/Nodo en Clientes, Cobros y Mapa.
///
/// Convención (decisión Rubén 2026-06-19): `seleccionados` arranca con TODO
/// seleccionado = **sin filtrar**; deseleccionar acota. **Aplica al instante**
/// (cada toque llama `onChanged`). La pill muestra el contador cuando hay menos
/// del total seleccionado. Usa un `OverlayEntry` anclado (no `showDialog` ni
/// `Navigator.pop` → sin riesgo de pantalla negra, checklist #7/#8).
class FiltroMultiDropdown extends StatefulWidget {
  const FiltroMultiDropdown({
    super.key,
    required this.icon,
    required this.hint,
    required this.opciones,
    required this.seleccionados,
    required this.onChanged,
    this.buscarHint,
  });

  final IconData icon;
  final String hint;
  final List<FiltroOpcion> opciones;
  final Set<String> seleccionados;
  final ValueChanged<Set<String>> onChanged;
  final String? buscarHint;

  @override
  State<FiltroMultiDropdown> createState() => _FiltroMultiDropdownState();
}

class _FiltroMultiDropdownState extends State<FiltroMultiDropdown> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  @override
  void dispose() {
    _overlay?.remove();
    _overlay = null;
    super.dispose();
  }

  void _toggleOverlay() {
    if (_overlay != null) {
      _cerrar();
    } else {
      _abrir();
    }
  }

  void _cerrar() {
    _overlay?.remove();
    _overlay = null;
    if (mounted) setState(() {});
  }

  void _abrir() {
    // 🔴 EL PANEL SE ACOTA A LA PANTALLA (2026-09-03).
    //
    // Se anclaba SIEMPRE por la izquierda del chip, con un ancho de hasta
    // 340px y sin mirar dónde estaba el chip. En Android, con el chip "Plan"
    // —que es el ÚLTIMO de la barra, o sea el más a la derecha— el panel
    // arrancaba cerca del borde y se cortaba: se veía "COMBO INTER…" y
    // "2.014,00 C$ · 1 clie…". Los de Cobrador y Zona nunca lo mostraron
    // porque están a la izquierda y ahí sobra lugar.
    //
    // Se calcula el espacio real a cada lado del chip y se elige: si por la
    // derecha no entra y por la izquierda hay más, el panel se ANCLA POR LA
    // DERECHA (crece hacia adentro). Y en los dos casos el ancho se clampea a
    // lo que hay. Es la misma lección del globo de la curva, que también se
    // salía por anclar sin acotar.
    final box = context.findRenderObject() as RenderBox?;
    final anchoPantalla = MediaQuery.sizeOf(context).width;
    const margen = 8.0;

    var alinearDerecha = false;
    var maxAncho = 340.0;
    if (box != null && box.hasSize) {
      final izqChip = box.localToGlobal(Offset.zero).dx;
      final derChip = izqChip + box.size.width;
      // Anclado a la IZQUIERDA del chip, el panel crece hacia la derecha.
      final espacioDerecha = anchoPantalla - izqChip - margen;
      // Anclado a la DERECHA del chip, crece hacia la izquierda.
      final espacioIzquierda = derChip - margen;

      alinearDerecha =
          espacioDerecha < 250 && espacioIzquierda > espacioDerecha;
      maxAncho = (alinearDerecha ? espacioIzquierda : espacioDerecha)
          .clamp(180.0, 340.0)
          .toDouble();
    }

    _overlay = OverlayEntry(
      builder: (_) => _Panel(
        link: _link,
        buscarHint: widget.buscarHint ?? 'Buscar…',
        opciones: widget.opciones,
        seleccionadosIniciales: widget.seleccionados,
        onChanged: widget.onChanged,
        onCerrar: _cerrar,
        alinearDerecha: alinearDerecha,
        maxAncho: maxAncho,
      ),
    );
    Overlay.of(context).insert(_overlay!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = widget.opciones.length;
    final n = widget.seleccionados.length;
    final activo = total > 0 && n < total;
    final abierto = _overlay != null;

    return CompositedTransformTarget(
      link: _link,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _toggleOverlay,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          decoration: BoxDecoration(
            color: activo ? scheme.primaryContainer : scheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: activo || abierto ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon,
                  size: 16,
                  color: activo
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                widget.hint,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: activo ? FontWeight.w600 : FontWeight.normal,
                  color:
                      activo ? scheme.onPrimaryContainer : scheme.onSurface,
                ),
              ),
              if (activo) ...[
                const SizedBox(width: 5),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$n',
                      style: TextStyle(fontSize: 11, color: scheme.onPrimary)),
                ),
              ],
              Icon(Icons.arrow_drop_down,
                  size: 18,
                  color: activo
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatefulWidget {
  const _Panel({
    required this.link,
    required this.buscarHint,
    required this.opciones,
    required this.seleccionadosIniciales,
    required this.onChanged,
    required this.onCerrar,
    required this.alinearDerecha,
    required this.maxAncho,
  });

  final LayerLink link;
  final String buscarHint;
  final List<FiltroOpcion> opciones;
  final Set<String> seleccionadosIniciales;
  final ValueChanged<Set<String>> onChanged;
  final VoidCallback onCerrar;

  /// El panel se ancla por la DERECHA del chip (crece hacia adentro) porque de
  /// ese lado no entraba. Lo decide `_abrir()` con el espacio real.
  final bool alinearDerecha;

  /// Ancho máximo ya acotado a lo que queda de pantalla.
  final double maxAncho;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  late Set<String> _sel;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _sel = {...widget.seleccionadosIniciales};
  }

  void _emit() => widget.onChanged({..._sel});

  void _toggle(String id) {
    setState(() => _sel.contains(id) ? _sel.remove(id) : _sel.add(id));
    _emit();
  }

  void _toggleGrupo(List<String> ids, bool todos) {
    setState(() => todos ? _sel.removeAll(ids) : _sel.addAll(ids));
    _emit();
  }

  void _todos() {
    setState(() => _sel = widget.opciones.map((o) => o.id).toSet());
    _emit();
  }

  void _ninguno() {
    setState(() => _sel.clear());
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Búsqueda por TOKENS, acento-insensible (audit #1d): cada palabra debe
    // aparecer (en cualquier orden) en el label o el grupo, plegando a ASCII
    // (encontrar "Núñez" tipeando "nunez"). Aplica a todos (cobros/clientes/mapa).
    final toks = tokensBusqueda(_query);
    final filtradas = toks.isEmpty
        ? widget.opciones
        : widget.opciones.where((o) {
            final label = foldBusqueda(o.label);
            final grupo = o.grupo == null ? '' : foldBusqueda(o.grupo!);
            return toks.every((t) => label.contains(t) || grupo.contains(t));
          }).toList();
    final hayGrupos = widget.opciones.any((o) => o.grupo != null);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onCerrar,
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          targetAnchor: widget.alinearDerecha
              ? Alignment.bottomRight
              : Alignment.bottomLeft,
          followerAnchor: widget.alinearDerecha
              ? Alignment.topRight
              : Alignment.topLeft,
          offset: const Offset(0, 6),
          child: Align(
            alignment: widget.alinearDerecha
                ? Alignment.topRight
                : Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              color: scheme.surface,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    // El mínimo no puede superar al máximo: en una pantalla
                    // angosta `maxAncho` puede quedar por debajo de 250 y eso
                    // sería una restricción imposible.
                    minWidth: widget.maxAncho < 250 ? widget.maxAncho : 250,
                    maxWidth: widget.maxAncho,
                    maxHeight: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                      child: TextField(
                        autofocus: true,
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 18),
                          hintText: widget.buscarHint,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    Flexible(child: _lista(scheme, filtradas, hayGrupos)),
                    const Divider(height: 1),
                    Row(
                      children: [
                        TextButton(
                            onPressed: _todos, child: const Text('Todos')),
                        TextButton(
                            onPressed: _ninguno, child: const Text('Ninguno')),
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Text(
                            '${_sel.length}/${widget.opciones.length}',
                            style: TextStyle(
                                color: scheme.onSurfaceVariant, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _lista(ColorScheme scheme, List<FiltroOpcion> opts, bool hayGrupos) {
    if (opts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Sin resultados'),
      );
    }
    if (!hayGrupos) {
      return ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [for (final o in opts) _fila(scheme, o)],
      );
    }
    final grupos = <String, List<FiltroOpcion>>{};
    for (final o in opts) {
      grupos.putIfAbsent(o.grupo ?? '—', () => []).add(o);
    }
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        for (final entry in grupos.entries) ...[
          _cabeceraGrupo(scheme, entry.key, entry.value),
          for (final o in entry.value) _fila(scheme, o, indent: true),
        ],
      ],
    );
  }

  Widget _cabeceraGrupo(
      ColorScheme scheme, String grupo, List<FiltroOpcion> hijos) {
    final ids = hijos.map((h) => h.id).toList();
    final marcados = ids.where(_sel.contains).length;
    final todos = marcados == ids.length;
    final algunos = marcados > 0 && !todos;
    return InkWell(
      onTap: () => _toggleGrupo(ids, todos),
      child: Container(
        color: scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(
              todos
                  ? Icons.check_box
                  : (algunos
                      ? Icons.indeterminate_check_box
                      : Icons.check_box_outline_blank),
              size: 19,
              color: todos || algunos ? _verde : scheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(grupo,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            Text('$marcados/${ids.length}',
                style:
                    TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _fila(ColorScheme scheme, FiltroOpcion o, {bool indent = false}) {
    final on = _sel.contains(o.id);
    return InkWell(
      onTap: () => _toggle(o.id),
      child: Padding(
        padding: EdgeInsets.fromLTRB(indent ? 28 : 10, 7, 10, 7),
        child: Row(
          children: [
            Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
                size: 19, color: on ? _verde : scheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(o.label, style: const TextStyle(fontSize: 14)),
                  if (o.subtitulo != null)
                    Text(o.subtitulo!,
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
