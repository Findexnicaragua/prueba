part of 'contrato_detail_screen.dart';

class _DocumentoContratoSection extends StatefulWidget {
  const _DocumentoContratoSection({
    required this.contratoId,
    required this.documentoPath,
    required this.tenantId,
    required this.esAdmin,
  });
  final String contratoId;
  final String? documentoPath;
  final String tenantId;
  final bool esAdmin;

  @override
  State<_DocumentoContratoSection> createState() =>
      _DocumentoContratoSectionState();
}

class _DocumentoContratoSectionState extends State<_DocumentoContratoSection> {
  static const _bucket = 'contratos-documentos';
  static const _maxSizeBytes = 10 * 1024 * 1024; // 10 MB
  // Por encima de esto se muestra el peso y se pide confirmar (sin bloquear).
  static const _avisoBytes = 5 * 1024 * 1024;
  bool _trabajando = false;

  @override
  void didUpdateWidget(_DocumentoContratoSection old) {
    super.didUpdateWidget(old);
    // Reset el flag de trabajo si cambió el contrato (defensa contra
    // estado stale en navegación profunda).
    if (old.contratoId != widget.contratoId) {
      setState(() => _trabajando = false);
    }
  }

  Future<void> _subir({required bool reemplazar}) async {
    if (_trabajando) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    var bytes = file.bytes;
    if (bytes == null) return;

    var ext = (file.extension ?? 'bin').toLowerCase();
    final esImagen = ext == 'jpg' || ext == 'jpeg' || ext == 'png';

    // PDF/Word: límite duro ANTES (no se pueden comprimir) + confirmación
    // si son pesados. Las imágenes se validan DESPUÉS de comprimir: una
    // foto de 12 MB del contrato firmado entra sobrada una vez comprimida.
    if (!esImagen) {
      if (bytes.length > _maxSizeBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'El archivo supera el límite de ${_maxSizeBytes ~/ (1024 * 1024)} MB')),
          );
        }
        return;
      }
      if (bytes.length > _avisoBytes) {
        if (!mounted) return;
        final seguir = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Archivo pesado'),
            content: Text(
                '"${file.name}" pesa ${Fmt.pesoArchivo(file.bytes!.length)}. '
                'Puede tardar en subir y en abrirse con datos móviles. '
                '¿Subirlo igual?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Subir igual')),
            ],
          ),
        );
        if (seguir != true || !mounted) return;
      }
    }

    if (!mounted) return;
    // "Subiendo..." visible también durante la compresión (puede tomar
    // segundos con fotos grandes), no solo durante el upload.
    setState(() => _trabajando = true);
    try {
      if (esImagen) {
        // Foto elegida como documento → mismo pipeline que las fotos de
        // cliente.
        final comp = await comprimirImagen(bytes,
            maxLado: 1920, calidad: 85, maxBytes: 9 * 1024 * 1024);
        if (!mounted) return;
        bytes = comp.bytes;
        ext = comp.ext;
        // Red de seguridad: imagen indecodificable (vuelve sin comprimir)
        // que excede el bucket.
        if (bytes.length > _maxSizeBytes) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'El archivo supera el límite de ${_maxSizeBytes ~/ (1024 * 1024)} MB')),
          );
          return;
        }
      }
      final mime = _mimeFor(ext);
      final storagePath =
          '${widget.tenantId}/${widget.contratoId}/${DateTime.now().millisecondsSinceEpoch}.$ext';

      // Si estamos reemplazando, borrar el archivo viejo del bucket
      // (la row queda actualizada con el nuevo path).
      if (reemplazar && widget.documentoPath != null) {
        try {
          await Supabase.instance.client.storage
              .from(_bucket)
              .remove([widget.documentoPath!]);
        } catch (_) {
          // No bloquea — si falla la limpieza queda huérfano pero
          // el upload del nuevo sigue.
        }
      }

      await Supabase.instance.client.storage
          .from(_bucket)
          .uploadBinary(storagePath, bytes,
              fileOptions: FileOptions(contentType: mime));

      // Hora REAL del dispositivo (UTC) para el change log — offline-first.
      final ahora = DateTime.now().toUtc();
      final ocurridoEn = ahora.toIso8601String();
      final user = Supabase.instance.client.auth.currentUser;
      final actor = user != null
          ? await OpLog.actorDeUsuario(ps.db, user.id)
          : const OpLogActor.systemAdmin();
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'UPDATE contratos SET documento_path = ?, ocurrido_en = ? WHERE id = ?',
          [storagePath, ocurridoEn, widget.contratoId],
        );
        // op_log (fix F0): adjuntar/reemplazar el documento deja rastro.
        await OpLog.escribir(tx,
            tenantId: widget.tenantId, opId: OpLog.nuevoOpId(),
            tipoOp: 'edicion_entidad', entidad: 'contratos',
            entidadId: widget.contratoId, accion: 'update',
            diff: {
              'campos': [
                {
                  'campo': 'documento_path',
                  'antes': widget.documentoPath,
                  'despues': storagePath
                }
              ]
            },
            actor: actor, ocurridoEn: ahora);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(reemplazar
                  ? 'Documento reemplazado'
                  : 'Documento adjuntado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _eliminar() async {
    if (_trabajando || widget.documentoPath == null) return;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar documento'),
        content: const Text('Esta acción no se puede deshacer.'),
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
    if (confirmar != true || !mounted) return;

    setState(() => _trabajando = true);
    try {
      // DB primero (consistente con FotoGalleryWidget).
      // Hora REAL del dispositivo (UTC) para el change log — offline-first.
      final ahora = DateTime.now().toUtc();
      final ocurridoEn = ahora.toIso8601String();
      final user = Supabase.instance.client.auth.currentUser;
      final actor = user != null
          ? await OpLog.actorDeUsuario(ps.db, user.id)
          : const OpLogActor.systemAdmin();
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'UPDATE contratos SET documento_path = NULL, ocurrido_en = ? WHERE id = ?',
          [ocurridoEn, widget.contratoId],
        );
        // op_log (fix F0): quitar el documento deja rastro.
        await OpLog.escribir(tx,
            tenantId: widget.tenantId, opId: OpLog.nuevoOpId(),
            tipoOp: 'edicion_entidad', entidad: 'contratos',
            entidadId: widget.contratoId, accion: 'update',
            diff: {
              'campos': [
                {
                  'campo': 'documento_path',
                  'antes': widget.documentoPath,
                  'despues': null
                }
              ]
            },
            actor: actor, ocurridoEn: ahora);
      });
      try {
        await Supabase.instance.client.storage
            .from(_bucket)
            .remove([widget.documentoPath!]);
      } catch (_) {
        // Orphan en Storage es inofensivo (la row ya no apunta).
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Documento eliminado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e, contexto: 'eliminar'))),
        );
      }
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _ver() async {
    if (widget.documentoPath == null) return;
    try {
      final url = await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(widget.documentoPath!, 3600);
      if (!mounted) return;

      // Imágenes: preview inline en Dialog con Image.network + zoom.
      // PDF/Word: abre en pestaña nueva (el navegador maneja preview o
      // descarga según MIME type — DOC/DOCX descargan, PDF se renderiza).
      if (_esImagen(widget.documentoPath!)) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(16),
            child: Stack(
              children: [
                Center(
                  child: InteractiveViewer(
                    child: Image.network(url, fit: BoxFit.contain),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
              ],
            ),
          ),
        );
        return;
      }

      final ok = await launchUrlString(url, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir el documento')),
        );
      }
    } catch (e) {
      if (mounted) {
        final esRed = e.toString().contains('SocketException') ||
            e.toString().contains('Failed host lookup') ||
            e.toString().contains('NetworkException');
        final mensaje = esRed
            ? 'Necesitás conexión para ver el documento.'
            : 'No se pudo abrir el documento. Intentá más tarde.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensaje)),
        );
      }
    }
  }

  String _mimeFor(String ext) => switch (ext) {
        'pdf' => 'application/pdf',
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'doc' => 'application/msword',
        'docx' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        _ => 'application/octet-stream',
      };

  IconData _iconFor(String? path) {
    if (path == null) return Icons.attach_file;
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf,
      'jpg' || 'jpeg' || 'png' => Icons.image,
      'doc' || 'docx' => Icons.description,
      _ => Icons.insert_drive_file,
    };
  }

  String _tipoLabel(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => 'PDF',
      'jpg' || 'jpeg' => 'JPG',
      'png' => 'PNG',
      'doc' => 'DOC',
      'docx' => 'DOCX',
      _ => ext.toUpperCase(),
    };
  }

  bool _esImagen(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ext == 'jpg' || ext == 'jpeg' || ext == 'png';
  }

  String _nombreCorto(String path) {
    final parts = path.split('/');
    return parts.isNotEmpty ? parts.last : path;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hayDoc = widget.documentoPath != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.folder_open, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text('Documento del contrato',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 8),
        if (!hayDoc) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.attach_file, size: 28, color: scheme.outline),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.esAdmin
                          ? 'Adjuntá el contrato firmado (PDF, Word o foto).'
                          : 'Sin documento adjunto.',
                      style: TextStyle(color: scheme.outline),
                    ),
                  ),
                  if (widget.esAdmin)
                    FilledButton.icon(
                      icon: _trabajando
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_file),
                      label: Text(_trabajando ? 'Subiendo...' : 'Adjuntar'),
                      onPressed:
                          _trabajando ? null : () => _subir(reemplazar: false),
                    ),
                ],
              ),
            ),
          ),
        ] else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(_iconFor(widget.documentoPath), size: 32, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('Documento adjunto',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _tipoLabel(widget.documentoPath!),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(_nombreCorto(widget.documentoPath!),
                            style: TextStyle(
                                fontSize: 11,
                                color: scheme.outline),
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.open_in_new),
                    tooltip: _esImagen(widget.documentoPath!)
                        ? 'Ver imagen'
                        : 'Abrir / Descargar',
                    onPressed: _trabajando ? null : _ver,
                  ),
                  if (widget.esAdmin) ...[
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Reemplazar',
                      onPressed: _trabajando
                          ? null
                          : () => _subir(reemplazar: true),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: scheme.error),
                      tooltip: 'Eliminar',
                      onPressed: _trabajando ? null : _eliminar,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
