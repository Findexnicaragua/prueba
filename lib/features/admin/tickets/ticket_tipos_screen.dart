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
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';
import '../../../data/utils/op_log.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import '../../../data/utils/errores.dart';

/// CRUD de tipos de ticket (catálogo per-tenant con SLA por tipo). Solo admin.
class TicketTiposScreen extends ConsumerStatefulWidget {
  const TicketTiposScreen({super.key});
  @override
  ConsumerState<TicketTiposScreen> createState() => _TicketTiposScreenState();
}

class _TicketTiposScreenState extends ConsumerState<TicketTiposScreen> {
  late final Stream<List<Map<String, dynamic>>> _tipos;

  @override
  void initState() {
    super.initState();
    _tipos = ps.db.watch(
        'SELECT * FROM ticket_tipos WHERE activo = 1 ORDER BY orden, nombre');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: ref.watch(soloLecturaProvider)
          ? null
          : FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Tipo'),
        onPressed: () => _crear(context),
      ),
      body: Column(
        children: [
          _slaPrioridadHeader(context),
          const Divider(height: 1),
          _autoCierreHeader(context),
          const Divider(height: 1),
          Expanded(child: _buildLista(context, scheme)),
        ],
      ),
    );
  }

  /// Acceso al editor de SLA por prioridad (setting per-tenant). El resumen
  /// muestra las horas vigentes, de la más urgente a la más laxa.
  Widget _slaPrioridadHeader(BuildContext context) {
    final slaMap = ref.watch(appSettingsProvider).slaHorasPorPrioridad;
    final resumen = kTicketPrioridades.reversed
        .map((p) =>
            '${prioridadLabel(p)} ${slaMap[p] != null ? '${slaMap[p]}h' : '—'}')
        .join(' · ');
    return ListTile(
      leading: const Icon(Icons.timer_outlined),
      title: const Text('Tiempo de respuesta por prioridad'),
      subtitle: Text(resumen),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _editarSlaPrioridad(context),
    );
  }

  Future<void> _editarSlaPrioridad(BuildContext context) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final actual = ref.read(appSettingsProvider).slaHorasPorPrioridad;
    final res = await showDialog<Map<String, int>>(
      context: context,
      builder: (_) => _SlaPrioridadDialog(actual: actual),
    );
    if (res == null) return;
    try {
      await ref.read(settingsRepoProvider).upsert(
            tenantId,
            'tickets.sla_horas_por_prioridad',
            res,
            categoria: 'tickets',
            usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
          );
    } catch (e) {
      if (context.mounted) _snack(context, mensajeErrorHumano(e));
    }
  }

  /// Acceso al editor de auto-cierre (setting per-tenant, 0 = desactivado).
  Widget _autoCierreHeader(BuildContext context) {
    final dias = ref.watch(appSettingsProvider).autoCierreDias;
    return ListTile(
      leading: const Icon(Icons.task_alt),
      title: const Text('Auto-cierre de tickets resueltos'),
      subtitle: Text(dias > 0
          ? 'Se cierran solos tras $dias día${dias == 1 ? '' : 's'} sin reapertura'
          : 'Desactivado'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _editarAutoCierre(context),
    );
  }

  Future<void> _editarAutoCierre(BuildContext context) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final actual = ref.read(appSettingsProvider).autoCierreDias;
    final res = await showDialog<int>(
      context: context,
      builder: (_) => _AutoCierreDialog(actual: actual),
    );
    if (res == null) return;
    try {
      await ref.read(settingsRepoProvider).upsert(
            tenantId,
            'tickets.auto_cierre_dias',
            res,
            categoria: 'tickets',
            usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
          );
    } catch (e) {
      if (context.mounted) _snack(context, mensajeErrorHumano(e));
    }
  }

  Widget _buildLista(BuildContext context, ColorScheme scheme) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _tipos,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text(mensajeErrorHumano(snap.error!)));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return EmptyState(
            icon: Icons.label_outline,
            titulo: 'Sin tipos de ticket',
            descripcion: 'Definí los tipos (instalación, reparación…) con su SLA.',
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
            final t = rows[i];
            final sla = t['sla_horas'] as int?;
            final efecto = (t['efecto'] as String?) ?? 'ninguno';
            final efectoLabel =
                efecto != 'ninguno' ? ' · ${_kEfectos[efecto] ?? efecto}' : '';
            // El precio es lo que decide si el tipo cobra → visible en la lista
            // sin tener que abrir cada uno (audit UX 2026-06-30).
            final precio = (t['precio'] as num?)?.toDouble() ?? 0;
            final precioLabel = precio > 0 ? ' · Cobra ${Fmt.cordobas(precio)}' : '';
            return ListTile(
              leading: Icon(Icons.label_outline, color: scheme.outline),
              title: Text(t['nombre'] as String),
              subtitle: Text(
                  '${sla != null ? 'SLA: $sla h' : 'Sin SLA'}$efectoLabel$precioLabel'),
              trailing: PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'editar') {
                    _crear(context, existente: t);
                  } else if (v == 'eliminar') {
                    _eliminar(context, t);
                  } else {
                    _showHistorial(context, t['id'] as String);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'editar', child: Text('Editar')),
                  PopupMenuItem(value: 'historial', child: Text('Historial')),
                  PopupMenuItem(value: 'eliminar', child: Text('Eliminar')),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final res = await showDialog<
        ({
          String nombre,
          String? descripcion,
          int? sla,
          String efecto,
          double precio,
          List<String> checklist
        })>(
      context: context,
      builder: (_) => _TipoDialog(existente: existente),
    );
    if (res == null) return;
    final checklistJson = jsonEncode(res.checklist);
    // op_log: actor + id de intención para el alta/edición del tipo de ticket.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    try {
      if (existente == null) {
        final id = const Uuid().v4();
        await ps.dbW.writeTransaction((tx) async {
          await tx.execute(
            'INSERT INTO ticket_tipos (id, tenant_id, nombre, descripcion, sla_horas, efecto, precio, checklist_template, orden, activo, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?)',
            [id, tenantId, res.nombre, res.descripcion, res.sla, res.efecto,
              res.precio, checklistJson, DateTime.now().toIso8601String()],
          );
          final despues = (await tx
                  .getAll('SELECT * FROM ticket_tipos WHERE id = ?', [id]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'ticket_tipos',
              entidadId: id, antes: const {}, despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurrido));
        });
      } else {
        final id = existente['id'] as String;
        await ps.dbW.writeTransaction((tx) async {
          final antesRows =
              await tx.getAll('SELECT * FROM ticket_tipos WHERE id = ?', [id]);
          final antes =
              antesRows.isNotEmpty ? antesRows.first : const <String, dynamic>{};
          await tx.execute(
            'UPDATE ticket_tipos SET nombre = ?, descripcion = ?, sla_horas = ?, efecto = ?, precio = ?, checklist_template = ? WHERE id = ?',
            [res.nombre, res.descripcion, res.sla, res.efecto, res.precio, checklistJson, id],
          );
          final despues = (await tx
                  .getAll('SELECT * FROM ticket_tipos WHERE id = ?', [id]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'ticket_tipos',
              entidadId: id, antes: antes, despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurrido));
        });
      }
    } catch (e) {
      _snack(context, mensajeErrorHumano(e));
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> t) async {
    final id = t['id'] as String;
    // Guarda de "en uso": el FK tickets.tipo_id es ON DELETE RESTRICT.
    final usos = await ps.db.getAll(
        'SELECT COUNT(*) AS n FROM tickets WHERE tipo_id = ?', [id]);
    if (!context.mounted) return;
    final n = (usos.first['n'] as int?) ?? 0;
    if (n > 0) {
      _snack(context, 'No se puede eliminar: $n ticket(s) usan este tipo.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar'),
        content: Text('¿Eliminar el tipo "${t['nombre']}"?'),
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
    if (ok != true) return;
    // op_log: baja del tipo de ticket (snapshot antes de borrar para que su
    // historial siga apareciendo filtrando por entidad_id).
    final tenantId = t['tenant_id'] as String?;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.dbW.writeTransaction((tx) async {
        final prevRows =
            await tx.getAll('SELECT * FROM ticket_tipos WHERE id = ?', [id]);
        await tx.execute('DELETE FROM ticket_tipos WHERE id = ?', [id]);
        if (tenantId != null && prevRows.isNotEmpty) {
          await OpLog.escribirBaja(tx,
              tenantId: tenantId, opId: opId, entidad: 'ticket_tipos',
              entidadId: id, snapshot: prevRows.first, actor: actor,
              ocurridoEn: DateTime.parse(ocurrido));
        }
      });
    } catch (e) {
      _snack(context, mensajeErrorHumano(e));
    }
  }

  void _showHistorial(BuildContext context, String id) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, sc) => SingleChildScrollView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Historial del tipo',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              HistorialOpLog(entidad: 'ticket_tipos', entidadId: id),
            ],
          ),
        ),
      ),
    );
  }
}

/// Efecto en el servicio de un tipo de orden de trabajo (0172). Clasifica la
/// orden para derivar las colas de facturación (corte→suspender,
/// reconexión→reactivar, instalación→cobro inicial). 'ninguno' = trabajo sin
/// efecto en facturación (reparación, reclamo…).
const _kEfectos = <String, String>{
  'ninguno': 'Ninguno (reparación, reclamo…)',
  'instalacion': 'Instalación',
  'corte': 'Corte de servicio',
  'reconexion': 'Reconexión',
};

class _TipoDialog extends StatefulWidget {
  const _TipoDialog({this.existente});
  final Map<String, dynamic>? existente;
  @override
  State<_TipoDialog> createState() => _TipoDialogState();
}

class _TipoDialogState extends State<_TipoDialog> {
  late final TextEditingController _nombre;
  late final TextEditingController _descripcion;
  late final TextEditingController _sla;
  late final TextEditingController _precio;
  late String _efecto;
  // Pasos del checklist (un controller por paso). Editable: agregar/quitar.
  late final List<TextEditingController> _pasos;

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _nombre = TextEditingController(text: e?['nombre'] as String? ?? '');
    _descripcion =
        TextEditingController(text: e?['descripcion'] as String? ?? '');
    _sla = TextEditingController(
        text: (e?['sla_horas'] as int?)?.toString() ?? '');
    final p = (e?['precio'] as num?)?.toDouble() ?? 0;
    _precio = TextEditingController(
        text: p <= 0
            ? ''
            : (p == p.roundToDouble() ? p.toInt().toString() : p.toString()));
    _efecto = (e?['efecto'] as String?) ?? 'ninguno';
    // checklist_template: JSONB (texto en SQLite) = lista de strings.
    final raw = e?['checklist_template'];
    var pasos = const <String>[];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) pasos = decoded.whereType<String>().toList();
      } catch (_) {}
    }
    _pasos = [for (final p in pasos) TextEditingController(text: p)];
  }

  @override
  void dispose() {
    _nombre.dispose();
    _descripcion.dispose();
    _sla.dispose();
    _precio.dispose();
    for (final c in _pasos) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nuevo tipo' : 'Editar tipo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descripcion,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sla,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'SLA en horas (opcional)',
                hintText: 'Ej. 24',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _efecto,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Efecto en el servicio',
                helperText:
                    'Para las colas de corte / reconexión / instalación',
              ),
              onChanged: (v) => setState(() => _efecto = v ?? 'ninguno'),
              items: [
                for (final e in _kEfectos.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _precio,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [montoInputFormatter],
              decoration: const InputDecoration(
                labelText: 'Precio del cobro (C\$)',
                hintText: '0 = no se cobra',
                helperText:
                    'Si es > 0, el ticket resuelto ofrece "Generar cobro".',
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Checklist (pasos del trabajo)',
                  style: Theme.of(context).textTheme.labelLarge),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Pasos que el técnico tilda al resolver. Se copian al ticket al crearlo.',
                style: TextStyle(fontSize: 11),
              ),
            ),
            const SizedBox(height: 4),
            for (int i = 0; i < _pasos.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pasos[i],
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Paso ${i + 1}',
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                      onPressed: () =>
                          setState(() => _pasos.removeAt(i).dispose()),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Agregar paso'),
                onPressed: () =>
                    setState(() => _pasos.add(TextEditingController())),
              ),
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
            final slaTxt = _sla.text.trim();
            final sla = slaTxt.isEmpty ? null : int.tryParse(slaTxt);
            final desc = _descripcion.text.trim();
            final precio = parseMonto(_precio.text) ?? 0;
            final pasos = _pasos
                .map((c) => c.text.trim())
                .where((s) => s.isNotEmpty)
                .toList();
            Navigator.pop(context, (
              nombre: n,
              descripcion: desc.isEmpty ? null : desc,
              sla: sla,
              efecto: _efecto,
              precio: precio,
              checklist: pasos,
            ));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

/// Editor del SLA de respuesta por prioridad (horas). Devuelve el map con SÓLO
/// los niveles con valor > 0; un campo vacío/0 = esa prioridad no impone límite
/// (cae al SLA del tipo).
class _SlaPrioridadDialog extends StatefulWidget {
  const _SlaPrioridadDialog({required this.actual});
  final Map<String, int> actual;
  @override
  State<_SlaPrioridadDialog> createState() => _SlaPrioridadDialogState();
}

class _SlaPrioridadDialogState extends State<_SlaPrioridadDialog> {
  late final Map<String, TextEditingController> _ctrls;

  @override
  void initState() {
    super.initState();
    _ctrls = {
      for (final p in kTicketPrioridades)
        p: TextEditingController(text: widget.actual[p]?.toString() ?? ''),
    };
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tiempo de respuesta por prioridad'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Horas para responder según la prioridad del ticket. El SLA real '
              'usa el MENOR entre esto y el SLA del tipo. Dejá vacío para que esa '
              'prioridad no imponga límite. Aplica a TODOS los tickets con '
              'prioridad, incluidos los ya creados.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            // De la más urgente a la más laxa.
            ...kTicketPrioridades.reversed.map((p) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _ctrls[p],
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: prioridadLabel(p),
                      suffixText: 'horas',
                      isDense: true,
                    ),
                  ),
                )),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final map = <String, int>{};
            for (final p in kTicketPrioridades) {
              final v = int.tryParse(_ctrls[p]!.text.trim());
              if (v != null && v > 0) map[p] = v;
            }
            Navigator.pop(context, map);
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

/// Editor de auto-cierre (un solo campo: días). 0/vacío = desactivado.
class _AutoCierreDialog extends StatefulWidget {
  const _AutoCierreDialog({required this.actual});
  final int actual;
  @override
  State<_AutoCierreDialog> createState() => _AutoCierreDialogState();
}

class _AutoCierreDialogState extends State<_AutoCierreDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
        text: widget.actual > 0 ? widget.actual.toString() : '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Auto-cierre de tickets resueltos'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Un ticket RESUELTO que nadie reabra se cierra solo tras estos días. '
            'Dejá vacío o 0 para desactivar. Es reversible: un ticket cerrado se '
            'puede reabrir.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Días',
              suffixText: 'días',
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final v = int.tryParse(_ctrl.text.trim()) ?? 0;
            Navigator.pop(context, v < 0 ? 0 : v);
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
