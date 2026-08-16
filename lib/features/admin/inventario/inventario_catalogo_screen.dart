// ignore_for_file: use_build_context_synchronously
//
// Los avisos de este archivo son FALSA ALARMA, verificados uno por uno: el
// `context` se pasa a `_snack`, que chequea `context.mounted` ADENTRO antes
// de tocarlo. El analizador no puede ver a través de la función, así que
// flaggea el call-site igual.
//
// REGLA PARA ESTE ARCHIVO: si agregás un uso DIRECTO del context después de un
// await (sin pasar por `_snack`), sacá este ignore y poné el guard donde va —
// si no, el aviso que sí importa queda tapado.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/busqueda_cliente.dart' show foldBusqueda, foldSqlExpr;
import '../../../data/utils/op_log.dart';
import '../../../data/utils/errores.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import '../../shared/widgets/selector_buscable.dart';
import 'inventario_oplog.dart';

/// Catálogo de inventario (config) — los 4 tabs de master data (Productos ·
/// Categorías · Ubicaciones · Proveedores). Pantalla dedicada en
/// `/admin/inventario/catalogo`, accesible con el botón "Catálogo" de la vista de
/// inventario. Antes vivía como tabs de la pantalla operativa (ya rediseñada).
class InventarioCatalogoScreen extends StatelessWidget {
  const InventarioCatalogoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 4,
      child: Column(
        children: [
          TabBar(isScrollable: true, tabs: [
            Tab(text: 'Productos'),
            Tab(text: 'Categorías'),
            Tab(text: 'Ubicaciones'),
            Tab(text: 'Proveedores'),
          ]),
          Expanded(
            child: TabBarView(children: [
              _ProductosTab(),
              _CategoriasTab(),
              _UbicacionesTab(),
              _ProveedoresTab(),
            ]),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// PRODUCTOS
// ===========================================================================
class _ProductosTab extends ConsumerStatefulWidget {
  const _ProductosTab();
  @override
  ConsumerState<_ProductosTab> createState() => _ProductosTabState();
}

class _ProductosTabState extends ConsumerState<_ProductosTab> {
  late final Stream<List<Map<String, dynamic>>> _productos;

  @override
  void initState() {
    super.initState();
    _productos = ps.db.watch('''
      SELECT p.*, c.nombre AS categoria_nombre
        FROM inv_productos p
   LEFT JOIN inv_categorias c ON c.id = p.categoria_id
       WHERE p.activo = 1
       ORDER BY p.nombre
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: ref.watch(soloLecturaProvider)
          ? null
          : FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Producto'),
        onPressed: () => _crear(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _productos,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text(mensajeErrorHumano(snap.error!)));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.inventory_2_outlined,
              titulo: 'Sin productos',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primero'),
                onPressed: () => _crear(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = rows[i];
              final serializado = (p['es_serializado'] as int? ?? 0) == 1;
              final cat = p['categoria_nombre'] as String?;
              final partes = [
                if (cat != null && cat.isNotEmpty) cat,
                serializado ? 'serializado' : 'granel (${p['unidad']})',
              ];
              return ListTile(
                leading: Icon(serializado ? Icons.qr_code_2 : Icons.straighten,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(p['nombre'] as String),
                subtitle: Text(partes.join(' · ')),
                trailing: _InvRowMenu(
                  onEditar: () => _crear(context, existente: p),
                  onHistorial: () => _showHistorialInv(context, 'inv_productos',
                      p['id'] as String, 'Historial del producto'),
                  onEliminar: () => _eliminar(context, p),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final res = await showDialog<_ProductoData>(
      context: context,
      builder: (_) =>
          _ProductoDialog(tenantId: tenantId, existente: existente, ref: ref),
    );
    if (res == null) return;
    // op_log (rework change log): actor + id de intención para registrar el
    // alta/edición del producto (1 entrada, diff antes→después curado).
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    // inv_productos no tiene columna ocurrido_en → solo para el op_log.
    final ocurridoEn = DateTime.now().toUtc();
    try {
      if (existente == null) {
        final id = const Uuid().v4();
        await ps.dbW.writeTransaction((tx) async {
          await tx.execute(
            '''INSERT INTO inv_productos
               (id, tenant_id, categoria_id, codigo, nombre, es_serializado,
                unidad, maneja_decimal, stock_minimo, costo_promedio, activo, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?)''',
            [
              id, tenantId, res.categoriaId, res.codigo, res.nombre,
              res.esSerializado ? 1 : 0, res.unidad, res.manejaDecimal ? 1 : 0,
              res.stockMinimo, DateTime.now().toIso8601String(),
            ],
          );
          final despues =
              (await tx.getAll('SELECT * FROM inv_productos WHERE id = ?', [id]))
                  .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_productos',
              entidadId: id, antes: const {}, despues: despues, actor: actor,
              ocurridoEn: ocurridoEn);
        });
      } else {
        // Guarda: no cambiar el TIPO (serializado↔granel) de un producto que ya
        // tiene seriales o movimientos → dejaría seriales huérfanos y el stock
        // (que se deriva distinto por tipo) incoherente.
        final cambiaTipo = res.esSerializado !=
            ((existente['es_serializado'] as int? ?? 0) == 1);
        if (cambiaTipo) {
          final enUso = await _contar(
            'SELECT (SELECT COUNT(*) FROM inv_seriales WHERE producto_id = ?)'
            ' + (SELECT COUNT(*) FROM inv_movimientos WHERE producto_id = ?) AS n',
            [existente['id'], existente['id']],
          );
          if (!context.mounted) return;
          if (enUso > 0) {
            _snack(context,
                'No se puede cambiar serializado/granel: el producto ya tiene movimientos o equipos.');
            return;
          }
        }
        final id = existente['id'] as String;
        await ps.dbW.writeTransaction((tx) async {
          final antesRows =
              await tx.getAll('SELECT * FROM inv_productos WHERE id = ?', [id]);
          final antes = antesRows.isNotEmpty
              ? antesRows.first
              : const <String, dynamic>{};
          await tx.execute(
            '''UPDATE inv_productos
                  SET categoria_id = ?, codigo = ?, nombre = ?, es_serializado = ?,
                      unidad = ?, maneja_decimal = ?, stock_minimo = ?
                WHERE id = ?''',
            [
              res.categoriaId, res.codigo, res.nombre, res.esSerializado ? 1 : 0,
              res.unidad, res.manejaDecimal ? 1 : 0, res.stockMinimo, id,
            ],
          );
          final despues =
              (await tx.getAll('SELECT * FROM inv_productos WHERE id = ?', [id]))
                  .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_productos',
              entidadId: id, antes: antes, despues: despues, actor: actor,
              ocurridoEn: ocurridoEn);
        });
      }
    } catch (e) {
      _snack(context, mensajeErrorHumano(e));
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> p) async {
    final id = p['id'] as String;
    // Guarda de "en uso": no borrar si tiene equipos serializados o movimientos
    // (el ledger es append-only; borrar el producto huerfanizaría su historial).
    final enSeriales = await _contar(
        'SELECT COUNT(*) AS n FROM inv_seriales WHERE producto_id = ?', [id]);
    final enMovs = await _contar(
        'SELECT COUNT(*) AS n FROM inv_movimientos WHERE producto_id = ?', [id]);
    if (!context.mounted) return;
    if (enSeriales + enMovs > 0) {
      _snack(context,
          'No se puede eliminar "${p['nombre']}": tiene equipos o movimientos asociados (${enSeriales + enMovs}).');
      return;
    }
    if (!await _confirmar(context, '"${p['nombre']}"')) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final err = await _borrarSiLibre(
      tabla: 'inv_productos',
      id: id,
      countSql: 'SELECT (SELECT COUNT(*) FROM inv_seriales WHERE producto_id = ?)'
          ' + (SELECT COUNT(*) FROM inv_movimientos WHERE producto_id = ?) AS n',
      countParams: [id, id],
      tenantId: tenantId,
      opId: OpLog.nuevoOpId(),
      actor: await actorOpLog(ref),
      ocurridoEn: DateTime.now().toUtc(),
    );
    if (!context.mounted) return;
    if (err != null) _snack(context, err);
  }
}

// ===========================================================================
// UBICACIONES
// ===========================================================================
const _tiposUbicacion = {
  'central': 'Bodega central',
  'bodega': 'Bodega',
  'vehiculo': 'Vehículo',
  'tecnico': 'Custodia de técnico',
  // 0204: material montado en la planta (troncales, splitters, herrajes). No
  // tiene cliente dueño ni está en bodega; sin este tipo el material de
  // construcción quedaba contado como stock disponible.
  'redes': 'Redes / planta',
};

class _UbicacionesTab extends ConsumerStatefulWidget {
  const _UbicacionesTab();
  @override
  ConsumerState<_UbicacionesTab> createState() => _UbicacionesTabState();
}

class _UbicacionesTabState extends ConsumerState<_UbicacionesTab> {
  late final Stream<List<Map<String, dynamic>>> _ubicaciones;

  @override
  void initState() {
    super.initState();
    _ubicaciones = ps.db.watch(
        'SELECT * FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: ref.watch(soloLecturaProvider)
          ? null
          : FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Ubicación'),
        onPressed: () => _crear(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _ubicaciones,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text(mensajeErrorHumano(snap.error!)));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.warehouse_outlined,
              titulo: 'Sin ubicaciones',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primera'),
                onPressed: () => _crear(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final u = rows[i];
              return ListTile(
                leading: Icon(Icons.warehouse,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(u['nombre'] as String),
                subtitle: Text(_tiposUbicacion[u['tipo']] ?? u['tipo'] as String),
                trailing: _InvRowMenu(
                  onEditar: () => _crear(context, existente: u),
                  onHistorial: () => _showHistorialInv(context,
                      'inv_ubicaciones', u['id'] as String,
                      'Historial de la ubicación'),
                  onEliminar: () => _eliminar(context, u),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final res = await showDialog<({String nombre, String tipo})>(
      context: context,
      builder: (_) => _UbicacionDialog(existente: existente),
    );
    if (res == null) return;
    // op_log: alta/edición de la ubicación. inv_ubicaciones no tiene ocurrido_en
    // → la hora local solo alimenta el op_log.
    final opId = OpLog.nuevoOpId();
    final actor = await actorOpLog(ref);
    final ocurridoEn = DateTime.now().toUtc();
    try {
      if (existente == null) {
        final id = const Uuid().v4();
        await ps.dbW.writeTransaction((tx) async {
          await tx.execute(
            'INSERT INTO inv_ubicaciones (id, tenant_id, nombre, tipo, activa, created_at) VALUES (?, ?, ?, ?, 1, ?)',
            [id, tenantId, res.nombre, res.tipo,
              DateTime.now().toIso8601String()],
          );
          final despues = (await tx
                  .getAll('SELECT * FROM inv_ubicaciones WHERE id = ?', [id]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_ubicaciones',
              entidadId: id, antes: const {}, despues: despues, actor: actor,
              ocurridoEn: ocurridoEn);
        });
      } else {
        final id = existente['id'] as String;
        await ps.dbW.writeTransaction((tx) async {
          final antesRows = await tx
              .getAll('SELECT * FROM inv_ubicaciones WHERE id = ?', [id]);
          final antes = antesRows.isNotEmpty
              ? antesRows.first
              : const <String, dynamic>{};
          await tx.execute(
            'UPDATE inv_ubicaciones SET nombre = ?, tipo = ? WHERE id = ?',
            [res.nombre, res.tipo, id],
          );
          final despues = (await tx
                  .getAll('SELECT * FROM inv_ubicaciones WHERE id = ?', [id]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_ubicaciones',
              entidadId: id, antes: antes, despues: despues, actor: actor,
              ocurridoEn: ocurridoEn);
        });
      }
    } catch (e) {
      _snack(context, mensajeErrorHumano(e));
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> u) async {
    final id = u['id'] as String;
    // Guarda de "en uso": no borrar si hay equipos o movimientos en esta
    // ubicación (su FK es ON DELETE SET NULL → borrar nulearía la referencia).
    final enSeriales = await _contar(
        'SELECT COUNT(*) AS n FROM inv_seriales WHERE ubicacion_id = ?', [id]);
    final enMovs = await _contar(
        'SELECT COUNT(*) AS n FROM inv_movimientos WHERE ubicacion_origen_id = ? OR ubicacion_destino_id = ?',
        [id, id]);
    if (!context.mounted) return;
    if (enSeriales + enMovs > 0) {
      _snack(context,
          'No se puede eliminar "${u['nombre']}": tiene equipos o movimientos asociados (${enSeriales + enMovs}).');
      return;
    }
    if (!await _confirmar(context, '"${u['nombre']}"')) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final err = await _borrarSiLibre(
      tabla: 'inv_ubicaciones',
      id: id,
      countSql:
          'SELECT (SELECT COUNT(*) FROM inv_seriales WHERE ubicacion_id = ?)'
          ' + (SELECT COUNT(*) FROM inv_movimientos'
          ' WHERE ubicacion_origen_id = ? OR ubicacion_destino_id = ?) AS n',
      countParams: [id, id, id],
      tenantId: tenantId,
      opId: OpLog.nuevoOpId(),
      actor: await actorOpLog(ref),
      ocurridoEn: DateTime.now().toUtc(),
    );
    if (!context.mounted) return;
    if (err != null) _snack(context, err);
  }
}

// ===========================================================================
// PROVEEDORES
// ===========================================================================
class _ProveedoresTab extends ConsumerStatefulWidget {
  const _ProveedoresTab();
  @override
  ConsumerState<_ProveedoresTab> createState() => _ProveedoresTabState();
}

class _ProveedoresTabState extends ConsumerState<_ProveedoresTab> {
  late final Stream<List<Map<String, dynamic>>> _proveedores;

  @override
  void initState() {
    super.initState();
    _proveedores = ps.db.watch(
        'SELECT * FROM inv_proveedores WHERE activo = 1 ORDER BY nombre');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: ref.watch(soloLecturaProvider)
          ? null
          : FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Proveedor'),
        onPressed: () => _crear(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _proveedores,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text(mensajeErrorHumano(snap.error!)));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.local_shipping_outlined,
              titulo: 'Sin proveedores',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primero'),
                onPressed: () => _crear(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = rows[i];
              final tel = p['telefono'] as String?;
              return ListTile(
                leading: Icon(Icons.local_shipping,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(p['nombre'] as String),
                subtitle: tel != null && tel.isNotEmpty ? Text(tel) : null,
                trailing: _InvRowMenu(
                  onEditar: () => _crear(context, existente: p),
                  onHistorial: () => _showHistorialInv(context,
                      'inv_proveedores', p['id'] as String,
                      'Historial del proveedor'),
                  onEliminar: () => _eliminar(context, p),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final res = await showDialog<({String nombre, String? telefono, String? notas})>(
      context: context,
      builder: (_) => _ProveedorDialog(existente: existente),
    );
    if (res == null) return;
    // op_log: alta/edición del proveedor. inv_proveedores no tiene ocurrido_en.
    final opId = OpLog.nuevoOpId();
    final actor = await actorOpLog(ref);
    final ocurridoEn = DateTime.now().toUtc();
    try {
      if (existente == null) {
        final id = const Uuid().v4();
        await ps.dbW.writeTransaction((tx) async {
          await tx.execute(
            'INSERT INTO inv_proveedores (id, tenant_id, nombre, telefono, notas, activo, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)',
            [id, tenantId, res.nombre, res.telefono, res.notas,
              DateTime.now().toIso8601String()],
          );
          final despues = (await tx
                  .getAll('SELECT * FROM inv_proveedores WHERE id = ?', [id]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_proveedores',
              entidadId: id, antes: const {}, despues: despues, actor: actor,
              ocurridoEn: ocurridoEn);
        });
      } else {
        final id = existente['id'] as String;
        await ps.dbW.writeTransaction((tx) async {
          final antesRows = await tx
              .getAll('SELECT * FROM inv_proveedores WHERE id = ?', [id]);
          final antes = antesRows.isNotEmpty
              ? antesRows.first
              : const <String, dynamic>{};
          await tx.execute(
            'UPDATE inv_proveedores SET nombre = ?, telefono = ?, notas = ? WHERE id = ?',
            [res.nombre, res.telefono, res.notas, id],
          );
          final despues = (await tx
                  .getAll('SELECT * FROM inv_proveedores WHERE id = ?', [id]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_proveedores',
              entidadId: id, antes: antes, despues: despues, actor: actor,
              ocurridoEn: ocurridoEn);
        });
      }
    } catch (e) {
      _snack(context, mensajeErrorHumano(e));
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> p) async {
    final id = p['id'] as String;
    // Guarda de "en uso": no borrar un proveedor con movimientos (su FK es
    // ON DELETE SET NULL → borrarlo perdería la procedencia del ingreso).
    final enMovs = await _contar(
        'SELECT COUNT(*) AS n FROM inv_movimientos WHERE proveedor_id = ?', [id]);
    if (!context.mounted) return;
    if (enMovs > 0) {
      _snack(context,
          'No se puede eliminar "${p['nombre']}": tiene movimientos asociados ($enMovs).');
      return;
    }
    if (!await _confirmar(context, '"${p['nombre']}"')) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final err = await _borrarSiLibre(
      tabla: 'inv_proveedores',
      id: id,
      countSql: 'SELECT COUNT(*) AS n FROM inv_movimientos WHERE proveedor_id = ?',
      countParams: [id],
      tenantId: tenantId,
      opId: OpLog.nuevoOpId(),
      actor: await actorOpLog(ref),
      ocurridoEn: DateTime.now().toUtc(),
    );
    if (!context.mounted) return;
    if (err != null) _snack(context, err);
  }
}

// ===========================================================================
// CATEGORÍAS (M8/B6: antes solo se creaban inline; ahora se editan/borran y
// tienen historial, como el resto de los sub-catálogos)
// ===========================================================================
class _CategoriasTab extends ConsumerStatefulWidget {
  const _CategoriasTab();
  @override
  ConsumerState<_CategoriasTab> createState() => _CategoriasTabState();
}

class _CategoriasTabState extends ConsumerState<_CategoriasTab> {
  late final Stream<List<Map<String, dynamic>>> _categorias;

  @override
  void initState() {
    super.initState();
    _categorias = ps.db.watch(
        'SELECT * FROM inv_categorias WHERE activo = 1 ORDER BY nombre');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: ref.watch(soloLecturaProvider)
          ? null
          : FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Categoría'),
        onPressed: () => _crear(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _categorias,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text(mensajeErrorHumano(snap.error!)));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.category_outlined,
              titulo: 'Sin categorías',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primera'),
                onPressed: () => _crear(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final c = rows[i];
              return ListTile(
                leading: Icon(Icons.category,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(c['nombre'] as String),
                trailing: _InvRowMenu(
                  onEditar: () => _crear(context, existente: c),
                  onHistorial: () => _showHistorialInv(context,
                      'inv_categorias', c['id'] as String,
                      'Historial de la categoría'),
                  onEliminar: () => _eliminar(context, c),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final ctrl =
        TextEditingController(text: existente?['nombre'] as String? ?? '');
    final nombre = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            Text(existente == null ? 'Nueva categoría' : 'Editar categoría'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nombre'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(existente == null ? 'Crear' : 'Guardar')),
        ],
      ),
    ).whenComplete(ctrl.dispose);
    if (nombre == null || nombre.isEmpty || !context.mounted) return;
    // Pre-check de duplicado (B6): el UNIQUE(tenant, nombre) vive en Postgres,
    // no en el SQLite local. Excluye la propia fila al editar.
    final dup = await ps.db.getOptional(
      'SELECT id FROM inv_categorias WHERE tenant_id = ? AND ${foldSqlExpr('nombre')} = ? AND id != ? LIMIT 1',
      [tenantId, foldBusqueda(nombre), existente?['id'] ?? ''],
    );
    if (!context.mounted) return;
    if (dup != null) {
      _snack(context, 'Ya existe una categoría "$nombre".');
      return;
    }
    // op_log: alta/edición de la categoría. inv_categorias no tiene ocurrido_en.
    final opId = OpLog.nuevoOpId();
    final actor = await actorOpLog(ref);
    final ocurridoEn = DateTime.now().toUtc();
    try {
      if (existente == null) {
        final id = const Uuid().v4();
        await ps.dbW.writeTransaction((tx) async {
          await tx.execute(
            'INSERT INTO inv_categorias (id, tenant_id, nombre, orden, activo, created_at) VALUES (?, ?, ?, 0, 1, ?)',
            [id, tenantId, nombre, DateTime.now().toIso8601String()],
          );
          final despues = (await tx
                  .getAll('SELECT * FROM inv_categorias WHERE id = ?', [id]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_categorias',
              entidadId: id, antes: const {}, despues: despues, actor: actor,
              ocurridoEn: ocurridoEn);
        });
      } else {
        final id = existente['id'] as String;
        await ps.dbW.writeTransaction((tx) async {
          final antesRows = await tx
              .getAll('SELECT * FROM inv_categorias WHERE id = ?', [id]);
          final antes = antesRows.isNotEmpty
              ? antesRows.first
              : const <String, dynamic>{};
          await tx.execute(
            'UPDATE inv_categorias SET nombre = ? WHERE id = ?',
            [nombre, id],
          );
          final despues = (await tx
                  .getAll('SELECT * FROM inv_categorias WHERE id = ?', [id]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_categorias',
              entidadId: id, antes: antes, despues: despues, actor: actor,
              ocurridoEn: ocurridoEn);
        });
      }
    } catch (e) {
      if (context.mounted) _snack(context, mensajeErrorHumano(e));
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> c) async {
    final id = c['id'] as String;
    // Guarda de "en uso": no borrar una categoría con productos asociados.
    final enUso = await _contar(
        'SELECT COUNT(*) AS n FROM inv_productos WHERE categoria_id = ?', [id]);
    if (!context.mounted) return;
    if (enUso > 0) {
      _snack(context,
          'No se puede eliminar "${c['nombre']}": tiene productos asociados ($enUso).');
      return;
    }
    if (!await _confirmar(context, '"${c['nombre']}"')) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final err = await _borrarSiLibre(
      tabla: 'inv_categorias',
      id: id,
      countSql: 'SELECT COUNT(*) AS n FROM inv_productos WHERE categoria_id = ?',
      countParams: [id],
      tenantId: tenantId,
      opId: OpLog.nuevoOpId(),
      actor: await actorOpLog(ref),
      ocurridoEn: DateTime.now().toUtc(),
    );
    if (!context.mounted) return;
    if (err != null) _snack(context, err);
  }
}

// ===========================================================================
// Diálogos
// ===========================================================================
class _UbicacionDialog extends StatefulWidget {
  const _UbicacionDialog({this.existente});
  final Map<String, dynamic>? existente;
  @override
  State<_UbicacionDialog> createState() => _UbicacionDialogState();
}

class _UbicacionDialogState extends State<_UbicacionDialog> {
  late final TextEditingController _nombre;
  late String _tipo;

  @override
  void initState() {
    super.initState();
    _nombre = TextEditingController(
        text: widget.existente?['nombre'] as String? ?? '');
    _tipo = widget.existente?['tipo'] as String? ?? 'central';
  }

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nueva ubicación' : 'Editar ubicación'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nombre,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _tipo,
            decoration: const InputDecoration(labelText: 'Tipo'),
            onChanged: (v) => setState(() => _tipo = v ?? 'central'),
            items: _tiposUbicacion.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final n = _nombre.text.trim();
            if (n.isEmpty) return;
            Navigator.pop(context, (nombre: n, tipo: _tipo));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _ProveedorDialog extends StatefulWidget {
  const _ProveedorDialog({this.existente});
  final Map<String, dynamic>? existente;
  @override
  State<_ProveedorDialog> createState() => _ProveedorDialogState();
}

class _ProveedorDialogState extends State<_ProveedorDialog> {
  late final TextEditingController _nombre;
  late final TextEditingController _telefono;
  late final TextEditingController _notas;

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _nombre = TextEditingController(text: e?['nombre'] as String? ?? '');
    _telefono = TextEditingController(text: e?['telefono'] as String? ?? '');
    _notas = TextEditingController(text: e?['notas'] as String? ?? '');
  }

  @override
  void dispose() {
    _nombre.dispose();
    _telefono.dispose();
    _notas.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nuevo proveedor' : 'Editar proveedor'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _telefono,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Teléfono (opcional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notas,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notas (opcional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final n = _nombre.text.trim();
            if (n.isEmpty) return;
            final tel = _telefono.text.trim();
            final notas = _notas.text.trim();
            Navigator.pop(context, (
              nombre: n,
              telefono: tel.isEmpty ? null : tel,
              notas: notas.isEmpty ? null : notas,
            ));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _ProductoData {
  const _ProductoData({
    required this.nombre,
    required this.categoriaId,
    required this.codigo,
    required this.esSerializado,
    required this.unidad,
    required this.manejaDecimal,
    required this.stockMinimo,
  });
  final String nombre;
  final String? categoriaId;
  final String? codigo;
  final bool esSerializado;
  final String unidad;
  final bool manejaDecimal;
  final num stockMinimo; // 0 = sin alerta
}

class _ProductoDialog extends StatefulWidget {
  const _ProductoDialog(
      {required this.tenantId, required this.ref, this.existente});
  final String tenantId;
  // Ref del ConsumerState padre (_ProductosTab): la creación inline de categoría
  // necesita resolver el actor del op_log.
  final WidgetRef ref;
  final Map<String, dynamic>? existente;
  @override
  State<_ProductoDialog> createState() => _ProductoDialogState();
}

class _ProductoDialogState extends State<_ProductoDialog> {
  late final TextEditingController _nombre;
  late final TextEditingController _codigo;
  late final TextEditingController _stockMin;
  // Campo-selector (read-only) de categoría: muestra el nombre elegido vía
  // elegirConBuscador, en vez de un DropdownButton.
  final _categoriaCtrl = TextEditingController();
  String? _categoriaId;
  bool _serializado = false;
  String _unidad = 'unidad';
  bool _manejaDecimal = false;

  static const _unidades = ['unidad', 'metro', 'rollo', 'caja', 'par'];

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _nombre = TextEditingController(text: e?['nombre'] as String? ?? '');
    _codigo = TextEditingController(text: e?['codigo'] as String? ?? '');
    final sMin = (e?['stock_minimo'] as num?) ?? 0;
    _stockMin =
        TextEditingController(text: sMin > 0 ? _fmtCant(sMin) : '');
    _categoriaId = e?['categoria_id'] as String?;
    _serializado = (e?['es_serializado'] as int? ?? 0) == 1;
    _unidad = e?['unidad'] as String? ?? 'unidad';
    _manejaDecimal = (e?['maneja_decimal'] as int? ?? 0) == 1;
    // Edición: hidratar el nombre de la categoría actual para no mostrar vacío.
    if (_categoriaId != null) _cargarNombreCategoria(_categoriaId!);
  }

  // Resuelve y muestra el nombre de una categoría por id (hidratación inicial al
  // editar, y tras crearla inline).
  Future<void> _cargarNombreCategoria(String id) async {
    final row = await ps.db.getOptional(
        'SELECT nombre FROM inv_categorias WHERE id = ?', [id]);
    if (!mounted || _categoriaId != id) return;
    setState(() => _categoriaCtrl.text = (row?['nombre'] as String?) ?? '');
  }

  Future<void> _elegirCategoria() async {
    final rows = await ps.db.getAll(
        'SELECT id, nombre FROM inv_categorias WHERE activo = 1 ORDER BY nombre');
    if (!mounted) return;
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí una categoría',
      hint: 'Buscar categoría...',
      opciones: [
        const OpcionSelector(
          valor: <String, dynamic>{'id': null, 'nombre': ''},
          nombre: '— Ninguno',
        ),
        for (final r in rows)
          OpcionSelector(valor: r, nombre: r['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _categoriaId = elegido['id'] as String?;
      _categoriaCtrl.text = (elegido['nombre'] as String?) ?? '';
    });
  }

  @override
  void dispose() {
    _nombre.dispose();
    _codigo.dispose();
    _stockMin.dispose();
    _categoriaCtrl.dispose();
    super.dispose();
  }

  Future<void> _crearCategoriaInline() async {
    final ctrl = TextEditingController();
    final nombre = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva categoría'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nombre'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Crear')),
        ],
      ),
    ).whenComplete(ctrl.dispose);
    if (nombre == null || nombre.isEmpty) return;
    // Pre-check local de duplicado (B6): el UNIQUE(tenant, nombre) vive en
    // Postgres, no en el SQLite local — sin esto una categoría duplicada se crea
    // local, el server la rechaza al sincronizar y desaparece sin aviso (con el
    // producto apuntando a una categoría huérfana). Si ya existe (case-insensitive)
    // la seleccionamos en vez de duplicar.
    final dup = await ps.db.getOptional(
      'SELECT id FROM inv_categorias WHERE tenant_id = ? AND ${foldSqlExpr('nombre')} = ? LIMIT 1',
      [widget.tenantId, foldBusqueda(nombre)],
    );
    if (dup != null) {
      if (mounted) {
        setState(() {
          _categoriaId = dup['id'] as String;
          _categoriaCtrl.text = nombre;
        });
      }
      return;
    }
    final id = const Uuid().v4();
    // op_log: la categoría creada inline también es un alta auditable.
    final opId = OpLog.nuevoOpId();
    final actor = await actorOpLog(widget.ref);
    final ocurridoEn = DateTime.now().toUtc();
    try {
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'INSERT INTO inv_categorias (id, tenant_id, nombre, orden, activo, created_at) VALUES (?, ?, ?, 0, 1, ?)',
          [id, widget.tenantId, nombre, DateTime.now().toIso8601String()],
        );
        final despues =
            (await tx.getAll('SELECT * FROM inv_categorias WHERE id = ?', [id]))
                .first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: widget.tenantId, opId: opId, entidad: 'inv_categorias',
            entidadId: id, antes: const {}, despues: despues, actor: actor,
            ocurridoEn: ocurridoEn);
      });
      if (mounted) {
        setState(() {
          _categoriaId = id;
          _categoriaCtrl.text = nombre;
        });
      }
    } catch (e) {
      if (mounted) _snack(context, mensajeErrorHumano(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nuevo producto' : 'Editar producto'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _codigo,
              decoration:
                  const InputDecoration(labelText: 'Código / SKU (opcional)'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _categoriaCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Categoría (opcional)',
                      hintText: 'Tocá para elegir',
                      suffixIcon: Icon(Icons.arrow_drop_down),
                    ),
                    onTap: _elegirCategoria,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Nueva categoría',
                  onPressed: _crearCategoriaInline,
                ),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Serializado'),
              subtitle: const Text('Equipo con serial único (ONU, router…)'),
              value: _serializado,
              onChanged: (v) => setState(() => _serializado = v),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _stockMin,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Stock mínimo (alerta)',
                hintText: '0 = sin alerta',
              ),
            ),
            if (!_serializado) ...[
              DropdownButtonFormField<String>(
                initialValue: _unidad,
                decoration: const InputDecoration(labelText: 'Unidad de medida'),
                onChanged: (v) => setState(() => _unidad = v ?? 'unidad'),
                items: _unidades
                    .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                    .toList(),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Admite decimales'),
                subtitle: const Text('Ej. cable por metros (12.5)'),
                value: _manejaDecimal,
                onChanged: (v) => setState(() => _manejaDecimal = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final nombre = _nombre.text.trim();
            if (nombre.isEmpty) return;
            final sMin =
                num.tryParse(_stockMin.text.trim().replaceAll(',', '.')) ?? 0;
            Navigator.pop(
              context,
              _ProductoData(
                nombre: nombre,
                categoriaId: _categoriaId,
                codigo: _codigo.text.trim().isEmpty ? null : _codigo.text.trim(),
                esSerializado: _serializado,
                unidad: _serializado ? 'unidad' : _unidad,
                manejaDecimal: _serializado ? false : _manejaDecimal,
                stockMinimo: sMin < 0 ? 0 : sMin,
              ),
            );
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

// ===========================================================================
// Helpers compartidos
// ===========================================================================
void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// Cuenta filas (para guardas de "en uso" antes de un borrado). El SELECT debe
/// proyectar `COUNT(*) AS n`.
Future<int> _contar(String sql, List<Object?> params) async {
  final rows = await ps.db.getAll(sql, params);
  return (rows.first['n'] as int?) ?? 0;
}

/// Borra `id` de `tabla` re-chequeando la guarda de uso (`countSql` → `n`)
/// DENTRO de la transacción: cierra el TOCTOU entre el pre-check de la UI y el
/// DELETE (otro device podría haber insertado un dependiente en el medio).
/// Devuelve mensaje de error o null si borró OK.
///
/// op_log (rework change log): registra la BAJA con el snapshot de la fila ANTES
/// de borrar (SELECT *), para que su historial siga apareciendo filtrando por
/// `entidad_id`. El actor/op_id se computan en el caller (necesita `ref`).
Future<String?> _borrarSiLibre({
  required String tabla,
  required String id,
  required String countSql,
  required List<Object?> countParams,
  required String tenantId,
  required String opId,
  required OpLogActor actor,
  required DateTime ocurridoEn,
}) async {
  try {
    await ps.dbW.writeTransaction((tx) async {
      final rows = await tx.getAll(countSql, countParams);
      if (((rows.first['n'] as int?) ?? 0) > 0) {
        throw const InvError('Quedó en uso; no se eliminó.');
      }
      final snapRows =
          await tx.getAll('SELECT * FROM $tabla WHERE id = ?', [id]);
      final snapshot =
          snapRows.isNotEmpty ? snapRows.first : const <String, dynamic>{};
      await tx.execute('DELETE FROM $tabla WHERE id = ?', [id]);
      if (snapshot.isNotEmpty) {
        await OpLog.escribirBaja(tx,
            tenantId: tenantId, opId: opId, entidad: tabla, entidadId: id,
            snapshot: snapshot, actor: actor, ocurridoEn: ocurridoEn);
      }
    });
    return null;
  } on InvError catch (e) {
    return e.message;
  } catch (e) {
    return mensajeErrorHumano(e);
  }
}

Future<bool> _confirmar(BuildContext context, String que) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Eliminar'),
      content: Text('¿Eliminar $que? No se puede deshacer.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar')),
      ],
    ),
  );
  return ok ?? false;
}

class _InvRowMenu extends ConsumerWidget {
  const _InvRowMenu({
    required this.onEditar,
    required this.onHistorial,
    required this.onEliminar,
  });
  final VoidCallback onEditar;
  final VoidCallback onHistorial;
  final VoidCallback onEliminar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Solo lectura (0198): queda únicamente "Historial".
    final soloLectura = ref.watch(soloLecturaProvider);
    return PopupMenuButton<String>(
      tooltip: 'Acciones',
      onSelected: (v) => switch (v) {
        'editar' => onEditar(),
        'eliminar' => onEliminar(),
        _ => onHistorial(),
      },
      itemBuilder: (_) => [
        if (!soloLectura)
          const PopupMenuItem(value: 'editar', child: Text('Editar')),
        const PopupMenuItem(value: 'historial', child: Text('Historial')),
        if (!soloLectura)
          const PopupMenuItem(value: 'eliminar', child: Text('Eliminar')),
      ],
    );
  }
}

void _showHistorialInv(
    BuildContext context, String tabla, String id, String titulo) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (_, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child:
                  Text(titulo, style: Theme.of(context).textTheme.titleMedium),
            ),
            HistorialOpLog(entidad: tabla, entidadId: id),
          ],
        ),
      ),
    ),
  );
}

String _fmtCant(num n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();
