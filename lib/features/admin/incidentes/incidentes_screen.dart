import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/selector_buscable.dart';
import '../../../data/utils/errores.dart';

/// Lista de incidentes (outages) del tenant. Filtro abiertos/resueltos, badge de
/// estado + alcance (nodo/hub/puerto/general), FAB → crear. Tap → detalle.
class IncidentesScreen extends ConsumerStatefulWidget {
  const IncidentesScreen({super.key});
  @override
  ConsumerState<IncidentesScreen> createState() => _IncidentesScreenState();
}

class _IncidentesScreenState extends ConsumerState<IncidentesScreen> {
  late Stream<List<Map<String, dynamic>>> _incidentes;
  String _filtro = 'abierto';

  @override
  void initState() {
    super.initState();
    _incidentes = _buildStream();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch('''
      SELECT i.id, i.titulo, i.estado, i.inicio, i.fin,
             i.nodo_id, i.hub_id, i.puerto_id, i.alcance_label,
             n.nombre AS nodo, h.nombre AS hub, p.nombre AS puerto
        FROM incidentes i
   LEFT JOIN red_nodos   n ON n.id = i.nodo_id
   LEFT JOIN red_hubs    h ON h.id = i.hub_id
   LEFT JOIN red_puertos p ON p.id = i.puerto_id
       WHERE i.estado = ?
       ORDER BY i.inicio DESC
       LIMIT 300
    ''', parameters: [_filtro]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: ref.watch(soloLecturaProvider)
          ? null
          : FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Incidente'),
        onPressed: _crear,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                for (final g in const ['abierto', 'resuelto'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(g == 'abierto' ? 'Abiertos' : 'Resueltos'),
                      selected: _filtro == g,
                      onSelected: (_) => setState(() {
                        _filtro = g;
                        _incidentes = _buildStream();
                      }),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _incidentes,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text(mensajeErrorHumano(snap.error!)));
                }
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return EmptyState(
                    icon: Icons.cell_tower_outlined,
                    titulo: _filtro == 'abierto'
                        ? 'Sin incidentes abiertos'
                        : 'Sin incidentes resueltos',
                    descripcion: _filtro == 'abierto'
                        ? 'Registrá un corte para agrupar los tickets afectados.'
                        : null,
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final abierto = r['estado'] == 'abierto';
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 6,
                        backgroundColor:
                            abierto ? scheme.error : Colors.green,
                      ),
                      title: Text(r['titulo'] as String? ?? '—',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${_alcanceLabel(r)} · ${Fmt.fechaCorta(DateTime.parse(r['inicio'] as String).toLocal())}',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(abierto ? 'Abierto' : 'Resuelto',
                          style: TextStyle(
                              color: abierto ? scheme.error : Colors.green,
                              fontSize: 12)),
                      // Regla #12: ruta del shell admin → go, no push (el
                      // detalle no tiene Scaffold propio; con push el AppBar
                      // mostraba 'Incidentes' en vez de 'Incidente').
                      onTap: () => context.go('/admin/incidentes/${r['id']}'),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _crear() async {
    // Alta atribuida al usuario (op_log) → bloqueada al impersonar; se crea desde
    // la cuenta real del ISP, no como System Admin (audit 2026-06-30).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final res = await showModalBottomSheet<_NuevoIncidente>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CrearIncidenteSheet(),
    );
    if (res == null) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) {
      // Feedback en vez de no-op silencioso (el sheet ya se cerró) — audit 2026-06-30.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo identificar el tenant. Reintentá.')));
      }
      return;
    }
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    // op_log: actor + id de intención para el alta del incidente.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final id = const Uuid().v4();
    try {
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          '''INSERT INTO incidentes
             (id, tenant_id, titulo, descripcion, nodo_id, hub_id, puerto_id,
              alcance_label, estado, inicio, created_at, ocurrido_en)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'abierto', ?, ?, ?)''',
          [
            id, tenantId, res.titulo, res.descripcion,
            res.nodoId, res.hubId, res.puertoId, res.alcanceLabel,
            ocurrido, now, ocurrido,
          ],
        );
        final despues =
            (await tx.getAll('SELECT * FROM incidentes WHERE id = ?', [id]))
                .first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId, opId: opId, entidad: 'incidentes',
            entidadId: id, antes: const {}, despues: despues, actor: actor,
            ocurridoEn: DateTime.parse(ocurrido));
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Incidente registrado')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }
}

/// Etiqueta del alcance: prefiere el nombre VIVO del FK (maneja renombres) y cae
/// al snapshot `alcance_label` cuando el FK quedó NULL (el nodo/hub/puerto se borró).
String _alcanceLabel(Map<String, dynamic> r) {
  if (r['puerto_id'] != null) return 'Puerto: ${r['puerto'] ?? '—'}';
  if (r['hub_id'] != null) return 'Hub: ${r['hub'] ?? '—'}';
  if (r['nodo_id'] != null) return 'Nodo: ${r['nodo'] ?? '—'}';
  final snap = r['alcance_label'] as String?;
  if (snap != null && snap.isNotEmpty) return snap;
  return 'Corte general';
}

/// Resultado del sheet de creación.
class _NuevoIncidente {
  const _NuevoIncidente({
    required this.titulo,
    this.descripcion,
    this.nodoId,
    this.hubId,
    this.puertoId,
    required this.alcanceLabel,
  });
  final String titulo;
  final String? descripcion;
  final String? nodoId;
  final String? hubId;
  final String? puertoId;
  final String alcanceLabel; // snapshot legible del alcance al crear
}

class _CrearIncidenteSheet extends ConsumerStatefulWidget {
  const _CrearIncidenteSheet();
  @override
  ConsumerState<_CrearIncidenteSheet> createState() =>
      _CrearIncidenteSheetState();
}

class _CrearIncidenteSheetState extends ConsumerState<_CrearIncidenteSheet> {
  final _titulo = TextEditingController();
  final _desc = TextEditingController();
  // Campos-selector (read-only) con buscador, en vez de DropdownButton.
  final _nodoCtrl = TextEditingController();
  final _hubCtrl = TextEditingController();
  final _puertoCtrl = TextEditingController();
  String _nivel = 'general'; // general | nodo | hub | puerto
  String? _nodoId;
  String? _hubId;
  String? _puertoId;

  @override
  void initState() {
    super.initState();
    _titulo.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _titulo.dispose();
    _desc.dispose();
    _nodoCtrl.dispose();
    _hubCtrl.dispose();
    _puertoCtrl.dispose();
    super.dispose();
  }

  bool get _scopeOk => switch (_nivel) {
        'nodo' => _nodoId != null,
        'hub' => _hubId != null,
        'puerto' => _puertoId != null,
        _ => true, // general
      };

  // Nombre del item elegido: lo guarda el controller del selector al elegir.
  String _nombreSel(TextEditingController ctrl) {
    final t = ctrl.text.trim();
    return t.isEmpty ? '—' : t;
  }

  void _confirmar() {
    final t = _titulo.text.trim();
    if (t.isEmpty || !_scopeOk) return;
    // Snapshot legible del alcance (sobrevive al borrado del nodo/hub/puerto).
    final label = switch (_nivel) {
      'puerto' => 'Puerto: ${_nombreSel(_puertoCtrl)}',
      'hub' => 'Hub: ${_nombreSel(_hubCtrl)}',
      'nodo' => 'Nodo: ${_nombreSel(_nodoCtrl)}',
      _ => 'Corte general',
    };
    Navigator.pop(
      context,
      _NuevoIncidente(
        titulo: t,
        descripcion: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        nodoId: _nivel == 'nodo' ? _nodoId : null,
        hubId: _nivel == 'hub' ? _hubId : null,
        puertoId: _nivel == 'puerto' ? _puertoId : null,
        alcanceLabel: label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 0, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Nuevo incidente',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              TextField(
                controller: _titulo,
                decoration: const InputDecoration(
                    labelText: 'Título', isDense: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _desc,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: 'Descripción (opcional)', isDense: true),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _nivel,
                decoration: const InputDecoration(
                    labelText: 'Alcance del corte', isDense: true),
                items: const [
                  DropdownMenuItem(value: 'general', child: Text('Corte general')),
                  DropdownMenuItem(value: 'nodo', child: Text('Por nodo')),
                  DropdownMenuItem(value: 'hub', child: Text('Por hub')),
                  DropdownMenuItem(value: 'puerto', child: Text('Por puerto')),
                ],
                onChanged: (v) => setState(() {
                  _nivel = v ?? 'general';
                  _nodoId = _hubId = _puertoId = null;
                  _nodoCtrl.clear();
                  _hubCtrl.clear();
                  _puertoCtrl.clear();
                }),
              ),
              if (_nivel != 'general') ...[
                const SizedBox(height: 8),
                _nodoDropdown(),
              ],
              if (_nivel == 'hub' || _nivel == 'puerto') ...[
                const SizedBox(height: 8),
                _hubDropdown(),
              ],
              if (_nivel == 'puerto') ...[
                const SizedBox(height: 8),
                _puertoDropdown(),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Registrar'),
                onPressed: (_titulo.text.trim().isNotEmpty && _scopeOk)
                    ? _confirmar
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nodoDropdown() => TextField(
        controller: _nodoCtrl,
        readOnly: true,
        decoration: const InputDecoration(
          labelText: 'Nodo',
          isDense: true,
          hintText: 'Tocá para elegir',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        onTap: _elegirNodo,
      );

  Widget _hubDropdown() => TextField(
        controller: _hubCtrl,
        readOnly: true,
        decoration: const InputDecoration(
          labelText: 'Hub',
          isDense: true,
          hintText: 'Tocá para elegir',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        onTap: _elegirHub,
      );

  Widget _puertoDropdown() => TextField(
        controller: _puertoCtrl,
        readOnly: true,
        decoration: const InputDecoration(
          labelText: 'Puerto',
          isDense: true,
          hintText: 'Tocá para elegir',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        onTap: _elegirPuerto,
      );

  // Selector de nodo (con buscador). Al elegir, resetea hub/puerto encadenados
  // y, si el nivel lo necesita, recarga los hubs del nodo elegido.
  Future<void> _elegirNodo() async {
    final tenantId = ref.read(tenantIdProvider);
    final rows = await ps.db.getAll(
        'SELECT id, nombre FROM red_nodos WHERE tenant_id = ? ORDER BY nombre',
        [tenantId]);
    if (!mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay nodos en la red.')));
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí el nodo',
      hint: 'Buscar nodo...',
      opciones: [
        for (final r in rows)
          OpcionSelector(valor: r, nombre: r['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _nodoId = elegido['id'] as String;
      _nodoCtrl.text = elegido['nombre'] as String;
      _hubId = _puertoId = null;
      _hubCtrl.clear();
      _puertoCtrl.clear();
    });
  }

  // Selector de hub (con buscador). Depende del nodo elegido; al elegir resetea
  // el puerto encadenado y recarga los puertos si el nivel es 'puerto'.
  Future<void> _elegirHub() async {
    final nodoId = _nodoId;
    if (nodoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Elegí un nodo primero.')));
      return;
    }
    final rows = await ps.db.getAll(
        'SELECT id, nombre FROM red_hubs WHERE nodo_id = ? ORDER BY nombre',
        [nodoId]);
    if (!mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ese nodo no tiene hubs.')));
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí el hub',
      hint: 'Buscar hub...',
      opciones: [
        for (final r in rows)
          OpcionSelector(valor: r, nombre: r['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _hubId = elegido['id'] as String;
      _hubCtrl.text = elegido['nombre'] as String;
      _puertoId = null;
      _puertoCtrl.clear();
    });
  }

  // Selector de puerto (con buscador). Depende del hub elegido.
  Future<void> _elegirPuerto() async {
    final hubId = _hubId;
    if (hubId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Elegí un hub primero.')));
      return;
    }
    final rows = await ps.db.getAll(
        'SELECT id, nombre FROM red_puertos WHERE hub_id = ? ORDER BY nombre',
        [hubId]);
    if (!mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ese hub no tiene puertos.')));
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí el puerto',
      hint: 'Buscar puerto...',
      opciones: [
        for (final r in rows)
          OpcionSelector(valor: r, nombre: r['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _puertoId = elegido['id'] as String;
      _puertoCtrl.text = elegido['nombre'] as String;
    });
  }
}
