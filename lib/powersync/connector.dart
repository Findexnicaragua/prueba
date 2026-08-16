import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../data/services/rechazos_sync_service.dart';

/// Conector entre PowerSync y Supabase usando **Supabase Auth directo**.
///
///  - `fetchCredentials`: devuelve el access token de la sesión Supabase actual.
///  - `uploadData`: drena la crud queue local hacia Postgres vía supabase_flutter.
///
/// **Manejo de errores no-retryables** (E2E bug #2):
/// Si un INSERT/UPDATE falla con un error de cliente (constraint violation,
/// trigger reject, RLS denied — típicamente status <500), el error NO es
/// retryable. Reintentar infinitamente bloquea todo el sync. En vez de
/// `rethrow`, logueamos el error, emitimos al stream `uploadErrors` para
/// que la UI lo muestre, y avanzamos al siguiente item del batch.
///
/// Errores de server (500, network timeout) SÍ se rethrolean para que
/// PowerSync reintente automáticamente.
class SupabaseConnector extends PowerSyncBackendConnector {
  SupabaseConnector(this._supabase);

  final SupabaseClient _supabase;

  /// Stream de errores de CRUD upload que la UI puede watchear para
  /// mostrar SnackBars cuando un write local fue rechazado por el server.
  final _uploadErrors = StreamController<CrudUploadError>.broadcast();
  Stream<CrudUploadError> get uploadErrors => _uploadErrors.stream;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final session = _supabase.auth.currentSession;
    if (session == null) return null;

    return PowerSyncCredentials(
      endpoint: Env.powersyncUrl,
      token: session.accessToken,
    );
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final transaction = await database.getCrudBatch();
    if (transaction == null) return;

    // Barrera 2 del rol `lectura` (0198): DESCARTAR la cola sin subir nada.
    //
    // El rol no tiene ninguna policy de escritura, así que todo write que se
    // escape de la UI sería rechazado por Postgres. Sin esto, ese rechazo
    // entraría al camino de "non-retryable" y le llenaría la pantalla de
    // errores de sync por algo que él no puede arreglar. Peor: un código no
    // clasificado como permanente TRABA la cola reintentando para siempre.
    // Descartar acá es seguro justamente porque el rol no genera datos que
    // valga la pena preservar.
    if (await _esSoloLectura(database)) {
      debugPrint('[CRUD] rol lectura: se descartan '
          '${transaction.crud.length} op(s) sin subir');
      await transaction.complete();
      return;
    }

    try {
      for (final op in transaction.crud) {
        try {
          final table = _supabase.from(op.table);
          switch (op.op) {
            case UpdateType.put:
              await table.upsert({'id': op.id, ...?op.opData});
              break;
            case UpdateType.patch:
              // PowerSync encola el PATCH aunque el UPDATE local no haya
              // cambiado nada (`ignoreEmptyUpdates` viene en false y el schema
              // no lo activa). Un PATCH sin campos no tiene nada que escribir:
              // se salta antes de armar el request.
              if (op.opData != null && op.opData!.isEmpty) break;
              if (op.opData != null) {
                // `.select('id')` NO es cosmético: sin él, un UPDATE que la
                // policy filtra por USING devuelve 204 con CERO filas y SIN
                // excepción, así que el connector lo daba por exitoso, sacaba
                // la op de la cola, y al llegar el checkpoint PowerSync pisaba
                // el valor local con el del server: el usuario veía su cambio
                // y minutos después volvía solo al anterior, sin un mensaje.
                // Documentado en el repo tras un bug real
                // (mora_count_provider.dart, cuotas_list_screen.dart), y con 57
                // policies en 32 tablas capaces de filtrar así.
                final filas =
                    await table.update(op.opData!).eq('id', op.id).select('id');
                if (filas.isEmpty &&
                    !_esEspejoLocal(op) &&
                    await _filaSigueVisible(table, op.id)) {
                  _registrarRechazo(op,
                      codigo: kCodigoRechazoSinFilas,
                      mensaje: 'El servidor no modificó ninguna fila '
                          '(sin permiso sobre ese registro).');
                  continue;
                }
              }
              break;
            case UpdateType.delete:
              final borradas =
                  await table.delete().eq('id', op.id).select('id');
              // Cero filas en un DELETE es ambiguo: la policy pudo filtrarlo, o
              // la fila YA no existe (la borró otro device, o es un reintento).
              // Solo lo primero es un rechazo; lo segundo ya alcanzó el estado
              // deseado. Si la fila sigue ahí, no se borró: eso sí es rechazo.
              if (borradas.isEmpty &&
                  await _filaSigueVisible(table, op.id)) {
                _registrarRechazo(op,
                    codigo: kCodigoRechazoSinFilas,
                    mensaje: 'El servidor no borró el registro '
                        '(sin permiso sobre ese registro).');
                continue;
              }
              break;
          }
        } on PostgrestException catch (e) {
          // Choque de correlativo de recibo: el número lo calcula el DEVICE
          // leyendo el máximo antes de la transacción, así que no es una
          // reserva — dos equipos con el mismo prefijo sacan el mismo número.
          // El server acepta uno y rechaza el otro con 23505.
          //
          // Descartarlo (que es lo que hacía el camino "permanente" de abajo)
          // PIERDE el comprobante, pero el `pago` de la misma transacción NO
          // tiene esa constraint y sí sube → cobro sin recibo. Medido en prod:
          // 34 casos, todos de una cuenta compartida entre varios equipos.
          //
          // Es el único 23505 que tiene arreglo automático: se pide el próximo
          // número libre y se reintenta. Si tampoco sale, cae al camino normal.
          if (op.table == 'recibos' && e.code == '23505') {
            final reintentado = await _reintentarReciboConNuevoNumero(op);
            if (reintentado) continue;
          }
          if (_isNonRetryable(e)) {
            // El write local fue RECHAZADO por el server (constraint/RLS/
            // trigger). No es retryable: lo saltamos para no trabar la cola.
            // OJO: el dato local queda DIVERGENTE del server (que no lo aceptó).
            // Doble rastro (audit 2026-06-11 #5; corregido 2026-07-03 — NO
            // existe tabla error_logs server-side): SnackBar inmediato
            // (uploadErrors) + aviso PERSISTENTE en el device
            // (RechazosSyncService, con el opData completo en `data` — único
            // registro del contenido para reconstruir el write a mano; vive
            // en shared_preferences.json del device).
            _registrarRechazo(op, codigo: e.code, mensaje: e.message);
            continue;
          }
          rethrow;
        }
      }
      await transaction.complete();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PowerSync uploadData falló: $e\n$st');
      }
      rethrow;
    }
  }

  /// Columnas que el CLIENTE escribe solo como ESPEJO local, para que la UI
  /// reaccione al toque sin esperar el sync, y cuyo dueño real es un trigger
  /// del server. Que el server rechace ese write es lo ESPERADO — el valor
  /// bueno baja después por sync — así que no se avisa.
  ///
  /// Sin esta lista, el aviso de rechazo se disparaba en cada cobro de cada
  /// cobrador: `registrarCobro`/`registrarCobroMultiple` llaman a
  /// `recalcVmvDeContrato` (pagos_repo.dart:439 y :683) para repintar el pin
  /// del mapa. Son ~1.900 cobros en 30 días: convertiría un bug silencioso en
  /// una lluvia de avisos sobre algo que funciona bien.
  ///
  /// OJO — el porqué CAMBIÓ con 0230 y este comentario decía algo hoy FALSO:
  /// afirmaba que "el cobrador no tiene ninguna policy de escritura sobre
  /// `clientes`". Desde 0230 sí la tiene (`clientes_write_notas`), así que su
  /// PATCH ya no lo filtra la RLS —lo revierte el trigger `trg_clientes_a_solo_
  /// notas`— y el UPDATE devuelve 1 fila en vez de 0. O sea que la detección ya
  /// no se dispararía igual. La lista se conserva como red: es barata y sigue
  /// siendo correcta si mañana el permiso se vuelve a cerrar.
  ///
  /// CONSECUENCIA ACEPTADA de 0230, que hay que tener presente: para `clientes`
  /// y `contratos` esta detección quedó CIEGA. Se apoyaba en que la RLS filtrara
  /// la fila (0 filas ⇒ rechazo); ahora la fila pasa y el trigger revierte por
  /// columna, así que un write denegado se ve exitoso. Hoy no hay ningún camino
  /// de la app que lo produzca —el gate de UI está alineado con lo que la
  /// barrera permite— pero si aparece uno, el usuario no va a recibir aviso.
  ///
  /// Regla para el que agregue un espejo nuevo: si el server es el dueño de la
  /// columna y el cliente la escribe solo por UX, va acá.
  static const _espejosLocales = <String, Set<String>>{
    'clientes': {'vencimiento_mas_viejo'},
  };

  /// El patch, ¿toca SOLO columnas de espejo local de esa tabla?
  bool _esEspejoLocal(CrudEntry op) {
    final columnas = _espejosLocales[op.table];
    if (columnas == null) return false;
    final campos = op.opData?.keys;
    if (campos == null || campos.isEmpty) return false;
    return campos.every(columnas.contains);
  }

  /// ¿La fila sigue siendo VISIBLE para este usuario? Es la pregunta que
  /// desambigua un resultado vacío, y sirve igual para el patch y para el
  /// delete.
  ///
  /// Por qué hace falta: `.select()` después de un UPDATE/DELETE pasa por la
  /// policy de **SELECT**, no por la de escritura. Un resultado vacío puede
  /// significar dos cosas muy distintas:
  ///   (a) la policy de escritura filtró la fila → RECHAZO real, hay que avisar;
  ///   (b) la escritura entró pero la policy de LECTURA no deja verla → todo
  ///       bien, avisar sería mentir.
  /// Si la fila SÍ se ve, (b) queda descartado: de haberse aplicado, el
  /// `.select()` de la escritura la habría devuelto. Si NO se ve, no se puede
  /// distinguir y no se acusa — queda como antes de este fix (silencioso), que
  /// es preferible a una alarma falsa.
  ///
  /// Se decidió así, y NO comparando los valores escritos contra los del
  /// server, porque esa comparación cruza dos sistemas de tipos: local
  /// `Column.integer('anulado')` manda 0/1 y Postgres devuelve false/true, las
  /// fechas son texto acá y timestamptz allá, y los decimales vuelven con otra
  /// precisión. Cada una de esas diferencias habría disparado un rechazo falso
  /// en operaciones normalísimas (anular un pago, para empezar).
  Future<bool> _filaSigueVisible(PostgrestQueryBuilder table, String id) async {
    try {
      final filas = await table.select('id').eq('id', id);
      return filas.isNotEmpty;
    } catch (_) {
      return false; // ante la duda, no acusar
    }
  }

  /// Deja el DOBLE rastro de un write que el server no persistió: el aviso
  /// inmediato (SnackBar via `uploadErrors`) y el aviso PERSISTENTE en el
  /// device (`RechazosSyncService`, con el `opData` completo — es el único
  /// registro del contenido para reconstruir el write a mano; no existe tabla
  /// de errores server-side).
  ///
  /// Lo usan los dos caminos de rechazo: el que llega como excepción de
  /// Postgres (constraint/trigger) y el SILENCIOSO de cero filas (policy que
  /// filtra por USING, que no levanta excepción).
  void _registrarRechazo(CrudEntry op,
      {required String? codigo, required String mensaje}) {
    final detalle = '${op.op.name.toUpperCase()} ${op.table}/${op.id}'
        ' — ${codigo ?? '?'} $mensaje';
    debugPrint('[CRUD] Non-retryable rejected: $detalle');
    _uploadErrors.add(CrudUploadError(
      table: op.table,
      id: op.id,
      message: mensaje,
      codigo: codigo,
    ));
    final ahoraUtc = DateTime.now().toUtc();
    unawaited(RechazosSyncService.instance.registrar(RechazoSync(
      id: '${ahoraUtc.microsecondsSinceEpoch}-${op.id}',
      tabla: op.table,
      registroId: op.id,
      op: op.op.name,
      codigo: codigo,
      mensaje: mensaje,
      fechaUtcIso: ahoraUtc.toIso8601String(),
      data: op.opData,
    )));
  }

  bool _isNonRetryable(PostgrestException e) => esCodigoNoRetryable(e.code);

  /// Reintenta subir un recibo cuyo correlativo chocó, con el próximo número
  /// libre del server. `true` = quedó subido.
  ///
  /// El número que el device imprimió ya no se puede honrar (lo tiene otro
  /// recibo), así que el papel entregado al cliente y el registro difieren en
  /// el número. Es un mal MENOR frente a la alternativa actual, que es quedarse
  /// sin comprobante: la plata queda con respaldo y el correlativo, contiguo.
  Future<bool> _reintentarReciboConNuevoNumero(CrudEntry op) async {
    final data = op.opData;
    if (data == null) return false;
    final prefijo = data['prefijo'] as String?;
    final cobradorId = data['cobrador_id'] as String?;
    final tenantId = data['tenant_id'] as String?;
    if (prefijo == null || cobradorId == null || tenantId == null) return false;

    try {
      // Máximo vigente para ese (cobrador, prefijo) — el mismo alcance del
      // índice único que rechazó (`recibos_correlativo_por_cobrador_prefijo`).
      final res = await _supabase
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijo)
          .order('correlativo', ascending: false)
          .limit(1);
      final maxActual =
          res.isEmpty ? 0 : (res.first['correlativo'] as num).toInt();
      final nuevo = maxActual + 1;

      await _supabase.from('recibos').upsert({
        'id': op.id,
        ...data,
        'correlativo': nuevo,
        'numero_completo': '$prefijo-${nuevo.toString().padLeft(5, '0')}',
      });
      debugPrint('[CRUD] recibo ${op.id}: correlativo reasignado a $nuevo');
      return true;
    } catch (e) {
      // Otro device ganó de nuevo, o falló por otra razón. No insistimos acá:
      // el caller sigue con el manejo normal (y PowerSync reintenta el batch).
      debugPrint('[CRUD] recibo ${op.id}: reintento falló ($e)');
      return false;
    }
  }

  /// Lee el rol del usuario actual desde el SQLite local (la fila propia de
  /// `cobradores` siempre está sincronizada). Se consulta acá y no vía
  /// Riverpod porque el connector corre fuera del árbol de widgets.
  ///
  /// Ante cualquier duda devuelve `false` (= subir normalmente): si la fila
  /// todavía no bajó, tragarse writes de un usuario que SÍ puede escribir
  /// perdería datos — un cobro offline, por ejemplo. El rol real lo vuelve a
  /// enforzar RLS del lado del server.
  Future<bool> _esSoloLectura(PowerSyncDatabase database) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return false;
    try {
      final rows = await database.getAll(
        'SELECT rol FROM cobradores WHERE id = ?',
        [userId],
      );
      if (rows.isEmpty) return false;
      return rows.first['rol'] == 'lectura';
    } catch (_) {
      return false;
    }
  }
}

/// Clasifica el código de error de un upload rechazado (pública para tests).
///
/// `true` = error PERMANENTE de cliente: el server NUNCA va a aceptar este
/// write tal como está. Se descarta de la cola (con aviso + registro) para
/// no trabar el sync. `false` = se reintenta.
///
/// La regla es ALLOWLIST de clases SQLSTATE permanentes — todo lo demás se
/// trata como transitorio, porque descartar un write válido pierde plata
/// (un cobro offline que el server nunca recibe), mientras que reintentar
/// de más solo demora la cola. Audit 2026-06-11 (#1): la versión anterior
/// clasificaba por prefijos `'P'`/`'4'` y descartaba transitorios reales:
/// PGRST301 (JWT expirado justo al recuperar señal, antes del refresh),
/// PGRST000/002 (DB no disponible) y códigos HTTP tipo 429 (rate limit).
///
///   - Permanentes: 23xxx (constraint), 42xxx (schema/permiso RLS),
///     22xxx (formato de dato) y P0001 (RAISE EXCEPTION de triggers de
///     negocio). Solo SQLSTATE reales (5 chars) — un '429' HTTP no matchea.
///   - Retryables: PGRST*, códigos HTTP, clase 40 (serialization/deadlock)
///     y cualquier desconocido. OJO: un permanente "raro" (p.ej. PGRST204
///     por columna que falta en el server) BLOQUEA la cola reintentando —
///     a propósito: preserva el dato y se destraba al correr la migración
///     faltante, en vez de perder el write para siempre.
bool esCodigoNoRetryable(String? code) {
  if (code == null) return false;
  if (code == 'P0001') return true;
  if (code.length != 5) return false;
  return code.startsWith('23') ||
      code.startsWith('42') ||
      code.startsWith('22');
}

/// Error de CRUD upload surfaceado a la UI.
class CrudUploadError {
  const CrudUploadError({
    required this.table,
    required this.id,
    required this.message,
    this.codigo,
  });

  final String table;
  final String id;
  final String message;

  /// Código SQLSTATE/PostgREST del rechazo — los shells lo usan para
  /// humanizar el mensaje (ver `humanizarRechazoSync`).
  final String? codigo;
}
