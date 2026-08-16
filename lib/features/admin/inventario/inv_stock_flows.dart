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
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/barcode_scanner_screen.dart';
import '../../shared/widgets/selector_buscable.dart';
import 'inventario_oplog.dart';

// ===========================================================================
// Flujos de INGRESO y MOVIMIENTO (granel) de inventario.
// Funciones públicas top-level reusables por la pantalla vieja y la ficha nueva.
// Recuperadas del rediseño; comportamiento IDÉNTICO al original.
// ===========================================================================

Future<void> ingresarStock(BuildContext context, WidgetRef ref) async {
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
  final res = await showDialog<_IngresoData>(
    context: context,
    builder: (_) => const _IngresoDialog(),
  );
  if (res == null) return;
  final now = DateTime.now().toIso8601String();
  // ocurrido_en en UTC (convención B10; antes iba local-naive y el
  // historial del serial se desordenaba ±6h).
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  // op_log: 1 intención (opId) cubre todos los seriales + movimientos del lote.
  final opId = OpLog.nuevoOpId();
  final actor = await actorOpLog(ref);
  final ocurridoEnDt = DateTime.parse(ocurridoEn);

  // Pre-check de unicidad de seriales (local). El UNIQUE(tenant,serial) del
  // server es la red dura si otro device creó el mismo serial sin sincronizar.
  if (res.esSerializado) {
    for (final s in res.seriales) {
      final dup = await ps.db.getAll(
        'SELECT 1 FROM inv_seriales WHERE tenant_id = ? AND serial = ? LIMIT 1',
        [tenantId, s.serial],
      );
      if (dup.isNotEmpty) {
        _snack(context, 'El serial "${s.serial}" ya existe.');
        return;
      }
    }
  }

  const movSql = '''INSERT INTO inv_movimientos
       (id, tenant_id, tipo, producto_id, serial_id, cantidad,
        ubicacion_destino_id, proveedor_id, numero_factura, costo_unitario,
        hecho_por, ocurrido_en, created_at)
       VALUES (?, ?, 'ingreso', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''';

  try {
    // Atómico: cada serial + su movimiento (y todo el lote) viven o caen
    // juntos (patrón writeTransaction del repo, igual que el cobro).
    await ps.dbW.writeTransaction((tx) async {
      // Costo promedio ponderado: capturamos stock y promedio ANTES del
      // ingreso (solo si vino un costo unitario; sin costo no tocamos el avg).
      num stockPrevio = 0;
      double avgPrevio = 0;
      if (res.costoUnitario != null) {
        final stockSql = res.esSerializado
            ? "SELECT COUNT(*) AS s FROM inv_seriales WHERE producto_id = ? AND estado = 'en_stock'"
            : '''SELECT COALESCE(SUM(CASE WHEN ubicacion_destino_id IS NOT NULL THEN cantidad ELSE 0 END)
                              - SUM(CASE WHEN ubicacion_origen_id  IS NOT NULL THEN cantidad ELSE 0 END), 0) AS s
                   FROM inv_movimientos WHERE producto_id = ?''';
        final sr = await tx.getAll(stockSql, [res.productoId]);
        stockPrevio = (sr.first['s'] as num?) ?? 0;
        final pr = await tx.getAll(
            'SELECT costo_promedio FROM inv_productos WHERE id = ?',
            [res.productoId]);
        avgPrevio = (pr.first['costo_promedio'] as num?)?.toDouble() ?? 0;
      }

      if (res.esSerializado) {
        for (final s in res.seriales) {
          final serialId = const Uuid().v4();
          await tx.execute(
            '''INSERT INTO inv_seriales
               (id, tenant_id, producto_id, serial, mac, estado, ubicacion_id,
                costo_ingreso, created_at)
               VALUES (?, ?, ?, ?, ?, 'en_stock', ?, ?, ?)''',
            [serialId, tenantId, res.productoId, s.serial, s.mac,
              res.ubicacionDestinoId, res.costoUnitario, now],
          );
          // op_log: alta del equipo (serial) recién ingresado.
          final despuesSerial = (await tx.getAll(
                  'SELECT * FROM inv_seriales WHERE id = ?', [serialId]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'inv_seriales',
              entidadId: serialId, antes: const {}, despues: despuesSerial,
              actor: actor, ocurridoEn: ocurridoEnDt);
          final movId = const Uuid().v4();
          await tx.execute(movSql, [
            movId, tenantId, res.productoId, serialId, 1,
            res.ubicacionDestinoId, res.proveedorId, res.numeroFactura,
            res.costoUnitario, hechoPor, ocurridoEn, now,
          ]);
          await opLogMovimiento(tx, movId,
              tenantId: tenantId, opId: opId, actor: actor,
              ocurridoEn: ocurridoEnDt);
        }
      } else {
        final movId = const Uuid().v4();
        await tx.execute(movSql, [
          movId, tenantId, res.productoId, null, res.cantidad,
          res.ubicacionDestinoId, res.proveedorId, res.numeroFactura,
          res.costoUnitario, hechoPor, ocurridoEn, now,
        ]);
        await opLogMovimiento(tx, movId,
            tenantId: tenantId, opId: opId, actor: actor,
            ocurridoEn: ocurridoEnDt);
      }

      // Promedio ponderado móvil: (stock·avg + cant·costo) / (stock + cant).
      // Si no había stock (o era negativo) arranca del costo de este ingreso.
      if (res.costoUnitario != null) {
        final n = res.esSerializado
            ? res.seriales.length.toDouble()
            : res.cantidad;
        final nuevoAvg = stockPrevio <= 0
            ? res.costoUnitario!
            : (stockPrevio * avgPrevio + n * res.costoUnitario!) /
                (stockPrevio + n);
        await tx.execute(
            'UPDATE inv_productos SET costo_promedio = ? WHERE id = ?',
            [nuevoAvg, res.productoId]);
      }
    });
    // Confirmar éxito: antes el ingreso quedaba MUDO tras registrar (el usuario
    // no sabía si guardó — audit 2026-06-30).
    if (context.mounted) _snack(context, 'Ingreso registrado');
  } catch (e) {
    _snack(context, mensajeErrorHumano(e));
  }
}

// Egreso / ajuste / transferencia de productos a GRANEL (los serializados se
// mueven por equipo en la pestaña Equipos). Un solo movimiento en el ledger.
Future<void> movimientoGranel(BuildContext context, WidgetRef ref) async {
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
  // Estado vacío (M5): sin productos a granel o sin ubicaciones el diálogo es
  // inusable; avisamos en vez de abrir un form imposible de completar.
  final granel = await _contar(
      'SELECT COUNT(*) AS n FROM inv_productos WHERE activo = 1 AND es_serializado = 0',
      const []);
  final ubis = await _contar(
      'SELECT COUNT(*) AS n FROM inv_ubicaciones WHERE activa = 1', const []);
  if (!context.mounted) return;
  if (granel == 0) {
    _snack(context,
        'No hay productos a granel. Los equipos serializados se mueven desde la pestaña Equipos.');
    return;
  }
  if (ubis == 0) {
    _snack(context, 'No hay ubicaciones. Creá una primero.');
    return;
  }
  final res = await showDialog<_MovimientoData>(
    context: context,
    builder: (_) => const _MovimientoDialog(),
  );
  if (res == null || !context.mounted) return;
  final now = DateTime.now().toIso8601String();
  // ocurrido_en en UTC (convención B10; antes iba local-naive y el
  // historial del serial se desordenaba ±6h).
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();

  // Mapear el tipo al par origen/destino que entiende la fórmula de stock.
  String? origen;
  String? destino;
  if (res.tipo == 'egreso') {
    origen = res.ubicacionOrigenId;
  } else if (res.tipo == 'transferencia') {
    origen = res.ubicacionOrigenId;
    destino = res.ubicacionDestinoId;
  } else {
    // ajuste: sumar → entra (destino +); restar → sale (origen −).
    if (res.sumar) {
      destino = res.ubicacionId;
    } else {
      origen = res.ubicacionId;
    }
  }

  // op_log: alta del movimiento de granel (egreso/ajuste/transferencia).
  final opId = OpLog.nuevoOpId();
  final actor = await actorOpLog(ref);
  final ocurridoEnDt = DateTime.parse(ocurridoEn);
  try {
    final movId = const Uuid().v4();
    await ps.dbW.writeTransaction((tx) async {
      await tx.execute(
        '''INSERT INTO inv_movimientos
           (id, tenant_id, tipo, producto_id, cantidad, ubicacion_origen_id,
            ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          movId, tenantId, res.tipo, res.productoId, res.cantidad,
          origen, destino, res.motivo, hechoPor, ocurridoEn, now,
        ],
      );
      await opLogMovimiento(tx, movId,
          tenantId: tenantId, opId: opId, actor: actor,
          ocurridoEn: ocurridoEnDt);
    });
    // M1: mostrar el stock resultante (y avisar si quedó negativo). Stock de
    // granel = Σdestino − Σorigen del ledger.
    final stockRows = await ps.db.getAll(
      '''SELECT p.nombre,
                COALESCE((
                  SELECT SUM(CASE WHEN ubicacion_destino_id IS NOT NULL THEN cantidad ELSE 0 END)
                       - SUM(CASE WHEN ubicacion_origen_id  IS NOT NULL THEN cantidad ELSE 0 END)
                    FROM inv_movimientos WHERE producto_id = p.id), 0) AS stock
           FROM inv_productos p WHERE p.id = ?''',
      [res.productoId],
    );
    if (!context.mounted) return;
    final nombre =
        stockRows.isNotEmpty ? stockRows.first['nombre'] as String? : null;
    final num stock =
        stockRows.isNotEmpty ? (stockRows.first['stock'] as num?) ?? 0 : 0;
    final etq = nombre != null ? ' de $nombre' : '';
    _snack(
      context,
      stock < 0
          ? '⚠ Movimiento registrado. Stock$etq: ${_fmtCant(stock)} (negativo)'
          : 'Movimiento registrado. Stock$etq: ${_fmtCant(stock)}',
    );
  } catch (e) {
    _snack(context, mensajeErrorHumano(e));
  }
}

class _IngresoData {
  const _IngresoData({
    required this.productoId,
    required this.esSerializado,
    required this.ubicacionDestinoId,
    required this.proveedorId,
    required this.numeroFactura,
    required this.costoUnitario,
    required this.cantidad,
    required this.seriales,
  });
  final String productoId;
  final bool esSerializado;
  final String ubicacionDestinoId;
  final String? proveedorId;
  final String? numeroFactura;
  final double? costoUnitario;
  final double cantidad;
  // Cada serial con su MAC opcional (formato "serial, MAC" por línea).
  final List<({String serial, String? mac})> seriales;
}

class _MovimientoData {
  const _MovimientoData({
    required this.tipo,
    required this.productoId,
    required this.cantidad,
    this.ubicacionOrigenId,
    this.ubicacionDestinoId,
    this.ubicacionId,
    this.sumar = false,
    this.motivo,
  });
  final String tipo; // 'egreso' | 'ajuste' | 'transferencia'
  final String productoId;
  final double cantidad;
  final String? ubicacionOrigenId; // egreso, transferencia
  final String? ubicacionDestinoId; // transferencia
  final String? ubicacionId; // ajuste
  final bool sumar; // ajuste: true=suma (+), false=resta (−)
  final String? motivo;
}

/// Movimiento de granel: egreso (−), ajuste (±) o transferencia (origen→destino).
class _MovimientoDialog extends StatefulWidget {
  const _MovimientoDialog();
  @override
  State<_MovimientoDialog> createState() => _MovimientoDialogState();
}

class _MovimientoDialogState extends State<_MovimientoDialog> {
  String _tipo = 'egreso';
  String? _productoId;
  String? _origenId;
  String? _destinoId;
  String? _ajusteUbiId;
  bool _sumar = false; // por defecto restar (corrección a la baja)
  final _cantidad = TextEditingController(text: '1');
  final _motivo = TextEditingController();
  // Campos-selector (read-only) en vez de dropdowns (que no commiteaban).
  final _tipoCtrl = TextEditingController();
  final _productoCtrl = TextEditingController();
  final _origenCtrl = TextEditingController();
  final _destinoCtrl = TextEditingController();
  final _ajusteCtrl = TextEditingController();
  final _operacionCtrl = TextEditingController();

  // Stock por ubicación del producto elegido (M2): para egreso/transferencia el
  // origen se restringe a ubicaciones con stock > 0, mostrando la cantidad.
  List<Map<String, dynamic>> _stockPorUbi = const [];
  bool _cargandoStock = false;

  static const _tipos = {
    'egreso': 'Egreso (salida)',
    'ajuste': 'Ajuste (corrección)',
    'transferencia': 'Transferencia',
  };

  @override
  void initState() {
    super.initState();
    _tipoCtrl.text = _tipos[_tipo]!;
    _operacionCtrl.text = _sumar ? 'Sumar (+)' : 'Restar (−)';
  }

  @override
  void dispose() {
    _cantidad.dispose();
    _motivo.dispose();
    _tipoCtrl.dispose();
    _productoCtrl.dispose();
    _origenCtrl.dispose();
    _destinoCtrl.dispose();
    _ajusteCtrl.dispose();
    _operacionCtrl.dispose();
    super.dispose();
  }

  // Recarga el stock por ubicación del producto (solo egreso/transferencia, que
  // salen de un origen concreto). El ajuste no lo necesita (corrige cualquier
  // ubicación). Limpia el origen elegido si dejó de tener stock.
  Future<void> _reloadStock() async {
    final pid = _productoId;
    final tipo = _tipo;
    if (pid == null || (tipo != 'egreso' && tipo != 'transferencia')) {
      if (mounted) setState(() => _stockPorUbi = const []);
      return;
    }
    setState(() => _cargandoStock = true);
    final List<Map<String, dynamic>> rows;
    try {
      rows = await ps.db.getAll('''
      SELECT u.id, u.nombre,
             COALESCE((
               SELECT SUM(CASE WHEN m.ubicacion_destino_id = u.id THEN m.cantidad ELSE 0 END)
                    - SUM(CASE WHEN m.ubicacion_origen_id  = u.id THEN m.cantidad ELSE 0 END)
                 FROM inv_movimientos m WHERE m.producto_id = ?), 0) AS stock
        FROM inv_ubicaciones u WHERE u.activa = 1 ORDER BY u.nombre
      ''', [pid]);
    } catch (_) {
      // Limpia el spinner si la query falla (regla #9): sino el campo "Ubicación
      // origen" quedaba con la barra de progreso permanente e inseleccionable.
      // Solo si sigue siendo el call vigente (uno más nuevo maneja su propio flag).
      if (mounted && pid == _productoId && tipo == _tipo) {
        setState(() => _cargandoStock = false);
      }
      return;
    }
    // Si el producto/tipo cambió mientras cargaba, descartamos este resultado
    // (el call más nuevo maneja el flag de carga y su propio resultado).
    if (!mounted || pid != _productoId || tipo != _tipo) return;
    setState(() {
      _stockPorUbi = rows
          .map((r) => {
                'id': r['id'],
                'nombre': r['nombre'],
                'stock': (r['stock'] as num?) ?? 0,
              })
          .where((r) => (r['stock'] as num) > 0)
          .toList();
      if (_origenId != null &&
          !_stockPorUbi.any((r) => r['id'] == _origenId)) {
        _origenId = null;
      }
      _cargandoStock = false;
    });
  }

  // Campo-selector de origen (egreso/transferencia): ubicaciones con stock.
  Widget _origenField() {
    if (_cargandoStock) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }
    return TextField(
      controller: _origenCtrl,
      readOnly: true,
      decoration: InputDecoration(
        labelText: 'Ubicación origen (con stock)',
        hintText: _productoId == null
            ? 'Elegí un producto primero'
            : (_stockPorUbi.isEmpty
                ? 'Sin stock en ninguna ubicación'
                : 'Tocá para elegir'),
        suffixIcon: const Icon(Icons.arrow_drop_down),
      ),
      onTap: () {
        if (_productoId == null) {
          _snack(context, 'Elegí un producto primero.');
          return;
        }
        if (_stockPorUbi.isEmpty) {
          _snack(context, 'Ese producto no tiene stock en ninguna ubicación.');
          return;
        }
        _elegirOrigen();
      },
    );
  }

  // Campo-selector de ubicación (destino/ajuste).
  Widget _ubiField(String label, TextEditingController ctrl,
      void Function(String, String) onPicked) {
    return TextField(
      controller: ctrl,
      readOnly: true,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'Tocá para elegir',
        suffixIcon: const Icon(Icons.arrow_drop_down),
      ),
      onTap: () => _elegirUbiMov(onPicked),
    );
  }

  // Selectores (SimpleDialog + SimpleDialogOption.onPressed + pop) — reemplazan
  // a los DropdownButton, cuyo onChanged no commiteaba en este diálogo.
  Future<void> _elegirTipo() async {
    final elegido = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Tipo de movimiento'),
        children: [
          for (final e in _tipos.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, e.key),
              child: Text(e.value),
            ),
        ],
      ),
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _tipo = elegido;
      _tipoCtrl.text = _tipos[elegido]!;
      _origenId = null;
      _origenCtrl.clear();
      _destinoId = null;
      _destinoCtrl.clear();
      _ajusteUbiId = null;
      _ajusteCtrl.clear();
    });
    _reloadStock();
  }

  Future<void> _elegirProducto() async {
    final productos = await ps.db.getAll(
        'SELECT id, nombre FROM inv_productos WHERE activo = 1 AND es_serializado = 0 ORDER BY nombre');
    if (!mounted) return;
    if (productos.isEmpty) {
      _snack(context, 'No hay productos a granel.');
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí un producto',
      hint: 'Buscar producto...',
      opciones: [
        for (final p in productos)
          OpcionSelector(valor: p, nombre: p['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _productoId = elegido['id'] as String;
      _productoCtrl.text = elegido['nombre'] as String;
    });
    _reloadStock();
  }

  Future<void> _elegirOrigen() async {
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Ubicación origen (con stock)',
      hint: 'Buscar ubicación...',
      opciones: [
        for (final u in _stockPorUbi)
          OpcionSelector(
            valor: u,
            nombre: '${u['nombre']} (${_fmtCant(u['stock'] as num)})',
          ),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _origenId = elegido['id'] as String;
      _origenCtrl.text =
          '${elegido['nombre']} (${_fmtCant(elegido['stock'] as num)})';
    });
  }

  Future<void> _elegirUbiMov(void Function(String, String) onPicked) async {
    final ubis = await ps.db.getAll(
        'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
    if (!mounted) return;
    if (ubis.isEmpty) {
      _snack(context, 'No hay ubicaciones.');
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí la ubicación',
      hint: 'Buscar ubicación...',
      opciones: [
        for (final u in ubis)
          OpcionSelector(valor: u, nombre: u['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(
        () => onPicked(elegido['id'] as String, elegido['nombre'] as String));
  }

  Future<void> _elegirOperacion() async {
    final elegido = await showDialog<bool>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Operación'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Restar (−)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sumar (+)'),
          ),
        ],
      ),
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _sumar = elegido;
      _operacionCtrl.text = elegido ? 'Sumar (+)' : 'Restar (−)';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Movimiento de stock'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _tipoCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Tipo',
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              onTap: _elegirTipo,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _productoCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Producto (granel)',
                hintText: 'Tocá para elegir',
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              onTap: _elegirProducto,
            ),
            const SizedBox(height: 12),
            if (_tipo == 'egreso') _origenField(),
            if (_tipo == 'transferencia') ...[
              _origenField(),
              const SizedBox(height: 12),
              _ubiField('Ubicación destino', _destinoCtrl, (id, n) {
                _destinoId = id;
                _destinoCtrl.text = n;
              }),
            ],
            if (_tipo == 'ajuste') ...[
              _ubiField('Ubicación', _ajusteCtrl, (id, n) {
                _ajusteUbiId = id;
                _ajusteCtrl.text = n;
              }),
              const SizedBox(height: 12),
              TextField(
                controller: _operacionCtrl,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Operación',
                  suffixIcon: Icon(Icons.arrow_drop_down),
                ),
                onTap: _elegirOperacion,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _cantidad,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Cantidad'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _motivo,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: _tipo == 'ajuste'
                    ? 'Motivo (obligatorio)'
                    : 'Motivo (opcional)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(onPressed: _submit, child: const Text('Registrar')),
      ],
    );
  }

  Future<void> _submit() async {
    if (_productoId == null) {
      _snack(context, 'Elegí un producto.');
      return;
    }
    final cant = double.tryParse(_cantidad.text.trim()) ?? 0;
    if (cant <= 0) {
      _snack(context, 'Cantidad inválida.');
      return;
    }
    final motivo = _motivo.text.trim();
    final _MovimientoData data;
    if (_tipo == 'egreso') {
      if (_origenId == null) {
        _snack(context, 'Elegí la ubicación origen.');
        return;
      }
      data = _MovimientoData(
        tipo: 'egreso',
        productoId: _productoId!,
        cantidad: cant,
        ubicacionOrigenId: _origenId,
        motivo: motivo.isEmpty ? null : motivo,
      );
    } else if (_tipo == 'transferencia') {
      if (_origenId == null || _destinoId == null) {
        _snack(context, 'Elegí origen y destino.');
        return;
      }
      if (_origenId == _destinoId) {
        _snack(context, 'Origen y destino deben ser distintos.');
        return;
      }
      data = _MovimientoData(
        tipo: 'transferencia',
        productoId: _productoId!,
        cantidad: cant,
        ubicacionOrigenId: _origenId,
        ubicacionDestinoId: _destinoId,
        motivo: motivo.isEmpty ? null : motivo,
      );
    } else {
      if (_ajusteUbiId == null) {
        _snack(context, 'Elegí la ubicación.');
        return;
      }
      if (motivo.isEmpty) {
        _snack(context, 'El ajuste requiere un motivo.');
        return;
      }
      data = _MovimientoData(
        tipo: 'ajuste',
        productoId: _productoId!,
        cantidad: cant,
        ubicacionId: _ajusteUbiId,
        sumar: _sumar,
        motivo: motivo,
      );
    }

    // Overselling (M2): egreso/transferencia que saca MÁS de lo disponible en la
    // ubicación origen → aviso suave (el modelo permite stock negativo, pero lo
    // señalamos para no romper una ubicación en silencio).
    if (_tipo == 'egreso' || _tipo == 'transferencia') {
      final disp = (_stockPorUbi.firstWhere(
            (r) => r['id'] == _origenId,
            orElse: () => const <String, dynamic>{},
          )['stock'] as num?) ??
          0;
      if (cant > disp) {
        final seguir = await _confirmarAccion(
          context,
          titulo: 'Más que el stock disponible',
          mensaje: 'En esa ubicación hay ${_fmtCant(disp)} y vas a sacar '
              '${_fmtCant(cant)}. Quedará en negativo. ¿Seguir?',
          confirmar: 'Sacar igual',
        );
        if (!seguir || !mounted) return;
      }
    }

    if (!mounted) return;
    Navigator.pop(context, data);
  }
}

class _IngresoDialog extends StatefulWidget {
  const _IngresoDialog();
  @override
  State<_IngresoDialog> createState() => _IngresoDialogState();
}

class _IngresoDialogState extends State<_IngresoDialog> {
  String? _productoId;
  bool _serializado = false;
  String? _ubicacionId;
  String? _proveedorId;
  final _factura = TextEditingController();
  final _costo = TextEditingController();
  final _cantidad = TextEditingController(text: '1');
  final _seriales = TextEditingController();
  // Producto/Ubicación: campos read-only que muestran el nombre elegido vía un
  // selector (SimpleDialog), en vez de un DropdownButton.
  final _productoCtrl = TextEditingController();
  final _ubicacionCtrl = TextEditingController();
  final _proveedorCtrl = TextEditingController();

  // Selector de producto: lista en SimpleDialog (SimpleDialogOption.onPressed +
  // Navigator.pop) — el patrón confiable de "Asignar a cliente". NO usa
  // DropdownButton (su onChanged no commiteaba en este diálogo).
  Future<void> _elegirProducto() async {
    final productos = await ps.db.getAll(
        'SELECT id, nombre, es_serializado FROM inv_productos WHERE activo = 1 ORDER BY nombre');
    if (!mounted) return;
    if (productos.isEmpty) {
      _snack(context, 'No hay productos. Creá uno en el Catálogo.');
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí un producto',
      hint: 'Buscar producto...',
      opciones: [
        for (final p in productos)
          OpcionSelector(valor: p, nombre: p['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _productoId = elegido['id'] as String;
      _serializado = (elegido['es_serializado'] as int? ?? 0) == 1;
      _productoCtrl.text = elegido['nombre'] as String;
    });
  }

  // Selector de ubicación destino (mismo patrón).
  Future<void> _elegirUbicacion() async {
    final ubis = await ps.db.getAll(
        'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
    if (!mounted) return;
    if (ubis.isEmpty) {
      _snack(context, 'No hay ubicaciones. Creá una en el Catálogo.');
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí la ubicación destino',
      hint: 'Buscar ubicación...',
      opciones: [
        for (final u in ubis)
          OpcionSelector(valor: u, nombre: u['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _ubicacionId = elegido['id'] as String;
      _ubicacionCtrl.text = elegido['nombre'] as String;
    });
  }

  // Selector de proveedor (opcional): primera opción limpia la selección.
  Future<void> _elegirProveedor() async {
    final provs = await ps.db.getAll(
        'SELECT id, nombre FROM inv_proveedores WHERE activo = 1 ORDER BY nombre');
    if (!mounted) return;
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Proveedor (opcional)',
      hint: 'Buscar proveedor...',
      opciones: [
        const OpcionSelector(
          valor: <String, dynamic>{'id': null, 'nombre': ''},
          nombre: '— Sin proveedor',
        ),
        for (final p in provs)
          OpcionSelector(valor: p, nombre: p['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _proveedorId = elegido['id'] as String?;
      _proveedorCtrl.text = (elegido['nombre'] as String?) ?? '';
    });
  }

  // Escaneo soportado solo en Android (target real). iOS NO es target y además le
  // falta el NSCameraUsageDescription → crashearía; Windows/web no tienen
  // mobile_scanner. En el resto el botón ni se muestra y el serial se tipea a mano.
  bool get _scanSoportado =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // Escanea un código y lo agrega como una línea más al campo de seriales.
  Future<void> _escanearSerial() async {
    final code = await BarcodeScannerScreen.escanear(context);
    if (code == null || !mounted) return;
    final actual = _seriales.text;
    final sep = actual.isEmpty || actual.endsWith('\n') ? '' : '\n';
    setState(() => _seriales.text = '$actual$sep$code');
  }

  @override
  void dispose() {
    _factura.dispose();
    _costo.dispose();
    _cantidad.dispose();
    _seriales.dispose();
    _productoCtrl.dispose();
    _ubicacionCtrl.dispose();
    _proveedorCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ingreso de mercadería'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Producto: campo read-only que abre un selector (SimpleDialog).
            // Reemplaza al DropdownButton, cuyo onChanged NO commiteaba en este
            // diálogo. Patrón confiable: SimpleDialogOption.onPressed + pop.
            TextField(
              controller: _productoCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Producto',
                hintText: 'Tocá para elegir',
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              onTap: _elegirProducto,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ubicacionCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Ubicación destino',
                hintText: 'Tocá para elegir',
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              onTap: _elegirUbicacion,
            ),
            const SizedBox(height: 12),
            // Cantidad (granel) o seriales (serializado).
            if (_productoId != null && _serializado)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _seriales,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Seriales (uno por línea; opcional "serial, MAC")',
                      hintText: 'SN001, AA:BB:CC:DD:EE:FF\nSN002',
                    ),
                  ),
                  if (_scanSoportado)
                    TextButton.icon(
                      icon: const Icon(Icons.qr_code_scanner, size: 18),
                      label: const Text('Escanear código'),
                      onPressed: _escanearSerial,
                    ),
                ],
              )
            else
              TextField(
                controller: _cantidad,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Cantidad'),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _costo,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Costo unitario (opcional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _proveedorCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Proveedor (opcional)',
                hintText: 'Tocá para elegir',
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              onTap: _elegirProveedor,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _factura,
              decoration:
                  const InputDecoration(labelText: 'N° de factura (opcional)'),
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
            if (_productoId == null || _ubicacionId == null) {
              _snack(context, 'Elegí producto y ubicación.');
              return;
            }
            final costo = double.tryParse(_costo.text.trim());
            if (_serializado) {
              // Cada línea: "serial" o "serial, MAC". Dedup por serial.
              final vistos = <String>{};
              final seriales = <({String serial, String? mac})>[];
              for (final linea in _seriales.text.split('\n')) {
                final partes = linea.split(',');
                final serial = partes[0].trim();
                if (serial.isEmpty || !vistos.add(serial)) continue;
                final mac = partes.length > 1 ? partes[1].trim() : '';
                seriales.add((serial: serial, mac: mac.isEmpty ? null : mac));
              }
              if (seriales.isEmpty) {
                _snack(context, 'Ingresá al menos un serial.');
                return;
              }
              Navigator.pop(
                context,
                _IngresoData(
                  productoId: _productoId!,
                  esSerializado: true,
                  ubicacionDestinoId: _ubicacionId!,
                  proveedorId: _proveedorId,
                  numeroFactura: _factura.text.trim().isEmpty
                      ? null
                      : _factura.text.trim(),
                  costoUnitario: costo,
                  cantidad: seriales.length.toDouble(),
                  seriales: seriales,
                ),
              );
            } else {
              final cant = double.tryParse(_cantidad.text.trim()) ?? 0;
              if (cant <= 0) {
                _snack(context, 'Cantidad inválida.');
                return;
              }
              Navigator.pop(
                context,
                _IngresoData(
                  productoId: _productoId!,
                  esSerializado: false,
                  ubicacionDestinoId: _ubicacionId!,
                  proveedorId: _proveedorId,
                  numeroFactura: _factura.text.trim().isEmpty
                      ? null
                      : _factura.text.trim(),
                  costoUnitario: costo,
                  cantidad: cant,
                  seriales: const [],
                ),
              );
            }
          },
          child: const Text('Registrar'),
        ),
      ],
    );
  }
}

// ===========================================================================
// Helpers locales (duplicación menor aceptada, igual que inv_seriales_acciones.dart).
// ===========================================================================
String _fmtCant(num n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();

void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// Cuenta filas (para guardas de estado vacío). El SELECT debe proyectar
/// `COUNT(*) AS n`.
Future<int> _contar(String sql, List<Object?> params) async {
  final rows = await ps.db.getAll(sql, params);
  return (rows.first['n'] as int?) ?? 0;
}

/// Confirmación genérica (título/mensaje/label propios). Para avisos suaves de
/// movimientos (overselling, etc.).
Future<bool> _confirmarAccion(
  BuildContext context, {
  required String titulo,
  required String mensaje,
  String confirmar = 'Confirmar',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(titulo),
      content: Text(mensaje),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(confirmar)),
      ],
    ),
  );
  return ok ?? false;
}
