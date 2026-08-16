import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/audit_changelog.dart' show kAuditEntidadLabel;

/// Un write local que el server RECHAZÓ de forma permanente (constraint /
/// RLS / trigger de negocio). El connector lo descarta de la cola para no
/// trabar el sync, así que el dato local queda DIVERGENTE del server.
///
/// Audit 2026-06-11 (finding #5): antes el único rastro visible era un
/// SnackBar de 6 segundos con el error crudo en inglés — un cobro rechazado
/// se descubría recién en el arqueo. Ahora cada rechazo se persiste acá y
/// el Perfil (cobrador/técnico) muestra la lista hasta que el usuario la
/// descarta a propósito.
class RechazoSync {
  const RechazoSync({
    required this.id,
    required this.tabla,
    required this.registroId,
    required this.op,
    required this.codigo,
    required this.mensaje,
    required this.fechaUtcIso,
    this.data,
  });

  /// Identificador del aviso (para descartarlo individualmente).
  final String id;
  final String tabla;
  final String registroId;

  /// Tipo de operación CRUD: 'put' | 'patch' | 'delete'.
  final String op;
  final String? codigo;

  /// Mensaje crudo del server (se guarda para diagnóstico; la UI usa
  /// [mensajeHumano]).
  final String mensaje;
  final String fechaUtcIso;

  /// Snapshot del opData descartado — el único rastro local del contenido
  /// del write para reconstruirlo a mano si hiciera falta.
  final Map<String, dynamic>? data;

  String get tablaLabel => etiquetaTablaSync(tabla);

  String get opLabel => switch (op) {
        'put' => 'Alta/edición',
        'patch' => 'Edición',
        'delete' => 'Borrado',
        _ => op,
      };

  String get mensajeHumano => humanizarRechazoSync(codigo, mensaje);

  Map<String, dynamic> toJson() => {
        'id': id,
        'tabla': tabla,
        'registro_id': registroId,
        'op': op,
        'codigo': codigo,
        'mensaje': mensaje,
        'fecha_utc': fechaUtcIso,
        'data': data,
      };

  static RechazoSync fromJson(Map<String, dynamic> json) => RechazoSync(
        id: json['id'] as String,
        tabla: json['tabla'] as String? ?? '?',
        registroId: json['registro_id'] as String? ?? '?',
        op: json['op'] as String? ?? '?',
        codigo: json['codigo'] as String?,
        mensaje: json['mensaje'] as String? ?? '',
        fechaUtcIso: json['fecha_utc'] as String? ?? '',
        data: (json['data'] as Map?)?.cast<String, dynamic>(),
      );
}

/// Nombre humano de la tabla (reusa los labels del change log).
String etiquetaTablaSync(String tabla) => kAuditEntidadLabel[tabla] ?? tabla;

/// Traduce el rechazo del server a un mensaje accionable en español.
/// Los P0001 (RAISE EXCEPTION de los triggers de negocio del proyecto) ya
/// vienen en español → se muestran tal cual.
/// Código propio (no de Postgres) para el rechazo SILENCIOSO: el server aplicó
/// el filtro de permisos y no tocó ninguna fila, así que respondió "ok" con
/// cero filas y sin error. Ver `connector.dart`.
const kCodigoRechazoSinFilas = 'RLS0';

String humanizarRechazoSync(String? codigo, String mensaje) {
  if (codigo == 'P0001') return mensaje;
  switch (codigo) {
    case kCodigoRechazoSinFilas:
      return 'El servidor no aceptó el cambio y lo va a revertir: '
          'no tenés permiso sobre ese registro.';
    case '23505':
      return 'Ya existía un registro igual en el servidor (duplicado).';
    case '23503':
      return 'El registro apunta a datos que ya no existen en el servidor.';
    case '23502':
      return 'Faltó un dato obligatorio.';
    case '23514':
      return 'El servidor rechazó el dato por una regla de validación.';
    case '42501':
      return 'Sin permiso para esta operación (o el módulo está '
          'desactivado para tu empresa).';
  }
  if (mensaje.toLowerCase().contains('row-level security')) {
    return 'Sin permiso para esta operación (o el módulo está '
        'desactivado para tu empresa).';
  }
  if (codigo != null && codigo.length == 5 && codigo.startsWith('22')) {
    return 'El formato de un dato no es válido.';
  }
  return 'El servidor rechazó el cambio'
      '${codigo == null ? '' : ' (código $codigo)'}.';
}

/// Persistencia (SharedPreferences) + stream de los rechazos de sync.
///
/// Best-effort: cualquier fallo de prefs se traga en silencio — este
/// servicio NUNCA debe romper el upload loop del connector. Nota: el store
/// es por DISPOSITIVO (no por usuario); los equipos de campo son personales,
/// así que en la práctica coincide.
class RechazosSyncService {
  RechazosSyncService._();
  static final RechazosSyncService instance = RechazosSyncService._();

  static const _kPrefsKey = 'rechazos_sync_v1';

  /// Tope de avisos guardados (los más nuevos pisan a los más viejos).
  static const _kMax = 50;

  final _cambios = StreamController<void>.broadcast();

  /// Cola interna: serializa los read-modify-write a prefs. Los `registrar`
  /// llegan `unawaited` desde el connector (varios descartes en un mismo
  /// batch) — concurrentes se pisarían y perderían avisos (audit Fase 4).
  Future<void> _serial = Future.value();

  Future<void> _encolar(Future<void> Function() accion) {
    // Las acciones nunca tiran (catch-all interno) → el encadenado es seguro.
    _serial = _serial.then((_) => accion());
    return _serial;
  }

  /// Lista actual al suscribirse + re-emisión en cada cambio.
  Stream<List<RechazoSync>> watch() async* {
    yield await listar();
    await for (final _ in _cambios.stream) {
      yield await listar();
    }
  }

  /// Rechazos guardados, el más nuevo primero. Entradas corruptas se saltan.
  Future<List<RechazoSync>> listar() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kPrefsKey) ?? const [];
      final out = <RechazoSync>[];
      for (final s in raw) {
        try {
          out.add(RechazoSync.fromJson(
              (jsonDecode(s) as Map).cast<String, dynamic>()));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> registrar(RechazoSync rechazo) =>
      _encolar(() => _registrarImpl(rechazo));

  Future<void> _registrarImpl(RechazoSync rechazo) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kPrefsKey) ?? <String>[];
      // Dedupe (audit Fase 4): si el batch se reintenta (op descartada + op
      // retryable en el MISMO batch), la misma op se re-descarta en cada
      // retry — sin esto se apilaba un aviso idéntico por intento. El más
      // nuevo reemplaza al viejo (refresca fecha y sube al tope).
      raw.removeWhere((s) {
        try {
          final m = jsonDecode(s) as Map;
          return m['tabla'] == rechazo.tabla &&
              m['registro_id'] == rechazo.registroId &&
              m['codigo'] == rechazo.codigo;
        } catch (_) {
          return true; // entrada corrupta: aprovechar y limpiarla
        }
      });
      raw.insert(0, jsonEncode(rechazo.toJson()));
      if (raw.length > _kMax) raw.removeRange(_kMax, raw.length);
      await prefs.setStringList(_kPrefsKey, raw);
      _cambios.add(null);
    } catch (_) {}
  }

  /// Descarta UN aviso (el dato divergente sigue tal cual — esto solo borra
  /// la notificación, decisión consciente del usuario).
  Future<void> descartar(String id) => _encolar(() => _descartarImpl(id));

  Future<void> _descartarImpl(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kPrefsKey) ?? <String>[];
      raw.removeWhere((s) {
        try {
          return (jsonDecode(s) as Map)['id'] == id;
        } catch (_) {
          return true; // entrada corrupta: aprovechar y limpiarla
        }
      });
      await prefs.setStringList(_kPrefsKey, raw);
      _cambios.add(null);
    } catch (_) {}
  }

  Future<void> limpiar() => _encolar(_limpiarImpl);

  Future<void> _limpiarImpl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPrefsKey);
      _cambios.add(null);
    } catch (_) {}
  }
}
