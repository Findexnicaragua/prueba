import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../powersync/db.dart' as ps;
import '../models/cobrador.dart';
import '../services/dispositivo_service.dart';
import 'db_epoch_provider.dart';
import 'impersonation_provider.dart';

/// La telemetría de versión se manda UNA vez por proceso (0225): el provider
/// re-emite cada vez que cambia la fila del usuario, y no tiene sentido
/// reportar de nuevo por eso.
bool _versionReportada = false;

/// Cobrador (usuario actual) sincronizado desde el SQLite local.
/// Reacciona a cambios en la fila (ej. admin actualiza prefijo_recibo).
final cobradorActualProvider = StreamProvider<Cobrador?>((ref) async* {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) {
    ps.rolActualCache = null;
    yield null;
    return;
  }

  // El watch puede tirar ClosedException si la DB se cierra durante un switch
  // de identidad/DB; el provider se recrea vía dbEpochProvider. Lo tragamos
  // para no spamear el error log con ruido transitorio y benigno.
  try {
    await for (final rows in ps.db.watch(
      'SELECT * FROM cobradores WHERE id = ?',
      parameters: [user.id],
    )) {
      if (rows.isEmpty) {
        ps.rolActualCache = null;
        yield null;
      } else {
        final c = Cobrador.fromRow(rows.first);
        // Espeja el rol para la guardia SÍNCRONA de escritura (`ps.dbW`), que
        // no puede consultar la DB. Este provider ya observa la fila, así que
        // el cache sigue al server sin lógica extra.
        ps.rolActualCache = c.rol;
        // Telemetría de versión (0225). Acá es donde la identidad reciÉn queda
        // completa (tenant + usuario + rol). Va sin await y una sola vez por
        // proceso: es best-effort y no debe demorar el arranque ni repetirse
        // con cada cambio de la fila (el provider re-emite al editarla).
        if (!_versionReportada) {
          _versionReportada = true;
          unawaited(DispositivoService.instance.reportar(
            tenantId: c.tenantId,
            usuarioId: c.id,
            usuarioNombre: c.nombre,
            rol: c.rol,
          ));
        }
        yield c;
      }
    }
  } catch (_) {
    // DB cerrada / recreándose; el provider se reconstruye en la DB nueva.
    // El cache se limpia también acá: si quedara el rol del usuario saliente,
    // un re-login del MISMO uid no pasa por `openDatabaseForUser` (early-return)
    // y heredaría permiso de escritura del rol anterior.
    ps.rolActualCache = null;
    yield null;
  }
});

/// True si el usuario actual NO puede modificar nada (rol `lectura`, 0198).
///
/// Es la fuente ÚNICA para ocultar acciones en la UI — no compares el rol a
/// mano en cada pantalla. Que devuelva `false` mientras el provider carga es
/// deliberado: la UI no debe parpadear mostrando todo bloqueado, y de todos
/// modos la UI es solo la primera de las tres barreras (las otras dos son el
/// connector, que descarta la cola de subida, y las policies de Postgres, que
/// para este rol son exclusivamente de SELECT).
final soloLecturaProvider = Provider<bool>((ref) =>
    ref.watch(cobradorActualProvider).valueOrNull?.esLectura ?? false);

/// Tenant efectivo: el impersonado si el super_admin está dentro de
/// un tenant, sino el del cobrador actual. Usar esto en vez de
/// `cobrador.tenantId` para operaciones que deben respetar la
/// impersonación (INSERT/UPDATE, queries scoped por tenant, etc.).
///
/// Para users normales (admin/cobrador), impersonation es siempre
/// null → retorna el tenant real del cobrador. Sin efecto.
final tenantIdProvider = Provider<String?>((ref) {
  final impersonated = ref.watch(impersonatedTenantIdProvider).valueOrNull;
  if (impersonated != null) return impersonated;
  return ref.watch(cobradorActualProvider).valueOrNull?.tenantId;
});
