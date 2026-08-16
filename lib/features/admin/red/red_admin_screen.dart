import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import '../../shared/widgets/mapa_picker_screen.dart';
import '../../../data/utils/errores.dart';

/// Datos capturados por `_NodoDialog` (crear/editar nodo).
typedef _NodoData = ({
  String nombre,
  String? tipo,
  String? notas,
  double? lat,
  double? lng,
});

/// CRUD de la topología de red (Nodo → Hub → Puerto). Parte del módulo de
/// cobranza base (no es módulo opcional). Mismo patrón de ExpansionTile
/// anidado que la pantalla de geografía: tocar un nodo revela sus hubs, tocar
/// un hub revela sus puertos. Cada nivel se crea inline. Per-tenant (0098).
class RedAdminScreen extends ConsumerStatefulWidget {
  const RedAdminScreen({super.key});

  @override
  ConsumerState<RedAdminScreen> createState() => _RedAdminScreenState();
}

class _RedAdminScreenState extends ConsumerState<RedAdminScreen> {
  late final Stream<List<Map<String, dynamic>>> _nodos;

  @override
  void initState() {
    super.initState();
    // Filtro explícito por tenant (F1): la SQLite del super_admin puede tener
    // red de System + del tenant impersonado; sin el WHERE el SELECT daría la
    // UNIÓN. Mismo guard que modulosHabilitadosProvider.
    final tenantId = ref.read(tenantIdProvider);
    _nodos = ps.db.watch(
      'SELECT * FROM red_nodos WHERE tenant_id = ? ORDER BY nombre',
      parameters: [tenantId],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Topología de red (Nodo → Hub → Puerto). Asigná un puerto a '
                  'cada cliente para ubicarlo en la red.',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
              const SizedBox(width: 12),
              if (!ref.watch(soloLecturaProvider))
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Nodo'),
                  onPressed: () => _crearNodo(context),
                ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _nodos,
            initialData: const [],
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text(mensajeErrorHumano(snap.error!)));
              }
              final nodos = snap.data!;
              if (nodos.isEmpty) {
                return EmptyState(
                  icon: Icons.hub_outlined,
                  titulo: 'Sin nodos',
                  accion: FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar primero'),
                    onPressed: () => _crearNodo(context),
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: nodos
                    .map((n) => _NodoTile(
                          key: ValueKey(n['id']?.toString() ?? ''),
                          nodo: n,
                        ))
                    .toList(),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _crearNodo(BuildContext context) async {
    final res = await showDialog<_NodoData?>(
      context: context,
      builder: (_) => const _NodoDialog(),
    );
    if (res == null) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return; // sin tenant resuelto no se puede crear
    // op_log (rework change log): actor + id de intención para el alta del nodo.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    try {
      final id = const Uuid().v4();
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'INSERT INTO red_nodos (id, tenant_id, nombre, tipo, notas, lat, lng, activo, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)',
          [id, tenantId, res.nombre, res.tipo, res.notas, res.lat, res.lng, DateTime.now().toIso8601String()],
        );
        final despues =
            (await tx.getAll('SELECT * FROM red_nodos WHERE id = ?', [id])).first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId, opId: opId, entidad: 'red_nodos', entidadId: id,
            antes: const {}, despues: despues, actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn));
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }
}

class _NodoTile extends ConsumerStatefulWidget {
  const _NodoTile({super.key, required this.nodo});
  final Map<String, dynamic> nodo;

  @override
  ConsumerState<_NodoTile> createState() => _NodoTileState();
}

class _NodoTileState extends ConsumerState<_NodoTile> {
  late Stream<List<Map<String, dynamic>>> _hubs;

  @override
  void initState() {
    super.initState();
    _hubs = _watch(widget.nodo['id'] as String);
  }

  @override
  void didUpdateWidget(_NodoTile old) {
    super.didUpdateWidget(old);
    if (old.nodo['id'] != widget.nodo['id']) {
      _hubs = _watch(widget.nodo['id'] as String);
    }
  }

  Stream<List<Map<String, dynamic>>> _watch(String nodoId) => ps.db.watch(
        'SELECT * FROM red_hubs WHERE nodo_id = ? ORDER BY nombre',
        parameters: [nodoId],
      );

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
      leading: const Icon(Icons.hub),
      title: Text(widget.nodo['nombre'] as String),
      trailing: _RedRowMenu(
        onEditar: () => _editarNodo(context),
        onHistorial: () => _showHistorialRed(context, 'red_nodos',
            widget.nodo['id'] as String, 'Historial del nodo'),
        onEliminar: () => _eliminarNodo(context),
      ),
      childrenPadding: const EdgeInsets.only(left: 16),
      maintainState: true,
      children: [
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _hubs,
          initialData: const [],
          builder: (context, snap) {
            final hubs = snap.data!;
            return Column(
              children: [
                ...hubs.map((h) => _HubTile(
                      key: ValueKey(h['id']?.toString() ?? ''),
                      hub: h,
                    )),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add, size: 18),
                  title: const Text('Agregar hub'),
                  onTap: () => _crearHub(context, widget.nodo['id'] as String),
                ),
              ],
            );
          },
        ),
      ],
      ),
    );
  }

  Future<void> _editarNodo(BuildContext context) async {
    final res = await showDialog<_NodoData?>(
      context: context,
      builder: (_) => _NodoDialog(inicial: widget.nodo),
    );
    if (res == null) return;
    final id = widget.nodo['id'] as String;
    final tenantId = widget.nodo['tenant_id'] as String?;
    // op_log: actor + id de intención para la edición del nodo.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.dbW.writeTransaction((tx) async {
        final antesRows =
            await tx.getAll('SELECT * FROM red_nodos WHERE id = ?', [id]);
        final antes =
            antesRows.isNotEmpty ? antesRows.first : const <String, dynamic>{};
        await tx.execute(
          'UPDATE red_nodos SET nombre = ?, tipo = ?, notas = ?, lat = ?, lng = ? WHERE id = ?',
          [res.nombre, res.tipo, res.notas, res.lat, res.lng, id],
        );
        final despues =
            (await tx.getAll('SELECT * FROM red_nodos WHERE id = ?', [id])).first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId ?? '', opId: opId, entidad: 'red_nodos',
            entidadId: id, antes: antes, despues: despues, actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn));
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }

  Future<void> _eliminarNodo(BuildContext context) async {
    if (!await _confirmarRed(context, 'el nodo')) return;
    final err = await _borrarRedSiLibre(
      tabla: 'red_nodos',
      id: widget.nodo['id'] as String,
      tablaUso: 'red_hubs',
      fkColumna: 'nodo_id',
      actor: await _actorRed(ref),
    );
    if (context.mounted && err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _crearHub(BuildContext context, String nodoId) async {
    final res = await promptNombreNotasRed(context, 'Nuevo hub');
    if (res == null) return;
    // El hub hereda el tenant del nodo padre (siempre synced). Guard defensivo.
    final tenantId = widget.nodo['tenant_id'] as String?;
    if (tenantId == null) return;
    // op_log: actor + id de intención para el alta del hub.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    try {
      final id = const Uuid().v4();
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'INSERT INTO red_hubs (id, tenant_id, nodo_id, nombre, notas, activo, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)',
          [id, tenantId, nodoId, res.nombre, res.notas, DateTime.now().toIso8601String()],
        );
        final despues =
            (await tx.getAll('SELECT * FROM red_hubs WHERE id = ?', [id])).first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId, opId: opId, entidad: 'red_hubs', entidadId: id,
            antes: const {}, despues: despues, actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn));
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }
}

class _HubTile extends ConsumerStatefulWidget {
  const _HubTile({super.key, required this.hub});
  final Map<String, dynamic> hub;

  @override
  ConsumerState<_HubTile> createState() => _HubTileState();
}

class _HubTileState extends ConsumerState<_HubTile> {
  late Stream<List<Map<String, dynamic>>> _puertos;

  @override
  void initState() {
    super.initState();
    _puertos = _watch(widget.hub['id'] as String);
  }

  @override
  void didUpdateWidget(_HubTile old) {
    super.didUpdateWidget(old);
    if (old.hub['id'] != widget.hub['id']) {
      _puertos = _watch(widget.hub['id'] as String);
    }
  }

  Stream<List<Map<String, dynamic>>> _watch(String hubId) => ps.db.watch(
        'SELECT * FROM red_puertos WHERE hub_id = ? ORDER BY nombre',
        parameters: [hubId],
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: ExpansionTile(
        leading: const Icon(Icons.router),
        title: Text(widget.hub['nombre'] as String),
        trailing: _RedRowMenu(
          onEditar: () => _editarHub(context),
          onHistorial: () => _showHistorialRed(context, 'red_hubs',
              widget.hub['id'] as String, 'Historial del hub'),
          onEliminar: () => _eliminarHub(context),
        ),
        childrenPadding: const EdgeInsets.only(left: 16),
        maintainState: true,
        children: [
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _puertos,
            initialData: const [],
            builder: (context, snap) {
              final puertos = snap.data!;
              return Column(
                children: [
                  ...puertos.map((p) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.settings_input_hdmi, size: 18),
                        title: Text(p['nombre'] as String),
                        trailing: _RedRowMenu(
                          onEditar: () => _editarPuerto(context, p),
                          onHistorial: () => _showHistorialRed(
                              context,
                              'red_puertos',
                              p['id'] as String,
                              'Historial del puerto'),
                          onEliminar: () => _eliminarPuerto(context, p),
                        ),
                      )),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.add, size: 18),
                    title: const Text('Agregar puerto'),
                    onTap: () => _crearPuerto(context, widget.hub['id'] as String),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _editarHub(BuildContext context) async {
    final res = await promptNombreNotasRed(context, 'Editar hub',
        inicial: widget.hub);
    if (res == null) return;
    final id = widget.hub['id'] as String;
    final tenantId = widget.hub['tenant_id'] as String?;
    // op_log: actor + id de intención para la edición del hub.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.dbW.writeTransaction((tx) async {
        final antesRows =
            await tx.getAll('SELECT * FROM red_hubs WHERE id = ?', [id]);
        final antes =
            antesRows.isNotEmpty ? antesRows.first : const <String, dynamic>{};
        await tx.execute(
          'UPDATE red_hubs SET nombre = ?, notas = ? WHERE id = ?',
          [res.nombre, res.notas, id],
        );
        final despues =
            (await tx.getAll('SELECT * FROM red_hubs WHERE id = ?', [id])).first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId ?? '', opId: opId, entidad: 'red_hubs',
            entidadId: id, antes: antes, despues: despues, actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn));
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }

  Future<void> _editarPuerto(
      BuildContext context, Map<String, dynamic> puerto) async {
    final res = await promptNombreNotasRed(context, 'Editar puerto',
        inicial: puerto);
    if (res == null) return;
    final id = puerto['id'] as String;
    final tenantId = puerto['tenant_id'] as String?;
    // op_log: actor + id de intención para la edición del puerto.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.dbW.writeTransaction((tx) async {
        final antesRows =
            await tx.getAll('SELECT * FROM red_puertos WHERE id = ?', [id]);
        final antes =
            antesRows.isNotEmpty ? antesRows.first : const <String, dynamic>{};
        await tx.execute(
          'UPDATE red_puertos SET nombre = ?, notas = ? WHERE id = ?',
          [res.nombre, res.notas, id],
        );
        final despues = (await tx
                .getAll('SELECT * FROM red_puertos WHERE id = ?', [id]))
            .first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId ?? '', opId: opId, entidad: 'red_puertos',
            entidadId: id, antes: antes, despues: despues, actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn));
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }

  Future<void> _eliminarHub(BuildContext context) async {
    if (!await _confirmarRed(context, 'el hub')) return;
    final err = await _borrarRedSiLibre(
      tabla: 'red_hubs',
      id: widget.hub['id'] as String,
      tablaUso: 'red_puertos',
      fkColumna: 'hub_id',
      actor: await _actorRed(ref),
    );
    if (context.mounted && err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _eliminarPuerto(
      BuildContext context, Map<String, dynamic> p) async {
    if (!await _confirmarRed(context, 'el puerto')) return;
    // FK clientes.puerto_id es ON DELETE SET NULL → no bloquea; por eso
    // verificamos a mano que no haya clientes asignados antes de borrar.
    final err = await _borrarRedSiLibre(
      tabla: 'red_puertos',
      id: p['id'] as String,
      tablaUso: 'clientes',
      fkColumna: 'puerto_id',
      actor: await _actorRed(ref),
      soloActivos: true, // solo un cliente ACTIVO ocupa la boca
    );
    if (context.mounted && err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _crearPuerto(BuildContext context, String hubId) async {
    final res = await promptNombreNotasRed(context, 'Nuevo puerto');
    if (res == null) return;
    // El puerto hereda el tenant del hub padre (siempre synced). Guard defensivo.
    final tenantId = widget.hub['tenant_id'] as String?;
    if (tenantId == null) return;
    // op_log: actor + id de intención para el alta del puerto.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    try {
      final id = const Uuid().v4();
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'INSERT INTO red_puertos (id, tenant_id, hub_id, nombre, notas, activo, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)',
          [id, tenantId, hubId, res.nombre, res.notas, DateTime.now().toIso8601String()],
        );
        final despues =
            (await tx.getAll('SELECT * FROM red_puertos WHERE id = ?', [id]))
                .first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId, opId: opId, entidad: 'red_puertos',
            entidadId: id, antes: const {}, despues: despues, actor: actor,
            ocurridoEn: DateTime.parse(ocurridoEn));
      });
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }
}

/// Menú de acciones por fila de red (Editar / Historial), reusado en los 3
/// niveles. Como `trailing` del ExpansionTile/ListTile.
class _RedRowMenu extends ConsumerWidget {
  const _RedRowMenu({
    required this.onEditar,
    required this.onHistorial,
    required this.onEliminar,
  });
  final VoidCallback onEditar;
  final VoidCallback onHistorial;
  final VoidCallback onEliminar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Solo lectura (0198): queda únicamente "Historial"; editar y eliminar no
    // se ofrecen. El `onSelected` igual no puede recibirlos si no están.
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

/// Resuelve el actor del op_log para la sesión actual (usuario real o System
/// Admin para el super_admin). Lo computa el caller con `ref` antes de delegar
/// al helper libre `_borrarRedSiLibre` (que no tiene acceso a `ref`).
Future<OpLogActor> _actorRed(WidgetRef ref) async {
  final me = ref.read(cobradorActualProvider).valueOrNull;
  return me != null
      ? await OpLog.actorDeUsuario(ps.db, me.id)
      : const OpLogActor.systemAdmin();
}

/// Borra una fila de red solo si NO está en uso (tiene hijas o clientes
/// asignados). Devuelve mensaje de error o null si borró OK. Emite la baja en
/// op_log (snapshot de la fila ANTES de borrar) dentro de la transacción.
Future<String?> _borrarRedSiLibre({
  required String tabla,
  required String id,
  required String tablaUso,
  required String fkColumna,
  required OpLogActor actor,
  // Puertos: "ocupado" = cliente ACTIVO (audit 2026-07-05). Sin esto el guard
  // contaba inactivos → un puerto con solo clientes de baja figuraba libre en
  // el picker/form pero no se podía borrar. Coherente con "inactivo libera la
  // boca" (FK ON DELETE SET NULL). nodo/hub no tienen columna activo.
  bool soloActivos = false,
}) async {
  final usos = await ps.db.getAll(
    'SELECT COUNT(*) AS n FROM $tablaUso WHERE $fkColumna = ?'
    '${soloActivos ? ' AND activo = 1' : ''}',
    [id],
  );
  final n = (usos.first['n'] as int?) ?? 0;
  if (n > 0) return 'No se puede eliminar: está en uso ($n).';
  final opId = OpLog.nuevoOpId();
  final ocurridoEn = DateTime.now().toUtc().toIso8601String();
  await ps.dbW.writeTransaction((tx) async {
    final previaRows =
        await tx.getAll('SELECT * FROM $tabla WHERE id = ?', [id]);
    if (previaRows.isNotEmpty) {
      final previa = previaRows.first;
      await OpLog.escribirBaja(tx,
          tenantId: (previa['tenant_id'] as String?) ?? '', opId: opId,
          entidad: tabla, entidadId: id, snapshot: previa, actor: actor,
          ocurridoEn: DateTime.parse(ocurridoEn));
    }
    await tx.execute('DELETE FROM $tabla WHERE id = ?', [id]);
  });
  return null;
}

Future<bool> _confirmarRed(BuildContext context, String que) async {
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

/// Abre el historial de cambios (audit log) de una fila de red, mismo patrón
/// que planes/cliente. `tabla` ∈ red_nodos/red_hubs/red_puertos.
void _showHistorialRed(
    BuildContext context, String tabla, String id, String titulo) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollCtrl) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.history),
                const SizedBox(width: 8),
                Text(titulo, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollCtrl,
              child: HistorialOpLog(entidad: tabla, entidadId: id),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Diálogo para Hub/Puerto: nombre + notas (opcional). `inicial` (fila) para editar.
Future<({String nombre, String? notas})?> promptNombreNotasRed(
    BuildContext context, String titulo,
    {Map<String, dynamic>? inicial}) async {
  final nombreCtrl = TextEditingController(text: inicial?['nombre'] as String? ?? '');
  final notasCtrl = TextEditingController(text: inicial?['notas'] as String? ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(titulo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nombreCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: notasCtrl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Notas (opcional)',
                hintText: 'Ej. detrás de la pulpería de Doña Rosa'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
  final nombre = nombreCtrl.text.trim();
  final notas = notasCtrl.text.trim();
  nombreCtrl.dispose();
  notasCtrl.dispose();
  if (ok != true || nombre.isEmpty) return null;
  return (nombre: nombre, notas: notas.isEmpty ? null : notas);
}

/// Diálogo de Nodo: nombre + tipo (fibra/wireless/híbrido) + lat/lng (opcionales).
class _NodoDialog extends StatefulWidget {
  const _NodoDialog({this.inicial});

  /// Fila del nodo a editar (null = crear nuevo).
  final Map<String, dynamic>? inicial;

  @override
  State<_NodoDialog> createState() => _NodoDialogState();
}

class _NodoDialogState extends State<_NodoDialog> {
  final _nombre = TextEditingController();
  final _notas = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  String? _tipo;

  @override
  void initState() {
    super.initState();
    final n = widget.inicial;
    if (n != null) {
      _nombre.text = n['nombre'] as String? ?? '';
      _notas.text = n['notas'] as String? ?? '';
      _lat.text = (n['lat'] as num?)?.toString() ?? '';
      _lng.text = (n['lng'] as num?)?.toString() ?? '';
      _tipo = n['tipo'] as String?;
    }
  }

  @override
  void dispose() {
    _nombre.dispose();
    _notas.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _elegirEnMapa() async {
    final inicial = (double.tryParse(_lat.text) != null &&
            double.tryParse(_lng.text) != null)
        ? LatLng(double.parse(_lat.text), double.parse(_lng.text))
        : const LatLng(12.13, -86.25); // Managua default
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => MapaPickerScreen(inicial: inicial)),
    );
    if (picked != null && mounted) {
      setState(() {
        _lat.text = picked.latitude.toStringAsFixed(6);
        _lng.text = picked.longitude.toStringAsFixed(6);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.inicial == null ? 'Nuevo nodo' : 'Editar nodo'),
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
            DropdownButtonFormField<String?>(
              initialValue: _tipo,
              decoration: const InputDecoration(labelText: 'Tipo (opcional)'),
              onChanged: (v) => setState(() => _tipo = v),
              items: const [
                DropdownMenuItem(value: null, child: Text('—')),
                DropdownMenuItem(value: 'fibra', child: Text('Fibra')),
                DropdownMenuItem(value: 'wireless', child: Text('Wireless')),
                DropdownMenuItem(value: 'hibrido', child: Text('Híbrido')),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notas,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Notas (opcional)',
                  hintText: 'Ej. torre detrás de la iglesia'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _lat,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Latitud'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lng,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Longitud'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.map),
                label: const Text('Elegir en el mapa'),
                onPressed: _elegirEnMapa,
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
        FilledButton(
          onPressed: () {
            final nombre = _nombre.text.trim();
            if (nombre.isEmpty) return;
            final notas = _notas.text.trim();
            Navigator.pop(context, (
              nombre: nombre,
              tipo: _tipo,
              notas: notas.isEmpty ? null : notas,
              // replaceAll(',', '.'): en Android es-NI el separador decimal por
              // defecto es la COMA y double.tryParse('12,13')=null → la coord se
              // guardaba NULL en silencio (audit 2026-06-30, criterio de parseMonto).
              lat: double.tryParse(_lat.text.trim().replaceAll(',', '.')),
              lng: double.tryParse(_lng.text.trim().replaceAll(',', '.')),
            ));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
