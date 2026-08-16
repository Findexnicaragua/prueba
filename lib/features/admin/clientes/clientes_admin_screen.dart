import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/router.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/busqueda_cliente.dart';
import '../../../data/utils/op_log.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/etiqueta_chip.dart';
import '../../shared/widgets/filtro_multi_dropdown.dart';
import '../../../data/utils/errores.dart';
import '../reportes/excel/reporte_excel.dart';
import 'seleccionar_cobrador_dialog.dart';

/// Centinela del dropdown de Cobrador para "Sin cobrador" (cobrador_id IS NULL).
/// Se ofrece como una opción más adentro del multi-select → reemplaza el toggle
/// suelto "Sin cobrador" (era redundante con el dropdown).
const _kSinCobrador = '__sin_cobrador__';

/// Estados del servicio del cliente para el filtro multi-select (rework
/// 2026-06-21). Cada uno es un predicado INDEPENDIENTE por cliente → se
/// combinan con OR adentro del dropdown (y con AND contra los demás filtros).
/// Reemplaza los toggles sueltos "Con mora" + "Suspendidos" (se pisaban con
/// "Solo activos"). Incluye los DEUDORES fuera de ruta (suspendido/cancelado),
/// que antes solo se veían entrando al contrato.
enum EstadoServicio { alDia, gracia, mora, suspendidoDeuda, canceladoDeuda, sinContrato }

extension EstadoServicioMeta on EstadoServicio {
  String get clave => name;
  String get label => switch (this) {
        EstadoServicio.alDia => 'Al día',
        EstadoServicio.gracia => 'En gracia',
        EstadoServicio.mora => 'En mora',
        EstadoServicio.suspendidoDeuda => 'Suspendido con deuda',
        EstadoServicio.canceladoDeuda => 'Cancelado con deuda',
        EstadoServicio.sinContrato => 'Sin contrato',
      };
}

/// Predicado SQL (sobre `c.id`) de un estado de servicio + sus params (en orden).
/// `diasGracia` se usa en mora/gracia. Día local Nicaragua (UTC-6).
({String sql, List<Object?> params}) _predEstadoServicio(
    EstadoServicio e, int diasGracia) {
  switch (e) {
    case EstadoServicio.mora:
      return (
        sql: 'c.id IN (SELECT cu.cliente_id FROM cuotas cu JOIN contratos ct ON ct.id = cu.contrato_id '
            "WHERE COALESCE(ct.estado,'activo') = 'activo' AND cu.estado IN ('pendiente','parcial') "
            "AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now','-6 hours'))",
        params: [diasGracia],
      );
    case EstadoServicio.gracia:
      return (
        sql: 'c.id IN (SELECT cu.cliente_id FROM cuotas cu JOIN contratos ct ON ct.id = cu.contrato_id '
            "WHERE COALESCE(ct.estado,'activo') = 'activo' AND cu.estado IN ('pendiente','parcial') "
            "AND date(cu.fecha_vencimiento) < date('now','-6 hours') "
            "AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now','-6 hours'))",
        params: [diasGracia],
      );
    case EstadoServicio.alDia:
      return (
        sql: "c.id IN (SELECT ct.cliente_id FROM contratos ct WHERE COALESCE(ct.estado,'activo') = 'activo' "
            'AND NOT EXISTS (SELECT 1 FROM cuotas cu WHERE cu.contrato_id = ct.id '
            "AND cu.estado IN ('pendiente','parcial') AND date(cu.fecha_vencimiento) < date('now','-6 hours')))",
        params: const [],
      );
    case EstadoServicio.suspendidoDeuda:
      return (
        sql: 'c.id IN (SELECT cu.cliente_id FROM cuotas cu JOIN contratos ct ON ct.id = cu.contrato_id '
            "WHERE ct.estado = 'suspendido' AND cu.estado IN ('pendiente','parcial') "
            'AND (cu.monto + COALESCE(cu.cargos_neto,0) - COALESCE(cu.monto_pagado, 0)) > 0)',
        params: const [],
      );
    case EstadoServicio.canceladoDeuda:
      return (
        sql: 'c.id IN (SELECT cu.cliente_id FROM cuotas cu JOIN contratos ct ON ct.id = cu.contrato_id '
            "WHERE ct.estado = 'cancelado' AND cu.estado IN ('pendiente','parcial') "
            'AND (cu.monto + COALESCE(cu.cargos_neto,0) - COALESCE(cu.monto_pagado, 0)) > 0)',
        params: const [],
      );
    case EstadoServicio.sinContrato:
      return (
        sql: 'c.id NOT IN (SELECT cliente_id FROM contratos WHERE cliente_id IS NOT NULL)',
        params: const [],
      );
  }
}

/// WHERE + params de los filtros de la lista de clientes. CENTRALIZADO: lo usan
/// la lista, el export "vista filtrada" y "seleccionar todos del filtro" para no
/// divergir (consistencia #10). Reglas: AND entre categorías, OR dentro de cada
/// multi-select; un set null o VACÍO = sin filtrar (nunca produce lista vacía
/// por accidente). [soloActivos] true=activos / false=inactivos (binario).
({List<String> where, List<Object?> params}) construirFiltroClientes({
  required String query,
  required Set<String>? cobrador,
  required Set<String>? comunidad,
  required Set<String>? nodo,
  required Set<String>? estadoServicio,
  required bool soloActivos,
  required int diasGracia,
  required AppSettings settings,
}) {
  final where = <String>[soloActivos ? 'c.activo = 1' : 'c.activo = 0'];
  final params = <Object?>[];

  // Búsqueda de cliente configurable (toggles super_admin) vía el helper
  // compartido — respeta qué campos están habilitados (nombre siempre entra).
  final b = busquedaClienteSql(query, settings, alias: 'c');
  if (b.sql.isNotEmpty) {
    where.add(b.sql);
    params.addAll(b.params);
  }

  // Cobrador: el set puede incluir el centinela "Sin cobrador" → OR cobrador_id
  // IS NULL. Set null/vacío = sin filtrar.
  if (cobrador != null && cobrador.isNotEmpty) {
    final ids = cobrador.where((x) => x != _kSinCobrador).toList();
    final sinCob = cobrador.contains(_kSinCobrador);
    final ors = <String>[];
    if (ids.isNotEmpty) {
      ors.add('c.cobrador_id IN (${List.filled(ids.length, '?').join(', ')})');
      params.addAll(ids);
    }
    if (sinCob) ors.add('c.cobrador_id IS NULL');
    if (ors.isNotEmpty) where.add('(${ors.join(' OR ')})');
  }

  if (comunidad != null && comunidad.isNotEmpty) {
    where.add('c.comunidad_id IN (${List.filled(comunidad.length, '?').join(', ')})');
    params.addAll(comunidad);
  }

  if (nodo != null && nodo.isNotEmpty) {
    where.add('c.puerto_id IN (SELECT p.id FROM red_puertos p '
        'JOIN red_hubs h ON h.id = p.hub_id WHERE h.nodo_id IN '
        '(${List.filled(nodo.length, '?').join(', ')}))');
    params.addAll(nodo);
  }

  // Estado de servicio: OR de los predicados seleccionados (orden del enum para
  // que los params de diasGracia queden alineados).
  if (estadoServicio != null && estadoServicio.isNotEmpty) {
    final ors = <String>[];
    for (final e in EstadoServicio.values) {
      if (estadoServicio.contains(e.clave)) {
        final p = _predEstadoServicio(e, diasGracia);
        ors.add(p.sql);
        params.addAll(p.params);
      }
    }
    if (ors.isNotEmpty) where.add('(${ors.join(' OR ')})');
  }

  return (where: where, params: params);
}

class ClientesAdminScreen extends ConsumerStatefulWidget {
  const ClientesAdminScreen({super.key, this.soloLectura = false});

  /// Modo solo-lectura (cobrador, #4): oculta las acciones de escritura (Nuevo
  /// cliente, exportar, selección + reasignar) y navega al detalle por la ruta
  /// no-admin (`/clientes/:id`). Mantiene TODOS los filtros, igual que el admin.
  final bool soloLectura;

  @override
  ConsumerState<ClientesAdminScreen> createState() =>
      _ClientesAdminScreenState();
}

class _ClientesAdminScreenState extends ConsumerState<ClientesAdminScreen> {
  /// El parámetro `soloLectura` solo lo pasa la ruta del cobrador; el rol
  /// `lectura` (0198) entra por /admin/clientes y llegaba con `false`, así
  /// que veía "Nuevo cliente" y la barra de asignación masiva.
  bool get _soloLectura =>
      widget.soloLectura || ref.watch(soloLecturaProvider);
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';
  Set<String>? _cobradorFilter; // null/vacío = sin filtrar; puede incluir _kSinCobrador
  Set<String>? _comunidadFilter;
  Set<String>? _nodoFilter; // null = todos (topología de red)
  Set<String>? _estadoServicio; // null/vacío = sin filtrar (EstadoServicio.clave)
  bool _soloActivos = true; // true=activos, false=inactivos (binario; sin "todos")
  final Set<String> _seleccionados = {};
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // En teléfono, al enfocar la búsqueda (o tener texto) colapsamos los botones
    // de acción para que la barra tome todo el ancho — rebuild al cambiar foco.
    _searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _resetSeleccion() {
    // Limpiar selección al cambiar filtros: sino los IDs quedan en
    // memoria pero invisibles (no entran en el nuevo subset). Riesgo:
    // user selecciona 10, cambia filtro, queda con "10 seleccionado(s)"
    // pero ve 0 de ellos. Bulk-assign actuaría sobre IDs fantasma.
    _seleccionados.clear();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          _query = v.trim().toLowerCase();
          _resetSeleccion();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final diasGracia = settings.diasGracia;
    // En teléfono (angosto), al enfocar la búsqueda o tener texto, colapsamos
    // "Nuevo cliente" + exportar para que la barra tome todo el ancho (reporte
    // del cliente: en Android la barra quedaba mínima). En desktop no aplica.
    final esAngosto = MediaQuery.of(context).size.width < 600;
    final colapsarAcciones =
        esAngosto && (_searchFocus.hasFocus || _searchCtrl.text.isNotEmpty);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  onChanged: _onSearch,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: placeholderBusqueda(settings),
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {
                                _query = '';
                                _resetSeleccion();
                              });
                            },
                          ),
                  ),
                ),
              ),
              if (!_soloLectura && !colapsarAcciones) ...[
                const SizedBox(width: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.person_add),
                  label: const Text('Nuevo cliente'),
                  onPressed: () => context.push('/admin/clientes/nuevo'),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.download),
                  tooltip: 'Exportar a Excel',
                  onSelected: (val) => _exportarAExcel(val, diasGracia),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'actual',
                      child: Row(
                        children: [
                          Icon(Icons.filter_list, size: 20),
                          SizedBox(width: 8),
                          Text('Vista filtrada actual'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'todos',
                      child: Row(
                        children: [
                          Icon(Icons.people, size: 20),
                          SizedBox(width: 8),
                          Text('Todos los clientes'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        _Filtros(
          cobradorActual: _cobradorFilter,
          comunidadActual: _comunidadFilter,
          nodoActual: _nodoFilter,
          estadoServicioActual: _estadoServicio,
          soloActivos: _soloActivos,
          filtrosActivos: _filtrosActivos,
          onCobrador: (v) => setState(() {
            _cobradorFilter = v;
            _resetSeleccion();
          }),
          onComunidad: (v) => setState(() {
            _comunidadFilter = v;
            _resetSeleccion();
          }),
          onNodo: (v) => setState(() {
            _nodoFilter = v;
            _resetSeleccion();
          }),
          onEstadoServicio: (v) => setState(() {
            _estadoServicio = v;
            _resetSeleccion();
          }),
          onSoloActivos: (v) => setState(() {
            _soloActivos = v;
            _resetSeleccion();
          }),
          onLimpiar: _limpiarFiltros,
        ),
        if (!_soloLectura)
          if (_seleccionados.isEmpty)
            _SeleccionarTodosBar(
              onSelectAll: () => _seleccionarTodosDelFiltro(diasGracia),
            )
          else
            _BulkBar(
              cantidad: _seleccionados.length,
              onSelectAll: () => _seleccionarTodosDelFiltro(diasGracia),
              onClear: () => setState(() => _seleccionados.clear()),
              onAssign: () => _bulkAssign(context),
            ),
        Expanded(
          child: _Lista(
            query: _query,
            cobradorFilter: _cobradorFilter,
            comunidadFilter: _comunidadFilter,
            nodoFilter: _nodoFilter,
            estadoServicio: _estadoServicio,
            soloActivos: _soloActivos,
            diasGracia: diasGracia,
            settings: settings,
            soloLectura: _soloLectura,
            seleccionados: _seleccionados,
            onToggle: (id) => setState(() {
              if (!_seleccionados.add(id)) _seleccionados.remove(id);
            }),
          ),
        ),
      ],
    );
  }

  Future<void> _bulkAssign(BuildContext context) async {
    final seleccion = await showDialog<({String? id, String label})>(
      context: context,
      builder: (_) => const SeleccionarCobradorDialog(),
    );
    if (seleccion == null || !context.mounted) return;

    final ids = _seleccionados.toList();
    // Confirmar antes de aplicar — bulk-assign no tiene undo.
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar asignación masiva'),
        content: Text(
          'Vas a ${seleccion.id == null ? 'desasignar' : 'asignar a "${seleccion.label}"'} '
          '${ids.length} cliente(s).\n\n'
          'Esta acción se registra en auditoría y no se puede deshacer en lote.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Asignar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !context.mounted) return;

    final now = DateTime.now().toIso8601String();
    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    // op_log por cada cliente afectado (1 fila por objeto, MISMO op_id/actor/
    // ocurrido_en para todo el lote), igual que el form unitario — sin esto la
    // reasignación masiva no dejaba rastro y el diálogo prometía "se registra
    // en auditoría" en falso (audit 2026-07-04).
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final tenantId = ref.read(tenantIdProvider);
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    // try/catch: sin él, la guardia de solo-lectura (0198) escapaba como error
    // async no manejado y el botón "no hacía nada" en silencio.
    try {
      await ps.dbW.writeTransaction((tx) async {
      for (final id in ids) {
        final antes =
            (await tx.getAll('SELECT * FROM clientes WHERE id = ?', [id])).first;
        await tx.execute(
          'UPDATE clientes SET cobrador_id = ?, updated_at = ?, ocurrido_en = ? WHERE id = ?',
          [seleccion.id, now, ocurridoEn, id],
        );
        final despues =
            (await tx.getAll('SELECT * FROM clientes WHERE id = ?', [id])).first;
        if (tenantId != null) {
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'clientes',
              entidadId: id, antes: antes, despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurridoEn));
        }
      }
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${ids.length} cliente(s) actualizados')),
      );
      setState(() => _seleccionados.clear());
    }
  }

  Future<void> _exportarAExcel(String tipo, int diasGracia) async {
    try {
      // 'actual' = respeta los filtros activos (misma lógica que la lista y
      // que "Seleccionar todos del filtro"); 'todos' = sin filtros.
      final (:whereSql, :params) = tipo == 'actual'
          ? _filtroWhere(diasGracia)
          : (whereSql: '', params: <Object?>[]);
      final sql = '''
        SELECT c.codigo, c.nombre, c.cedula, c.telefono, c.direccion,
               c.direccion_referencia, c.activo, c.created_at,
               co.nombre AS comunidad,
               cb.nombre AS cobrador,
               (SELECT GROUP_CONCAT(DISTINCT pl.nombre)
                  FROM contratos ct JOIN planes pl ON pl.id = ct.plan_id
                 WHERE ct.cliente_id = c.id) AS planes,
               (SELECT GROUP_CONCAT(DISTINCT ct.dia_pago)
                  FROM contratos ct WHERE ct.cliente_id = c.id) AS dias_pago,
                COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                   FROM cuotas cu
                  WHERE cu.cliente_id = c.id
                    AND cu.estado IN ('pendiente','parcial')
                    AND COALESCE((SELECT ct2.estado FROM contratos ct2
                                    WHERE ct2.id = cu.contrato_id), 'activo') = 'activo'), 0) AS saldo,
               -- Deuda de contratos que YA NO están activos (suspendidos o
               -- cancelados). Queda fuera del `saldo` de arriba a propósito
               -- —ése es "lo cobrable en ruta"— pero se cobra igual, y omitirla
               -- hacía que el Excel mostrara MENOS plata de la que se debe.
                COALESCE((SELECT SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0))
                   FROM cuotas cu
                  WHERE cu.cliente_id = c.id
                    AND cu.estado IN ('pendiente','parcial')
                    AND COALESCE((SELECT ct2.estado FROM contratos ct2
                                    WHERE ct2.id = cu.contrato_id), 'activo') <> 'activo'), 0) AS saldo_fuera_ruta
          FROM clientes c
     LEFT JOIN comunidades co ON co.id = c.comunidad_id
     LEFT JOIN cobradores cb ON cb.id = c.cobrador_id
        $whereSql
        ORDER BY c.activo DESC, c.nombre
      ''';

      final rows = await ps.db.getAll(sql, params);

      final headers = [
        'Código', 'Nombre', 'Cédula', 'Teléfono', 'Dirección', 'Referencia',
        'Comunidad', 'Cobrador', 'Plan(es)', 'Día de pago',
        'Saldo pendiente (C\$)', 'Deuda fuera de ruta (C\$)',
        'Deuda total (C\$)', 'Estado', 'Fecha de alta',
      ];

      final filas = rows.map((r) {
        return <Object?>[
          r['codigo']?.toString() ?? '',
          r['nombre']?.toString() ?? '',
          r['cedula']?.toString() ?? '',
          r['telefono']?.toString() ?? '',
          r['direccion']?.toString() ?? '',
          r['direccion_referencia']?.toString() ?? '',
          r['comunidad']?.toString() ?? '',
          r['cobrador']?.toString() ?? '',
          r['planes']?.toString() ?? '',
          r['dias_pago']?.toString() ?? '',
          (r['saldo'] as num?) ?? 0,
          (r['saldo_fuera_ruta'] as num?) ?? 0,
          ((r['saldo'] as num?) ?? 0) + ((r['saldo_fuera_ruta'] as num?) ?? 0),
          (r['activo'] as int? ?? 1) == 1 ? 'Activo' : 'Inactivo',
          r['created_at'] == null ? '' : Fmt.fechaNi(r['created_at'] as String),
        ];
      }).toList();

      final now = DateTime.now();
      final mm = now.month.toString().padLeft(2, '0');
      final dd = now.day.toString().padLeft(2, '0');
      final fileName = '${tipo == 'actual' ? 'clientes_filtrados' : 'todos_los_clientes'}_${now.year}_${mm}_$dd.xlsx';

      final ruta = await descargarExcel(
        fileName: fileName,
        hojaNombre: tipo == 'actual' ? 'Clientes Filtrados' : 'Todos los Clientes',
        headers: headers,
        filas: filas,
        empresaNombre: ref.read(empresaNombreProvider).valueOrNull ?? 'ISP',
        titulo: tipo == 'actual'
            ? 'Listado de clientes — vista filtrada'
            : 'Listado de clientes',
        periodo: 'Al ${Fmt.fechaCorta(now)}',
      );

      if (mounted && ruta != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reporte Excel guardado')),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e is UnsupportedError
            ? (e.message?.toString() ?? 'Exportación no soportada')
            : mensajeErrorHumano(e, contexto: 'generar el Excel');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    }
  }

  /// WHERE + params de los filtros activos. Lo comparten el export "vista
  /// filtrada" y "Seleccionar todos del filtro" para no divergir (misma
  /// lógica que la query de la lista).
  ({String whereSql, List<Object?> params}) _filtroWhere(int diasGracia) {
    final (:where, :params) = construirFiltroClientes(
      query: _query,
      cobrador: _cobradorFilter,
      comunidad: _comunidadFilter,
      nodo: _nodoFilter,
      estadoServicio: _estadoServicio,
      soloActivos: _soloActivos,
      diasGracia: diasGracia,
      settings: ref.read(appSettingsProvider),
    );
    return (
      whereSql: where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}',
      params: params,
    );
  }

  /// ¿Hay al menos un filtro activo? (para mostrar "Limpiar (N)").
  int get _filtrosActivos {
    var n = 0;
    if (_cobradorFilter != null && _cobradorFilter!.isNotEmpty) n++;
    if (_comunidadFilter != null && _comunidadFilter!.isNotEmpty) n++;
    if (_nodoFilter != null && _nodoFilter!.isNotEmpty) n++;
    if (_estadoServicio != null && _estadoServicio!.isNotEmpty) n++;
    if (!_soloActivos) n++; // "Inactivos" es un filtro no-default
    return n;
  }

  void _limpiarFiltros() {
    setState(() {
      _cobradorFilter = null;
      _comunidadFilter = null;
      _nodoFilter = null;
      _estadoServicio = null;
      _soloActivos = true;
      _resetSeleccion();
    });
  }

  /// Carga en `_seleccionados` TODOS los clientes que matchean el filtro
  /// actual (no solo la página visible) → habilita la reasignación masiva
  /// por zona/cobrador sin tildar uno por uno.
  Future<void> _seleccionarTodosDelFiltro(int diasGracia) async {
    final (:whereSql, :params) = _filtroWhere(diasGracia);
    final rows =
        await ps.db.getAll('SELECT c.id FROM clientes c $whereSql', params);
    if (!mounted) return;
    setState(() {
      _seleccionados
        ..clear()
        ..addAll(rows.map((r) => r['id'] as String));
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('${_seleccionados.length} cliente(s) seleccionados')),
    );
  }
}

class _Filtros extends StatelessWidget {
  const _Filtros({
    required this.cobradorActual,
    required this.comunidadActual,
    required this.nodoActual,
    required this.estadoServicioActual,
    required this.soloActivos,
    required this.filtrosActivos,
    required this.onCobrador,
    required this.onComunidad,
    required this.onNodo,
    required this.onEstadoServicio,
    required this.onSoloActivos,
    required this.onLimpiar,
  });

  final Set<String>? cobradorActual;
  final Set<String>? comunidadActual;
  final Set<String>? nodoActual;
  final Set<String>? estadoServicioActual;
  final bool soloActivos;
  final int filtrosActivos;
  final ValueChanged<Set<String>?> onCobrador;
  final ValueChanged<Set<String>?> onComunidad;
  final ValueChanged<Set<String>?> onNodo;
  final ValueChanged<Set<String>?> onEstadoServicio;
  final ValueChanged<bool> onSoloActivos;
  final VoidCallback onLimpiar;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _CobradorChip(seleccionados: cobradorActual, onChanged: onCobrador),
          const SizedBox(width: 8),
          _ComunidadChip(seleccionados: comunidadActual, onChanged: onComunidad),
          const SizedBox(width: 8),
          _NodoChip(seleccionados: nodoActual, onChanged: onNodo),
          const SizedBox(width: 8),
          _EstadoServicioChip(
              seleccionados: estadoServicioActual, onChanged: onEstadoServicio),
          const SizedBox(width: 8),
          _ActivoChip(soloActivos: soloActivos, onChanged: onSoloActivos),
          if (filtrosActivos > 0) ...[
            const SizedBox(width: 8),
            TextButton.icon(
              icon: const Icon(Icons.filter_alt_off, size: 18),
              label: Text('Limpiar ($filtrosActivos)'),
              onPressed: onLimpiar,
            ),
          ],
        ],
      ),
    );
  }
}

/// Filtro multi-select de Estado de servicio (opciones fijas). Incluye los
/// deudores fuera de ruta (suspendido/cancelado con deuda).
class _EstadoServicioChip extends StatelessWidget {
  const _EstadoServicioChip(
      {required this.seleccionados, required this.onChanged});
  final Set<String>? seleccionados; // null/vacío = todos
  final ValueChanged<Set<String>?> onChanged;

  @override
  Widget build(BuildContext context) {
    final opts = [
      for (final e in EstadoServicio.values)
        FiltroOpcion(id: e.clave, label: e.label),
    ];
    final allIds = opts.map((o) => o.id).toSet();
    return FiltroMultiDropdown(
      icon: Icons.assignment_outlined,
      hint: 'Estado de servicio',
      buscarHint: 'Buscar estado…',
      opciones: opts,
      seleccionados: seleccionados ?? allIds,
      // Todo o nada seleccionado = sin filtrar (nunca lista vacía por accidente).
      onChanged: (s) =>
          onChanged(s.isEmpty || s.length >= allIds.length ? null : s),
    );
  }
}

/// Selector binario Activos / Inactivos (default Activos). Reemplaza el viejo
/// "Solo activos / inactivos / todos" — "todos" se quitó por decisión de Rubén.
class _ActivoChip extends StatelessWidget {
  const _ActivoChip({required this.soloActivos, required this.onChanged});
  final bool soloActivos;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<bool>(
      onSelected: onChanged,
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: true,
          child: Row(children: [
            Icon(Icons.visibility, size: 18),
            SizedBox(width: 8),
            Text('Activos'),
          ]),
        ),
        PopupMenuItem(
          value: false,
          child: Row(children: [
            Icon(Icons.visibility_off, size: 18),
            SizedBox(width: 8),
            Text('Inactivos'),
          ]),
        ),
      ],
      child: Chip(
        avatar: Icon(soloActivos ? Icons.visibility : Icons.visibility_off,
            size: 18),
        label: Text(soloActivos ? 'Activos' : 'Inactivos'),
        deleteIcon: const Icon(Icons.arrow_drop_down, size: 18),
        onDeleted: () {},
      ),
    );
  }
}

class _CobradorChip extends StatefulWidget {
  const _CobradorChip({required this.seleccionados, required this.onChanged});
  final Set<String>? seleccionados; // null = todos
  final ValueChanged<Set<String>?> onChanged;

  @override
  State<_CobradorChip> createState() => _CobradorChipState();
}

class _CobradorChipState extends State<_CobradorChip> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _cobradoresStream;

  @override
  void initState() {
    super.initState();
    _cobradoresStream = ps.db.watch(
      '''
      SELECT id, nombre FROM cobradores
       WHERE activo = 1 AND rol = 'cobrador'
       ORDER BY nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cobradoresStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Chip(label: Text(mensajeErrorHumano(snap.error!)));
        }
        final opts = [
          // "Sin cobrador" como opción del dropdown (reemplaza el toggle suelto).
          const FiltroOpcion(id: _kSinCobrador, label: 'Sin cobrador'),
          for (final r in snap.data!)
            if (r['id'] != null)
              FiltroOpcion(
                  id: r['id'] as String, label: (r['nombre'] as String?) ?? ''),
        ];
        final allIds = opts.map((o) => o.id).toSet();
        return FiltroMultiDropdown(
          icon: Icons.person,
          hint: 'Cobrador',
          buscarHint: 'Buscar cobrador…',
          opciones: opts,
          seleccionados: widget.seleccionados ?? allIds,
          onChanged: (s) => widget
              .onChanged(s.isEmpty || s.length >= allIds.length ? null : s),
        );
      },
    );
  }
}

class _ComunidadChip extends StatefulWidget {
  const _ComunidadChip({required this.seleccionados, required this.onChanged});
  final Set<String>? seleccionados; // null = todas
  final ValueChanged<Set<String>?> onChanged;

  @override
  State<_ComunidadChip> createState() => _ComunidadChipState();
}

class _ComunidadChipState extends State<_ComunidadChip> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _comunidadesStream;

  @override
  void initState() {
    super.initState();
    _comunidadesStream = ps.db.watch(
      '''
      SELECT co.id, co.nombre, m.nombre AS mun
        FROM comunidades co
        JOIN municipios m ON m.id = co.municipio_id
       ORDER BY m.nombre, co.nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _comunidadesStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Chip(label: Text(mensajeErrorHumano(snap.error!)));
        }
        final opts = [
          for (final r in snap.data!)
            if (r['id'] != null)
              FiltroOpcion(
                id: r['id'] as String,
                label: (r['nombre'] as String?) ?? '',
                grupo: r['mun'] as String?,
              ),
        ];
        final allIds = opts.map((o) => o.id).toSet();
        return FiltroMultiDropdown(
          icon: Icons.place,
          hint: 'Zona',
          buscarHint: 'Buscar municipio o comunidad…',
          opciones: opts,
          seleccionados: widget.seleccionados ?? allIds,
          onChanged: (s) => widget
              .onChanged(s.isEmpty || s.length >= allIds.length ? null : s),
        );
      },
    );
  }
}

class _NodoChip extends StatefulWidget {
  const _NodoChip({required this.seleccionados, required this.onChanged});
  final Set<String>? seleccionados; // null = todos
  final ValueChanged<Set<String>?> onChanged;

  @override
  State<_NodoChip> createState() => _NodoChipState();
}

class _NodoChipState extends State<_NodoChip> {
  late final Stream<List<Map<String, dynamic>>> _nodosStream;

  @override
  void initState() {
    super.initState();
    _nodosStream = ps.db.watch(
      'SELECT id, nombre FROM red_nodos WHERE activo = 1 ORDER BY nombre',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _nodosStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Chip(label: Text(mensajeErrorHumano(snap.error!)));
        }
        final opts = [
          for (final r in snap.data!)
            if (r['id'] != null)
              FiltroOpcion(
                  id: r['id'] as String, label: (r['nombre'] as String?) ?? ''),
        ];
        final allIds = opts.map((o) => o.id).toSet();
        return FiltroMultiDropdown(
          icon: Icons.hub,
          hint: 'Nodo',
          buscarHint: 'Buscar nodo…',
          opciones: opts,
          seleccionados: widget.seleccionados ?? allIds,
          onChanged: (s) => widget
              .onChanged(s.isEmpty || s.length >= allIds.length ? null : s),
        );
      },
    );
  }
}

/// Barra fina (sin selección) para entrar al modo masivo: selecciona TODOS
/// los clientes que matchean el filtro actual, no solo la página visible.
class _SeleccionarTodosBar extends StatelessWidget {
  const _SeleccionarTodosBar({required this.onSelectAll});
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: TextButton.icon(
          icon: const Icon(Icons.checklist, size: 18),
          label: const Text('Seleccionar todos del filtro'),
          onPressed: onSelectAll,
        ),
      ),
    );
  }
}

class _BulkBar extends StatelessWidget {
  const _BulkBar({
    required this.cantidad,
    required this.onSelectAll,
    required this.onClear,
    required this.onAssign,
  });
  final int cantidad;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: onClear,
            ),
            Text('$cantidad seleccionado(s)'),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.checklist, size: 18),
              label: const Text('Todos del filtro'),
              onPressed: onSelectAll,
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Asignar cobrador'),
              onPressed: onAssign,
            ),
          ],
        ),
      ),
    );
  }
}

class _Lista extends StatefulWidget {
  const _Lista({
    required this.query,
    required this.cobradorFilter,
    required this.comunidadFilter,
    required this.nodoFilter,
    required this.estadoServicio,
    required this.soloActivos,
    required this.diasGracia,
    required this.settings,
    required this.soloLectura,
    required this.seleccionados,
    required this.onToggle,
  });

  final String query;
  final Set<String>? cobradorFilter;
  final Set<String>? comunidadFilter;
  final Set<String>? nodoFilter;
  final Set<String>? estadoServicio;
  final bool soloActivos;
  final int diasGracia;
  final AppSettings settings;
  final bool soloLectura;
  final Set<String> seleccionados;
  final ValueChanged<String> onToggle;

  @override
  State<_Lista> createState() => _ListaState();
}

class _ListaState extends State<_Lista> {
  // Paginación (Capa 1+2): mostramos una PÁGINA y la agrandamos al hacer scroll
  // cerca del fondo. La query agrega SOLO la página visible (no los miles del
  // tenant) → carga rápida sin importar el tamaño. Mismas fórmulas que antes
  // (consistencia #10), solo acotadas a la página vía subconsulta con LIMIT.
  //
  // Manejamos la suscripción a mano (no StreamBuilder) para que el build sea
  // PURO: el footer/contador/“hay más” se derivan de estado seteado vía
  // setState en los callbacks del stream (data Y error), nunca mutado dentro
  // del builder. Así la paginación no puede quedar bloqueada por un stream que
  // falló ni por carreras con _onScroll.
  static const int _tamPagina = 60;
  int _limite = _tamPagina;
  final ScrollController _scrollCtrl = ScrollController();
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  // Filas a mostrar (ya recortadas a _limite). null = cargando primera página
  // (o refiltrando) → spinner.
  List<Map<String, dynamic>>? _filas;
  Object? _error;
  // ¿Hay al menos una fila más allá de la página actual? Traemos _limite+1 para
  // saberlo EXACTO (sin una query de más en el borde múltiplo-de-_tamPagina).
  bool _hayMas = false;
  // Agrandando la ventana (footer "cargando más" + guard anti-doble disparo).
  bool _creciendo = false;

  // Total REAL de clientes del filtro (NO solo los cargados). Es la MISMA query
  // de filtro que "Seleccionar todos del filtro" → el número del header y el de
  // ese botón SIEMPRE coinciden. Corre en paralelo a la lista (no la traba); se
  // re-suscribe solo al cambiar filtro (no al paginar). null = aún contando.
  StreamSubscription<List<Map<String, dynamic>>>? _subTotal;
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
    _scrollCtrl.dispose();
    _sub?.cancel();
    _subTotal?.cancel();
    super.dispose();
  }

  // (Re)suscribe el conteo total (mismo filtro que la lista, SIN paginar). Solo
  // se llama al cambiar filtro (NO al paginar — el total no cambia al crecer la
  // ventana). Reactivo: si se agrega/quita un cliente, el número se actualiza.
  void _suscribirTotal() {
    _subTotal?.cancel();
    _subTotal = _buildCountStream().listen((rows) {
      if (!mounted) return;
      setState(() =>
          _total = rows.isEmpty ? 0 : ((rows.first['n'] as num?)?.toInt() ?? 0));
    });
  }

  // (Re)suscribe el watch con el _limite actual. Mantiene las filas previas
  // visibles mientras llega la primera emisión (no parpadea al paginar). Para
  // refiltrar, el caller pone _filas=null antes → vuelve al spinner desde el
  // tope, sin mostrar filas del filtro anterior.
  void _suscribir() {
    _sub?.cancel();
    _sub = _buildStream().listen(
      (data) {
        if (!mounted) return;
        setState(() {
          // Vino _limite+1: si llegó la fila extra, hay más → la descartamos
          // del render y marcamos _hayMas. El "+" y el footer quedan exactos.
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

  // Al acercarse al fondo, crecemos la ventana → re-suscribe con más límite.
  // Guards: _hayMas (ya trajimos todo) y _creciendo (anti-doble disparo).
  void _onScroll() {
    if (!_scrollCtrl.hasClients || !_hayMas || _creciendo) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) {
      setState(() {
        _creciendo = true;
        _limite += _tamPagina;
      });
      _suscribir();
    }
  }

  @override
  void didUpdateWidget(_Lista old) {
    super.didUpdateWidget(old);
    // Solo re-suscribir si cambió algún param que afecta la SQL.
    // seleccionados/onToggle NO tocan la query — solo el render.
    if (old.query != widget.query ||
        !setEquals(old.cobradorFilter, widget.cobradorFilter) ||
        !setEquals(old.comunidadFilter, widget.comunidadFilter) ||
        !setEquals(old.nodoFilter, widget.nodoFilter) ||
        !setEquals(old.estadoServicio, widget.estadoServicio) ||
        old.soloActivos != widget.soloActivos ||
        old.diasGracia != widget.diasGracia ||
        old.settings != widget.settings) {
      // Cambió el filtro → primera página desde el tope (spinner, sin filas
      // viejas del filtro anterior) + recontar el total.
      setState(() {
        _limite = _tamPagina;
        _hayMas = false;
        _creciendo = false;
        _filas = null;
        _error = null;
        _total = null;
      });
      _suscribir();
      _suscribirTotal();
    }
  }

  // Conteo total del filtro (SIN LIMIT). Mismo construirFiltroClientes que la
  // lista y que "Seleccionar todos del filtro" → el número del header coincide
  // SIEMPRE con el de ese botón. Es solo COUNT(*) (sin agregaciones por
  // cliente) → liviano aun reactivo; corre en paralelo, no traba la lista.
  Stream<List<Map<String, dynamic>>> _buildCountStream() {
    final (:where, :params) = construirFiltroClientes(
      query: widget.query,
      cobrador: widget.cobradorFilter,
      comunidad: widget.comunidadFilter,
      nodo: widget.nodoFilter,
      estadoServicio: widget.estadoServicio,
      soloActivos: widget.soloActivos,
      diasGracia: widget.diasGracia,
      settings: widget.settings,
    );
    final sql =
        'SELECT COUNT(*) AS n FROM clientes c WHERE ${where.join(' AND ')}';
    return ps.db.watch(sql, parameters: params);
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    // Filtros centralizados (mismo helper que el export y "seleccionar todos"
    // → consistencia #10). La mora/gracia ahora se filtran vía Estado de
    // servicio, no con HAVING.
    final (:where, :params) = construirFiltroClientes(
      query: widget.query,
      cobrador: widget.cobradorFilter,
      comunidad: widget.comunidadFilter,
      nodo: widget.nodoFilter,
      estadoServicio: widget.estadoServicio,
      soloActivos: widget.soloActivos,
      diasGracia: widget.diasGracia,
      settings: widget.settings,
    );
    // El SELECT usa diasGracia DOS veces (vencidas + en_gracia) ANTES del WHERE.
    // + _limite+1 al final: LIMIT de la subconsulta interna. La fila extra
    // (más allá de _limite) solo sirve para saber EXACTO si hay más página;
    // se descarta del render en _suscribir.
    final fullParams = <Object?>[
      widget.diasGracia, widget.diasGracia, ...params, _limite + 1,
    ];

    final sql = '''
      SELECT c.id, c.codigo, c.nombre, c.telefono, c.direccion_referencia,
             c.cobrador_id, c.activo,
             co.nombre AS cobrador_nombre,
             cm.nombre AS comunidad, m.nombre AS municipio,
             COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                                AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
                               THEN 1 ELSE 0 END), 0) AS vencidas,
             COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                                AND date(cu.fecha_vencimiento) < date('now', '-6 hours')
                                AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now', '-6 hours')
                               THEN 1 ELSE 0 END), 0) AS en_gracia,
             COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                                THEN max(cu.monto + COALESCE(cu.cargos_neto, 0) - COALESCE(cu.monto_pagado, 0), 0)
                                ELSE 0 END), 0) AS saldo,
             COALESCE((SELECT SUM(max(cu2.monto + COALESCE(cu2.cargos_neto,0) - COALESCE(cu2.monto_pagado, 0), 0))
                FROM cuotas cu2 JOIN contratos ct3 ON ct3.id = cu2.contrato_id
               WHERE cu2.cliente_id = c.id AND cu2.estado IN ('pendiente','parcial')
                 AND ct3.estado IN ('suspendido','cancelado')), 0) AS saldo_fuera_ruta,
             (SELECT COUNT(*) FROM contratos ct
               WHERE ct.cliente_id = c.id
                 AND COALESCE(ct.estado, 'activo') = 'activo') AS contratos_activos,
             (SELECT GROUP_CONCAT(e.nombre || char(31) || e.color || char(31) || e.icono, char(30))
                FROM cliente_etiquetas ce JOIN etiquetas e ON e.id = ce.etiqueta_id
               WHERE ce.cliente_id = c.id) AS etiquetas_concat
        FROM clientes c
   LEFT JOIN cobradores  co ON co.id = c.cobrador_id
   LEFT JOIN comunidades cm ON cm.id = c.comunidad_id
   LEFT JOIN municipios  m  ON m.id = cm.municipio_id
   LEFT JOIN cuotas      cu ON cu.cliente_id = c.id
          AND COALESCE((SELECT ct2.estado FROM contratos ct2
                          WHERE ct2.id = cu.contrato_id), 'activo') = 'activo'
       WHERE c.id IN (
               SELECT c.id FROM clientes c
                WHERE ${where.join(' AND ')}
                ORDER BY c.nombre
                LIMIT ?
             )
       GROUP BY c.id, c.codigo, c.nombre, c.telefono, c.direccion_referencia,
                c.cobrador_id, c.activo, co.nombre, cm.nombre, m.nombre
       ORDER BY c.nombre
    ''';

    return ps.db.watch(sql, parameters: fullParams);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(mensajeErrorHumano(_error!)));
    }
    final rows = _filas;
    // Capa 1: primera carga / refiltrado → SPINNER (nunca el vacío "Sin
    // clientes" mientras calcula — ese era el bug que confundía con "no hay
    // data").
    if (rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      final hayFiltros = widget.query.isNotEmpty ||
          (widget.cobradorFilter?.isNotEmpty ?? false) ||
          (widget.comunidadFilter?.isNotEmpty ?? false) ||
          (widget.nodoFilter?.isNotEmpty ?? false) ||
          (widget.estadoServicio?.isNotEmpty ?? false) ||
          !widget.soloActivos;
      return EmptyState(
        icon: Icons.people_outline,
        titulo: hayFiltros ? 'Ningún cliente coincide' : 'Sin clientes',
        descripcion: hayFiltros
            ? 'Ningún cliente coincide con estos filtros. Tocá "Limpiar" arriba para verlos todos.'
            : 'Creá tu primer cliente con "Nuevo cliente".',
      );
    }
    // Footer "cargando más" solo mientras se agranda la ventana.
    final mostrarFooter = _creciendo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            // Total REAL del filtro (mismo número que "Seleccionar todos del
            // filtro"). Mientras se cuenta (un pestañeo en el filtro de estado)
            // se ve "…". Las filas se cargan solas al scrollear; este número NO
            // cambia al bajar.
            _total != null
                ? '${Fmt.entero(_total!)} ${_total == 1 ? 'cliente' : 'clientes'}'
                : '…',
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).colorScheme.outline),
          ),
        ),
        Expanded(
          child: ListView.separated(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: rows.length + (mostrarFooter ? 1 : 0),
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
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
              final r = rows[i];
              final selected = widget.seleccionados.contains(r['id']);
              return _ClienteCard(
                row: r,
                selected: selected,
                soloLectura: widget.soloLectura,
                onToggle: () => widget.onToggle(r['id'] as String),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ClienteCard extends ConsumerWidget {
  const _ClienteCard({
    required this.row,
    required this.selected,
    required this.soloLectura,
    required this.onToggle,
  });

  final Map<String, dynamic> row;
  final bool selected;
  final bool soloLectura;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final colores = ref.watch(appSettingsProvider).coloresEstados;
    final vencidas = row['vencidas'] as int? ?? 0;
    final enGracia = row['en_gracia'] as int? ?? 0;
    final contratos = row['contratos_activos'] as int? ?? 0;
    final saldo = (row['saldo'] as num? ?? 0).toDouble();
    final fueraRuta = (row['saldo_fuera_ruta'] as num? ?? 0).toDouble();
    final sinCobrador = row['cobrador_id'] == null;
    final etiquetaChips = etiquetaChipsDesdeConcat(row['etiquetas_concat']);
    final inactivo = (row['activo'] as int? ?? 1) == 0;
    // Color de "en gracia" desde la paleta configurable del tenant.
    final ambar = colores.gracia;

    return Card(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
      child: InkWell(
        onTap: () => context.push(soloLectura
            ? '/clientes/${row['id']}'
            : '/admin/clientes/${row['id']}'),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (!soloLectura)
                Checkbox(
                  value: selected,
                  onChanged: (_) => onToggle(),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (row['codigo'] != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(row['codigo'] as String,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                              letterSpacing: 0.5,
                            )),
                      ),
                    Row(
                      children: [
                        Flexible(
                          child: Text(row['nombre'] as String,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: inactivo ? scheme.outline : null,
                                decoration: inactivo ? TextDecoration.lineThrough : null,
                              )),
                        ),
                        if (inactivo) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('Inactivo',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.outline)),
                          ),
                        ],
                      ],
                    ),
                    if (row['comunidad'] != null)
                      Text('${row['comunidad']} · ${row['municipio'] ?? ''}',
                          style: TextStyle(color: scheme.outline, fontSize: 12)),
                    const SizedBox(height: 4),
                    if (etiquetaChips.isNotEmpty) ...[
                      Wrap(spacing: 6, runSpacing: 4, children: etiquetaChips),
                      const SizedBox(height: 4),
                    ],
                    Wrap(
                      spacing: 6,
                      children: [
                        if (sinCobrador)
                          Chip(
                            avatar: Icon(Icons.person_off, size: 14, color: scheme.error),
                            label: const Text('Sin cobrador'),
                            backgroundColor: scheme.errorContainer.withValues(alpha: 0.3),
                            visualDensity: VisualDensity.compact,
                          )
                        else
                          Chip(
                            avatar: const Icon(Icons.person, size: 14),
                            label: Text(row['cobrador_nombre'] as String? ?? '—'),
                            visualDensity: VisualDensity.compact,
                          ),
                        // Tag de contratos SIEMPRE visible (P4): cuántos
                        // servicios activos tiene el cliente de un vistazo
                        // (la mora y el saldo agregan todos los contratos).
                        // 0 activos (nuevo sin contrato o único suspendido)
                        // → "Sin contrato" en gris.
                        if (contratos >= 1)
                          Chip(
                            avatar: Icon(Icons.description_outlined,
                                size: 14, color: scheme.primary),
                            label: Text(contratos == 1
                                ? '1 contrato'
                                : '$contratos contratos'),
                            backgroundColor:
                                scheme.primaryContainer.withValues(alpha: 0.3),
                            visualDensity: VisualDensity.compact,
                          )
                        else
                          Chip(
                            avatar: Icon(Icons.description_outlined,
                                size: 14, color: scheme.outline),
                            label: Text('Sin contrato',
                                style: TextStyle(color: scheme.outline)),
                            backgroundColor: scheme.surfaceContainerHighest,
                            visualDensity: VisualDensity.compact,
                          ),
                        if (vencidas > 0)
                          Chip(
                            avatar: Icon(Icons.warning, size: 14, color: colores.mora),
                            label: Text('$vencidas vencida(s)'),
                            backgroundColor: colores.mora.withValues(alpha: 0.12),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (enGracia > 0)
                          Chip(
                            avatar: Icon(Icons.hourglass_bottom,
                                size: 14, color: ambar),
                            label: Text('$enGracia en gracia'),
                            backgroundColor: ambar.withValues(alpha: 0.12),
                            visualDensity: VisualDensity.compact,
                          ),
                        // Deuda en contratos suspendidos/cancelados — antes
                        // invisible (la lista de ruta la excluye). Cierra el
                        // agujero de visibilidad sin tocar el saldo de ruta.
                        if (fueraRuta > 0)
                          Chip(
                            avatar: Icon(Icons.error_outline,
                                size: 14, color: ambar),
                            label: Text(
                                'debe ${Fmt.cordobas(fueraRuta)} fuera de ruta'),
                            backgroundColor: ambar.withValues(alpha: 0.12),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    Fmt.cordobas(saldo),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: vencidas > 0 ? colores.mora : null,
                    ),
                  ),
                  Text('Saldo',
                      style: TextStyle(color: scheme.outline, fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

