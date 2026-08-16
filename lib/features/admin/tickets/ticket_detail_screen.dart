import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/cobro_puntual.dart';
import '../../../data/services/external_actions.dart';
import '../../../data/utils/cola_tecnico.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../data/utils/ubicacion_actual.dart';
import '../../../powersync/db.dart' as ps;
import '../../cobro/cobro_puntual_dialog.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import '../../shared/widgets/ticket_sla_countdown.dart';
import 'ticket_adjuntos_widget.dart';
import 'ticket_materiales_widget.dart';

/// Detalle de un ticket: header (estado/SLA/tipo/cliente/asignado), acciones de
/// transición de estado (válidas según el estado actual; el server re-valida),
/// reasignar, comentar, y la bitácora (`ticket_eventos`).
///
/// `tecnicoMode`: vista del técnico en campo (Fase 3B). Acota lo que se OFRECE —
/// sólo avanzar/pausar/resolver ([kEstadosDestinoTecnico]) y SIN reasignar. El
/// admin (modo normal) tiene todas las transiciones + reasignar.
class TicketDetailScreen extends ConsumerStatefulWidget {
  const TicketDetailScreen({
    super.key,
    required this.ticketId,
    this.tecnicoMode = false,
  });
  final String ticketId;
  final bool tecnicoMode;
  @override
  ConsumerState<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends ConsumerState<TicketDetailScreen> {
  /// El modo técnico ya recortaba las acciones de admin; el rol `lectura`
  /// (0198) se comporta igual pero sin poder tocar NADA. Se agrupan acá
  /// para no repetir la condición en cada botón.
  bool get _esSoloVista =>
      widget.tecnicoMode || ref.watch(soloLecturaProvider);

  /// No puede EDITAR EL TRABAJO en sí (audit 2026-07-26).
  ///
  /// `_esSoloVista` no alcanzaba: el coordinador no es técnico ni `lectura`, así
  /// que se le dibujaba la pantalla completa —comentar, adjuntar, tildar el
  /// checklist, cargar materiales, retirar equipos— y el server le rechazaba las
  /// SEIS cosas (`te_insert`, `ta_write`, `tm_insert` y el trigger de columnas
  /// piden roles que él no tiene). Offline eso se ve como que funcionó y falla
  /// recién al sincronizar, cuando ya se fue de la casa del cliente.
  ///
  /// El técnico sí comenta y adjunta, por eso NO se puede simplemente ampliar
  /// `_esSoloVista`: son dos conceptos distintos.
  bool get _noEditaTrabajo =>
      _esSoloVista ||
      (ref.watch(cobradorActualProvider).valueOrNull?.esCoordinador ?? false);
  /// Captura de GPS en curso (0204). Flag de estado en vez de un diálogo de
  /// carga: si el GPS falla, un `showDialog` dejaría la barrera pegada (#7).
  bool _marcandoUbicacion = false;

  /// Cola del técnico al que está asignada ESTA orden (0206).
  ///
  /// La lista ya no deja abrir una orden bloqueada, pero esto es la segunda
  /// barrera: por deep link o por el back-stack se puede llegar igual, y sin
  /// este chequeo el técnico podría resolver la #3 antes que la #1.
  ///
  /// Se resuelve el técnico con una subconsulta en vez de leer el provider, así
  /// el stream se arma en `initState` (regla #2) sin depender de que el rol ya
  /// haya cargado. Si la orden no está asignada, no hay cola y no hay bloqueo.
  late final Stream<List<Map<String, dynamic>>> _cola;

  /// Intentos de contacto registrados antes de cerrar la orden (0208).
  late final Stream<List<Map<String, dynamic>>> _intentos;
  late final Stream<List<Map<String, dynamic>>> _ticket;
  late final Stream<List<Map<String, dynamic>>> _eventos;
  late final Stream<List<Map<String, dynamic>>> _cobroTicket;
  final _comentario = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Intentos de contacto del call center antes de cerrar (0208).
    _intentos = ps.db.watch('''
      SELECT id, comentario, ocurrido_en, created_at
        FROM ticket_eventos
       WHERE ticket_id = ? AND tipo_evento = 'contacto'
       ORDER BY COALESCE(ocurrido_en, created_at) ASC
    ''', parameters: [widget.ticketId]);
    _cola = ps.db.watch('''
      SELECT id, estado, orden_cola, created_at
        FROM tickets
       WHERE estado IN ('abierto', 'asignado', 'en_progreso', 'reabierto')
         AND asignado_a IS NOT NULL
         AND asignado_a = (SELECT asignado_a FROM tickets WHERE id = ?)
    ''', parameters: [widget.ticketId]);
    _ticket = ps.db.watch('''
      SELECT t.*, tt.nombre AS tipo_nombre, tt.sla_horas,
             tt.precio AS tipo_precio, tt.efecto AS tipo_efecto,
             cl.nombre AS cliente_nombre, co.nombre AS asignado_nombre,
             inc.titulo AS incidente_titulo,
             ver.nombre AS verificado_por_nombre
        FROM tickets t
   LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
   LEFT JOIN clientes cl ON cl.id = t.cliente_id
   LEFT JOIN cobradores co ON co.id = t.asignado_a
   LEFT JOIN cobradores ver ON ver.id = t.verificado_por
   LEFT JOIN incidentes inc ON inc.id = t.incidente_id
       WHERE t.id = ?
    ''', parameters: [widget.ticketId]);
    // Cobro ligado a este ticket (cuota manual no anulada) — para mostrar
    // "Generar cobro" / "Continuar cobro" / "Cobrado" sin doble-cobrar (0173).
    _cobroTicket = ps.db.watch(
      'SELECT cu.id, cu.monto, cu.monto_pagado, r.id AS recibo_id '
      'FROM cuotas cu '
      'LEFT JOIN pagos p ON p.cuota_id = cu.id AND p.anulado = 0 '
      // r.anulado = 0 (defensa ante re-emisión); ORDER por p.created_at para que,
      // si la cuota tuvo 2 pagos, tome el recibo MÁS RECIENTE (audit QA 2026-06-30).
      'LEFT JOIN recibos r ON r.pago_id = p.id AND r.anulado = 0 '
      "WHERE cu.ticket_id = ? AND cu.estado != 'anulada' "
      'ORDER BY cu.created_at DESC, p.created_at DESC LIMIT 1',
      parameters: [widget.ticketId],
    );
    _eventos = ps.db.watch('''
      SELECT e.*, c.nombre AS autor
        FROM ticket_eventos e
   LEFT JOIN cobradores c ON c.id = e.hecho_por
       WHERE e.ticket_id = ?
       ORDER BY COALESCE(e.ocurrido_en, e.created_at) DESC
    ''', parameters: [widget.ticketId]);
  }

  @override
  void dispose() {
    _comentario.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // SLA por prioridad se lee acá (build del Consumer), no dentro del builder
    // del StreamBuilder (que puede reconstruirse solo). Se pasa a _header.
    final slaMap = ref.watch(appSettingsProvider).slaHorasPorPrioridad;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _ticket,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text(mensajeErrorHumano(snap.error!)));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
              icon: Icons.confirmation_number_outlined,
              titulo: 'Ticket no encontrado');
        }
        final t = rows.first;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
              children: [
                _header(context, t, slaMap),
                const SizedBox(height: 8),
                _acciones(context, t),
                // Panel de cierre del call center (0208): solo sobre una orden
                // RESUELTA y solo para quien la cierra. El técnico la resolvió
                // y no cierra; el coordinador reparte y no cierra.
                if ((t['estado'] as String?) == 'resuelto' &&
                    !_esSoloVista &&
                    !(ref.watch(cobradorActualProvider).valueOrNull
                            ?.esCoordinador ??
                        false)) ...[
                  const SizedBox(height: 12),
                  _panelCierre(context, t),
                ],
                const SizedBox(height: 16),
                _checklistSection(context, t),
                if (!_noEditaTrabajo) _comentarRow(context, t),
                const SizedBox(height: 16),
                TicketAdjuntosWidget(
                    ticketId: widget.ticketId,
                    tenantId: t['tenant_id'] as String,
                    canEdit: !_noEditaTrabajo),
                const SizedBox(height: 16),
                // Materiales consumidos (Fase 3C) — visible si el tenant tiene
                // el módulo inventario. El técnico consume de su custodia.
                TicketMaterialesWidget(
                    ticketId: widget.ticketId,
                    tenantId: t['tenant_id'] as String,
                    clienteId: t['cliente_id'] as String?,
                    tecnicoMode: widget.tecnicoMode,
                    canEdit: !_noEditaTrabajo),
                const SizedBox(height: 16),
                // Equipos que el cliente YA tiene, para retirarlos a revisión
                // (0205). Va DESPUÉS de materiales: primero se instala lo nuevo,
                // después se levanta lo viejo. Se auto-oculta si no hay nada.
                TicketEquiposClienteWidget(
                    ticketId: widget.ticketId,
                    tenantId: t['tenant_id'] as String,
                    clienteId: t['cliente_id'] as String?,
                    canEdit: !_noEditaTrabajo),
                const SizedBox(height: 16),
                _timeline(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(
      BuildContext context, Map<String, dynamic> t, Map<String, int> slaMap) {
    final scheme = Theme.of(context).colorScheme;
    final estado = t['estado'] as String? ?? 'abierto';
    final prioridad = t['prioridad'] as String?;
    final createdAt = parseTicketWallClock(t['created_at'] as String);
    final pausado = (t['segundos_pausado'] as int?) ?? 0;
    // SLA EFECTIVO = min(SLA del tipo, SLA de la prioridad). El chip muestra la
    // cuenta regresiva viva (tick 1s en el detalle).
    final ef = slaHorasEfectivas(t['sla_horas'] as int?, slaMap[prioridad]);
    final sla = ticketSlaEstado(
      estado: estado,
      createdAt: createdAt,
      slaHoras: ef,
      prioridad: prioridad,
      segundosPausado: pausado,
    );
    final viva = sla == SlaEstado.enPlazo ||
        sla == SlaEstado.porVencer ||
        sla == SlaEstado.vencido;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ticketCodigo(t['correlativo'] as num?),
                style: TextStyle(
                    color: scheme.primary, fontWeight: FontWeight.w700)),
            Text(t['titulo'] as String,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _chip(estadoTicketLabel(estado), estadoTicketColor(estado, scheme)),
              if (sla != SlaEstado.sinSla && sla != SlaEstado.cerrado)
                TicketSlaCountdown(
                  estado: estado,
                  createdAt: createdAt,
                  slaHoras: ef,
                  prioridad: prioridad,
                  segundosPausado: pausado,
                  tick: const Duration(seconds: 1),
                ),
              if (prioridad != null)
                _chip(prioridadLabel(prioridad), prioridadColor(prioridad, scheme)),
            ]),
            const SizedBox(height: 12),
            if ((t['descripcion'] as String?)?.isNotEmpty ?? false) ...[
              Text(t['descripcion'] as String),
              const SizedBox(height: 12),
            ],
            _row(context, Icons.label_outline, 'Tipo', t['tipo_nombre'] as String?),
            _row(context, Icons.person, 'Cliente', t['cliente_nombre'] as String?),
            _row(context, Icons.engineering, 'Asignado',
                t['asignado_nombre'] as String?),
            // Incidente vinculado (sólo el admin sincroniza incidentes → para el
            // técnico viene null y no se muestra).
            if (t['incidente_titulo'] != null)
              _row(context, Icons.cell_tower, 'Incidente',
                  t['incidente_titulo'] as String?),
            _row(context, Icons.schedule, 'Creado',
                Fmt.fechaCorta(createdAt.toLocal())),
            // Quién firmó la verificación (backlog del audit 2026-07-26): se
            // guardaba y no se veía en ningún lado — la orden salía de la
            // bandeja del gestor y no quedaba rastro visible de quién la
            // aprobó, que es justo lo que un flujo de aprobación tiene que
            // dejar. 'pendiente' también se muestra: avisa que falta el paso.
            if (t['verificacion_estado'] != null)
              _row(
                context,
                t['verificacion_estado'] == 'verificada'
                    ? Icons.verified_outlined
                    : Icons.pending_outlined,
                'Verificación',
                _textoVerificacion(t),
              ),
            // Dónde trabajó el técnico (0204). Hasta el audit 2026-07-26 esto se
            // guardaba y no se mostraba en ningún lado: la ubicación existía en
            // la base pero no servía para auditar nada, que era todo su punto.
            if (t['lat'] != null && t['lng'] != null)
              InkWell(
                onTap: () => ExternalActions.navegarA(
                  context,
                  lat: (t['lat'] as num).toDouble(),
                  lng: (t['lng'] as num).toDouble(),
                  label: 'Orden ${ticketCodigo(t['correlativo'] as num?)}',
                ),
                child: _row(
                  context,
                  Icons.map_outlined,
                  'Trabajó acá',
                  '${(t['lat'] as num).toStringAsFixed(5)}, '
                      '${(t['lng'] as num).toStringAsFixed(5)}  ·  ver en el mapa',
                ),
              ),
            // Vencimiento del SLA (sólo con cuenta regresiva viva; en espera el
            // plazo se corre, así que no mostramos una fecha que cambiaría).
            if (viva && ef != null)
              _row(context, Icons.timer_outlined, 'Vence',
                  _fmtVence(createdAt, ef, pausado)),
          ],
        ),
      ),
    );
  }

  /// Texto de la fila de verificación, a prueba de datos incompletos.
  ///
  /// El CHECK de `verificacion_estado` NO obliga a que 'verificada' venga con
  /// `verificado_en` (audit profundo 2026-07-26): un arreglo por SQL, un sync
  /// parcial o un camino futuro pueden dejar la fecha en NULL, y un
  /// `DateTime.parse` de eso tiraba y se llevaba puesto el header ENTERO — la
  /// orden dejaba de abrirse. Una fecha que falta no puede matar una pantalla.
  String _textoVerificacion(Map<String, dynamic> t) {
    if (t['verificacion_estado'] != 'verificada') return 'pendiente del gestor';
    final quien = (t['verificado_por_nombre'] as String?) ?? 'alguien';
    final cuando = DateTime.tryParse((t['verificado_en'] as String?) ?? '');
    return cuando == null
        ? quien
        : '$quien · ${Fmt.fechaCorta(cuando.toLocal())}';
  }

  // Chip compacto reutilizado en el header (estado / prioridad).
  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  // Fila ícono + label + valor. Se oculta si el valor es vacío/null.
  Widget _row(BuildContext context, IconData icon, String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 12),
          SizedBox(
              width: 90,
              child: Text(label, style: TextStyle(color: scheme.outline))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  // Fecha/hora local del vencimiento del SLA: created_at + sla efectivo + pausa.
  String _fmtVence(DateTime createdAt, int slaHoras, int segundosPausado) {
    final d = createdAt
        .add(Duration(hours: slaHoras))
        .add(Duration(seconds: segundosPausado))
        .toLocal();
    return '${Fmt.fechaCorta(d)} ${Fmt.hora(d)}';
  }

  // Checklist del ticket (snapshot del template del tipo). El técnico/admin tilda
  // los pasos; se guarda como JSONB en tickets.checklist. No renderiza si está vacío.
  Widget _checklistSection(BuildContext context, Map<String, dynamic> t) {
    final lista = _parseChecklist(t['checklist']);
    if (lista.isEmpty) return const SizedBox.shrink();
    final hechos = lista.where((e) => e['hecho'] == true).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Checklist',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  Text('$hechos/${lista.length}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            ),
            for (int i = 0; i < lista.length; i++)
              CheckboxListTile(
                dense: true,
                value: lista[i]['hecho'] == true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('${lista[i]['texto'] ?? ''}'),
                // null = deshabilitado. El coordinador VE el avance del trabajo
                // (le sirve para repartir) pero no lo tilda: el checklist vive
                // en `tickets.checklist` y su trigger de columnas lo rechaza.
                onChanged: _noEditaTrabajo
                    ? null
                    : (v) => _toggleChecklist(t, lista, i, v ?? false),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _parseChecklist(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return [
          for (final e in decoded)
            if (e is Map) Map<String, dynamic>.from(e)
        ];
      }
    } catch (_) {}
    return const [];
  }

  Future<void> _toggleChecklist(Map<String, dynamic> t,
      List<Map<String, dynamic>> lista, int index, bool hecho) async {
    // Acción atribuida al usuario → bloqueada al impersonar (queda en op_log; se
    // hace desde la cuenta real del ISP, no como System Admin — audit 2026-06-30).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    if (index < 0 || index >= lista.length) return;
    final nueva = [for (final e in lista) Map<String, dynamic>.from(e)];
    nueva[index]['hecho'] = hecho;
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final paso = '${lista[index]['texto'] ?? ''}'.trim();
    // op_log: actor + id de intención. El checklist NO es campo visible en la
    // allowlist de tickets (escribirCambioEntidad no lo emitiría) → registramos
    // un evento scopeado al ticket con el paso tildado/destildado.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final tenantId = t['tenant_id'] as String?;
    try {
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'UPDATE tickets SET checklist = ?, ocurrido_en = ? WHERE id = ?',
          [jsonEncode(nueva), ocurrido, t['id']],
        );
        if (tenantId != null) {
          await OpLog.escribir(
            tx,
            tenantId: tenantId,
            opId: opId,
            tipoOp: 'edicion_entidad',
            entidad: 'tickets',
            entidadId: t['id'] as String,
            accion: 'update',
            diff: {
              'campos': const [],
              'resumen': {
                'motivo': hecho
                    ? 'Checklist tildado: ${paso.isEmpty ? "(paso)" : paso}'
                    : 'Checklist destildado: ${paso.isEmpty ? "(paso)" : paso}',
              },
            },
            actor: actor,
            ocurridoEn: DateTime.parse(ocurrido),
          );
        }
      });
    } catch (e) {
      _snack(mensajeErrorHumano(e));
    }
  }

  Widget _acciones(BuildContext context, Map<String, dynamic> t) {
    // Cola del técnico (0206): si esta orden no es la que le toca, no se opera.
    // Solo aplica al técnico — el admin/coordinador ve y toca cualquiera.
    if (widget.tecnicoMode) {
      return StreamBuilder<List<Map<String, dynamic>>>(
        stream: _cola,
        initialData: const [],
        builder: (context, snap) {
          final cola = snap.data ?? const [];
          final bloqueada = ordenBloqueada(t, ordenActiva(cola));
          if (!bloqueada) return _accionesBotones(context, t);
          final scheme = Theme.of(context).colorScheme;
          return Card(
            color: scheme.surfaceContainerHighest,
            child: ListTile(
              leading: Icon(Icons.lock_outline, color: scheme.onSurfaceVariant),
              title: const Text('Todavía no te toca esta orden'),
              subtitle: const Text(
                  'Resolvé la primera de tu lista y esta se habilita sola.'),
            ),
          );
        },
      );
    }
    return _accionesBotones(context, t);
  }

  Widget _accionesBotones(BuildContext context, Map<String, dynamic> t) {
    final estado = t['estado'] as String? ?? 'abierto';
    // Coordinador (0207): reparte el trabajo, no lo modifica. Ve solo asignar y
    // ordenar. Esto es COMODIDAD, no seguridad — la barrera real es el trigger
    // `tickets_coordinador_solo_orden`, que rechaza cualquier otra columna.
    final esCoordinador =
        ref.watch(cobradorActualProvider).valueOrNull?.esCoordinador ?? false;
    if (esCoordinador) {
      final terminal = estado == 'cerrado' || estado == 'cancelado';
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (!terminal)
            OutlinedButton.icon(
              icon: const Icon(Icons.engineering, size: 18),
              label: const Text('Asignar técnico'),
              onPressed: () => _reasignar(t),
            ),
          if (!terminal)
            OutlinedButton.icon(
              icon: const Icon(Icons.low_priority, size: 18),
              label: Text(t['orden_cola'] == null
                  ? 'Poner en la cola'
                  : 'Posición ${t['orden_cola']}'),
              onPressed: () => _moverEnCola(t),
            ),
          if (terminal)
            Text('La orden está ${estadoTicketLabel(estado)}.',
                style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    }
    // El técnico sólo avanza/pausa/resuelve; el admin tiene todas las transiciones.
    final transiciones = widget.tecnicoMode
        ? transicionesTecnico(estado)
        : transicionesDesde(estado);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ...transiciones.map((to) => OutlinedButton(
              onPressed: () => _cambiarEstadoConfirmando(t, to),
              child: Text(estadoTicketLabel(to)),
            )),
        // Ubicación de la orden (0204): la marca quien la ejecuta en sitio.
        // Se ofrece mientras la orden no sea terminal; ya marcada, el botón
        // pasa a confirmar y permite re-marcar (pudo marcarse en la oficina).
        if (!_esSoloVista && estado != 'cerrado' && estado != 'cancelado')
          TextButton.icon(
            icon: _marcandoUbicacion
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(
                    t['lat'] != null
                        ? Icons.where_to_vote
                        : Icons.add_location_alt_outlined,
                    size: 18),
            label: Text(t['lat'] != null
                ? 'Ubicación marcada'
                : 'Marcar ubicación'),
            onPressed: _marcandoUbicacion ? null : () => _marcarUbicacion(t),
          ),
        // Reasignar: sólo el admin (no el técnico) y no en estados terminales.
        if (!_esSoloVista && estado != 'cerrado' && estado != 'cancelado')
          TextButton.icon(
            icon: const Icon(Icons.engineering, size: 18),
            label: const Text('Reasignar'),
            onPressed: () => _reasignar(t),
          ),
        // Vincular a un incidente/outage abierto (sólo admin). El flujo real es
        // tickets-primero → el admin declara el corte → agrupa los tickets.
        if (!_esSoloVista)
          TextButton.icon(
            icon: const Icon(Icons.cell_tower, size: 18),
            label: const Text('Incidente'),
            onPressed: () => _vincularIncidente(t),
          ),
        // Cobro del ticket (0173) AL FINAL: solo si el tipo tiene precio > 0 y es
        // admin/cobranza no impersonando. Se autogestiona (generar/continuar/
        // cobrado). Al final del Wrap para que su shrink (cuando no aplica) no
        // deje un gap inicial; el FilledButton igual resalta.
        _botonCobro(context, t),
      ],
    );
  }

  /// Botón de cobro del ticket (0173). Solo admin/cobranza no impersonando y tipo
  /// con precio > 0. Watchea el cobro ligado para no doble-cobrar: sin cobro +
  /// resuelto/cerrado → "Generar cobro"; cobro pendiente → "Continuar cobro";
  /// cobro saldado → chip "Cobrado".
  Widget _botonCobro(BuildContext context, Map<String, dynamic> t) {
    final precioTipo = (t['tipo_precio'] as num?)?.toDouble() ?? 0;
    final clienteId = t['cliente_id'] as String?;
    final estado = t['estado'] as String? ?? 'abierto';
    final me = ref.watch(cobradorActualProvider).valueOrNull;
    final impersonando = ref.watch(estaImpersonandoProvider);
    // Gateado por el toggle super_admin 'cobranza.cobro_extra' (0177): misma
    // llave que el "Cobro extra" del cliente. Default OFF → no se muestra.
    final cobroExtraOn = ref.watch(appSettingsProvider).cobroExtraHabilitado;
    final puedeCobrar = !_esSoloVista &&
        !impersonando &&
        cobroExtraOn &&
        me != null &&
        (me.tieneAccesoAdmin || me.esAdminCobranza);
    // Tipo NO cobrable o sin permiso → ni se muestra (no es una acción posible).
    if (!puedeCobrar || precioTipo <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cobroTicket,
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        if (rows.isNotEmpty) {
          final c = rows.first;
          final monto = (c['monto'] as num?)?.toDouble() ?? 0;
          final pagado = (c['monto_pagado'] as num?)?.toDouble() ?? 0;
          if (monto - pagado <= 0.01) {
            // Cobrado → chip TAPPABLE que abre el recibo (audit UX: parecía
            // botón pero no respondía).
            final reciboId = c['recibo_id'] as String?;
            return ActionChip(
              avatar:
                  Icon(Icons.check_circle, size: 18, color: scheme.primary),
              label: Text('Cobrado · ${Fmt.cordobas(monto)}'),
              // Siempre responde: si el recibo aún no sincronizó, avisar en vez de
              // quedar muerto (audit QA: reaparecía "parece botón y no responde").
              onPressed: () {
                if (reciboId != null) {
                  context.push('/recibo/$reciboId');
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text(
                          'El recibo se está sincronizando, probá en un momento.')));
                }
              },
            );
          }
          return FilledButton.tonalIcon(
            icon: const Icon(Icons.point_of_sale, size: 18),
            label: const Text('Continuar cobro'),
            onPressed: () => context.push('/cobro/${c['id']}'),
          );
        }
        // Sin cobro: en vez de OCULTAR el botón (parecía roto — audit UX 0173),
        // mostrarlo DESHABILITADO con el motivo VISIBLE.
        if (clienteId == null) {
          return _cobroDeshabilitado(
              scheme, 'Este ticket no tiene cliente: no se puede cobrar');
        }
        if (estado == 'cancelado') {
          return _cobroDeshabilitado(
              scheme, 'El ticket está cancelado: no se cobra');
        }
        if (estado != 'resuelto' && estado != 'cerrado') {
          return _cobroDeshabilitado(
              scheme, 'Se habilita al resolver el ticket');
        }
        return FilledButton.icon(
          icon: const Icon(Icons.point_of_sale, size: 18),
          label: const Text('Generar cobro'),
          onPressed: () => _generarCobro(context, t),
        );
      },
    );
  }

  // "Generar cobro" deshabilitado + el motivo VISIBLE (no solo tooltip, que en
  // touch casi no aparece) — audit UX 2026-06-30.
  Widget _cobroDeshabilitado(ColorScheme scheme, String motivo) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.icon(
            onPressed: null,
            icon: const Icon(Icons.point_of_sale, size: 18),
            label: const Text('Generar cobro'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 2),
            child: Text(motivo,
                style:
                    TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
          ),
        ],
      );

  Future<void> _generarCobro(
      BuildContext context, Map<String, dynamic> t) async {
    final clienteId = t['cliente_id'] as String?;
    if (clienteId == null) return;
    final cuotaId = await mostrarCobroPuntual(
      context,
      clienteId: clienteId,
      ticketId: widget.ticketId,
      tipoFijo: tipoCobroDeEfecto(t['tipo_efecto'] as String?),
      descripcionInicial: (t['tipo_nombre'] as String?) ?? 'Servicio',
      montoInicial: (t['tipo_precio'] as num?)?.toDouble(),
    );
    if (cuotaId == null || !context.mounted) return;
    context.push('/cobro/$cuotaId');
  }

  Future<void> _vincularIncidente(Map<String, dynamic> t) async {
    // Vinculación atribuida al usuario (bitácora + op_log) → bloqueada al
    // impersonar (audit 2026-06-30).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final incidentes = await ps.db.getAll(
        "SELECT id, titulo FROM incidentes WHERE estado = 'abierto' ORDER BY inicio DESC");
    if (!mounted) return;
    if (incidentes.isEmpty) {
      _snack('No hay incidentes abiertos para vincular.');
      return;
    }
    final actual = t['incidente_id'] as String?;
    final elegido = await showModalBottomSheet<({String? id})>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('— Sin incidente —'),
              selected: actual == null,
              onTap: () => Navigator.pop(context, (id: null)),
            ),
            ...incidentes.map((i) => ListTile(
                  leading: const Icon(Icons.cell_tower),
                  title: Text(i['titulo'] as String),
                  selected: actual == i['id'],
                  onTap: () =>
                      Navigator.pop(context, (id: i['id'] as String?)),
                )),
          ],
        ),
      ),
    );
    if (elegido == null || elegido.id == actual) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final hechoPor = me?.id;
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final nombreInc = elegido.id == null
        ? null
        : incidentes.firstWhere((i) => i['id'] == elegido.id)['titulo'] as String;
    // op_log: actor + id de intención. incidente_id NO es campo visible en la
    // allowlist de tickets → registramos un evento scopeado al ticket con el
    // texto del vínculo/desvínculo (lo mismo que narra la bitácora).
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    try {
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          'UPDATE tickets SET incidente_id = ?, ocurrido_en = ? WHERE id = ?',
          [elegido.id, ocurrido, t['id']],
        );
        await _evento(tx, t['id'] as String, tenantId, 'comentario', null, null,
            hechoPor, ocurrido, now,
            comentario: elegido.id == null
                ? 'Desvinculado del incidente'
                : 'Vinculado al incidente: $nombreInc');
        await OpLog.escribir(
          tx,
          tenantId: tenantId,
          opId: opId,
          tipoOp: 'edicion_entidad',
          entidad: 'tickets',
          entidadId: t['id'] as String,
          accion: 'update',
          diff: {
            'campos': const [],
            'resumen': {
              'motivo': elegido.id == null
                  ? 'Desvinculado del incidente'
                  : 'Vinculado al incidente: $nombreInc',
            },
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurrido),
        );
      });
    } catch (e) {
      _snack(mensajeErrorHumano(e));
    }
  }

  Widget _comentarRow(BuildContext context, Map<String, dynamic> t) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _comentario,
            decoration: const InputDecoration(
              labelText: 'Agregar comentario',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          icon: const Icon(Icons.send),
          onPressed: () => _comentar(t),
        ),
      ],
    );
  }

  void _showHistorialCambios(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Historial de cambios del ticket',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                // Agregador: ticket + adjuntos + materiales en una timeline
                // (patrón cuota/cliente). La bitácora narra los eventos aparte.
                child: HistorialOpLog(
                    entidad: 'tickets', entidadId: widget.ticketId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _timeline(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _eventos,
      initialData: const [],
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        if (rows.isEmpty) {
          return const SizedBox.shrink();
        }
        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Bitácora',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    // M9: la bitácora (ticket_eventos) es el log de dominio; este
                    // botón abre el change-log (op_log) del ticket. El técnico no
                    // sincroniza op_log → el sheet saldría vacío, así que solo se
                    // lo mostramos a admin/super. (audit_log se eliminó en 0140.)
                    if (!_esSoloVista)
                      IconButton(
                        icon: const Icon(Icons.history, size: 20),
                        tooltip: 'Historial de cambios',
                        onPressed: () => _showHistorialCambios(context),
                      ),
                  ],
                ),
              ),
              ...rows.map((e) {
                final tipo = e['tipo_evento'] as String? ?? '';
                final ant = e['estado_anterior'] as String?;
                final nue = e['estado_nuevo'] as String?;
                final com = e['comentario'] as String?;
                // hecho_por NULL = evento del sistema (ej. auto-cierre del cron);
                // autor null con hecho_por seteado = persona desconocida (sin sync).
                final autor = e['autor'] as String? ??
                    (e['hecho_por'] == null ? 'Sistema' : '—');
                final fecha = DateTime.parse(
                    (e['ocurrido_en'] ?? e['created_at']) as String).toLocal();
                final detalle = [
                  if (tipo == 'cambio_estado' && ant != null && nue != null)
                    '${estadoTicketLabel(ant)} → ${estadoTicketLabel(nue)}',
                  if (com != null && com.isNotEmpty) com,
                ].join(' · ');
                return ListTile(
                  dense: true,
                  leading: Icon(tipoEventoIcon(tipo),
                      size: 20, color: scheme.outline),
                  title: Text(tipoEventoLabel(tipo),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([
                    if (detalle.isNotEmpty) detalle,
                    '${Fmt.fechaCorta(fecha)} ${Fmt.hora(fecha)} · $autor',
                  ].join('\n')),
                  isThreeLine: detalle.isNotEmpty,
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // ── Acciones ────────────────────────────────────────────────────────────

  /// Sella en la orden la ubicación REAL donde el técnico la ejecutó (0204).
  ///
  /// Es del ticket, no del cliente: la ficha puede estar mal geolocalizada y lo
  /// que audita el trabajo es dónde se paró el técnico. Se puede re-marcar
  /// mientras la orden no esté cerrada (el técnico puede haberla tomado desde
  /// la oficina y marcar recién al llegar).
  ///
  /// Sin `showDialog` de carga (regla #7): usa `_marcandoUbicacion` + un
  /// indicador en el propio botón, así una excepción no deja una barrera
  /// modal pegada sin salida.
  Future<void> _marcarUbicacion(Map<String, dynamic> t) async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    if (_marcandoUbicacion) return;
    setState(() => _marcandoUbicacion = true);
    try {
      final r = await UbicacionActual.obtener();
      if (!mounted) return;
      if (!r.exito) {
        _snack(r.error!);
        return;
      }
      final ocurrido = DateTime.now().toUtc().toIso8601String();
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final opId = OpLog.nuevoOpId();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      final tenantId = t['tenant_id'] as String?;
      await ps.dbW.writeTransaction((tx) async {
        final antesRows =
            await tx.getAll('SELECT * FROM tickets WHERE id = ?', [t['id']]);
        final cur = antesRows.isNotEmpty ? antesRows.first : null;
        if (cur == null) throw const _TkError('La orden ya no existe.');
        // No se re-marca una orden terminal: su ubicación es parte del acta.
        final est = cur['estado'] as String? ?? '';
        if (est == 'cerrado' || est == 'cancelado') {
          throw _TkError('La orden está $est; no se puede cambiar la ubicación.');
        }
        await tx.execute(
          'UPDATE tickets SET lat = ?, lng = ?, ocurrido_en = ? WHERE id = ?',
          [r.lat, r.lng, ocurrido, t['id']],
        );
        if (tenantId != null) {
          final despues =
              (await tx.getAll('SELECT * FROM tickets WHERE id = ?', [t['id']]))
                  .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'tickets',
              entidadId: t['id'] as String, antes: cur, despues: despues,
              actor: actor, ocurridoEn: DateTime.parse(ocurrido));
        }
      });
      if (mounted) _snack('Ubicación marcada');
    } on _TkError catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack(mensajeErrorHumano(e));
    } finally {
      // En `finally` para que una excepción no deje el botón girando (regla #9).
      if (mounted) setState(() => _marcandoUbicacion = false);
    }
  }

  /// Panel de cierre del call center (0208).
  ///
  /// Aparece solo sobre una orden `resuelto`: el técnico ya hizo el trabajo y
  /// falta confirmarlo con el cliente. Del audio 1: *"va a cerrar el ticket una
  /// vez que se comunique con el cliente y le diga que todo está arreglado; si
  /// no, no lo va a poder cerrar"*.
  ///
  /// La válvula: si el cliente no aparece, tras N intentos y D días se habilita
  /// cerrar igual, con motivo obligatorio y marcado como "sin confirmar" para
  /// que el ISP pueda medir cuántas cierra a ciegas.
  Widget _panelCierre(BuildContext context, Map<String, dynamic> t) {
    final cfg = ref.watch(appSettingsProvider);
    final minIntentos = cfg.cierreIntentosMin;
    final minDias = cfg.cierreDiasMin;
    // Fallback a `created_at` (backlog del audit 2026-07-26): las órdenes que
    // llegaron a 'resuelto' antes de que se sellara `resuelto_en` daban 0 días
    // y NUNCA habilitaban el cierre sin confirmar — quedaban trabadas para
    // siempre. Con la fecha de alta al menos hay una cota real.
    // `resuelto_en` va en UTC; `created_at` es local-naive A PROPÓSITO, así que
    // el fallback pasa por `parseTicketWallClock` —la convención del proyecto—
    // y se compara contra la hora local. Mezclar los dos husos daba un corrimiento
    // de 6h que dejaba cerrar antes de tiempo (audit profundo 2026-07-26).
    final resueltoUtc = DateTime.tryParse((t['resuelto_en'] as String?) ?? '');
    final diasDesde = resueltoUtc != null
        ? DateTime.now().toUtc().difference(resueltoUtc).inDays
        : ((t['created_at'] as String?) == null
            ? 0
            : DateTime.now()
                .difference(parseTicketWallClock(t['created_at'] as String))
                .inDays);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _intentos,
      initialData: const [],
      builder: (context, snap) {
        final intentos = snap.data ?? const [];
        final habilitado =
            intentos.length >= minIntentos && diasDesde >= minDias;
        final faltan = minIntentos - intentos.length;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Confirmar con el cliente',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  'El trabajo está resuelto. La orden se cierra cuando el '
                  'cliente confirme que quedó bien.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (intentos.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Intentos de contacto (${intentos.length})',
                      style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(height: 4),
                  ...intentos.map((i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${Fmt.fechaHoraNi((i['ocurrido_en'] ?? i['created_at']) as String?)}'
                          ' · ${i['comentario'] ?? ''}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      )),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.phone_missed, size: 18),
                      label: const Text('Registrar intento'),
                      onPressed: () => _registrarIntento(t),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Confirmado, cerrar'),
                      onPressed: () => _cambiarEstadoConfirmando(t, 'cerrado'),
                    ),
                    if (habilitado)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.report_gmailerrorred, size: 18),
                        label: const Text('Cerrar sin confirmar'),
                        onPressed: () => _cerrarSinConfirmar(t),
                      ),
                  ],
                ),
                if (!habilitado) ...[
                  const SizedBox(height: 8),
                  // Decir QUÉ falta, no solo que no se puede: sin esto el
                  // operador cree que la app está rota.
                  Text(
                    faltan > 0
                        ? 'Para cerrar sin confirmar faltan $faltan intento(s).'
                        : 'Para cerrar sin confirmar falta que pasen '
                            '${minDias - diasDesde} día(s) más.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Registra un intento de contacto como evento de la bitácora del ticket.
  Future<void> _registrarIntento(Map<String, dynamic> t) async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    // Enum fijo y corto → Dropdown/SimpleDialog está OK (regla #10; el que NO
    // commitea dentro de un diálogo es el alimentado por una lista de la DB).
    const opciones = [
      'No contesta',
      'Buzón de voz',
      'Número equivocado',
      'Pidió que lo llamen después',
    ];
    final resultado = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('¿Qué pasó al llamar?'),
        children: [
          for (final o in opciones)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, o), child: Text(o)),
        ],
      ),
    );
    if (resultado == null || !mounted) return;
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final now = DateTime.now().toIso8601String();
    final me = ref.read(cobradorActualProvider).valueOrNull;
    try {
      await ps.dbW.writeTransaction((tx) async {
        await tx.execute(
          '''INSERT INTO ticket_eventos
             (id, tenant_id, ticket_id, tipo_evento, comentario, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, ?, 'contacto', ?, ?, ?, ?)''',
          [
            const Uuid().v4(), t['tenant_id'], t['id'], resultado, me?.id,
            ocurrido, now,
          ],
        );
      });
      if (mounted) _snack('Intento registrado');
    } catch (e) {
      if (mounted) _snack(mensajeErrorHumano(e));
    }
  }

  /// Cierra la orden SIN confirmación del cliente, con motivo obligatorio.
  ///
  /// Queda marcada con `cerrado_sin_confirmar` para que los reportes puedan
  /// separarla de un cierre normal: si ese número crece, el problema no es la
  /// app sino la operación.
  Future<void> _cerrarSinConfirmar(Map<String, dynamic> t) async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final ctrl = TextEditingController();
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cerrar sin confirmar'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('El cliente no confirmó que el trabajo quedó bien. '
                'Contá qué pasó — queda en el historial de la orden.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Motivo', hintText: 'No contesta desde el lunes'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Volver')),
          FilledButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isEmpty) return; // motivo obligatorio
              Navigator.pop(ctx, v);
            },
            child: const Text('Cerrar la orden'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (motivo == null || !mounted) return;
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final tenantId = t['tenant_id'] as String?;
    try {
      await ps.dbW.writeTransaction((tx) async {
        final antesRows =
            await tx.getAll('SELECT * FROM tickets WHERE id = ?', [t['id']]);
        final cur = antesRows.isNotEmpty ? antesRows.first : null;
        if (cur == null || cur['estado'] != 'resuelto') {
          throw const _TkError('La orden cambió de estado; recargá.');
        }
        await tx.execute(
          'UPDATE tickets SET estado = ?, cerrado_en = ?, ocurrido_en = ?, '
          'cerrado_sin_confirmar = 1, motivo_cierre = ? WHERE id = ?',
          ['cerrado', ocurrido, ocurrido, motivo, t['id']],
        );
        await tx.execute(
          '''INSERT INTO ticket_eventos
             (id, tenant_id, ticket_id, tipo_evento, comentario, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, ?, 'cerrado', ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, t['id'],
            'Cerrado sin confirmar: $motivo', me?.id, ocurrido,
            DateTime.now().toIso8601String(),
          ],
        );
        if (tenantId != null) {
          final despues =
              (await tx.getAll('SELECT * FROM tickets WHERE id = ?', [t['id']]))
                  .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'tickets',
              entidadId: t['id'] as String, antes: cur, despues: despues,
              actor: actor, ocurridoEn: DateTime.parse(ocurrido));
        }
      });
      if (mounted) _snack('Orden cerrada sin confirmar');
    } on _TkError catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack(mensajeErrorHumano(e));
    }
  }

  /// Mueve la orden en la cola del técnico (0206/0207).
  ///
  /// Del audio 6: *"que el coordinador, porque no encontraron a la persona,
  /// pueda pasarlo para segundo lugar, tercer lugar o último lugar"*. Por eso
  /// las opciones son POSICIONES relativas y no un número a tipear: nadie sabe
  /// de memoria qué número le toca, y el coordinador está apurado.
  Future<void> _moverEnCola(Map<String, dynamic> t) async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final asignado = t['asignado_a'] as String?;
    if (asignado == null) {
      _snack('Primero asignale un técnico: la cola es de cada uno.');
      return;
    }
    // Las órdenes vivas de ESE técnico, en el orden en que las va a hacer.
    // Se copian a Map porque `getAll` devuelve `Row` (inmutable) y acá la lista
    // se reordena y se le inserta el ticket actual.
    final cola = (await ps.db.getAll('''
      SELECT id, orden_cola, created_at
        FROM tickets
       WHERE asignado_a = ?
         AND estado IN ('abierto', 'asignado', 'en_progreso', 'reabierto')
    ''', [asignado]))
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    cola.sort(compararEnCola);
    if (!mounted) return;
    final destino = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('¿Dónde va en la cola?'),
        children: [
          for (var i = 0; i < cola.length; i++)
            if (cola[i]['id'] != t['id'])
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, i + 1),
                child: Text(i == 0
                    ? 'Primera, antes de todo'
                    : 'En la posición ${i + 1}'),
              ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, cola.length),
            child: const Text('Última'),
          ),
        ],
      ),
    );
    if (destino == null || !mounted) return;
    // Renumeración COMPLETA de la cola de ese técnico: insertar la orden en la
    // posición pedida y reescribir 1..N. Es más escrituras que mover una sola,
    // pero deja la cola sin huecos ni empates, que es lo que hace predecible
    // cuál es "la primera" para el candado del técnico.
    final resto = cola.where((c) => c['id'] != t['id']).toList();
    final nuevo = [...resto]..insert(destino.clamp(1, resto.length + 1) - 1, t);
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final tenantId = t['tenant_id'] as String?;
    try {
      await ps.dbW.writeTransaction((tx) async {
        for (var i = 0; i < nuevo.length; i++) {
          final id = nuevo[i]['id'] as String;
          final antesRows =
              await tx.getAll('SELECT * FROM tickets WHERE id = ?', [id]);
          if (antesRows.isEmpty) continue;
          if ((antesRows.first['orden_cola'] as int?) == i + 1) continue;
          await tx.execute(
            'UPDATE tickets SET orden_cola = ?, ocurrido_en = ? WHERE id = ?',
            [i + 1, ocurrido, id],
          );
          if (tenantId != null) {
            final despues =
                (await tx.getAll('SELECT * FROM tickets WHERE id = ?', [id]))
                    .first;
            await OpLog.escribirCambioEntidad(tx,
                tenantId: tenantId, opId: opId, entidad: 'tickets',
                entidadId: id, antes: antesRows.first, despues: despues,
                actor: actor, ocurridoEn: DateTime.parse(ocurrido));
          }
        }
      });
      if (mounted) _snack('Cola actualizada');
    } catch (e) {
      if (mounted) _snack(mensajeErrorHumano(e));
    }
  }

  Future<void> _cambiarEstado(Map<String, dynamic> t, String nuevo) async {
    // Transición atribuida al usuario (sella resuelto_en/cerrado_en + op_log) →
    // bloqueada al impersonar (audit 2026-06-30).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final anterior = t['estado'] as String? ?? 'abierto';
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    // Sello de tiempo según el estado destino.
    final extraSet = switch (nuevo) {
      'resuelto' => ', resuelto_en = ?',
      'cerrado' => ', cerrado_en = ?',
      _ => '',
    };
    // op_log: actor + id de intención (estado es campo visible → diff antes→después).
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final tenantId = t['tenant_id'] as String?;
    try {
      await ps.dbW.writeTransaction((tx) async {
        // Re-validar el estado esperado dentro de la tx (evita pisar un cambio
        // hecho en otra pestaña/device; el trigger del server igual re-valida).
        final antesRows =
            await tx.getAll('SELECT * FROM tickets WHERE id = ?', [t['id']]);
        final cur = antesRows.isNotEmpty ? antesRows.first : null;
        if (cur == null || cur['estado'] != anterior) {
          throw const _TkError('El ticket cambió de estado; recargá.');
        }
        await tx.execute(
          'UPDATE tickets SET estado = ?, ocurrido_en = ?$extraSet WHERE id = ?',
          extraSet.isEmpty
              ? [nuevo, ocurrido, t['id']]
              : [nuevo, ocurrido, ocurrido, t['id']],
        );
        if (tenantId != null) {
          final despues =
              (await tx.getAll('SELECT * FROM tickets WHERE id = ?', [t['id']]))
                  .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tenantId, opId: opId, entidad: 'tickets',
              entidadId: t['id'] as String, antes: cur, despues: despues,
              actor: actor, ocurridoEn: DateTime.parse(ocurrido));
        }
      });
    } on _TkError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack(mensajeErrorHumano(e));
    }
  }

  /// M16 (audit UX): las transiciones TERMINALES para el rol confirman —
  /// el técnico no puede volver de 'resuelto' (reabrir es del admin) y los
  /// botones del Wrap son contiguos (guantes/sol → tap equivocado).
  Future<void> _cambiarEstadoConfirmando(
      Map<String, dynamic> t, String to) async {
    final terminales = widget.tecnicoMode
        ? const {'resuelto'}
        : const {'cancelado', 'cerrado'};
    if (terminales.contains(to)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('¿Marcar como "${estadoTicketLabel(to)}"?'),
          content: Text(widget.tecnicoMode
              ? 'No vas a poder volverlo a "En progreso": si falta algo, '
                  'tendrá que reabrirlo el administrador.'
              : 'Es un estado terminal del ticket.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Volver'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _cambiarEstado(t, to);
  }

  Future<void> _comentar(Map<String, dynamic> t) async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final texto = _comentario.text.trim();
    if (texto.isEmpty) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final hechoPor = me?.id;
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    // op_log: el evento de bitácora es hijo del ticket → entrada scopeada al
    // ticket para que aparezca en su historial de cambios.
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    try {
      await ps.dbW.writeTransaction((tx) async {
        await _evento(tx, t['id'] as String, tenantId, 'comentario', null, null,
            hechoPor, ocurrido, now, comentario: texto);
        await OpLog.escribir(
          tx,
          tenantId: tenantId,
          opId: opId,
          tipoOp: 'alta_entidad',
          entidad: 'tickets',
          entidadId: t['id'] as String,
          accion: 'create',
          diff: {
            'campos': const [],
            'resumen': {'motivo': 'Comentario: $texto'},
          },
          actor: actor,
          ocurridoEn: DateTime.parse(ocurrido),
        );
      });
      _comentario.clear();
    } catch (e) {
      _snack(mensajeErrorHumano(e));
    }
  }

  Future<void> _reasignar(Map<String, dynamic> t) async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final tecnicos = await ps.db.getAll(
        "SELECT id, nombre FROM cobradores WHERE activo = 1 AND rol IN ('tecnico','admin_tickets','admin') ORDER BY nombre");
    if (!mounted) return;
    final elegido = await showModalBottomSheet<({String? id, String nombre})>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.person_off),
              title: const Text('— Sin asignar —'),
              onTap: () => Navigator.pop(context, (id: null, nombre: 'sin asignar')),
            ),
            ...tecnicos.map((c) => ListTile(
                  leading: const Icon(Icons.engineering),
                  title: Text(c['nombre'] as String),
                  onTap: () => Navigator.pop(
                      context, (id: c['id'] as String, nombre: c['nombre'] as String)),
                )),
          ],
        ),
      ),
    );
    if (elegido == null || !mounted) return;
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final tenantId = t['tenant_id'] as String?;
    // op_log: actor + id de intención. asignado_a NO es campo visible en la
    // allowlist de tickets → registramos un evento scopeado al ticket con el
    // nuevo responsable.
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    try {
      await ps.dbW.writeTransaction((tx) async {
        // Re-leer el estado FRESCO dentro de la tx (simetría con _cambiarEstado):
        // computamos nuevoEstado desde el valor real, no del snapshot stale, para
        // no generar una transición inválida que el server rechazaría.
        final cur = await tx.getOptional(
            'SELECT estado FROM tickets WHERE id = ?', [t['id']]);
        final estadoActual = cur?['estado'] as String? ?? 'abierto';
        // Asignar mueve abierto→asignado; en cualquier otro estado solo cambia el
        // responsable (sin tocar el estado, para no romper transiciones).
        final nuevoEstado =
            estadoActual == 'abierto' && elegido.id != null ? 'asignado' : estadoActual;
        await tx.execute(
          'UPDATE tickets SET asignado_a = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
          [elegido.id, nuevoEstado, ocurrido, t['id']],
        );
        if (tenantId != null) {
          await OpLog.escribir(
            tx,
            tenantId: tenantId,
            opId: opId,
            tipoOp: 'edicion_entidad',
            entidad: 'tickets',
            entidadId: t['id'] as String,
            accion: 'update',
            diff: {
              'campos': const [],
              'resumen': {
                'motivo': elegido.id == null
                    ? 'Sin asignar'
                    : 'Reasignado a ${elegido.nombre}',
              },
            },
            actor: actor,
            ocurridoEn: DateTime.parse(ocurrido),
          );
        }
      });
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

class _TkError implements Exception {
  const _TkError(this.message);
  final String message;
}

Future<void> _evento(dynamic tx, String ticketId, String tenantId,
    String tipoEvento, String? estadoAnt, String? estadoNue, String? hechoPor,
    String ocurrido, String now,
    {String? comentario}) async {
  await tx.execute(
    '''INSERT INTO ticket_eventos
       (id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
        comentario, hecho_por, ocurrido_en, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
    [
      const Uuid().v4(), tenantId, ticketId, tipoEvento, estadoAnt, estadoNue,
      comentario, hechoPor, ocurrido, now,
    ],
  );
}
