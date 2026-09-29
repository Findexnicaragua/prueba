import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/sync_status_provider.dart';
import '../../../powersync/db.dart' as ps;

/// Aviso de COLA ATASCADA: hay cambios locales que llevan demasiado sin subir
/// A PESAR de haber conexión.
///
/// Cubre la familia de fallas que NADIE más ve: un error clasificado como
/// retryable (PGRST*, HTTP, desconocidos) reintenta para siempre — a propósito,
/// para no perder el dato — pero mientras tanto la cola entera queda frenada y
/// el cobrador sigue cobrando sin enterarse. Del lado del server esa situación
/// es INVISIBLE (no llega nada, no se rechaza nada). El único que puede verla
/// es este teléfono, así que el aviso vive acá.
///
/// Sin conexión NO aparece: cobrar offline con cola llena es el estado normal
/// del día de campo. Solo alarma la combinación conectado + cola vieja.
class ColaAtascadaBanner extends ConsumerStatefulWidget {
  const ColaAtascadaBanner({super.key});

  @override
  ConsumerState<ColaAtascadaBanner> createState() =>
      _ColaAtascadaBannerState();
}

class _ColaAtascadaBannerState extends ConsumerState<ColaAtascadaBanner> {
  /// Con señal, un batch sube en segundos. 30 min conectados con la cola sin
  /// vaciarse no es lentitud: algo la tiene frenada.
  static const _umbral = Duration(minutes: 30);

  Timer? _timer;
  int _pendientes = 0;

  /// Desde cuándo la cola está no-vacía SIN interrupciones. Se limpia en
  /// cuanto baja a 0 (o sea: mide "atascada", no "usada").
  DateTime? _desde;

  @override
  void initState() {
    super.initState();
    _chequear();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _chequear());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _chequear() async {
    try {
      final stats = await ps.db.getUploadQueueStats();
      if (!mounted) return;
      setState(() {
        _pendientes = stats.count;
        if (stats.count == 0) {
          _desde = null;
        } else {
          _desde ??= DateTime.now();
        }
      });
    } catch (_) {
      // DB en recreación (cambio de usuario / wipe): no alarmar con datos
      // a medias; el próximo tick vuelve a mirar.
    }
  }

  @override
  Widget build(BuildContext context) {
    final conectado =
        ref.watch(syncStatusProvider).valueOrNull?.connected ?? false;
    final desde = _desde;
    final atascada = conectado &&
        _pendientes > 0 &&
        desde != null &&
        DateTime.now().difference(desde) >= _umbral;
    if (!atascada) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final mins = DateTime.now().difference(desde).inMinutes;
    final hace = mins >= 60 ? '${mins ~/ 60} h ${mins % 60} min' : '$mins min';

    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(children: [
          Icon(Icons.cloud_upload_outlined,
              size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Tenés $_pendientes cambio${_pendientes == 1 ? '' : 's'} sin '
              'subir desde hace $hace, con conexión. No cierres el día sin '
              'avisar a la oficina.',
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  color: scheme.onErrorContainer),
            ),
          ),
        ]),
      ),
    );
  }
}
