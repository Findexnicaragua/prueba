import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import '../../../data/utils/errores.dart';

/// CRUD de planes del tenant. Sin planes no se pueden crear contratos.
///
/// **ConsumerStatefulWidget** para cachear el stream de PowerSync en
/// `late final _planesStream` inicializado en `initState`. Sin este cache,
/// cada `build()` re-ejecuta `ps.db.watch(...)` creando un nuevo stream
/// subscription → flicker + waste.
class PlanesAdminScreen extends ConsumerStatefulWidget {
  const PlanesAdminScreen({super.key});

  @override
  ConsumerState<PlanesAdminScreen> createState() => _PlanesAdminScreenState();
}

class _PlanesAdminScreenState extends ConsumerState<PlanesAdminScreen> {
  late final Stream<List<Map<String, dynamic>>> _planesStream;

  @override
  void initState() {
    super.initState();
    _planesStream = ps.db.watch(
      '''
      SELECT p.*,
             (SELECT COUNT(*) FROM contratos
               WHERE plan_id = p.id AND estado = 'activo') AS contratos_activos
        FROM planes p
       ORDER BY p.activo DESC, p.precio_mensual
      ''',
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
                  'Planes del tenant. Cada plan se asigna al crear un contrato.',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
              const SizedBox(width: 12),
              if (!ref.watch(soloLecturaProvider))
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Nuevo plan'),
                  onPressed: () => _abrirForm(context, null),
                ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _planesStream,
            initialData: const [],
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text(mensajeErrorHumano(snap.error!)));
              }
              final rows = snap.data!;
              if (rows.isEmpty) {
                return EmptyState(
                  icon: Icons.wifi,
                  titulo: 'No hay planes',
                  descripcion:
                      'Tenés que crear al menos un plan para poder asignar contratos.',
                  accion: FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Crear primer plan'),
                    onPressed: () => _abrirForm(context, null),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _PlanCard(
                  row: rows[i],
                  onEdit: ref.watch(soloLecturaProvider)
                      ? null
                      : () => _abrirForm(context, rows[i]),
                  onHistory: () =>
                      _showHistorial(context, rows[i]['id'] as String),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _abrirForm(
    BuildContext context,
    Map<String, dynamic>? row,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _PlanFormDialog(plan: row),
    );
  }

  void _showHistorial(BuildContext context, String planId) {
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
                  Text('Historial del plan',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                child: HistorialOpLog(
                  entidad: 'planes',
                  entidadId: planId,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.row,
    required this.onEdit,
    required this.onHistory,
  });
  final Map<String, dynamic> row;
  /// null = el rol no puede editar (solo lectura) → no se dibuja el botón.
  final VoidCallback? onEdit;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activo = (row['activo'] as int? ?? 1) == 1;
    final tipo = row['tipo'] as String;
    final contratos = row['contratos_activos'] as int? ?? 0;

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: activo
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Icon(_icon(tipo),
              color: activo ? scheme.primary : scheme.outline),
        ),
        title: Text(row['nombre'] as String,
            style: TextStyle(
              decoration: activo ? null : TextDecoration.lineThrough,
            )),
        subtitle: Text(
          '$tipo · $contratos contrato(s) activo(s)',
          style: TextStyle(color: scheme.outline, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              Fmt.cordobas(row['precio_mensual'] as num),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (onEdit != null)
              IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Editar plan',
                  onPressed: onEdit),
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Historial del plan',
              onPressed: onHistory,
            ),
          ],
        ),
      ),
    );
  }

  IconData _icon(String tipo) => switch (tipo) {
        'internet' => Icons.wifi,
        'tv' => Icons.tv,
        'combo' => Icons.tv_outlined,
        _ => Icons.subscriptions,
      };
}

class _PlanFormDialog extends ConsumerStatefulWidget {
  const _PlanFormDialog({this.plan});
  final Map<String, dynamic>? plan;

  @override
  ConsumerState<_PlanFormDialog> createState() => _PlanFormDialogState();
}

class _PlanFormDialogState extends ConsumerState<_PlanFormDialog> {
  late TextEditingController _nombre;
  late TextEditingController _precio;
  late String _tipo;
  late bool _activo;
  bool _guardando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nombre = TextEditingController(text: widget.plan?['nombre'] as String? ?? '');
    _precio = TextEditingController(
      text: (widget.plan?['precio_mensual'] as num?)?.toString() ?? '',
    );
    _tipo = widget.plan?['tipo'] as String? ?? 'internet';
    _activo = (widget.plan?['activo'] as int? ?? 1) == 1;
  }

  @override
  void dispose() {
    _nombre.dispose();
    _precio.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (_nombre.text.trim().isEmpty) {
      setState(() => _error = 'Nombre requerido');
      return;
    }
    final precio = parseMonto(_precio.text); // acepta coma decimal (M8)
    if (precio == null || precio <= 0) {
      setState(() => _error = 'Precio inválido');
      return;
    }
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) {
      setState(() => _error = 'Sin tenant');
      return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });

    try {
      // op_log (rework change log): actor + id de intención para registrar el
      // alta/edición del plan (1 entrada, diff antes→después curado).
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final opId = OpLog.nuevoOpId();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();
      if (widget.plan == null) {
        final id = const Uuid().v4();
        await ps.dbW.writeTransaction((tx) async {
          await tx.execute(
            '''
            INSERT INTO planes (id, tenant_id, nombre, tipo, precio_mensual,
                                activo, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              id,
              tenantId,
              _nombre.text.trim(),
              _tipo,
              precio,
              _activo ? 1 : 0,
              DateTime.now().toIso8601String(),
            ],
          );
          final despues =
              (await tx.getAll('SELECT * FROM planes WHERE id = ?', [id])).first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'planes', entidadId: id,
              antes: const {}, despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurridoEn));
        });
      } else {
        final id = widget.plan!['id'] as String;
        await ps.dbW.writeTransaction((tx) async {
          final antesRows =
              await tx.getAll('SELECT * FROM planes WHERE id = ?', [id]);
          final antes = antesRows.isNotEmpty
              ? antesRows.first
              : const <String, dynamic>{};
          await tx.execute(
            '''
            UPDATE planes
               SET nombre = ?, tipo = ?, precio_mensual = ?, activo = ?
             WHERE id = ?
            ''',
            [
              _nombre.text.trim(),
              _tipo,
              precio,
              _activo ? 1 : 0,
              id,
            ],
          );
          final despues =
              (await tx.getAll('SELECT * FROM planes WHERE id = ?', [id])).first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'planes', entidadId: id,
              antes: antes, despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurridoEn));
        });
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _error = mensajeErrorHumano(e, contexto: 'guardar el plan'));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ancho responsive: 400 en desktop/tablet, 90% del viewport en mobile
    // chico (un 400 fijo desborda el AlertDialog en pantallas ~360px).
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;
    return AlertDialog(
      title: Text(widget.plan == null ? 'Nuevo plan' : 'Editar plan'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nombre,
              decoration: const InputDecoration(
                labelText: 'Nombre *',
                hintText: 'Ej. Internet 10MB',
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _tipo,
              decoration: const InputDecoration(labelText: 'Tipo'),
              items: const [
                DropdownMenuItem(value: 'internet', child: Text('Internet')),
                DropdownMenuItem(value: 'tv', child: Text('TV')),
                DropdownMenuItem(value: 'combo', child: Text('Combo')),
              ],
              onChanged: (v) => setState(() => _tipo = v ?? _tipo),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _precio,
              decoration: const InputDecoration(
                labelText: 'Precio mensual (C\$) *',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [montoInputFormatter],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _activo,
              onChanged: (v) => setState(() => _activo = v),
              title: Text(_activo ? 'Activo' : 'Inactivo'),
              subtitle: !_activo
                  ? const Text(
                      'No aparecerá al crear nuevos contratos',
                      style: TextStyle(fontSize: 12),
                    )
                  : null,
              contentPadding: EdgeInsets.zero,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _guardar,
          child: Text(_guardando ? 'Guardando...' : 'Guardar'),
        ),
      ],
    );
  }
}
