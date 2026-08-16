import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/services/imagen_compresion.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/signature_pad.dart';
import '../../../data/utils/errores.dart';

const _maxAdjuntos = 10;
const _bucket = 'ticket-adjuntos';

/// Galería de adjuntos (fotos) de un ticket. Patrón de FotoGalleryWidget;
/// además registra un evento `adjunto` en la bitácora al subir. La foto requiere
/// conexión (Storage), así que es efectivamente online.
class TicketAdjuntosWidget extends ConsumerStatefulWidget {
  const TicketAdjuntosWidget({
    super.key,
    required this.ticketId,
    required this.tenantId,
    this.canEdit = true,
  });
  final String ticketId;
  final String tenantId;
  final bool canEdit;

  @override
  ConsumerState<TicketAdjuntosWidget> createState() =>
      _TicketAdjuntosWidgetState();
}

class _TicketAdjuntosWidgetState extends ConsumerState<TicketAdjuntosWidget> {
  /// `canEdit` del llamador Y el rol: el rol `lectura` (0198) nunca edita,
  /// sin depender de que cada llamador pase bien el flag.
  bool get _puedeEditar =>
      widget.canEdit && !ref.watch(soloLecturaProvider);
  late final Stream<List<Map<String, dynamic>>> _stream;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(
      'SELECT id, storage_path FROM ticket_adjuntos WHERE ticket_id = ? ORDER BY created_at ASC',
      parameters: [widget.ticketId],
    );
  }

  Future<void> _pickAndUpload() async {
    if (_uploading) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920, maxHeight: 1920, imageQuality: 80,
    );
    if (picked == null || !mounted) return;
    // Spinner visible DESDE acá: la compresión (0.5-3 s) con el botón activo
    // invita al doble tap → adjunto + evento de bitácora duplicados.
    setState(() => _uploading = true);
    try {
      final bytes = await picked.readAsBytes();
      // Compresión client-side (Windows ignora imageQuality/maxWidth del
      // picker; bucket de 5 MB).
      final comp = await comprimirImagen(bytes,
          maxLado: 1920, calidad: 85, maxBytes: 4800 * 1024);
      if (!mounted) return;
      await _subir(comp.bytes, comp.ext, comp.mime);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // Firma del cliente: pad propio → PNG → mismo upload que un adjunto, con
  // descripción "Firma del cliente". Requiere conexión (Storage), igual que fotos.
  Future<void> _capturarFirma() async {
    if (_uploading) return;
    final bytes = await SignaturePad.capturar(context);
    if (bytes == null || !mounted) return;
    await _subir(bytes, 'png', 'image/png', descripcion: 'Firma del cliente');
  }

  Future<void> _subir(Uint8List bytes, String ext, String mime,
      {String? descripcion}) async {
    // Alta de adjunto atribuida al usuario (op_log) → bloqueada al impersonar
    // (audit 2026-06-30).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    setState(() => _uploading = true);
    try {
      final path =
          '${widget.tenantId}/${widget.ticketId}/${DateTime.now().millisecondsSinceEpoch}.$ext';
      await Supabase.instance.client.storage
          .from(_bucket)
          .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));

      final me = ref.read(cobradorActualProvider).valueOrNull;
      final hechoPor = me?.id;
      final now = DateTime.now().toIso8601String();
      final ocurrido = DateTime.now().toUtc().toIso8601String();
      // op_log: el adjunto es hijo del ticket → entrada scopeada al ticket.
      final opId = OpLog.nuevoOpId();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'INSERT INTO ticket_adjuntos (id, tenant_id, ticket_id, storage_path, descripcion, subido_por, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [const Uuid().v4(), widget.tenantId, widget.ticketId, path,
            descripcion, hechoPor, now],
        );
        await tx.execute(
          '''INSERT INTO ticket_eventos
             (id, tenant_id, ticket_id, tipo_evento, comentario, hecho_por, ocurrido_en, created_at)
             VALUES (?, ?, ?, 'adjunto', ?, ?, ?, ?)''',
          [const Uuid().v4(), widget.tenantId, widget.ticketId, descripcion,
            hechoPor, ocurrido, now],
        );
        await OpLog.escribir(
          tx,
          tenantId: widget.tenantId,
          opId: opId,
          tipoOp: 'alta_entidad',
          entidad: 'tickets',
          entidadId: widget.ticketId,
          accion: 'create',
          diff: {
            'campos': const [],
            'resumen': {'motivo': 'Adjunto: ${descripcion ?? 'Adjunto subido'}'},
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurrido),
        );
      });
      if (mounted) _snack(descripcion ?? 'Adjunto subido');
    } catch (e) {
      if (mounted) _snack(mensajeErrorHumano(e, contexto: 'subir'));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _delete(String id, String path) async {
    // Baja de adjunto atribuida al usuario (op_log) → bloqueada al impersonar.
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar adjunto'),
        content: const Text('No se puede deshacer.'),
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
    if (ok != true || !mounted) return;
    // op_log: la baja del adjunto es un evento del ticket → entrada scopeada.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.dbW.writeTransaction((tx) async {
        final prev =
            await tx.getOptional('SELECT descripcion FROM ticket_adjuntos WHERE id = ?', [id]);
        final desc = prev?['descripcion'] as String?;
        await tx.execute('DELETE FROM ticket_adjuntos WHERE id = ?', [id]);
        await OpLog.escribir(
          tx,
          tenantId: widget.tenantId,
          opId: opId,
          tipoOp: 'baja_entidad',
          entidad: 'tickets',
          entidadId: widget.ticketId,
          accion: 'delete',
          diff: {
            'campos': const [],
            'resumen': {'motivo': 'Adjunto eliminado: ${desc ?? 'Adjunto'}'},
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurrido),
        );
      });
      await Supabase.instance.client.storage.from(_bucket).remove([path]);
      if (mounted) _snack('Adjunto eliminado');
    } catch (e) {
      if (mounted) _snack(mensajeErrorHumano(e));
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.attach_file, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Adjuntos',
                  style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _stream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) return Text(mensajeErrorHumano(snap.error!));
                final rows = snap.data!;
                final canAdd = _puedeEditar && rows.length < _maxAdjuntos;
                if (rows.isEmpty && !_puedeEditar) {
                  return Text('Sin adjuntos',
                      style: TextStyle(color: scheme.outline));
                }
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in rows)
                      _Thumb(
                        path: f['storage_path'] as String,
                        canDelete: _puedeEditar,
                        onDelete: () =>
                            _delete(f['id'] as String, f['storage_path'] as String),
                      ),
                    if (canAdd) _AddBtn(uploading: _uploading, onTap: _pickAndUpload),
                    if (canAdd)
                      _AddBtn(
                          uploading: _uploading,
                          onTap: _capturarFirma,
                          icon: Icons.gesture,
                          label: 'Firma'),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({required this.path, required this.canDelete, required this.onDelete});
  final String path;
  final bool canDelete;
  final VoidCallback onDelete;
  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  String? _url;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final url = await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(widget.path, 86400);
      if (mounted) setState(() { _url = url; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _url = null; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = 120.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _loading
              ? Container(
                  color: scheme.surfaceContainerHighest,
                  child: const Center(
                      child: SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))))
              : _url != null
                  ? GestureDetector(
                      onTap: () => _fullScreen(context, _url!),
                      child: Image.network(_url!,
                          width: size, height: size, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                              color: scheme.surfaceContainerHighest,
                              child: Icon(Icons.broken_image, color: scheme.outline))),
                    )
                  : Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.broken_image, color: scheme.outline)),
        ),
        if (widget.canDelete)
          Positioned(
            top: 4, right: 4,
            child: GestureDetector(
              onTap: widget.onDelete,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
                child: Icon(Icons.close, size: 14, color: scheme.onError),
              ),
            ),
          ),
      ]),
    );
  }

  void _fullScreen(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(children: [
          Center(child: InteractiveViewer(child: Image.network(url))),
          Positioned(
            top: 8, right: 8,
            child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(ctx)),
          ),
        ]),
      ),
    );
  }
}

class _AddBtn extends StatelessWidget {
  const _AddBtn({
    required this.uploading,
    required this.onTap,
    this.icon = Icons.add_a_photo,
    this.label = 'Agregar',
  });
  final bool uploading;
  final VoidCallback onTap;
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: uploading ? null : onTap,
      child: Container(
        width: 120, height: 120,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outline),
          color: scheme.surfaceContainerHighest,
        ),
        child: uploading
            ? const Center(
                child: SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2)))
            : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(fontSize: 11, color: scheme.primary)),
              ]),
      ),
    );
  }
}
