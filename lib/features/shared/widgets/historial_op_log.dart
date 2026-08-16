import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../data/models/pago.dart' show MetodoPago, Moneda;
import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log_campos.dart';
import '../../../powersync/db.dart' as ps;

/// Historial de cambios UNIFICADO (rework change log — CHANGELOG-REWORK.md).
/// Lee `op_log`: UNA entrada por intención del usuario sobre ESTE objeto,
/// scoped a sus atributos. Es el MISMO componente para toda la app — se
/// instancia con la entidad (tabla) y el id del objeto.
///
/// Solo admin/admin_cobranza/super sincronizan `op_log` → para cobrador/técnico
/// muestra "Sin movimientos". Ordena por fecha/hora (device-time) desc.
class HistorialOpLog extends ConsumerStatefulWidget {
  const HistorialOpLog({
    super.key,
    required this.entidad,
    required this.entidadId,
  });

  /// Tabla del objeto: 'cuotas' | 'contratos' | 'clientes' | ...
  final String entidad;

  /// PK del objeto. Si es null, muestra el historial de TODA la entidad (todos
  /// los objetos de esa tabla) — útil para un log global (ej. configuración).
  final String? entidadId;

  @override
  ConsumerState<HistorialOpLog> createState() => _HistorialOpLogState();
}

class _HistorialOpLogState extends ConsumerState<HistorialOpLog> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(HistorialOpLog old) {
    super.didUpdateWidget(old);
    if (old.entidad != widget.entidad || old.entidadId != widget.entidadId) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    const cols = 'SELECT id, op_id, tipo_op, entidad, entidad_id, actor_label, '
        'accion, diff, ocurrido_en, created_at FROM op_log WHERE entidad = ?';
    const orden = ' ORDER BY COALESCE(ocurrido_en, created_at) DESC';
    // entidadId null → historial de TODA la entidad (log global).
    if (widget.entidadId == null) {
      return ps.db.watch('$cols$orden', parameters: [widget.entidad]);
    }
    return ps.db.watch(
      '$cols AND entidad_id = ?$orden',
      parameters: [widget.entidad, widget.entidadId],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Cold-start (#7): recrear el stream al recrearse la DB (cambio de usuario
    // o schema) para no quedar leyendo una conexión cerrada.
    ref.listen(dbEpochProvider, (_, __) {
      if (mounted) setState(() => _stream = _buildStream());
    });

    // Override del super_admin de qué campos mostrar por operación (panel
    // OpLogCamposScreen). Vacío = defaults del catálogo. Watch → re-render vivo.
    final camposOverride = ref.watch(appSettingsProvider).opLogCamposOverride;

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No se pudo cargar el historial.'),
          );
        }
        final rows = snap.data ?? const <Map<String, dynamic>>[];
        if (rows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: Text('Sin movimientos')),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) =>
              _OpLogTile(row: rows[i], camposOverride: camposOverride),
        );
      },
    );
  }
}

class _OpLogTile extends StatelessWidget {
  const _OpLogTile({required this.row, required this.camposOverride});
  final Map<String, dynamic> row;
  final Map<String, List<String>> camposOverride;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diff = _decodeDiff(row['diff']);
    final resumen =
        (diff['resumen'] as Map?)?.cast<String, dynamic>() ?? const {};
    final campos = ((diff['campos'] as List?) ?? const [])
        .cast<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

    final v = _verbo(
      row['tipo_op'] as String?,
      row['accion'] as String?,
      resumen,
    );
    final subtitulo = _subtitulo(row, resumen);
    final titulo = Text(v.titulo,
        style: const TextStyle(fontWeight: FontWeight.w700));
    final sub = Text(subtitulo, style: TextStyle(color: scheme.onSurfaceVariant));
    final icono = Icon(v.icono, color: v.color);

    final filas = _detalleFilas(context, row['entidad'] as String?,
        row['tipo_op'] as String?, campos, resumen);
    final hijo = filas.isEmpty
        ? ListTile(dense: true, leading: icono, title: titulo, subtitle: sub)
        : ExpansionTile(
            leading: icono,
            title: titulo,
            subtitle: sub,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: filas,
          );

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: v.color, width: 5)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(color: Colors.transparent, child: hijo),
      ),
    );
  }

  Widget _filaCampo(BuildContext context, Map<String, dynamic> c) {
    final scheme = Theme.of(context).colorScheme;
    final campo = c['campo'] as String? ?? '';
    final antes = _fmtValor(campo, c['antes']);
    final despues = _fmtValor(campo, c['despues']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(opLogCampoLabel(campo),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: antes,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const TextSpan(text: '  →  '),
              TextSpan(
                  text: despues,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ])),
          ),
        ],
      ),
    );
  }

  /// Filas del detalle según la config de campos visibles (defaults
  /// universales; el override del super_admin se enchufa en Fase B). Para
  /// operaciones sin config fija (ediciones de entidad) muestra todos los
  /// campos que cambiaron.
  List<Widget> _detalleFilas(BuildContext ctx, String? entidad, String? tipoOp,
      List<Map<String, dynamic>> campos, Map<String, dynamic> resumen) {
    final visibles = opLogCamposVisibles(entidad, override: camposOverride);
    if (visibles == null) {
      return [for (final c in campos) _filaCampo(ctx, c)];
    }
    final rows = <Widget>[];
    for (final key in visibles) {
      final campo = _buscarCampo(campos, key);
      if (campo != null) {
        rows.add(_filaCampo(ctx, campo)); // antes → después
      } else if (resumen.containsKey(key) &&
          !_resumenVacio(key, resumen) &&
          !(key == 'monto' && _montoOcultoEnResumen.contains(tipoOp))) {
        rows.add(_filaResumen(ctx, key, resumen)); // valor simple
      }
    }
    return rows;
  }

  Map<String, dynamic>? _buscarCampo(
      List<Map<String, dynamic>> campos, String key) {
    for (final c in campos) {
      if (c['campo'] == key) return c;
    }
    return null;
  }

  /// Un campo del resumen está "vacío" (no se muestra) cuando no aporta: vuelto
  /// 0, entregado igual al aplicado sin vuelto, o motivo en blanco.
  bool _resumenVacio(String key, Map<String, dynamic> r) {
    final v = r[key];
    if (v == null) return true;
    if (key == 'vuelto') return v is num && v == 0;
    if (key == 'entregado') {
      final sinVuelto = r['vuelto'] is num ? r['vuelto'] == 0 : true;
      return sinVuelto && v == r['monto'];
    }
    if (key == 'motivo' || key == 'notas') return '$v'.trim().isEmpty;
    return false;
  }

  Widget _filaResumen(BuildContext ctx, String key, Map<String, dynamic> r) {
    final scheme = Theme.of(ctx).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(opLogCampoLabel(key),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(_fmtResumen(key, r),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  String _fmtResumen(String key, Map<String, dynamic> r) {
    final v = r[key];
    switch (key) {
      case 'monto':
      case 'vuelto':
        return v is num ? Fmt.cordobas(v) : '$v';
      case 'entregado':
        if (v is num) {
          return Moneda.fromString('${r['moneda'] ?? 'NIO'}') == Moneda.usd
              ? 'US\$${v.toStringAsFixed(2)}'
              : Fmt.cordobas(v);
        }
        return '$v';
      case 'metodo':
        return MetodoPago.fromString('$v').label;
      case 'fecha_pago':
        final d = DateTime.tryParse('$v');
        return d != null ? Fmt.fechaCorta(d) : '$v';
      default:
        return '$v';
    }
  }
}

/// Verbo + ícono + color por tipo de operación (extensible para features nuevas).
class _VerboInfo {
  const _VerboInfo(this.titulo, this.icono, this.color);
  final String titulo;
  final IconData icono;
  final Color color;
}

_VerboInfo _verbo(String? tipoOp, String? accion, Map<String, dynamic> resumen) {
  final monto = resumen['monto'];
  final montoTxt = monto is num ? Fmt.cordobas(monto) : '';
  switch (tipoOp) {
    case 'cobro':
    case 'cobro_multiple':
      return _VerboInfo('Cobró $montoTxt'.trim(), Icons.payments,
          const Color(0xFF1D9E75));
    case 'anulacion_pago':
      return const _VerboInfo('Pago anulado', Icons.money_off_csred,
          Color(0xFFD4537E));
    case 'edicion_pago':
      return const _VerboInfo('Pago editado', Icons.edit_note,
          Color(0xFF378ADD));
    case 'cambio_fecha':
      return const _VerboInfo('Cambio de fecha de pago', Icons.event_repeat,
          Color(0xFF378ADD));
    case 'suspension':
      return const _VerboInfo('Contrato suspendido', Icons.pause_circle,
          Color(0xFFD85A30));
    case 'cancelacion':
      return const _VerboInfo('Contrato cancelado', Icons.cancel,
          Color(0xFFD4537E));
    case 'reactivacion':
      return const _VerboInfo('Contrato reactivado', Icons.play_circle,
          Color(0xFF1D9E75));
    case 'revertir_suspension':
      return const _VerboInfo('Revirtió la suspensión', Icons.undo,
          Color(0xFF378ADD));
    case 'revertir_cancelacion':
      return const _VerboInfo('Revirtió la cancelación', Icons.undo,
          Color(0xFF378ADD));
    case 'aplicar_credito':
      return _VerboInfo('Crédito aplicado $montoTxt'.trim(), Icons.savings,
          const Color(0xFF1D9E75));
    case 'disposicion_excedente':
      return _VerboInfo('Crédito por excedente $montoTxt'.trim(),
          Icons.account_balance_wallet, const Color(0xFF7F77DD));
    case 'cargo_cuota':
      return _VerboInfo('Cargo aplicado $montoTxt'.trim(),
          Icons.add_circle_outline, const Color(0xFFD85A30));
    case 'cobro_puntual':
      return const _VerboInfo('Cobro puntual creado', Icons.point_of_sale,
          Color(0xFF0F766E));
    case 'descuento_cuota':
      return _VerboInfo('Descuento aplicado $montoTxt'.trim(), Icons.percent,
          const Color(0xFF1D9E75));
    case 'quitar_cargo_cuota':
      return const _VerboInfo('Cargo/descuento quitado', Icons.remove_circle_outline,
          Color(0xFFD4537E));
    case 'foto_cliente_alta':
      return const _VerboInfo('Foto agregada', Icons.add_photo_alternate,
          Color(0xFF7F77DD));
    case 'foto_cliente_baja':
      return const _VerboInfo('Foto eliminada', Icons.no_photography,
          Color(0xFFD4537E));
    case 'alta_entidad':
      return const _VerboInfo('Creado', Icons.add_circle, Color(0xFF7F77DD));
    case 'baja_entidad':
      return const _VerboInfo('Eliminado', Icons.delete, Color(0xFFD4537E));
    case 'edicion_entidad':
    default:
      switch (accion) {
        case 'create':
          return const _VerboInfo('Creado', Icons.add_circle, Color(0xFF7F77DD));
        case 'delete':
          return const _VerboInfo('Eliminado', Icons.delete, Color(0xFFD4537E));
        default:
          return const _VerboInfo('Actualizado', Icons.edit, Color(0xFF378ADD));
      }
  }
}

String _subtitulo(Map<String, dynamic> row, Map<String, dynamic> resumen) {
  final fecha = _fechaHoraAmPm(
      (row['ocurrido_en'] ?? row['created_at']) as String?);
  final actor = row['actor_label'] as String? ?? '';
  final recibo = resumen['recibo'];
  final motivo = resumen['motivo'];
  final extra = recibo != null
      ? ' · Recibo $recibo'
      : (motivo is String && motivo.isNotEmpty ? ' · $motivo' : '');
  return '$fecha · $actor$extra';
}

final _fechaAmPm = DateFormat('d MMM y', 'es_NI');

/// Formatea un ISO UTC a "19 jun 2026 · 2:32 PM" (hora local del device, AM/PM).
String _fechaHoraAmPm(String? iso) {
  if (iso == null) return '';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final h24 = dt.hour;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final mm = dt.minute.toString().padLeft(2, '0');
  return '${_fechaAmPm.format(dt)} · $h12:$mm $ampm';
}

String _fmtValor(String campo, dynamic v) {
  if (v == null) return '—';
  if (campo == 'saldo' || campo == 'monto' || campo.contains('monto')) {
    if (v is num) return Fmt.cordobas(v);
  }
  if (campo == 'estado') return _estadoLabel(v.toString());
  if (campo == 'metodo') return MetodoPago.fromString(v.toString()).label;
  if (campo == 'fecha_vencimiento' ||
      campo == 'fecha_fin' ||
      campo == 'fecha_pago') {
    final d = DateTime.tryParse(v.toString());
    if (d != null) return Fmt.fechaCorta(d);
  }
  // SQLite no tiene bool → las columnas boolean llegan como int 1/0. Sin esto
  // el historial mostraba "Activo: 1 → 0" en vez de "Sí → No" (audit Fase 3).
  // Acotado a los campos boolean CONOCIDOS para no confundir int legítimos
  // (p.ej. `orden`) que casualmente valgan 0/1.
  if (_camposBool.contains(campo)) {
    final b = v is bool ? v : (v == 1 || v == '1');
    return b ? 'Sí' : 'No';
  }
  if (v is bool) return v ? 'Sí' : 'No';
  return v.toString();
}

// Campos boolean conocidos (SQLite los devuelve como int 1/0). Ver _fmtValor.
const _camposBool = {
  'activo', 'activa', 'es_serializado', 'maneja_decimal', 'puede_cambiar_fecha',
};

// tipo_op cuyo monto NO se muestra como fila del resumen: cobro/cobro_multiple
// ya lo llevan en el título ("Cobró C$X") y la anulación se verificó en vivo sin
// esa fila. edicion_pago lo muestra como CAMPO (antes→después) y cambio_fecha
// como fila del resumen (el puente), así que esos SÍ lo renderizan.
// aplicar_credito/descuento_cuota/cargo_cuota TAMBIÉN llevan el monto en el
// título ("Descuento aplicado C$X") → sin esto salía duplicado como fila (F3).
const _montoOcultoEnResumen = {
  'cobro', 'cobro_multiple', 'anulacion_pago',
  'aplicar_credito', 'descuento_cuota', 'cargo_cuota',
};

const _estados = {
  'pendiente': 'Pendiente',
  'parcial': 'Parcial',
  'pagada': 'Pagada',
  'anulada': 'Anulada',
  'vencida': 'Vencida',
  'en_gracia': 'En gracia',
  'hoy': 'Vence hoy',
  'activo': 'Activo',
  'suspendido': 'Suspendido',
  'cancelado': 'Cancelado',
};

String _estadoLabel(String s) {
  final known = _estados[s];
  if (known != null) return known;
  if (s.isEmpty) return s;
  // Estados de ticket/incidente multi-palabra (en_progreso, en_espera…) no
  // están en el map → reemplazar '_' por espacio ANTES de capitalizar, si no
  // salía "En_progreso" con guión literal (audit Fase 3).
  final clean = s.replaceAll('_', ' ');
  return '${clean[0].toUpperCase()}${clean.substring(1)}';
}

/// Decodifica el `diff`. OJO: PowerSync **re-serializa** una columna `text` que
/// contiene JSON al re-sincronizarla (echo del server) → el valor local vuelve
/// DOBLE-encodeado (`"\"{...}\""`), aunque en el server quede single. Por eso
/// decodificamos en bucle hasta obtener un Map (sirve para single, double o un
/// Map ya parseado), con guard para no loopear.
Map<String, dynamic> _decodeDiff(dynamic raw) {
  dynamic m = raw;
  var guard = 0;
  while (m is String && guard++ < 4) {
    final s = m.trim();
    if (s.isEmpty) return const {};
    try {
      m = jsonDecode(s);
    } catch (_) {
      return const {};
    }
  }
  if (m is Map) return Map<String, dynamic>.from(m);
  return const {};
}
