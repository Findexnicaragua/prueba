import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../../data/utils/errores.dart';
import '../../shared/widgets/selector_buscable.dart';

/// Cantidad sin decimales superfluos (entero si es redondo). Espeja `_fmtCant`
/// de inventario_screen (privado allá).
String _fmtCant(num n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();

/// Materiales consumidos en un ticket (Fase 3C). Lista lo registrado + permite
/// agregar (serial de la custodia o granel). El descuento de stock lo hace el
/// trigger server-side (0106); acá sólo se inserta la fila `ticket_materiales`
/// (+ un evento 'material' en la bitácora). Gateado por el módulo `inventario`.
///
/// `tecnicoMode`: el origen del material es SU custodia (`inv_ubicaciones`
/// tipo='tecnico', cobrador_id = él); el admin elige cualquier ubicación.
class TicketMaterialesWidget extends ConsumerStatefulWidget {
  const TicketMaterialesWidget({
    super.key,
    required this.ticketId,
    required this.tenantId,
    this.clienteId,
    this.tecnicoMode = false,
    this.canEdit = true,
  });
  final String ticketId;
  final String tenantId;

  /// false = el rol ve los materiales pero no los toca (coordinador, audit
  /// 2026-07-26). Su policy `tm_insert` pide `is_ticket_staff()`, que él no es:
  /// sin esto el botón escribía local y el server lo rechazaba al sincronizar.
  final bool canEdit;

  /// Cliente del ticket. Si es null (outage), NO se permite consumir equipos
  /// serializados (no se puede instalar un serial "a nadie"); sólo granel.
  final String? clienteId;
  final bool tecnicoMode;

  @override
  ConsumerState<TicketMaterialesWidget> createState() =>
      _TicketMaterialesWidgetState();
}

class _TicketMaterialesWidgetState
    extends ConsumerState<TicketMaterialesWidget> {
  late final Stream<List<Map<String, dynamic>>> _materiales;

  @override
  void initState() {
    super.initState();
    _materiales = ps.db.watch('''
      SELECT tm.id, tm.cantidad, tm.serial_id, tm.costo_unit_snapshot,
             p.nombre AS producto, p.unidad, s.serial
        FROM ticket_materiales tm
   LEFT JOIN inv_productos p ON p.id = tm.producto_id
   LEFT JOIN inv_seriales  s ON s.id = tm.serial_id
       WHERE tm.ticket_id = ?
       ORDER BY COALESCE(tm.ocurrido_en, tm.created_at) DESC
    ''', parameters: [widget.ticketId]);
  }

  @override
  Widget build(BuildContext context) {
    // Sólo si el tenant tiene el módulo inventario encendido (además de tickets).
    final modulos = ref.watch(modulosHabilitadosProvider).valueOrNull;
    if (modulos == null || !modulos.contains('inventario')) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.inventory_2_outlined, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('Materiales',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (widget.canEdit && !ref.watch(soloLecturaProvider))
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Agregar'),
                    onPressed: _agregar,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _materiales,
              initialData: const [],
              builder: (context, snap) {
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('Sin materiales registrados.',
                        style: TextStyle(color: scheme.outline)),
                  );
                }
                return Column(
                  children: [
                    for (final m in rows)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(
                            m['serial_id'] != null
                                ? Icons.qr_code_2
                                : Icons.category_outlined,
                            color: scheme.outline,
                            size: 20),
                        title: Text(m['producto'] as String? ?? '—'),
                        subtitle: Text(m['serial_id'] != null
                            ? 'Serial: ${m['serial'] ?? '—'}'
                            : 'Cantidad: ${_fmtCant((m['cantidad'] as num?)?.toDouble() ?? 0)} ${m['unidad'] ?? ''}'),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _agregar() async {
    if (!widget.canEdit) return;
    // Consumo de material atribuido al usuario (op_log + descuenta stock) →
    // bloqueado al impersonar (audit 2026-06-30).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    // 1. Resolver las ubicaciones-origen candidatas según el rol.
    final List<Map<String, dynamic>> ubicaciones;
    if (widget.tecnicoMode) {
      final yo = ref.read(cobradorActualProvider).valueOrNull?.id;
      ubicaciones = await ps.db.getAll(
        'SELECT id, nombre FROM inv_ubicaciones '
        "WHERE cobrador_id = ? AND tipo = 'tecnico' AND activa = 1 ORDER BY nombre",
        [yo],
      );
      if (ubicaciones.isEmpty) {
        _snack('No tenés una custodia de inventario asignada. '
            'Pedile al admin que te cree una ubicación tipo "técnico".');
        return;
      }
    } else {
      ubicaciones = await ps.db.getAll(
        'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre',
      );
      if (ubicaciones.isEmpty) {
        _snack('No hay ubicaciones de inventario. Creá una en Inventario.');
        return;
      }
    }
    if (!mounted) return;

    final elegido = await showModalBottomSheet<_MaterialElegido>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AgregarMaterialSheet(
          ubicaciones: ubicaciones, permiteSerial: widget.clienteId != null),
    );
    if (elegido == null) return;

    // 2. Insertar el material + evento de bitácora (el trigger descuenta stock).
    // tenant_id = el del ticket (autoritativo, == current_tenant_id() del writer).
    final tenantId = widget.tenantId;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final hechoPor = me?.id;
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    // op_log: el material consumido es hijo del ticket → entrada scopeada al
    // ticket con la descripción legible (la misma que va a la bitácora).
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    try {
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          // `tipo` va EXPLÍCITO, no por el DEFAULT de Postgres (0205): el SQLite
          // local no tiene defaults, así que omitirlo dejaría NULL y el conector
          // sube la fila entera con ese NULL → la violaría el NOT NULL y se
          // trabaría la cola de upload. (Las apps viejas, cuyo schema no tiene la
          // columna, no la mandan y sí caen en el DEFAULT: ese caso es seguro.)
          '''INSERT INTO ticket_materiales
             (id, tenant_id, ticket_id, tipo, producto_id, serial_id, cantidad,
              ubicacion_origen_id, costo_unit_snapshot, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, ?, 'consumo', ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, widget.ticketId, elegido.productoId,
            elegido.serialId, elegido.cantidad, elegido.ubicacionId,
            elegido.costo, hechoPor, ocurrido, now,
          ],
        );
        await tx.execute(
          '''INSERT INTO ticket_eventos
             (id, tenant_id, ticket_id, tipo_evento, comentario, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, ?, 'material', ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, widget.ticketId,
            elegido.descripcion, hechoPor, ocurrido, now,
          ],
        );
        await OpLog.escribir(
          tx,
          tenantId: tenantId,
          opId: opId,
          tipoOp: 'alta_entidad',
          entidad: 'tickets',
          entidadId: widget.ticketId,
          accion: 'create',
          diff: {
            'campos': const [],
            'resumen': {'motivo': 'Material consumido: ${elegido.descripcion}'},
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurrido),
        );
        // Si el material es un serial, dejar rastro en la ficha del EQUIPO
        // también (su historial lee op_log de entidad='inv_seriales'). El
        // estado 'instalado'+cliente lo pone un trigger server al sincronizar,
        // así que acá va como INTENCIÓN (mismo modelo append-only que el resto
        // del op_log; comparte el op_id de esta consumición).
        if (elegido.serialId != null) {
          await OpLog.escribir(
            tx,
            tenantId: tenantId,
            opId: opId,
            tipoOp: 'edicion_entidad',
            entidad: 'inv_seriales',
            entidadId: elegido.serialId!,
            accion: 'update',
            diff: {
              'campos': const [],
              'resumen': {'motivo': 'Instalado en cliente vía ticket'},
            },
            actor: actor,
            ocurridoEn: DateTime.parse(ocurrido),
          );
        }
      });
      _snack('Material registrado. El stock se descuenta al sincronizar.');
    } catch (e) {
      _snack(mensajeErrorHumano(e));
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}

/// Equipos que el cliente tiene instalados, con la acción de retirarlos a
/// revisión desde la propia orden (0205).
///
/// Cierra el ciclo del material: hasta acá el técnico podía INSTALAR desde la
/// orden pero no DEVOLVER lo que desinstalaba, así que el retiro lo tenía que
/// recargar un admin después, de memoria — que es como el registro se despega
/// de la realidad.
///
/// NO escribe `inv_seriales`: el rol `tecnico` no tiene RLS de UPDATE sobre esa
/// tabla, así que una escritura directa se vería OK offline y la rechazaría el
/// server al sincronizar. Inserta una fila `ticket_materiales` con
/// `tipo='retiro'` —que su policy sí le permite— y el trigger SECURITY DEFINER
/// mueve el equipo a `en_revision`. Mismo camino que ya usa el consumo.
class TicketEquiposClienteWidget extends ConsumerStatefulWidget {
  const TicketEquiposClienteWidget({
    super.key,
    required this.ticketId,
    required this.tenantId,
    this.clienteId,
    this.canEdit = true,
  });
  final String ticketId;
  final String tenantId;

  /// Cliente del ticket. NULL (outage) → no hay equipos que retirar.
  final String? clienteId;

  /// false = ve qué tiene instalado el cliente pero no lo retira (coordinador).
  final bool canEdit;

  @override
  ConsumerState<TicketEquiposClienteWidget> createState() =>
      _TicketEquiposClienteWidgetState();
}

class _TicketEquiposClienteWidgetState
    extends ConsumerState<TicketEquiposClienteWidget> {
  late final Stream<List<Map<String, dynamic>>> _equipos;

  @override
  void initState() {
    super.initState();
    // El stream se crea acá (no en build) — regla #2 del checklist.
    //
    // El NOT IN da FEEDBACK INSTANTÁNEO offline: el cambio de estado del serial
    // lo hace el trigger del SERVER al sincronizar, así que sin esto el equipo
    // seguiría listado como instalado después de tocar "Retirar" y se tocaría
    // dos veces.
    //
    // Se excluye TODO retiro sin una reinstalación posterior, no solo los de
    // esta orden (backlog del audit 2026-07-26): acotarlo al ticket dejaba el
    // equipo visible en OTRA orden abierta del mismo cliente, y el segundo
    // retiro decía "Equipo retirado" para algo que el server ignora. La
    // condición de reinstalación evita esconderlo para siempre — es el mismo
    // patrón que usa la query de materiales disponibles con las devoluciones.
    _equipos = ps.db.watch('''
      SELECT s.id, s.serial, s.mac, s.producto_id, p.nombre AS producto
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
       WHERE s.cliente_id = ? AND s.estado = 'instalado'
         AND s.id NOT IN (
           SELECT tm.serial_id FROM ticket_materiales tm
            WHERE tm.serial_id IS NOT NULL AND tm.tipo = 'retiro'
              AND NOT EXISTS (
                SELECT 1 FROM inv_movimientos mv
                 WHERE mv.serial_id = tm.serial_id
                   AND mv.tipo IN ('asignacion', 'consumo')
                   AND COALESCE(mv.ocurrido_en, mv.created_at)
                       > COALESCE(tm.ocurrido_en, tm.created_at)))
       ORDER BY p.nombre, s.serial
    ''', parameters: [widget.clienteId ?? '']);
  }

  Future<void> _retirar(Map<String, dynamic> eq) async {
    if (!widget.canEdit || ref.read(soloLecturaProvider)) return;
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final serial = (eq['serial'] as String?) ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Retirar el equipo?'),
        content: Text('$serial sale del cliente y queda en revisión. '
            'En bodega deciden si vuelve a stock o va a descarte.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Retirar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final tenantId = widget.tenantId;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final now = DateTime.now().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = hechoPor != null
        ? await OpLog.actorDeUsuario(ps.db, hechoPor)
        : const OpLogActor.systemAdmin();
    try {
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          '''INSERT INTO ticket_materiales
             (id, tenant_id, ticket_id, tipo, producto_id, serial_id, cantidad,
              hecho_por, ocurrido_en, created_at)
             VALUES (?, ?, ?, 'retiro', ?, ?, 1, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, widget.ticketId, eq['producto_id'],
            eq['id'], hechoPor, ocurrido, now,
          ],
        );
        await tx.execute(
          '''INSERT INTO ticket_eventos
             (id, tenant_id, ticket_id, tipo_evento, comentario, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, ?, 'material', ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, widget.ticketId,
            'Retiró $serial → revisión', hechoPor, ocurrido, now,
          ],
        );
        // Rastro en la ficha del EQUIPO: su historial lee op_log de
        // entidad='inv_seriales'. Va como INTENCIÓN — el estado real lo pone el
        // trigger al sincronizar (mismo modelo que el consumo).
        await OpLog.escribir(
          tx,
          tenantId: tenantId,
          opId: opId,
          tipoOp: 'edicion_entidad',
          entidad: 'inv_seriales',
          entidadId: eq['id'] as String,
          accion: 'update',
          diff: {
            'campos': const [],
            'resumen': {'motivo': 'Retirado del cliente vía ticket → revisión'},
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurrido),
        );
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Equipo retirado. Pasa a revisión al sincronizar.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final modulos = ref.watch(modulosHabilitadosProvider).valueOrNull;
    if (modulos == null || !modulos.contains('inventario')) {
      return const SizedBox.shrink();
    }
    if (widget.clienteId == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _equipos,
      initialData: const [],
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        // Sin equipos instalados no se dibuja la tarjeta: en una instalación
        // nueva no hay nada que retirar y sería ruido en la pantalla.
        if (rows.isEmpty) return const SizedBox.shrink();
        final soloLectura =
            ref.watch(soloLecturaProvider) || !widget.canEdit;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.router_outlined, color: scheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Text('Equipos del cliente',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 4),
                ...rows.map((eq) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text((eq['producto'] as String?) ?? 'Equipo'),
                      subtitle: Text(
                        [
                          eq['serial'],
                          if ((eq['mac'] as String?)?.isNotEmpty ?? false)
                            eq['mac'],
                        ].whereType<String>().join(' · '),
                      ),
                      trailing: soloLectura
                          ? null
                          : TextButton(
                              onPressed: () => _retirar(eq),
                              child: const Text('Retirar'),
                            ),
                    )),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Resultado del sheet: qué material se consume.
class _MaterialElegido {
  const _MaterialElegido({
    required this.productoId,
    required this.serialId,
    required this.cantidad,
    required this.ubicacionId,
    required this.costo,
    required this.descripcion,
  });
  final String productoId;
  final String? serialId;
  final double cantidad;
  final String ubicacionId;
  final double? costo;
  final String descripcion; // para el evento de bitácora
}

/// Sheet para elegir el material: ubicación-origen + (Serial | Granel).
class _AgregarMaterialSheet extends StatefulWidget {
  const _AgregarMaterialSheet({
    required this.ubicaciones,
    required this.permiteSerial,
  });
  final List<Map<String, dynamic>> ubicaciones;
  final bool permiteSerial; // false = ticket sin cliente → sólo granel

  @override
  State<_AgregarMaterialSheet> createState() => _AgregarMaterialSheetState();
}

class _AgregarMaterialSheetState extends State<_AgregarMaterialSheet> {
  late String _ubicacionId;
  late bool _serial; // true = serializado, false = granel
  final _cantidadCtrl = TextEditingController(text: '1');
  final _ubicacionCtrl = TextEditingController();
  final _serialCtrl = TextEditingController();
  final _granelCtrl = TextEditingController();

  // Datos cargados según ubicación + modo.
  List<Map<String, dynamic>> _seriales = const [];
  List<Map<String, dynamic>> _granel = const [];
  String? _serialSel;
  String? _granelSel;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _ubicacionId = widget.ubicaciones.first['id'] as String;
    _ubicacionCtrl.text = widget.ubicaciones.first['nombre'] as String;
    // Sin cliente (outage) no se puede instalar un serial → arrancar en granel.
    _serial = widget.permiteSerial;
    // Rebuild al tipear la cantidad → el botón "Registrar" se habilita/deshabilita.
    _cantidadCtrl.addListener(() => setState(() {}));
    _recargar();
  }

  @override
  void dispose() {
    _cantidadCtrl.dispose();
    _ubicacionCtrl.dispose();
    _serialCtrl.dispose();
    _granelCtrl.dispose();
    super.dispose();
  }

  Future<void> _recargar() async {
    setState(() => _cargando = true);
    // Seriales en stock en la ubicación, EXCLUYENDO los consumidos por ticket
    // que AÚN no se reflejan en el estado (pendientes de sync) — evita el
    // doble-consumo offline del mismo serial (el trigger de descuento es
    // server-side 0106, así que local el estado sigue 'en_stock' hasta sincronizar).
    // OJO: el NOT IN debe scopearse al consumo NO devuelto: un equipo reusado
    // (instalado → devuelto a stock → reinstalar) tiene su fila vieja en
    // ticket_materiales (append-only) pero YA volvió a stock → si excluyéramos
    // todo el histórico quedaría invisible para siempre. Lo acotamos a los
    // consumos SIN una devolución posterior en el ledger (inv_movimientos).
    final seriales = await ps.db.getAll('''
      SELECT s.id, s.serial, s.producto_id, s.costo_ingreso, p.nombre AS producto
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
       WHERE s.ubicacion_id = ? AND s.estado = 'en_stock'
         AND s.id NOT IN (
           SELECT tm.serial_id FROM ticket_materiales tm
            WHERE tm.serial_id IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM inv_movimientos mv
                 WHERE mv.serial_id = tm.serial_id
                   AND mv.tipo = 'devolucion'
                   AND COALESCE(mv.ocurrido_en, mv.created_at)
                       > COALESCE(tm.ocurrido_en, tm.created_at)))
       ORDER BY p.nombre, s.serial
    ''', [_ubicacionId]);
    // Productos granel con stock > 0 en la ubicación (stock = Σdestino − Σorigen).
    final granel = await ps.db.getAll('''
      SELECT p.id, p.nombre, p.unidad, p.costo_promedio,
             COALESCE((
               SELECT SUM(CASE WHEN m.ubicacion_destino_id = ? THEN m.cantidad ELSE 0 END)
                    - SUM(CASE WHEN m.ubicacion_origen_id  = ? THEN m.cantidad ELSE 0 END)
                 FROM inv_movimientos m WHERE m.producto_id = p.id), 0) AS stock
        FROM inv_productos p
       WHERE p.es_serializado = 0 AND p.activo = 1
       ORDER BY p.nombre
    ''', [_ubicacionId, _ubicacionId]);
    final granelConStock =
        granel.where((g) => ((g['stock'] as num?) ?? 0) > 0).toList();
    if (!mounted) return;
    setState(() {
      _seriales = seriales;
      _granel = granelConStock;
      _serialSel = null;
      _granelSel = null;
      _serialCtrl.clear();
      _granelCtrl.clear();
      _cargando = false;
    });
  }

  // Las ubicaciones ya vienen resueltas de la DB en widget.ubicaciones
  // (inv_ubicaciones, filtradas por rol). Elegir una recarga el stock.
  Future<void> _elegirUbicacion() async {
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Desde la ubicación',
      hint: 'Buscar...',
      opciones: [
        for (final u in widget.ubicaciones)
          OpcionSelector(valor: u, nombre: u['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _ubicacionId = elegido['id'] as String;
      _ubicacionCtrl.text = elegido['nombre'] as String;
    });
    _recargar();
  }

  // Seriales en stock ya cargados por _recargar (excluyen los consumidos sin
  // sincronizar) → se eligen de la lista en memoria, no se re-consulta.
  Future<void> _elegirSerial() async {
    if (_seriales.isEmpty) return;
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Equipo (serial)',
      hint: 'Buscar...',
      opciones: [
        for (final s in _seriales)
          OpcionSelector(
              valor: s, nombre: '${s['producto']} · ${s['serial']}'),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _serialSel = elegido['id'] as String;
      _serialCtrl.text = '${elegido['producto']} · ${elegido['serial']}';
    });
  }

  // Productos granel con stock ya cargados por _recargar.
  Future<void> _elegirGranel() async {
    if (_granel.isEmpty) return;
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Producto',
      hint: 'Buscar...',
      opciones: [
        for (final g in _granel)
          OpcionSelector(
              valor: g,
              nombre:
                  '${g['nombre']} (stock ${_fmtCant((g['stock'] as num).toDouble())})'),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _granelSel = elegido['id'] as String;
      _granelCtrl.text =
          '${elegido['nombre']} (stock ${_fmtCant((elegido['stock'] as num).toDouble())})';
    });
  }

  void _confirmar() {
    if (_serial) {
      final s = _seriales.firstWhere((e) => e['id'] == _serialSel,
          orElse: () => const {});
      if (s.isEmpty) return;
      Navigator.pop(
        context,
        _MaterialElegido(
          productoId: s['producto_id'] as String,
          serialId: s['id'] as String,
          cantidad: 1,
          ubicacionId: _ubicacionId,
          costo: (s['costo_ingreso'] as num?)?.toDouble(),
          descripcion: 'Instaló ${s['producto']} (serial ${s['serial']})',
        ),
      );
    } else {
      final g = _granel.firstWhere((e) => e['id'] == _granelSel,
          orElse: () => const {});
      if (g.isEmpty) return;
      final cant = double.tryParse(_cantidadCtrl.text.replaceAll(',', '.'));
      if (cant == null || cant <= 0) return;
      Navigator.pop(
        context,
        _MaterialElegido(
          productoId: g['id'] as String,
          serialId: null,
          cantidad: cant,
          ubicacionId: _ubicacionId,
          costo: (g['costo_promedio'] as num?)?.toDouble(),
          descripcion:
              'Usó ${_fmtCant(cant)} ${g['unidad'] ?? ''} de ${g['nombre']}',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cantNum = double.tryParse(_cantidadCtrl.text.replaceAll(',', '.'));
    final puedeConfirmar = _serial
        ? _serialSel != null
        : (_granelSel != null && cantNum != null && cantNum > 0);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 0, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Agregar material',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            // Ubicación-origen (única para el técnico; lista para el admin).
            if (widget.ubicaciones.length > 1)
              TextField(
                controller: _ubicacionCtrl,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Desde la ubicación',
                  hintText: 'Toca para elegir',
                  isDense: true,
                  suffixIcon: Icon(Icons.arrow_drop_down),
                ),
                onTap: _elegirUbicacion,
              )
            else
              Text('Desde: ${widget.ubicaciones.first['nombre']}',
                  style: TextStyle(color: scheme.outline)),
            const SizedBox(height: 12),
            // Sin cliente (outage) no se ofrece "Serializado": no se puede
            // instalar un equipo a un ticket sin cliente.
            if (widget.permiteSerial)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Serializado'), icon: Icon(Icons.qr_code_2)),
                  ButtonSegment(value: false, label: Text('Granel'), icon: Icon(Icons.category_outlined)),
                ],
                selected: {_serial},
                onSelectionChanged: (s) => setState(() => _serial = s.first),
              )
            else
              Text('Ticket sin cliente: sólo material a granel.',
                  style: TextStyle(color: scheme.outline)),
            const SizedBox(height: 12),
            if (_cargando)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_serial) ...[
              if (_seriales.isEmpty)
                Text('No hay equipos serializados en stock en esta ubicación.',
                    style: TextStyle(color: scheme.outline))
              else
                TextField(
                  controller: _serialCtrl,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'Equipo (serial)',
                    hintText: 'Toca para elegir',
                    isDense: true,
                    suffixIcon: Icon(Icons.arrow_drop_down),
                  ),
                  onTap: _elegirSerial,
                ),
            ] else ...[
              if (_granel.isEmpty)
                Text('No hay productos a granel con stock en esta ubicación.',
                    style: TextStyle(color: scheme.outline))
              else ...[
                TextField(
                  controller: _granelCtrl,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'Producto',
                    hintText: 'Toca para elegir',
                    isDense: true,
                    suffixIcon: Icon(Icons.arrow_drop_down),
                  ),
                  onTap: _elegirGranel,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _cantidadCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Cantidad', isDense: true),
                ),
              ],
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('Registrar'),
              onPressed: puedeConfirmar ? _confirmar : null,
            ),
          ],
        ),
      ),
    );
  }
}
