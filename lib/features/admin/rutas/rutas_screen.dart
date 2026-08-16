import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/utils/busqueda_cliente.dart' show coincideTokens;
import '../../../data/utils/errores.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/filtro_multi_dropdown.dart';
import '../clientes/seleccionar_cobrador_dialog.dart';

/// Pantalla "Rutas" (admin): una comunidad = una ruta. Muestra el cobrador
/// actual de cada comunidad (derivado de sus clientes activos) y permite
/// reasignar la ruta ENTERA a otro cobrador de una. Reset total: cambia a
/// TODOS los clientes activos de la comunidad, incluidos los especiales —
/// esos se reasignan después a mano desde la lista de clientes (decisión
/// Rubén 2026-06-17). El server propaga `cobrador_id` a cuotas/mapa/cobros,
/// así que requiere estar online.
class RutasScreen extends ConsumerStatefulWidget {
  const RutasScreen({super.key});

  @override
  ConsumerState<RutasScreen> createState() => _RutasScreenState();
}

class _RutasScreenState extends ConsumerState<RutasScreen> {
  late Stream<List<Map<String, dynamic>>> _comunidades;
  late Stream<List<Map<String, dynamic>>> _cobradores;

  // Filtro client-side sobre la lista ya emitida (no recrea el stream).
  // _municipioIds null = todos los municipios; un Set acota. Búsqueda con
  // debounce 250ms. Todo corre en memoria sobre lo ya cargado → 100% offline.
  final _busquedaCtrl = TextEditingController();
  String _busqueda = '';
  Timer? _busquedaDebounce;
  Set<String>? _municipioIds;
  // Chip "Cobrador": null = todos; ids de cobradores + _sinAsignarId.
  Set<String>? _cobradorIds;

  // Comunidades con ≥1 cliente activo + el cobrador derivado de esos clientes.
  // n_cobradores = cobradores distintos (sin contar NULL); sin_cobrador =
  // cuántos sin asignar; algun_cobrador = uno cualquiera (MAX ignora NULL);
  // cobradores_csv = TODOS los cobradores presentes (para el chip "Cobrador"
  // — GROUP_CONCAT DISTINCT es SQLite-válido, separador ',' y los uuid no
  // llevan coma).
  static const _comunidadesSql = '''
    SELECT cm.id AS comunidad_id, cm.nombre AS comunidad, m.nombre AS municipio,
           COUNT(c.id) AS n_clientes,
           COUNT(DISTINCT c.cobrador_id) AS n_cobradores,
           MAX(c.cobrador_id) AS algun_cobrador,
           SUM(CASE WHEN c.cobrador_id IS NULL THEN 1 ELSE 0 END) AS sin_cobrador,
           GROUP_CONCAT(DISTINCT c.cobrador_id) AS cobradores_csv
      FROM comunidades cm
      JOIN municipios m ON m.id = cm.municipio_id
 LEFT JOIN clientes c ON c.comunidad_id = cm.id AND c.activo = 1
     GROUP BY cm.id, cm.nombre, m.nombre
    HAVING COUNT(c.id) > 0
     ORDER BY m.nombre, cm.nombre
  ''';

  /// Id centinela del chip "Cobrador" para "Sin asignar" (clientes con
  /// cobrador NULL). No colisiona con uuids reales.
  static const _sinAsignarId = '__sin_asignar__';

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  void _rebuild() {
    _comunidades = ps.db.watch(_comunidadesSql);
    // Todos los cobradores (incluso inactivos) para resolver el nombre del
    // cobrador actual aunque alguno se haya desactivado sin reasignar.
    _cobradores =
        ps.db.watch('SELECT id, nombre, activo FROM cobradores ORDER BY nombre');
  }

  void _limpiar() {
    _busquedaDebounce?.cancel();
    _busquedaCtrl.clear();
    setState(() {
      _municipioIds = null;
      _cobradorIds = null;
      _busqueda = '';
    });
  }

  @override
  void dispose() {
    _busquedaDebounce?.cancel();
    _busquedaCtrl.dispose();
    super.dispose();
  }

  /// Fila de filtro: chips "Municipio" + "Cobrador" (multi-select) + botón
  /// Limpiar. Las opciones se derivan de los streams YA suscriptos
  /// (municipios de la lista de comunidades; cobradores del stream de
  /// cobradores) — sin suscripción extra (regla audit #2).
  Widget _buildFiltros(List<String> municipios, Map<String, String> cobMap,
      Set<String> inactivos) {
    final scheme = Theme.of(context).colorScheme;
    final opts = [for (final m in municipios) FiltroOpcion(id: m, label: m)];
    final allIds = opts.map((o) => o.id).toSet();
    // Chip Cobrador: "Sin asignar" primero + todos los cobradores (los
    // inactivos marcados — pueden seguir figurando como ruta hasta reasignar).
    final cobOpts = [
      const FiltroOpcion(id: _sinAsignarId, label: 'Sin asignar'),
      for (final e in cobMap.entries)
        FiltroOpcion(
          id: e.key,
          label: inactivos.contains(e.key) ? '${e.value} (inactivo)' : e.value,
        ),
    ];
    final cobAllIds = cobOpts.map((o) => o.id).toSet();
    final activos =
        (_municipioIds != null && _municipioIds!.isNotEmpty ? 1 : 0) +
            (_cobradorIds != null && _cobradorIds!.isNotEmpty ? 1 : 0) +
            (_busqueda.isNotEmpty ? 1 : 0);
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          FiltroMultiDropdown(
            icon: Icons.location_city_outlined,
            hint: 'Municipio',
            buscarHint: 'Buscar municipio…',
            opciones: opts,
            seleccionados: _municipioIds ?? allIds,
            // Todos o nada marcado = sin filtrar (null), nunca lista vacía.
            onChanged: (s) => setState(() => _municipioIds =
                s.isEmpty || s.length >= allIds.length ? null : s),
          ),
          const SizedBox(width: 8),
          FiltroMultiDropdown(
            icon: Icons.person_outline,
            hint: 'Cobrador',
            buscarHint: 'Buscar cobrador…',
            opciones: cobOpts,
            seleccionados: _cobradorIds ?? cobAllIds,
            onChanged: (s) => setState(() => _cobradorIds =
                s.isEmpty || s.length >= cobAllIds.length ? null : s),
          ),
          const Spacer(),
          if (activos > 0)
            TextButton.icon(
              icon: const Icon(Icons.filter_alt_off, size: 18),
              label: Text('Limpiar ($activos)'),
              onPressed: _limpiar,
            ),
        ],
      ),
    );
  }

  /// Buscador de comunidad (o municipio). Filtra client-side la lista ya
  /// cargada con debounce 250ms; no recrea el stream.
  Widget _buildBuscador() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: _busquedaCtrl,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: 'Buscar comunidad…',
          suffixIcon: _busqueda.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Limpiar',
                  onPressed: () {
                    _busquedaDebounce?.cancel();
                    _busquedaCtrl.clear();
                    setState(() => _busqueda = '');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
        onChanged: (v) {
          _busquedaDebounce?.cancel();
          _busquedaDebounce = Timer(const Duration(milliseconds: 250), () {
            if (mounted) setState(() => _busqueda = v.trim());
          });
        },
      ),
    );
  }

  Widget _listaComunidades(
    List<Map<String, dynamic>> filtradas,
    Map<String, String> cobMap,
    Set<String> inactivos,
    ColorScheme scheme,
  ) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: filtradas.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final r = filtradas[i];
        final n = (r['n_clientes'] as int?) ?? 0;
        final sin = (r['sin_cobrador'] as int?) ?? 0;
        final ruta = _ruta(r, cobMap, inactivos);
        final esSinAsignar = ruta.label == 'Sin asignar';
        // "Sin asignar" = rojo (nadie cobra en el campo);
        // "Mixto"/"(inactivo)" = ámbar (atención); resto = neutro.
        final Color bg;
        final Color fg;
        if (esSinAsignar) {
          bg = scheme.errorContainer;
          fg = scheme.onErrorContainer;
        } else if (ruta.alerta) {
          bg = scheme.tertiaryContainer;
          fg = scheme.onTertiaryContainer;
        } else {
          bg = scheme.secondaryContainer;
          fg = scheme.onSecondaryContainer;
        }
        return Card(
          child: ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: Text(r['comunidad'] as String),
            subtitle: Text(
              '${r['municipio']} · $n cliente(s)'
              '${sin > 0 && !esSinAsignar ? ' · $sin sin asignar' : ''}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    ruta.label,
                    style: TextStyle(fontSize: 12, color: fg),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
            onTap: () => _reasignar(r),
          ),
        );
      },
    );
  }

  /// Etiqueta + flag de alerta del cobrador de la ruta: "Sin asignar" (ninguno
  /// con cobrador), el nombre si es único, con "(inactivo)" si ese cobrador
  /// está desactivado, o "Mixto" si hay más de uno. `alerta` = necesita
  /// atención del admin (destaca visualmente).
  ({String label, bool alerta}) _ruta(Map<String, dynamic> r,
      Map<String, String> cobMap, Set<String> inactivos) {
    final n = (r['n_cobradores'] as int?) ?? 0;
    final sin = (r['sin_cobrador'] as int?) ?? 0;
    if (n == 0) return (label: 'Sin asignar', alerta: true);
    if (n == 1 && sin == 0) {
      final id = r['algun_cobrador'] as String?;
      final nombre = cobMap[id] ?? 'Cobrador';
      if (id != null && inactivos.contains(id)) {
        return (label: '$nombre (inactivo)', alerta: true);
      }
      return (label: nombre, alerta: false);
    }
    return (label: 'Mixto', alerta: true);
  }

  Future<void> _reasignar(Map<String, dynamic> com) async {
    // Resumen de cómo están asignados HOY los clientes activos de la comunidad
    // (una query con nombres) para mostrarlo en el selector.
    final distRows = await ps.db.getAll('''
      SELECT c.cobrador_id, co.nombre AS cobrador_nombre,
             co.activo AS cobrador_activo, COUNT(*) AS cnt
        FROM clientes c
   LEFT JOIN cobradores co ON co.id = c.cobrador_id
       WHERE c.comunidad_id = ? AND c.activo = 1
       GROUP BY c.cobrador_id, co.nombre, co.activo
       ORDER BY cnt DESC
    ''', [com['comunidad_id']]);
    if (!mounted) return;
    final dist = distRows.map((d) {
      final id = d['cobrador_id'] as String?;
      final inactivo = (d['cobrador_activo'] as int? ?? 1) == 0;
      final etiqueta = id == null
          ? 'Sin cobrador'
          : '${d['cobrador_nombre'] as String? ?? 'Cobrador'}'
              '${inactivo ? ' (inactivo)' : ''}';
      return (etiqueta: etiqueta, cantidad: (d['cnt'] as int?) ?? 0);
    }).toList();

    // Reasignación auditada (emite op_log) → atribuida al usuario → bloqueada al
    // impersonar; se hace desde la cuenta real del ISP (audit 2026-06-30).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final seleccion = await showDialog<({String? id, String label})>(
      context: context,
      builder: (_) => SeleccionarCobradorDialog(distribucionActual: dist),
    );
    if (seleccion == null || !mounted) return;

    final n = (com['n_clientes'] as int?) ?? 0;
    final comunidad = com['comunidad'] as String;
    // P3b: Rutas puede desasignar (cobrador_id NULL) → esos clientes quedan
    // admin-managed (solo la oficina los ve/cobra) hasta reasignar.
    final destino = seleccion.id == null
        ? 'sin cobrador (solo lo ve la oficina)'
        : '"${seleccion.label}"';
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reasignar ruta'),
        content: Text(
          'Los $n cliente(s) activos de "$comunidad" pasan a $destino.\n\n'
          'Cambia a TODOS, incluidos los que tengan un cobrador especial — '
          'esos los reasignás después desde la lista de clientes. Requiere '
          'conexión y se registra en auditoría.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reasignar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;

    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc();
    final ocurridoEn = ocurrido.toIso8601String();
    // Clientes afectados con su cobrador ACTUAL (para el diff del op_log).
    final afectados = await ps.db.getAll(
      'SELECT id, cobrador_id FROM clientes WHERE comunidad_id = ? AND activo = 1',
      [com['comunidad_id']],
    );
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final tenantId = ref.read(tenantIdProvider);
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    // Reasignación + op_log en UNA transacción: 1 fila por cliente afectado con el
    // cambio de cobrador (antes→después), para que la reasignación masiva SÍ quede
    // en el change-log (antes prometía "auditoría" y no dejaba rastro — audit
    // 2026-06-30). El server propaga cobrador_id a cuotas/mapa/cobros vía trigger.
    // try/catch: la guardia de solo-lectura (0198) escapaba sin capturar y la
    // reasignación masiva fallaba en silencio.
    try {
      await ps.dbW.writeTransaction((tx) async {
      final opId = OpLog.nuevoOpId();
      for (final c in afectados) {
        final id = c['id'] as String;
        await tx.execute(
          'UPDATE clientes SET cobrador_id = ?, updated_at = ?, ocurrido_en = ? '
          'WHERE id = ?',
          [seleccion.id, now, ocurridoEn, id],
        );
        if (tenantId != null) {
          await OpLog.escribirCambioEntidad(
            tx,
            tenantId: tenantId,
            opId: opId,
            entidad: 'clientes',
            entidadId: id,
            antes: {'cobrador_id': c['cobrador_id']},
            despues: {'cobrador_id': seleccion.id},
            actor: actor,
            ocurridoEn: ocurrido,
          );
        }
      }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$n cliente(s) reasignados a $destino')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dbEpochProvider, (_, __) => setState(_rebuild));
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cobradores,
      initialData: const [],
      builder: (context, cobSnap) {
        final cobMap = <String, String>{};
        final inactivos = <String>{};
        for (final r in cobSnap.data!) {
          final id = r['id'] as String;
          cobMap[id] = r['nombre'] as String;
          if ((r['activo'] as int? ?? 1) == 0) inactivos.add(id);
        }
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: _comunidades,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text(mensajeErrorHumano(snap.error!)));
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.route_outlined,
                titulo: 'Sin rutas',
                descripcion: 'No hay comunidades con clientes activos.',
              );
            }
            // Municipios distintos presentes (para el chip), derivados de la
            // MISMA lista del stream — sin suscripción extra (regla audit #2).
            final municipios = <String>{
              for (final r in rows) (r['municipio'] as String?) ?? '—',
            }.toList()
              ..sort();
            // Filtro client-side: por municipio (chip), por cobrador (chip:
            // la comunidad matchea si el cobrador elegido tiene ≥1 cliente
            // activo ahí — las "Mixto" aparecen si participa; "Sin asignar"
            // matchea las que tienen clientes sin cobrador) y por texto.
            // En memoria sobre lo ya cargado → 100% offline.
            final filtradas = rows.where((r) {
              final muni = (r['municipio'] as String?) ?? '—';
              if (_municipioIds != null && !_municipioIds!.contains(muni)) {
                return false;
              }
              if (_cobradorIds != null) {
                final csv = (r['cobradores_csv'] as String?) ?? '';
                final presentes =
                    csv.isEmpty ? const <String>[] : csv.split(',');
                final tieneSin = ((r['sin_cobrador'] as int?) ?? 0) > 0;
                final match = _cobradorIds!.any((id) =>
                    id == _sinAsignarId ? tieneSin : presentes.contains(id));
                if (!match) return false;
              }
              if (_busqueda.isEmpty) return true;
              // Tokens sobre comunidad + municipio (encontrar "Peñas Blancas"
              // tipeando "penas", o "jinotega penas" en cualquier orden).
              return coincideTokens(
                  '${r['comunidad'] as String? ?? ''} $muni', _busqueda);
            }).toList();
            return Column(
              children: [
                Container(
                  width: double.infinity,
                  color: scheme.surfaceContainerHighest,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text(
                    'Reasignar una ruta cambia el cobrador de TODOS los clientes '
                    'activos de esa comunidad. Los casos especiales se ajustan '
                    'después desde Clientes.',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
                _buildFiltros(municipios, cobMap, inactivos),
                _buildBuscador(),
                if (filtradas.isEmpty)
                  const Expanded(
                    child: EmptyState(
                      icon: Icons.search_off,
                      titulo: 'Sin resultados',
                      descripcion: 'Ninguna comunidad coincide con el filtro.',
                    ),
                  )
                else
                  Expanded(
                    child:
                        _listaComunidades(filtradas, cobMap, inactivos, scheme),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
