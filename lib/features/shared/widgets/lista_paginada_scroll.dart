import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/utils/errores.dart';
import 'empty_state.dart';

/// Lista paginada estándar de la app (scroll-windowing + contador real).
///
/// Generaliza el patrón gold-standard de `clientes_admin_screen.dart`
/// (`_ListaState`) para que CUALQUIER lista de miles de filas (clientes,
/// cobros, inventario…) cargue rápido y se comporte igual. Las 6 piezas:
///
/// 1. **Ventana SQL**: el consumidor pide `LIMIT limite + 1` en su query
///    ([construirStream]) → la fila extra dice si hay más SIN un COUNT en el
///    borde. El SELECT agrega solo sobre la página → costo O(página), no
///    O(tenant).
/// 2. **Scroll-windowing**: [tamPagina] (def. 60); al acercarse al fondo crece
///    `+tamPagina` y re-suscribe.
/// 3. **Contador real**: [construirConteo] (`COUNT(*)` con el MISMO WHERE, sin
///    LIMIT) corre en paralelo → el número del header nunca diverge de la lista.
/// 4. **Build puro / anti-flicker**: la suscripción se maneja a mano (no
///    `StreamBuilder`); el render se deriva de estado seteado en los callbacks
///    (data Y error) → la paginación nunca queda bloqueada por un stream que
///    falló (regla audit #2).
/// 5. **Reset por filtro**: cuando cambia [filtroKey] → primera página + recuento.
/// 6. **Cold-start (audit #7)**: `ref.listen(dbEpochProvider)` re-suscribe si la
///    DB se recrea (cambio de usuario) — ahora TODO consumidor lo hereda.
class ListaPaginadaScroll extends ConsumerStatefulWidget {
  const ListaPaginadaScroll({
    super.key,
    required this.construirStream,
    required this.construirConteo,
    required this.itemBuilder,
    required this.filtroKey,
    this.headerBuilder,
    this.vacio,
    this.tamPagina = 60,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.separador = const SizedBox(height: 8),
    this.scrollController,
  });

  /// Construye el stream de UNA página. DEBE pedir `LIMIT limite + 1` (la fila
  /// extra le dice al widget si hay más, sin un COUNT en el borde). Se re-invoca
  /// al crecer la ventana y al cambiar [filtroKey].
  final Stream<List<Map<String, dynamic>>> Function(int limite) construirStream;

  /// Stream del total REAL del filtro (`COUNT(*)` con el MISMO WHERE, sin LIMIT).
  /// Corre en paralelo a la lista; alimenta el contador del header. Re-suscrito
  /// solo al cambiar [filtroKey] (paginar NO recuenta).
  final Stream<int> Function() construirConteo;

  /// Renderiza una fila.
  final Widget Function(BuildContext context, Map<String, dynamic> fila)
      itemBuilder;

  /// Cambia ⇒ la lista resetea a la primera página y recuenta. El consumidor lo
  /// arma con sus filtros (un `String`/record). Si no cambia, paginar no recuenta.
  final Object filtroKey;

  /// Header opcional (ej. el contador "148 productos"). Recibe el total real
  /// (null mientras cuenta) → devolvé tu widget, o null para no mostrar header.
  final Widget? Function(int? total)? headerBuilder;

  /// Qué mostrar cuando la página vino vacía. Default: un [EmptyState] genérico.
  final Widget? vacio;

  final int tamPagina;
  final EdgeInsetsGeometry padding;
  final Widget separador;

  /// Controller externo opcional (para anidar la lista en otro scroll).
  final ScrollController? scrollController;

  @override
  ConsumerState<ListaPaginadaScroll> createState() =>
      _ListaPaginadaScrollState();
}

class _ListaPaginadaScrollState extends ConsumerState<ListaPaginadaScroll> {
  late int _limite = widget.tamPagina;
  ScrollController? _scrollPropio;
  ScrollController get _scrollCtrl =>
      widget.scrollController ?? (_scrollPropio ??= ScrollController());

  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  StreamSubscription<int>? _subTotal;

  // Filas recortadas a _limite. null = cargando primera página (o refiltrando).
  List<Map<String, dynamic>>? _filas;
  Object? _error;
  // ¿Hay al menos una fila más allá de la página? Traemos _limite+1 para saberlo
  // EXACTO sin una query extra en el borde múltiplo-de-tamPagina.
  bool _hayMas = false;
  // Agrandando la ventana (footer "cargando más" + guard anti-doble disparo).
  bool _creciendo = false;
  int? _total;

  @override
  void initState() {
    super.initState();
    _suscribir();
    _suscribirTotal();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollPropio?.dispose();
    _sub?.cancel();
    _subTotal?.cancel();
    super.dispose();
  }

  void _suscribir() {
    _sub?.cancel();
    _sub = widget.construirStream(_limite).listen(
      (data) {
        if (!mounted) return;
        setState(() {
          // Vino _limite+1: si llegó la fila extra, hay más → la descartamos del
          // render y marcamos _hayMas. El contador y el footer quedan exactos.
          _hayMas = data.length > _limite;
          _filas = _hayMas ? data.sublist(0, _limite) : data;
          _creciendo = false;
          _error = null;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        // Limpiamos _creciendo TAMBIÉN en error → la paginación nunca queda
        // bloqueada por un stream que falló.
        setState(() {
          _error = e;
          _creciendo = false;
        });
      },
    );
  }

  void _suscribirTotal() {
    _subTotal?.cancel();
    _subTotal = widget.construirConteo().listen((n) {
      if (!mounted) return;
      setState(() => _total = n);
    });
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients || !_hayMas || _creciendo) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) {
      setState(() {
        _creciendo = true;
        _limite += widget.tamPagina;
      });
      _suscribir();
    }
  }

  // Primera página desde el tope (spinner, sin filas del filtro anterior) +
  // recuento. Lo dispara el cambio de filtroKey y la recreación de la DB.
  void _reiniciar() {
    setState(() {
      _limite = widget.tamPagina;
      _hayMas = false;
      _creciendo = false;
      _filas = null;
      _error = null;
      _total = null;
    });
    _suscribir();
    _suscribirTotal();
  }

  @override
  void didUpdateWidget(ListaPaginadaScroll old) {
    super.didUpdateWidget(old);
    if (widget.filtroKey != old.filtroKey) _reiniciar();
  }

  @override
  Widget build(BuildContext context) {
    // Cold-start (audit #7): re-suscribir si se recreó la DB (cambio de usuario).
    ref.listen(dbEpochProvider, (_, __) => _reiniciar());

    if (_error != null) {
      return Center(child: Text(mensajeErrorHumano(_error!)));
    }
    final rows = _filas;
    // Primera carga / refiltrado → SPINNER (nunca el vacío mientras calcula).
    if (rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      return widget.vacio ??
          const EmptyState(
            icon: Icons.inbox_outlined,
            titulo: 'Sin resultados',
            descripcion: 'No hay nada que coincida con el filtro.',
          );
    }
    final header = widget.headerBuilder?.call(_total);
    final mostrarFooter = _creciendo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null) header,
        Expanded(
          child: ListView.separated(
            controller: _scrollCtrl,
            padding: widget.padding,
            itemCount: rows.length + (mostrarFooter ? 1 : 0),
            separatorBuilder: (_, __) => widget.separador,
            itemBuilder: (context, i) {
              if (i >= rows.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              return widget.itemBuilder(context, rows[i]);
            },
          ),
        ),
      ],
    );
  }
}
