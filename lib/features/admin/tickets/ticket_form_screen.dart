import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/form_dirty_provider.dart';
import '../../../data/utils/op_log.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../../data/utils/errores.dart';
import '../../shared/widgets/confirm_discard_dialog.dart';
import '../../shared/widgets/selector_buscable.dart';

/// Crear un ticket. El correlativo se computa cliente-side (MAX+1 por tenant);
/// el UNIQUE(tenant,correlativo) del server es la red dura. Al crear se registra
/// el evento `creado` (+ `asignado` si se asigna un técnico) en la bitácora.
class TicketFormScreen extends ConsumerStatefulWidget {
  const TicketFormScreen({super.key, this.clienteIdInicial});

  /// Cliente pre-seleccionado al abrir (ej. "generar orden de corte" desde la
  /// lista de mora). Carga su nombre y auto-selecciona el contrato si hay uno
  /// solo; el resto (tipo de corte, técnico) lo elige el admin.
  final String? clienteIdInicial;

  @override
  ConsumerState<TicketFormScreen> createState() => _TicketFormScreenState();
}

class _TicketFormScreenState extends ConsumerState<TicketFormScreen> {
  String? _tipoId;
  String? _tipoEfecto;
  String? _clienteId;
  String? _clienteNombre;
  String? _contratoId;
  String? _contratoLabel;
  String? _asignadoA;
  String? _incidenteId;
  String _prioridad = 'media';
  final _titulo = TextEditingController();
  final _descripcion = TextEditingController();
  final _tipoCtrl = TextEditingController();
  final _asignadoCtrl = TextEditingController();
  final _incidenteCtrl = TextEditingController();
  bool _guardando = false;
  bool _dirty = false;
  // Notifier capturado en initState (ref no es válido en dispose).
  late final StateController<bool> _formDirtyCtrl;

  @override
  void initState() {
    super.initState();
    _formDirtyCtrl = ref.read(formDirtyProvider.notifier);
    if (widget.clienteIdInicial != null) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _precargarCliente(widget.clienteIdInicial!));
    }
  }

  /// Pre-carga el cliente (nombre) y auto-selecciona su contrato si tiene uno.
  /// NO marca el form como dirty: es un valor inicial, no una edición del user.
  Future<void> _precargarCliente(String clienteId) async {
    final c = await ps.db
        .getOptional('SELECT nombre FROM clientes WHERE id = ?', [clienteId]);
    if (!mounted || c == null) return;
    setState(() {
      _clienteId = clienteId;
      _clienteNombre = c['nombre'] as String?;
    });
    final cons = await ps.db.getAll(
      '''SELECT ct.id, ct.codigo, ct.estado, pl.nombre AS plan
           FROM contratos ct LEFT JOIN planes pl ON pl.id = ct.plan_id
          WHERE ct.cliente_id = ?''',
      [clienteId],
    );
    if (mounted && cons.length == 1) {
      setState(() {
        _contratoId = cons.first['id'] as String;
        _contratoLabel = _contratoLabelDe(cons.first);
      });
    }
  }

  void _marcarDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    // Reset defensivo: el shell que watchea formDirtyProvider no debe ver dirty
    // tras desmontar (si no, el próximo sidebar-tap mostraría un dialog huérfano).
    _formDirtyCtrl.state = false;
    _titulo.dispose();
    _descripcion.dispose();
    _tipoCtrl.dispose();
    _asignadoCtrl.dispose();
    _incidenteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Sincroniza formDirtyProvider (lo watchea el shell para interceptar el
    // sidebar-tap) con _dirty, post-frame (no se puede notificar en build).
    if (ref.read(formDirtyProvider) != _dirty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _formDirtyCtrl.state = _dirty;
      });
    }
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await confirmDiscardChanges(context);
        if (confirm != true || !context.mounted) return;
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin/tickets');
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
        children: [
          // Tipo (define el SLA).
          TextField(
            controller: _tipoCtrl,
            readOnly: true,
            decoration: const InputDecoration(
              labelText: 'Tipo de ticket',
              hintText: 'Toca para elegir',
              suffixIcon: Icon(Icons.arrow_drop_down),
            ),
            onTap: _elegirTipo,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titulo,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Título'),
            onChanged: (_) => _marcarDirty(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descripcion,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration:
                const InputDecoration(labelText: 'Descripción (opcional)'),
            onChanged: (_) => _marcarDirty(),
          ),
          const SizedBox(height: 12),
          // Cliente (opcional: outage/instalación pre-contrato no lo tienen).
          InkWell(
            onTap: _elegirCliente,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Cliente (opcional)',
                suffixIcon: _clienteId != null
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _clienteId = null;
                          _clienteNombre = null;
                          _contratoId = null;
                          _contratoLabel = null;
                          _dirty = true;
                        }),
                      )
                    : const Icon(Icons.search),
              ),
              child: Text(_clienteNombre ?? 'Sin cliente',
                  style: _clienteNombre == null
                      ? TextStyle(color: Theme.of(context).colorScheme.outline)
                      : null),
            ),
          ),
          const SizedBox(height: 12),
          // Contrato (solo si hay cliente): vincula la orden de trabajo a un
          // servicio concreto → habilita las colas corte/reconexión/instalación.
          if (_clienteId != null) ...[
            InkWell(
              onTap: _elegirContrato,
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Contrato (opcional)',
                  helperText: 'Para órdenes de corte / reconexión / instalación',
                  suffixIcon: _contratoId != null
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() {
                            _contratoId = null;
                            _contratoLabel = null;
                            _dirty = true;
                          }),
                        )
                      : const Icon(Icons.search),
                ),
                child: Text(_contratoLabel ?? 'Sin contrato',
                    style: _contratoLabel == null
                        ? TextStyle(color: Theme.of(context).colorScheme.outline)
                        : null),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Aviso: una orden de corte/reconexión necesita el contrato para
          // alimentar las colas de facturación (suspender/reactivar).
          if ((_tipoEfecto == 'corte' || _tipoEfecto == 'reconexion') &&
              _contratoId == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: Theme.of(context).colorScheme.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _clienteId == null
                          ? 'Elegí el cliente y su contrato para que esta orden aparezca en las colas de facturación.'
                          : 'Elegí el contrato para que esta orden aparezca en las colas de facturación.',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.tertiary),
                    ),
                  ),
                ],
              ),
            ),
          DropdownButtonFormField<String>(
            initialValue: _prioridad,
            decoration: const InputDecoration(labelText: 'Prioridad'),
            onChanged: (v) => setState(() {
              _prioridad = v ?? 'media';
              _dirty = true;
            }),
            items: kTicketPrioridades
                .map((p) =>
                    DropdownMenuItem(value: p, child: Text(prioridadLabel(p))))
                .toList(),
          ),
          const SizedBox(height: 12),
          // Asignar a (opcional).
          TextField(
            controller: _asignadoCtrl,
            readOnly: true,
            decoration: const InputDecoration(
              labelText: 'Asignar a (opcional)',
              hintText: 'Toca para elegir',
              suffixIcon: Icon(Icons.arrow_drop_down),
            ),
            onTap: _elegirAsignado,
          ),
          const SizedBox(height: 12),
          // Incidente (opcional): sólo si hay outages abiertos para agrupar.
          TextField(
            controller: _incidenteCtrl,
            readOnly: true,
            decoration: const InputDecoration(
              labelText: 'Incidente / corte (opcional)',
              hintText: 'Toca para elegir',
              suffixIcon: Icon(Icons.arrow_drop_down),
            ),
            onTap: _elegirIncidente,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('Crear ticket'),
            onPressed: _guardando ? null : _guardar,
          ),
        ],
        ),
      ),
    );
  }

  Future<void> _elegirTipo() async {
    final rows = await ps.db.getAll(
        'SELECT id, nombre, efecto FROM ticket_tipos WHERE activo = 1 ORDER BY orden, nombre');
    if (!mounted) return;
    if (rows.isEmpty) {
      _snack('No hay tipos de ticket configurados.');
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Tipo de ticket',
      hint: 'Buscar...',
      opciones: [
        for (final r in rows)
          OpcionSelector(valor: r, nombre: r['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _tipoId = elegido['id'] as String;
      _tipoCtrl.text = elegido['nombre'] as String;
      _tipoEfecto = elegido['efecto'] as String?;
      _dirty = true;
    });
  }

  Future<void> _elegirAsignado() async {
    final rows = await ps.db.getAll(
        "SELECT id, nombre FROM cobradores WHERE activo = 1 AND rol IN ('tecnico','admin_tickets','admin') ORDER BY nombre");
    if (!mounted) return;
    // Fila-centinela para "sin asignar": así el null que devuelve elegir =
    // cancelar (no toca la selección actual) ≠ elegir explícitamente "ninguno".
    const ninguno = <String, dynamic>{'__ninguno__': true};
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Asignar a',
      hint: 'Buscar...',
      opciones: [
        const OpcionSelector(valor: ninguno, nombre: '— Sin asignar —'),
        for (final r in rows)
          OpcionSelector(valor: r, nombre: r['nombre'] as String),
      ],
    );
    if (elegido == null || !mounted) return; // canceló
    setState(() {
      _dirty = true;
      if (identical(elegido, ninguno)) {
        _asignadoA = null;
        _asignadoCtrl.text = '— Sin asignar —';
      } else {
        _asignadoA = elegido['id'] as String;
        _asignadoCtrl.text = elegido['nombre'] as String;
      }
    });
  }

  Future<void> _elegirIncidente() async {
    final rows = await ps.db.getAll(
        "SELECT id, titulo FROM incidentes WHERE estado = 'abierto' ORDER BY inicio DESC");
    if (!mounted) return;
    // Fila-centinela para "ninguno" (ver _elegirAsignado).
    const ninguno = <String, dynamic>{'__ninguno__': true};
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Incidente / corte',
      hint: 'Buscar...',
      opciones: [
        const OpcionSelector(valor: ninguno, nombre: '— Ninguno —'),
        for (final r in rows)
          OpcionSelector(valor: r, nombre: r['titulo'] as String),
      ],
    );
    if (elegido == null || !mounted) return; // canceló
    setState(() {
      _dirty = true;
      if (identical(elegido, ninguno)) {
        _incidenteId = null;
        _incidenteCtrl.text = '— Ninguno —';
      } else {
        _incidenteId = elegido['id'] as String;
        _incidenteCtrl.text = elegido['titulo'] as String;
      }
    });
  }

  Future<void> _elegirCliente() async {
    // Carga en memoria + buscador por tokens (SelectorBuscable), sin re-suscribir
    // un stream de PowerSync por cada tecla (AGENTS #9/#10).
    final rows = await ps.db.getAll(
      'SELECT id, nombre, codigo, cedula FROM clientes '
      'WHERE activo = 1 ORDER BY nombre',
    );
    if (!mounted) return;
    if (rows.isEmpty) {
      _snack('No hay clientes activos.');
      return;
    }
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Elegí un cliente',
      hint: 'Buscar por nombre, código o cédula',
      opciones: rows.map((c) {
        final cod = c['codigo'] as String?;
        return OpcionSelector<Map<String, dynamic>>(
          valor: c,
          nombre: c['nombre'] as String,
          subtitulo: (cod != null && cod.isNotEmpty) ? cod : null,
          textoBusqueda: '${c['codigo'] ?? ''} ${c['cedula'] ?? ''}',
        );
      }).toList(),
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _clienteId = elegido['id'] as String;
      _clienteNombre = elegido['nombre'] as String;
      _contratoId = null;
      _contratoLabel = null;
      _dirty = true;
    });
    // Conveniencia: si el cliente tiene EXACTAMENTE un contrato, pre-seleccionarlo.
    final cons = await ps.db.getAll(
      '''SELECT ct.id, ct.codigo, ct.estado, pl.nombre AS plan
           FROM contratos ct LEFT JOIN planes pl ON pl.id = ct.plan_id
          WHERE ct.cliente_id = ?''',
      [elegido['id']],
    );
    if (mounted && cons.length == 1) {
      setState(() {
        _contratoId = cons.first['id'] as String;
        _contratoLabel = _contratoLabelDe(cons.first);
      });
    }
  }

  Future<void> _elegirContrato() async {
    final cid = _clienteId;
    if (cid == null) return;
    final rows = await ps.db.getAll(
      '''SELECT ct.id, ct.codigo, ct.estado, pl.nombre AS plan
           FROM contratos ct
      LEFT JOIN planes pl ON pl.id = ct.plan_id
          WHERE ct.cliente_id = ?
          ORDER BY ct.created_at DESC''',
      [cid],
    );
    if (!mounted) return;
    if (rows.isEmpty) {
      _snack('El cliente no tiene contratos.');
      return;
    }
    const ninguno = <String, dynamic>{'__ninguno__': true};
    final elegido = await elegirConBuscador<Map<String, dynamic>>(
      context,
      titulo: 'Contrato del cliente',
      hint: 'Buscar...',
      opciones: [
        const OpcionSelector(valor: ninguno, nombre: '— Sin contrato —'),
        for (final r in rows)
          OpcionSelector(
            valor: r,
            nombre: _contratoLabelDe(r),
            subtitulo: r['estado'] as String?,
          ),
      ],
    );
    if (elegido == null || !mounted) return;
    setState(() {
      _dirty = true;
      if (identical(elegido, ninguno)) {
        _contratoId = null;
        _contratoLabel = null;
      } else {
        _contratoId = elegido['id'] as String;
        _contratoLabel = _contratoLabelDe(elegido);
      }
    });
  }

  String _contratoLabelDe(Map<String, dynamic> r) {
    final cod = (r['codigo'] as String?) ?? '';
    final plan = (r['plan'] as String?) ?? '';
    final l = [cod, plan].where((s) => s.isNotEmpty).join(' · ');
    return l.isEmpty ? 'Contrato' : l;
  }

  Future<void> _guardar() async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    if (_tipoId == null) {
      _snack('Elegí un tipo de ticket.');
      return;
    }
    if (_titulo.text.trim().isEmpty) {
      _snack('Poné un título.');
      return;
    }
    // Las órdenes de corte/reconexión necesitan el contrato para alimentar las
    // colas de facturación. Sin contrato, confirmar (puede ser un corte general
    // no atado a un servicio puntual).
    if ((_tipoEfecto == 'corte' || _tipoEfecto == 'reconexion') &&
        _contratoId == null) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Sin contrato vinculado'),
          content: Text(
              'Esta orden de ${_tipoEfecto == 'corte' ? 'corte' : 'reconexión'} '
              'no está vinculada a un contrato → no aparecerá en las colas de '
              'facturación (suspender / reactivar). ¿Crear igual?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: const Text('Crear igual')),
          ],
        ),
      );
      if (seguir != true || !mounted) return;
    }
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final hechoPor = me?.id;
    setState(() => _guardando = true);

    // puerto_id derivado del cliente (si tiene), para enganchar la red.
    String? puertoId;
    if (_clienteId != null) {
      final c = await ps.db.getOptional(
          'SELECT puerto_id FROM clientes WHERE id = ?', [_clienteId]);
      puertoId = c?['puerto_id'] as String?;
    }

    // Snapshot del checklist del tipo (template → [{texto, hecho:false}]). El
    // snapshot vive en el ticket: editar el template después NO toca este ticket.
    var checklistJson = '[]';
    final tipoRow = await ps.db.getOptional(
        'SELECT checklist_template FROM ticket_tipos WHERE id = ?', [_tipoId]);
    final tmplRaw = tipoRow?['checklist_template'];
    if (tmplRaw is String && tmplRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(tmplRaw);
        if (decoded is List) {
          checklistJson = jsonEncode([
            for (final p in decoded.whereType<String>())
              {'texto': p, 'hecho': false}
          ]);
        }
      } catch (_) {}
    }

    final maxRow = await ps.db.getAll(
        'SELECT COALESCE(MAX(correlativo), 0) + 1 AS n FROM tickets WHERE tenant_id = ?',
        [tenantId]);
    final correlativo = (maxRow.first['n'] as int?) ?? 1;
    final id = const Uuid().v4();
    final estado = _asignadoA != null ? 'asignado' : 'abierto';
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();

    // op_log (rework change log): actor + id de intención para registrar el alta
    // del ticket (1 entrada, snapshot inicial).
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();

    try {
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          '''INSERT INTO tickets
             (id, tenant_id, correlativo, tipo_id, cliente_id, contrato_id,
              puerto_id, incidente_id, titulo, descripcion, estado, prioridad,
              asignado_a, creado_por, created_at, ocurrido_en, checklist)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            id, tenantId, correlativo, _tipoId, _clienteId, _contratoId, puertoId,
            _incidenteId, _titulo.text.trim(),
            _descripcion.text.trim().isEmpty ? null : _descripcion.text.trim(),
            estado, _prioridad, _asignadoA, hechoPor, now, ocurrido, checklistJson,
          ],
        );
        final despues =
            (await tx.getAll('SELECT * FROM tickets WHERE id = ?', [id])).first;
        await OpLog.escribirCambioEntidad(tx,
            tenantId: tenantId, opId: opId, entidad: 'tickets', entidadId: id,
            antes: const {}, despues: despues, actor: actor,
            ocurridoEn: DateTime.parse(ocurrido));
      });
      if (mounted) {
        // Reset dirty PRE-pop: el PopScope (canPop:!_dirty) no debe interceptar
        // el cierre tras guardar OK.
        _dirty = false;
        _formDirtyCtrl.state = false;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ticket ${ticketCodigo(correlativo)} creado')));
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin/tickets');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        _snack(mensajeErrorHumano(e));
      }
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}

