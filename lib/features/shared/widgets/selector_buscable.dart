import 'package:flutter/material.dart';

import '../../../data/utils/busqueda_cliente.dart'
    show foldBusqueda, tokensBusqueda;

/// Una opción del [elegirConBuscador]: el [valor] que devuelve al elegir, el
/// [nombre] que se muestra y matchea, y un [subtitulo] opcional para desambiguar.
class OpcionSelector<T> {
  const OpcionSelector({
    required this.valor,
    required this.nombre,
    this.subtitulo,
    this.textoBusqueda,
  });

  final T valor;
  final String nombre;
  final String? subtitulo;

  /// Texto extra contra el que matchea el buscador, ADEMÁS del [nombre]. Útil
  /// para encontrar el ítem por campos que no se muestran como título (código,
  /// cédula, teléfono). Si es null, el buscador matchea solo por [nombre].
  final String? textoBusqueda;
}

/// Selector con **buscador en vivo**, pensado para listas grandes (cientos/miles
/// de ítems): tocás → escribís → la lista se filtra al instante → tocás el
/// resultado. Devuelve el `valor` elegido (o null si se cancela).
///
/// El match pliega AMBOS lados (lo escrito y el nombre) a forma canónica con
/// [foldBusqueda] → es insensible a mayúsculas/acentos/ñ y SIMÉTRICO: encontrás
/// "Cañón" tanto escribiendo "cañón" como "canon" (regla #1d del proyecto).
///
/// Reemplaza al `DropdownButton`, que en estos diálogos no commitea su
/// `onChanged` (su menú es una ruta-overlay aparte). Este es un diálogo común
/// con `onTap` + `Navigator.pop`, que sí commitea.
Future<T?> elegirConBuscador<T>(
  BuildContext context, {
  required String titulo,
  required List<OpcionSelector<T>> opciones,
  String hint = 'Buscar...',
}) {
  return showDialog<T>(
    context: context,
    builder: (_) =>
        _SelectorBuscable<T>(titulo: titulo, opciones: opciones, hint: hint),
  );
}

class _SelectorBuscable<T> extends StatefulWidget {
  const _SelectorBuscable({
    required this.titulo,
    required this.opciones,
    required this.hint,
  });

  final String titulo;
  final List<OpcionSelector<T>> opciones;
  final String hint;

  @override
  State<_SelectorBuscable<T>> createState() => _SelectorBuscableState<T>();
}

class _SelectorBuscableState<T> extends State<_SelectorBuscable<T>> {
  final _ctrl = TextEditingController();
  late List<OpcionSelector<T>> _filtradas = widget.opciones;
  // Texto plegado de cada opción (nombre + textoBusqueda opcional), precomputado
  // una vez (no en cada tecla).
  late final List<String> _nombresFold = widget.opciones
      .map((o) => foldBusqueda(
          o.textoBusqueda == null ? o.nombre : '${o.nombre} ${o.textoBusqueda}'))
      .toList();

  void _filtrar(String q) {
    // Búsqueda por TOKENS: cada palabra debe aparecer (en cualquier orden) en el
    // nombre plegado → "maria ruiz" encuentra "María Luisa Peña Ruíz".
    final toks = tokensBusqueda(q);
    setState(() {
      _filtradas = toks.isEmpty
          ? widget.opciones
          : [
              for (var i = 0; i < widget.opciones.length; i++)
                if (toks.every(_nombresFold[i].contains)) widget.opciones[i],
            ];
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Buscador SIEMPRE visible: estas listas vienen de la DB y crecen (planes,
    // clientes, productos, nodos…) → el typing tokenizado (foldBusqueda) debe
    // estar siempre, no solo en listas largas. La lista queda debajo y
    // scrolleable; el alto se ajusta al contenido hasta el máximo.
    final altoMax =
        (MediaQuery.of(context).size.height * 0.6).clamp(300.0, 460.0);
    final alto = (96 + widget.opciones.length * 56.0).clamp(180.0, altoMax);
    // Autofocus solo en listas largas (donde seguro vas a tipear). En cortas el
    // box está visible pero sin robar foco → podés tocar un ítem directo sin que
    // salte el teclado en Android.
    final autofocus = widget.opciones.length > 8;
    return AlertDialog(
      title: Text(widget.titulo),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 380,
        height: alto,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _ctrl,
                autofocus: autofocus,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: _filtrar,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_filtradas.length} de ${widget.opciones.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _filtradas.isEmpty
                  ? Center(
                      child: Text(
                        'Sin resultados',
                        style: TextStyle(color: Theme.of(context).hintColor),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filtradas.length,
                      itemBuilder: (context, i) {
                        final o = _filtradas[i];
                        return ListTile(
                          title: Text(o.nombre),
                          subtitle:
                              o.subtitulo == null ? null : Text(o.subtitulo!),
                          onTap: () => Navigator.pop(context, o.valor),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
