import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/foto_comprobante_service.dart';

final fotoComprobanteServiceProvider = Provider<FotoComprobanteService>(
    (ref) => FotoComprobanteService(Supabase.instance.client));

/// Stream de resultados de cada corrida de upload. La UI lo watchea con
/// `ref.listen` para mostrar un SnackBar global cuando `failed > 0`
/// (R8). El service no emite si la corrida no tuvo intento real de
/// upload, así que el stream es silencioso en condiciones normales.
final uploadResultsProvider = StreamProvider<UploadResult>((ref) {
  return ref.watch(fotoComprobanteServiceProvider).results;
});
