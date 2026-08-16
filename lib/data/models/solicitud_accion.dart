import 'dart:convert';

import 'deuda_snapshot.dart';

enum TipoSolicitud {
  crearContrato,
  cancelarContrato,
  suspenderContrato,
  reactivarContrato,
  desactivarCliente,
  cambiarPlan,

  /// Tipo que ESTA versión no conoce (lo creó una app más nueva).
  ///
  /// Antes el fallback de [_parseTipo] era `crearContrato`: una solicitud de un
  /// tipo futuro se mostraba como "Crear contrato" y su ejecutor intentaba un
  /// INSERT con datos que no le correspondían. Ahora degrada a esto, que la UI
  /// muestra pero NO deja aprobar. Es la red para el próximo tipo que se agregue.
  desconocido,
}

enum EstadoSolicitud { pendiente, aprobada, rechazada }

class SolicitudAccion {
  const SolicitudAccion({
    required this.id,
    required this.tenantId,
    required this.solicitanteId,
    required this.tipo,
    required this.entidadId,
    required this.datos,
    this.motivo,
    this.notas,
    this.deudaSnapshot,
    required this.estado,
    this.aprobadorId,
    this.motivoRechazo,
    this.solicitanteLabel,
    required this.createdAt,
    required this.ocurridoEn,
    this.resolvedAt,
  });

  final String id;
  final String tenantId;
  final String solicitanteId;
  final TipoSolicitud tipo;
  final String entidadId;

  /// Borrador de la entidad a crear/afectar (para `crear_contrato`: plan,
  /// fecha, día de pago, notas DEL CONTRATO…). NO lleva el motivo/notas de la
  /// solicitud: eso son columnas desde 0222.
  final Map<String, dynamic> datos;

  /// Motivo de la solicitud, ya resuelto: columna `motivo` (0222) o, si la fila
  /// todavía no la tiene, lo que haya en `datos`. Vacío ⇒ null.
  final String? motivo;

  /// Detalle escrito por el solicitante, resuelto igual que [motivo].
  final String? notas;

  /// Deuda cobrable calculada al momento de PEDIR (0229). Solo la traen las
  /// solicitudes de suspender/cancelar creadas desde v0.31.29 — las anteriores
  /// quedan en null y la tarjeta se muestra igual, sin la comparación.
  final DeudaSnapshot? deudaSnapshot;

  final EstadoSolicitud estado;
  final String? aprobadorId;
  final String? motivoRechazo;
  final String? solicitanteLabel;
  final String createdAt;
  final String ocurridoEn;
  final String? resolvedAt;

  bool get esPendiente => estado == EstadoSolicitud.pendiente;

  factory SolicitudAccion.fromRow(Map<String, dynamic> row) {
    final datos = _parseDatos(row['datos']);
    final (:motivo, :notas) =
        _resolverMotivoNotas(row['motivo'], row['notas'], datos);
    return SolicitudAccion(
      id: row['id'] as String,
      tenantId: row['tenant_id'] as String,
      solicitanteId: row['solicitante_id'] as String,
      tipo: _parseTipo(row['tipo'] as String),
      entidadId: row['entidad_id'] as String,
      datos: datos,
      motivo: motivo,
      notas: notas,
      deudaSnapshot: DeudaSnapshot.decode(row['deuda_snapshot'] as String?),
      estado: _parseEstado(row['estado'] as String),
      aprobadorId: row['aprobador_id'] as String?,
      motivoRechazo: row['motivo_rechazo'] as String?,
      solicitanteLabel: row['solicitante_label'] as String?,
      createdAt: row['created_at'] as String,
      ocurridoEn: row['ocurrido_en'] as String,
      resolvedAt: row['resolved_at'] as String?,
    );
  }

  String get tipoLabel => tipoLabelDe(tipo);

  /// Version estatica: la usan quienes tienen el enum pero todavia no la fila
  /// (el helper que ARMA la solicitud). Antes cada uno tenia su propia copia
  /// del switch y agregar un tipo obligaba a acordarse de las tres.
  static String tipoLabelDe(TipoSolicitud tipo) {
    switch (tipo) {
      case TipoSolicitud.crearContrato:
        return 'Crear contrato';
      case TipoSolicitud.cancelarContrato:
        return 'Cancelar contrato';
      case TipoSolicitud.suspenderContrato:
        return 'Suspender contrato';
      case TipoSolicitud.reactivarContrato:
        return 'Reactivar contrato';
      case TipoSolicitud.desactivarCliente:
        return 'Desactivar cliente';
      case TipoSolicitud.cambiarPlan:
        return 'Cambiar plan';
      case TipoSolicitud.desconocido:
        return 'Solicitud no reconocida';
    }
  }

  String get estadoLabel {
    switch (estado) {
      case EstadoSolicitud.pendiente:
        return 'Pendiente';
      case EstadoSolicitud.aprobada:
        return 'Aprobada';
      case EstadoSolicitud.rechazada:
        return 'Rechazada';
    }
  }

  String get tipoDb => tipoDbDe(tipo);

  /// Version estatica: la usa el repo al persistir.
  static String tipoDbDe(TipoSolicitud tipo) {
    switch (tipo) {
      case TipoSolicitud.crearContrato:
        return 'crear_contrato';
      case TipoSolicitud.cancelarContrato:
        return 'cancelar_contrato';
      case TipoSolicitud.suspenderContrato:
        return 'suspender_contrato';
      case TipoSolicitud.reactivarContrato:
        return 'reactivar_contrato';
      case TipoSolicitud.desactivarCliente:
        return 'desactivar_cliente';
      case TipoSolicitud.cambiarPlan:
        return 'cambiar_plan';
      case TipoSolicitud.desconocido:
        // No se persiste nunca: solo existe al LEER un tipo que esta version
        // no conoce. Si llega acá es un bug de llamada, no un dato.
        throw StateError('TipoSolicitud.desconocido no es persistible');
    }
  }

  static TipoSolicitud _parseTipo(String s) {
    switch (s) {
      case 'crear_contrato':
        return TipoSolicitud.crearContrato;
      case 'cancelar_contrato':
        return TipoSolicitud.cancelarContrato;
      case 'suspender_contrato':
        return TipoSolicitud.suspenderContrato;
      case 'reactivar_contrato':
        return TipoSolicitud.reactivarContrato;
      case 'desactivar_cliente':
        return TipoSolicitud.desactivarCliente;
      case 'cambiar_plan':
        return TipoSolicitud.cambiarPlan;
      default:
        // NO cae a crearContrato: una solicitud de un tipo futuro se mostraba
        // como "Crear contrato" y su ejecutor intentaba crear uno con datos
        // ajenos. Degradar acá deja que la app vieja la VEA sin poder actuarla.
        return TipoSolicitud.desconocido;
    }
  }

  static EstadoSolicitud _parseEstado(String s) {
    switch (s) {
      case 'aprobada':
        return EstadoSolicitud.aprobada;
      case 'rechazada':
        return EstadoSolicitud.rechazada;
      default:
        return EstadoSolicitud.pendiente;
    }
  }

  /// ÚNICO lugar donde vive la cadena de fallback del motivo/notas.
  ///
  /// Desde 0222 el dato canónico son las COLUMNAS `motivo`/`notas`. El JSON
  /// `datos` queda como red para las filas que todavía no las tienen: las
  /// creadas antes de la migración y las que sigan escribiendo los dispositivos
  /// que no actualizaron. Dos formatos históricos ahí adentro:
  ///
  ///  · v0.31.23 → `solicitud_motivo` / `solicitud_notas` (claves propias).
  ///  · v0.31.20 → `motivo` / `notas` sueltas. La `notas` legacy SOLO se toma
  ///    si viene acompañada del `motivo` legacy: en el formato nuevo `notas`
  ///    pertenece a la ENTIDAD (son las notas del contrato a crear) y leerlas
  ///    como notas de la solicitud repite el bug que 0222 vino a cerrar.
  static ({String? motivo, String? notas}) _resolverMotivoNotas(
    dynamic colMotivo,
    dynamic colNotas,
    Map<String, dynamic> datos,
  ) {
    final legacy = _textoONull(datos['motivo']);
    return (
      motivo: _textoONull(colMotivo) ??
          _textoONull(datos['solicitud_motivo']) ??
          legacy,
      notas: _textoONull(colNotas) ??
          _textoONull(datos['solicitud_notas']) ??
          (legacy != null ? _textoONull(datos['notas']) : null),
    );
  }

  /// Texto recortado, o null si no es String o quedó vacío (así el consumidor
  /// chequea `!= null` y no `!= null && isNotEmpty` en cada uso).
  static String? _textoONull(dynamic v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  static Map<String, dynamic> _parseDatos(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        // Doble-encoding: jsonb almacenó un string JSON en vez de un object.
        if (decoded is String) {
          final inner = jsonDecode(decoded);
          if (inner is Map<String, dynamic>) return inner;
        }
      } catch (_) {}
      return {};
    }
    return {};
  }
}
