import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/etiquetas_repo.dart';
import '../../../data/utils/cuota_estado_visual.dart'
    show kPaletaColoresEstados, hexFromColor, colorFromHex;
import '../../../data/utils/errores.dart';
import '../../../data/utils/icono_helpers.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/etiqueta_chip.dart';
import '../../shared/widgets/historial_op_log.dart';

/// CRUD del catálogo de etiquetas de clientes (P5). Catálogo per-tenant
/// (nombre + color + icono). Las asigna a clientes el admin/admin_cobranza
/// desde el detalle del cliente; acá solo se DEFINE el catálogo.
class EtiquetasAdminScreen extends ConsumerStatefulWidget {
  const EtiquetasAdminScreen({super.key});
  @override
  ConsumerState<EtiquetasAdminScreen> createState() =>
      _EtiquetasAdminScreenState();
}

class _EtiquetasAdminScreenState extends ConsumerState<EtiquetasAdminScreen> {
  late final Stream<List<Map<String, dynamic>>> _etiquetas;

  @override
  void initState() {
    super.initState();
    _etiquetas = ps.db.watch(
      'SELECT e.*, '
      '(SELECT COUNT(*) FROM cliente_etiquetas ce WHERE ce.etiqueta_id = e.id) AS usos '
      'FROM etiquetas e ORDER BY e.orden, e.nombre',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Botón "Etiqueta" arriba (consistente con Geografía / Red / Planes).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Etiquetas para marcar clientes (VIP, moroso histórico, zona '
                    'difícil…). Se ven en la lista, en cobros y en el mapa. Las '
                    'asignás desde el detalle de cada cliente.',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.outline),
                  ),
                ),
                const SizedBox(width: 12),
                if (!ref.watch(soloLecturaProvider))
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Etiqueta'),
                    onPressed: () => _crear(context),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildLista(context)),
        ],
      ),
    );
  }

  Widget _buildLista(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _etiquetas,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(mensajeErrorHumano(snap.error!)));
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return EmptyState(
            icon: Icons.label_outline,
            titulo: 'Sin etiquetas',
            descripcion: 'Creá la primera para empezar a marcar clientes.',
            accion: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Nueva etiqueta'),
              onPressed: () => _crear(context),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final e = rows[i];
            final color = colorFromHex(e['color'] as String? ?? '') ??
                scheme.outline;
            final usos = (e['usos'] as int?) ?? 0;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(iconoEtiqueta(e['icono'] as String?), color: color),
              ),
              title: Text(e['nombre'] as String? ?? ''),
              subtitle: Text(usos == 0
                  ? 'Sin clientes'
                  : '$usos cliente${usos == 1 ? '' : 's'}'),
              trailing: PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'editar') {
                    _crear(context, existente: e);
                  } else if (v == 'eliminar') {
                    _eliminar(context, e, usos);
                  } else {
                    _showHistorial(context, e['id'] as String);
                  }
                },
                itemBuilder: (_) => [
                  if (!ref.watch(soloLecturaProvider))
                    const PopupMenuItem(value: 'editar', child: Text('Editar')),
                  const PopupMenuItem(
                      value: 'historial', child: Text('Historial')),
                  if (!ref.watch(soloLecturaProvider))
                    const PopupMenuItem(
                        value: 'eliminar', child: Text('Eliminar')),
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
    final res = await showDialog<({String nombre, String colorHex, String iconoKey})>(
      context: context,
      builder: (_) => _EtiquetaDialog(existente: existente),
    );
    if (res == null) return;
    final repo = ref.read(etiquetasRepoProvider);
    final me = ref.read(cobradorActualProvider).valueOrNull;
    try {
      if (existente == null) {
        await repo.crear(
          tenantId: tenantId,
          nombre: res.nombre,
          colorHex: res.colorHex,
          iconoKey: res.iconoKey,
          usuarioId: me?.id ?? '',
        );
      } else {
        await repo.actualizar(
          id: existente['id'] as String,
          nombre: res.nombre,
          colorHex: res.colorHex,
          iconoKey: res.iconoKey,
          usuarioId: me?.id ?? '',
        );
      }
    } catch (e) {
      if (context.mounted) _snack(context, mensajeErrorHumano(e));
    }
  }

  Future<void> _eliminar(
      BuildContext context, Map<String, dynamic> e, int usos) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar etiqueta'),
        content: Text(usos == 0
            ? '¿Eliminar la etiqueta "${e['nombre']}"?'
            : '¿Eliminar la etiqueta "${e['nombre']}"? Se quitará de $usos '
                'cliente${usos == 1 ? '' : 's'} (no borra los clientes).'),
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
    try {
      await ref.read(etiquetasRepoProvider).eliminar(e['id'] as String,
          usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id ?? '');
    } catch (err) {
      if (context.mounted) _snack(context, mensajeErrorHumano(err));
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
                child: Text('Historial de la etiqueta',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              HistorialOpLog(entidad: 'etiquetas', entidadId: id),
            ],
          ),
        ),
      ),
    );
  }
}

/// Diálogo de alta/edición: nombre + color (swatches) + icono (grid) + preview.
class _EtiquetaDialog extends StatefulWidget {
  const _EtiquetaDialog({this.existente});
  final Map<String, dynamic>? existente;
  @override
  State<_EtiquetaDialog> createState() => _EtiquetaDialogState();
}

class _EtiquetaDialogState extends State<_EtiquetaDialog> {
  late final TextEditingController _nombre;
  late String _colorHex;
  late String _iconoKey;

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _nombre = TextEditingController(text: e?['nombre'] as String? ?? '');
    _colorHex = e?['color'] as String? ?? hexFromColor(kPaletaColoresEstados.first);
    _iconoKey = e?['icono'] as String? ?? kIconosEtiquetaKeys.first;
  }

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nombrePreview = _nombre.text.trim().isEmpty
        ? 'Etiqueta'
        : _nombre.text.trim();
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nueva etiqueta' : 'Editar etiqueta'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              maxLength: 24,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nombre'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            // Preview en vivo.
            Align(
              alignment: Alignment.centerLeft,
              child: EtiquetaChip(
                nombre: nombrePreview,
                colorHex: _colorHex,
                iconoKey: _iconoKey,
              ),
            ),
            const SizedBox(height: 16),
            Text('Color', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in kPaletaColoresEstados)
                  _ColorSwatch(
                    color: c,
                    selected: _sameHex(hexFromColor(c), _colorHex),
                    onTap: () => setState(() => _colorHex = hexFromColor(c)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Icono', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final key in kIconosEtiquetaKeys)
                  _IconChoice(
                    icono: iconoEtiqueta(key),
                    color: colorFromHex(_colorHex) ?? scheme.primary,
                    selected: key == _iconoKey,
                    onTap: () => setState(() => _iconoKey = key),
                  ),
              ],
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
            Navigator.pop(context,
                (nombre: n, colorHex: _colorHex, iconoKey: _iconoKey));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }

  bool _sameHex(String a, String b) => a.toUpperCase() == b.toUpperCase();
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch(
      {required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : Colors.transparent,
            width: 3,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 18)
            : null,
      ),
    );
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.icono,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final IconData icono;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Icon(icono, color: selected ? color : scheme.onSurfaceVariant, size: 20),
      ),
    );
  }
}

void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
