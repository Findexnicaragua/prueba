import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/utils/busqueda_cliente.dart' show foldSqlTokens;
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/filtro_multi_dropdown.dart';
import '../../shared/widgets/filtros_bar.dart';
import '../../shared/widgets/lista_paginada_scroll.dart';
import 'inv_stock_flows.dart';
import 'inventario_comun.dart';
import '../../../data/providers/cobrador_provider.dart';

/// Inventario rediseñado (vista exclusiva) — montado sobre los estándares de
/// listas: [ListaPaginadaScroll] (scroll-windowing + COUNT real) y [FiltrosBar]
/// (filtros multi-selección con la continuidad de Clientes/Cobros).
///
/// Tabs **Equipos** (seriales paginados + filtros) y **Existencias** (granel con
/// stock derivado del ledger + "bajo mínimo") + botón **Catálogo** → config. Es
/// la ruta de producción `/admin/inventario` (reemplazó a la `InventarioScreen`
/// vieja en el cierre del rediseño 2026; la ficha en `/admin/inventario/equipo/:id`).
/// NOTA: la clase conserva el sufijo `V2` por historia; renombrar es cosmético.
class InventarioV2Screen extends StatelessWidget {
  const InventarioV2Screen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: TabBar(tabs: [
                  Tab(text: 'Equipos'),
                  Tab(text: 'Existencias'),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextButton.icon(
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Catálogo'),
                  // go (no push): ruta del AdminShell → sino el título del shell
                  // queda en "Inventario" (regla #12, audit 2026-07-05).
                  onPressed: () => context.go('/admin/inventario/catalogo'),
                ),
              ),
            ],
          ),
          const Expanded(
            child: TabBarView(children: [
              _EquiposTab(),
              _ExistenciasTab(),
            ]),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// TAB EQUIPOS (seriales) — paginado + filtros + búsqueda
// ===========================================================================
class _EquiposTab extends ConsumerStatefulWidget {
  const _EquiposTab();
  @override
  ConsumerState<_EquiposTab> createState() => _EquiposTabState();
}

class _EquiposTabState extends ConsumerState<_EquiposTab> {
  final TextEditingController _busquedaCtrl = TextEditingController();
  Timer? _debounce;
  String _busqueda = '';
  bool _tieneTexto = false; // la "X" reacciona al instante (sin esperar debounce)

  // null = sin filtrar (la convención de FiltrosBar).
  Set<String>? _estados;
  Set<String>? _productos;
  Set<String>? _ubicaciones;

  // Opciones dinámicas de los chips. Se (re)suscriben en initState y cada vez que
  // se recrea la DB (cambio de usuario, dbEpoch) → nunca quedan con datos del
  // tenant anterior (igual que ListaPaginadaScroll para la lista).
  StreamSubscription<List<Map<String, dynamic>>>? _subProd;
  StreamSubscription<List<Map<String, dynamic>>>? _subUbic;
  List<FiltroOpcion> _prodOpts = const [];
  List<FiltroOpcion> _ubicOpts = const [];

  @override
  void initState() {
    super.initState();
    _suscribirOpciones();
  }

  void _suscribirOpciones() {
    // Solo productos serializados pueden tener seriales (= Equipos).
    _subProd?.cancel();
    _subProd = ps.db
        .watch(
            'SELECT id, nombre FROM inv_productos WHERE activo = 1 AND es_serializado = 1 ORDER BY nombre')
        .listen((rows) {
      if (mounted) setState(() => _prodOpts = opcionesDesdeRows(rows));
    });
    _subUbic?.cancel();
    _subUbic = ps.db
        .watch(
            'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre')
        .listen((rows) {
      if (mounted) setState(() => _ubicOpts = opcionesDesdeRows(rows));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _subProd?.cancel();
    _subUbic?.cancel();
    _busquedaCtrl.dispose();
    super.dispose();
  }

  void _onBusqueda(String v) {
    // La "X" reacciona al instante; la query se debouncea 300ms aparte.
    final tiene = v.trim().isNotEmpty;
    if (tiene != _tieneTexto) setState(() => _tieneTexto = tiene);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _busqueda = v.trim());
    });
  }

  void _limpiar() {
    _debounce?.cancel();
    _busquedaCtrl.clear();
    setState(() {
      _busqueda = '';
      _tieneTexto = false;
      _estados = null;
      _productos = null;
      _ubicaciones = null;
    });
  }

  // Key que cambia cuando cambia cualquier filtro → ListaPaginadaScroll resetea
  // a la primera página y recuenta. Ordenamos los sets para una key estable.
  String get _filtroKey {
    String k(Set<String>? s) => s == null ? '' : (s.toList()..sort()).join(',');
    return '$_busqueda|${k(_estados)}|${k(_productos)}|${k(_ubicaciones)}';
  }

  // WHERE + params compartidos por la lista y el COUNT (consistencia #10: el
  // contador del header nunca diverge de la lista).
  (List<String>, List<Object?>) _construirWhere() {
    final where = <String>[];
    final params = <Object?>[];
    void inClause(String col, Set<String>? sel) {
      if (sel != null && sel.isNotEmpty) {
        where.add('$col IN (${List.filled(sel.length, '?').join(',')})');
        params.addAll(sel);
      }
    }

    inClause('s.estado', _estados);
    inClause('s.producto_id', _productos);
    inClause('s.ubicacion_id', _ubicaciones);
    if (_busqueda.isNotEmpty) {
      // Búsqueda por TOKENS (audit #1d/#10, 2026-06-30): cada campo debe contener
      // TODOS los tokens en CUALQUIER orden → "ruiz maria" encuentra el equipo de
      // "María … Ruíz". Antes era substring contiguo (fallaba el orden invertido),
      // crítico para cl.nombre (multi-palabra). Acentos/ñ vía foldSqlExpr (#1d).
      final serial = foldSqlTokens('s.serial', _busqueda);
      if (serial.sql.isNotEmpty) {
        final nombre = foldSqlTokens('p.nombre', _busqueda);
        final cliente = foldSqlTokens('cl.nombre', _busqueda);
        where.add('(${serial.sql} OR ${nombre.sql} OR ${cliente.sql})');
        params.addAll([...serial.params, ...nombre.params, ...cliente.params]);
      }
    }
    return (where, params);
  }

  Stream<List<Map<String, dynamic>>> _streamEquipos(int limite) {
    final (where, params) = _construirWhere();
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    // LIMIT ?  con limite+1 = la fila-centinela que le dice a ListaPaginadaScroll
    // si hay más página (sin un COUNT en el borde).
    final sql = '''
      SELECT s.id, s.serial, s.estado, s.producto_id, s.ubicacion_id, s.cliente_id,
             p.nombre AS producto, cl.nombre AS cliente_nombre
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
   LEFT JOIN clientes cl ON cl.id = s.cliente_id
       $whereSql
       ORDER BY p.nombre, s.serial
       LIMIT ?
    ''';
    return ps.db.watch(sql, parameters: [...params, limite + 1]);
  }

  Stream<int> _conteoEquipos() {
    final (where, params) = _construirWhere();
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    // Mismo FROM/JOIN/WHERE que la lista (la búsqueda filtra por p.nombre y
    // cl.nombre, así que los JOIN son necesarios también en el COUNT).
    final sql = '''
      SELECT COUNT(*) AS n
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
   LEFT JOIN clientes cl ON cl.id = s.cliente_id
       $whereSql
    ''';
    return ps.db
        .watch(sql, parameters: params)
        .map((rows) => rows.isEmpty ? 0 : ((rows.first['n'] as num?)?.toInt() ?? 0));
  }

  @override
  Widget build(BuildContext context) {
    // Re-suscribir las opciones de los chips si se recreó la DB (cambio de usuario).
    ref.listen(dbEpochProvider, (_, __) => _suscribirOpciones());
    final scheme = Theme.of(context).colorScheme;
    final hayFiltro = _busqueda.isNotEmpty ||
        _estados != null ||
        _productos != null ||
        _ubicaciones != null;
    return Scaffold(
      // Ingreso de equipos serializados (crea seriales en stock).
      floatingActionButton: ref.watch(soloLecturaProvider)
          ? null
          : FloatingActionButton.extended(
        heroTag: 'fab_ingreso_eq',
        onPressed: () => ingresarStock(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Ingreso'),
      ),
      body: Column(
      children: [
        // Buscador (serial / producto / cliente), debounced.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _busquedaCtrl,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Buscar por serial, producto o cliente…',
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              suffixIcon: !_tieneTexto
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Limpiar búsqueda',
                      onPressed: () {
                        _debounce?.cancel();
                        _busquedaCtrl.clear();
                        setState(() {
                          _busqueda = '';
                          _tieneTexto = false;
                        });
                      },
                    ),
            ),
            onChanged: _onBusqueda,
          ),
        ),
        FiltrosBar(
          dimensiones: [
            FiltroDim(
              icon: Icons.flag_outlined,
              hint: 'Estado',
              opciones: kEstadoSerialOpciones,
              seleccion: _estados,
              onChanged: (s) => setState(() => _estados = s),
            ),
            FiltroDim(
              icon: Icons.inventory_2_outlined,
              hint: 'Producto',
              buscarHint: 'Buscar producto…',
              opciones: _prodOpts,
              seleccion: _productos,
              onChanged: (s) => setState(() => _productos = s),
            ),
            FiltroDim(
              icon: Icons.place_outlined,
              hint: 'Ubicación',
              buscarHint: 'Buscar ubicación…',
              opciones: _ubicOpts,
              seleccion: _ubicaciones,
              onChanged: (s) => setState(() => _ubicaciones = s),
            ),
          ],
          activosExtra: _busqueda.isEmpty ? 0 : 1,
          onLimpiar: _limpiar,
        ),
        Expanded(
          child: ListaPaginadaScroll(
            filtroKey: _filtroKey,
            construirStream: _streamEquipos,
            construirConteo: _conteoEquipos,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            separador: const Divider(height: 1),
            headerBuilder: (total) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                total == null
                    ? '…'
                    : '$total ${total == 1 ? 'equipo' : 'equipos'}',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
            vacio: EmptyState(
              icon: Icons.qr_code_2,
              titulo: 'Sin equipos',
              descripcion: hayFiltro
                  ? 'Ningún equipo coincide con el filtro. Tocá "Limpiar" para verlos todos.'
                  : 'Cargá equipos serializados con el botón "Ingreso".',
            ),
            itemBuilder: (context, row) => _CardEquipo(row: row),
          ),
        ),
      ],
      ),
    );
  }
}

/// Card de un equipo serializado. Tap → historial del serial (op_log).
class _CardEquipo extends StatelessWidget {
  const _CardEquipo({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estado = row['estado'] as String? ?? 'en_stock';
    final cli = row['cliente_nombre'] as String?;
    final color = estadoSerialColor(estado, scheme);
    final sub = [
      row['producto'] as String? ?? '',
      if (estado == 'instalado' && cli != null) 'en $cli',
    ].join(' · ');
    return ListTile(
      leading: Icon(Icons.qr_code_2, color: scheme.outline),
      title: Text(row['serial'] as String? ?? ''),
      subtitle: Text(sub),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          kEstadoSerial[estado] ?? estado,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      onTap: () =>
          context.go('/admin/inventario/equipo/${row['id'] as String}'),
    );
  }
}

// ===========================================================================
// TAB EXISTENCIAS (granel) — stock derivado del ledger, paginado + filtros
// ===========================================================================

// Stock granel de un producto = Σ(cantidad con destino) − Σ(cantidad con
// origen) sobre el ledger inv_movimientos. Se reusa en el SELECT y en el filtro
// "bajo mínimo" (SQLite no deja filtrar por el alias derivado → se repite).
const _granelStock =
    'COALESCE((SELECT SUM(CASE WHEN m.ubicacion_destino_id IS NOT NULL THEN m.cantidad ELSE 0 END)'
    ' - SUM(CASE WHEN m.ubicacion_origen_id IS NOT NULL THEN m.cantidad ELSE 0 END)'
    ' FROM inv_movimientos m WHERE m.producto_id = p.id), 0)';

// Cantidad: entero si es redondo, si no decimal (espeja inventario_screen.dart).
String _fmtCant(num n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();

class _ExistenciasTab extends ConsumerStatefulWidget {
  const _ExistenciasTab();
  @override
  ConsumerState<_ExistenciasTab> createState() => _ExistenciasTabState();
}

class _ExistenciasTabState extends ConsumerState<_ExistenciasTab> {
  final TextEditingController _busquedaCtrl = TextEditingController();
  Timer? _debounce;
  String _busqueda = '';
  bool _tieneTexto = false;
  Set<String>? _categorias;
  bool _soloBajo = false;

  StreamSubscription<List<Map<String, dynamic>>>? _subCat;
  List<FiltroOpcion> _catOpts = const [];

  @override
  void initState() {
    super.initState();
    _suscribirOpciones();
  }

  void _suscribirOpciones() {
    _subCat?.cancel();
    _subCat = ps.db
        .watch(
            'SELECT id, nombre FROM inv_categorias WHERE activo = 1 ORDER BY nombre')
        .listen((rows) {
      if (mounted) setState(() => _catOpts = opcionesDesdeRows(rows));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _subCat?.cancel();
    _busquedaCtrl.dispose();
    super.dispose();
  }

  void _onBusqueda(String v) {
    final tiene = v.trim().isNotEmpty;
    if (tiene != _tieneTexto) setState(() => _tieneTexto = tiene);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _busqueda = v.trim());
    });
  }

  void _limpiar() {
    _debounce?.cancel();
    _busquedaCtrl.clear();
    setState(() {
      _busqueda = '';
      _tieneTexto = false;
      _categorias = null;
      _soloBajo = false;
    });
  }

  String get _filtroKey {
    final cats =
        _categorias == null ? '' : (_categorias!.toList()..sort()).join(',');
    return '$_busqueda|$cats|$_soloBajo';
  }

  (List<String>, List<Object?>) _construirWhere() {
    final where = <String>['p.activo = 1', 'p.es_serializado = 0'];
    final params = <Object?>[];
    if (_categorias != null && _categorias!.isNotEmpty) {
      where.add(
          'p.categoria_id IN (${List.filled(_categorias!.length, '?').join(',')})');
      params.addAll(_categorias!);
    }
    if (_busqueda.isNotEmpty) {
      // Búsqueda por TOKENS (audit #1d/#10) — palabra por palabra, cualquier orden.
      final nombre = foldSqlTokens('p.nombre', _busqueda);
      if (nombre.sql.isNotEmpty) {
        final codigo = foldSqlTokens('p.codigo', _busqueda);
        where.add('(${nombre.sql} OR ${codigo.sql})');
        params.addAll([...nombre.params, ...codigo.params]);
      }
    }
    if (_soloBajo) {
      // Misma definición que el badge del menú (inventarioStockBajoCountProvider):
      // mínimo configurado (>0) y stock por debajo. Repetimos la subquery porque
      // SQLite no permite filtrar por el alias derivado en el WHERE.
      where.add('p.stock_minimo > 0 AND $_granelStock < p.stock_minimo');
    }
    return (where, params);
  }

  Stream<List<Map<String, dynamic>>> _streamExistencias(int limite) {
    final (where, params) = _construirWhere();
    final sql = '''
      SELECT p.id, p.nombre, p.unidad, p.costo_promedio, p.stock_minimo,
             $_granelStock AS stock
        FROM inv_productos p
       WHERE ${where.join(' AND ')}
       ORDER BY p.nombre
       LIMIT ?
    ''';
    return ps.db.watch(sql, parameters: [...params, limite + 1]);
  }

  Stream<int> _conteoExistencias() {
    final (where, params) = _construirWhere();
    final sql =
        'SELECT COUNT(*) AS n FROM inv_productos p WHERE ${where.join(' AND ')}';
    return ps.db.watch(sql, parameters: params).map(
        (rows) => rows.isEmpty ? 0 : ((rows.first['n'] as num?)?.toInt() ?? 0));
  }

  @override
  Widget build(BuildContext context) {
    // Re-suscribir las opciones de los chips si se recreó la DB (cambio de usuario).
    ref.listen(dbEpochProvider, (_, __) => _suscribirOpciones());
    final scheme = Theme.of(context).colorScheme;
    final hayFiltro = _busqueda.isNotEmpty || _categorias != null || _soloBajo;
    return Scaffold(
      // Granel: Ingreso (recibir stock) + Movimiento (egreso/ajuste/transferencia).
      floatingActionButton: ref.watch(soloLecturaProvider)
          ? null
          : Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'fab_mov_ex',
            onPressed: () => movimientoGranel(context, ref),
            tooltip: 'Movimiento de granel',
            child: const Icon(Icons.swap_horiz),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'fab_ingreso_ex',
            onPressed: () => ingresarStock(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('Ingreso'),
          ),
        ],
      ),
      body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _busquedaCtrl,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Buscar producto…',
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              suffixIcon: !_tieneTexto
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Limpiar búsqueda',
                      onPressed: () {
                        _debounce?.cancel();
                        _busquedaCtrl.clear();
                        setState(() {
                          _busqueda = '';
                          _tieneTexto = false;
                        });
                      },
                    ),
            ),
            onChanged: _onBusqueda,
          ),
        ),
        FiltrosBar(
          dimensiones: [
            FiltroDim(
              icon: Icons.category_outlined,
              hint: 'Categoría',
              buscarHint: 'Buscar categoría…',
              opciones: _catOpts,
              seleccion: _categorias,
              onChanged: (s) => setState(() => _categorias = s),
            ),
          ],
          trailing: [
            FilterChip(
              label: const Text('Bajo mínimo'),
              avatar: Icon(Icons.warning_amber_rounded,
                  size: 18, color: scheme.outline),
              selected: _soloBajo,
              onSelected: (v) => setState(() => _soloBajo = v),
            ),
          ],
          activosExtra: (_busqueda.isEmpty ? 0 : 1) + (_soloBajo ? 1 : 0),
          onLimpiar: _limpiar,
        ),
        Expanded(
          child: ListaPaginadaScroll(
            filtroKey: _filtroKey,
            construirStream: _streamExistencias,
            construirConteo: _conteoExistencias,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            separador: const Divider(height: 1),
            headerBuilder: (total) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                total == null
                    ? '…'
                    : '$total ${total == 1 ? 'producto' : 'productos'}',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
            vacio: EmptyState(
              icon: Icons.inventory_2_outlined,
              titulo: 'Sin existencias',
              descripcion: hayFiltro
                  ? 'Ningún producto a granel coincide con el filtro.'
                  : 'Cargá stock a granel con el botón "Ingreso".',
            ),
            itemBuilder: (context, row) => _CardExistencia(row: row),
          ),
        ),
      ],
      ),
    );
  }
}

/// Card de un producto a granel. Tap → desglose de stock por ubicación.
class _CardExistencia extends StatelessWidget {
  const _CardExistencia({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stock = (row['stock'] as num?) ?? 0;
    final stockMin = (row['stock_minimo'] as num?) ?? 0;
    final unidad = (row['unidad'] as String?) ?? 'u';
    final costo = (row['costo_promedio'] as num?) ?? 0;
    final valor = stock > 0 ? stock * costo : 0;
    // Bajo = sin stock, o por debajo del mínimo configurado (espeja la card vieja).
    final bajo = stock <= 0 || (stockMin > 0 && stock < stockMin);
    return ListTile(
      leading: Icon(Icons.inventory_2_outlined, color: scheme.outline),
      title: Text(row['nombre'] as String? ?? ''),
      subtitle: costo > 0
          ? Text(
              'Costo prom. ${Fmt.cordobas(costo)}'
              '${valor > 0 ? ' · Valor ${Fmt.cordobas(valor)}' : ''}',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            )
          : null,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${_fmtCant(stock)} $unidad',
            style: TextStyle(
                fontWeight: FontWeight.w600, color: bajo ? scheme.error : null),
          ),
          if (stockMin > 0)
            Text('mín ${_fmtCant(stockMin)}',
                style: TextStyle(fontSize: 11, color: scheme.outline)),
        ],
      ),
      onTap: () => _verStockPorUbicacion(
          context, row['id'] as String, row['nombre'] as String? ?? '', unidad),
    );
  }
}

void _verStockPorUbicacion(
    BuildContext context, String productoId, String nombre, String unidad) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _StockUbicacionSheet(
        productoId: productoId, nombre: nombre, unidad: unidad),
  );
}

/// Desglose de stock (granel) por ubicación, derivado del ledger.
class _StockUbicacionSheet extends StatefulWidget {
  const _StockUbicacionSheet(
      {required this.productoId, required this.nombre, required this.unidad});
  final String productoId;
  final String nombre;
  final String unidad;
  @override
  State<_StockUbicacionSheet> createState() => _StockUbicacionSheetState();
}

class _StockUbicacionSheetState extends State<_StockUbicacionSheet> {
  late final Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch('''
      SELECT u.nombre,
             COALESCE((SELECT SUM(CASE WHEN m.ubicacion_destino_id = u.id THEN m.cantidad ELSE 0 END)
                            - SUM(CASE WHEN m.ubicacion_origen_id  = u.id THEN m.cantidad ELSE 0 END)
                         FROM inv_movimientos m WHERE m.producto_id = ?), 0) AS n
        FROM inv_ubicaciones u
       WHERE u.activa = 1
       ORDER BY u.nombre
    ''', parameters: [widget.productoId]);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Stock por ubicación · ${widget.nombre}',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _stream,
            initialData: const [],
            builder: (context, snap) {
              final rows = (snap.data ?? const [])
                  .where((r) => ((r['n'] as num?) ?? 0) != 0)
                  .toList();
              if (rows.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Sin stock en ninguna ubicación.'),
                );
              }
              return Column(
                children: [
                  for (final r in rows)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(r['nombre'] as String? ?? ''),
                      trailing: Text(
                          '${_fmtCant((r['n'] as num?) ?? 0)} ${widget.unidad}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
