import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/deuda_snapshot.dart';
import '../../../data/models/solicitud_accion.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/contrato_providers.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/repositories/contratos_repo.dart';
import '../../../data/repositories/solicitudes_repo.dart';
import '../../../data/utils/busqueda_cliente.dart'
    show foldBusqueda, foldSqlExpr;
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/op_log.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/deuda_contrato_bloque.dart';
import '../../shared/widgets/empty_state.dart';

class SolicitudesScreen extends ConsumerWidget {
  const SolicitudesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esAdminUsuarios = cobrador?.esAdminUsuarios ?? false;

    // "Por verificar" (0209): órdenes de instalación cerradas esperando que el
    // gestor compare lo que se hizo contra lo que dice el contrato. Va acá y no
    // en /admin/tickets porque el gestor NO tiene acceso a tickets (su allowlist
    // es clientes/mapa/solicitudes/contratos) y no necesita tenerlo: lo suyo es
    // verificar datos, no gestionar órdenes.
    // La pestaña solo existe si el tenant USA tickets. Sin este gate, los
    // tenants que no tienen el módulo veían una pestaña nueva y vacía después
    // de actualizar — un cambio de pantalla para gente que no pidió nada de
    // esto. Es el único punto del paquete que se filtraba fuera del módulo.
    final ticketsOn =
        ref.watch(modulosHabilitadosProvider).valueOrNull?.contains('tickets') ??
            false;
    final tabs = <String>[
      if (esAdminUsuarios) 'Mis solicitudes' else ...['Pendientes', 'Historial'],
      if (ticketsOn) 'Por verificar',
    ];
    final vistas = <Widget>[
      if (esAdminUsuarios)
        _MisSolicitudesTab(cobrador!.id)
      else ...[
        _PendientesTab(),
        _HistorialTab(),
      ],
      if (ticketsOn) const _PorVerificarTab(),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(
        children: [
          // Con una sola pestaña el TabBar es ruido: no hay a dónde ir.
          if (tabs.length > 1)
            TabBar(tabs: [for (final t in tabs) Tab(text: t)]),
          Expanded(
            child: tabs.length > 1
                ? TabBarView(children: vistas)
                : vistas.first,
          ),
        ],
      ),
    );
  }
}

/// Órdenes de instalación cerradas, esperando la verificación del gestor (0209).
///
/// Audio 2: *"que verifique que lo que se escribió en el contrato es lo mismo
/// que está escrito en la orden […] y el número de contrato"*. Por eso la
/// tarjeta muestra los datos ENFRENTADOS en vez de mandarlo a abrir dos
/// pantallas y comparar de memoria.
class _PorVerificarTab extends ConsumerStatefulWidget {
  const _PorVerificarTab();
  @override
  ConsumerState<_PorVerificarTab> createState() => _PorVerificarTabState();
}

class _PorVerificarTabState extends ConsumerState<_PorVerificarTab> {
  late final Stream<List<Map<String, dynamic>>> _pendientes;

  @override
  void initState() {
    super.initState();
    _pendientes = ps.db.watch('''
      SELECT t.id, t.correlativo, t.titulo, t.cerrado_en, t.contrato_id,
             t.cerrado_sin_confirmar,
             cl.nombre AS cliente_nombre, cl.telefono AS cliente_telefono,
             ct.codigo AS contrato_codigo, ct.estado AS contrato_estado,
             tt.nombre AS tipo_nombre
        FROM tickets t
   LEFT JOIN clientes  cl ON cl.id = t.cliente_id
   LEFT JOIN contratos ct ON ct.id = t.contrato_id
   LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
       WHERE t.verificacion_estado = 'pendiente'
       ORDER BY t.cerrado_en ASC
    ''');
  }

  Future<void> _verificar(Map<String, dynamic> t) async {
    if (ref.read(soloLecturaProvider)) return;
    // Toda esta carpeta no tenía el guard (0 llamadas acá contra 31 en el resto
    // de lib/features). Un super_admin impersonando pasa el gate del menú
    // (tieneAccesoAdmin incluye esSuperAdmin), recibe las solicitudes por el
    // bucket impersonated_tenant, y la policy super_admin_all le deja subir el
    // UPDATE: quedaba SU id estampado en aprobador_id / suspendido_por /
    // anulada_por, y el tenant después ve "aprobado por —". Daño ya hecho: 0
    // de 202 resueltas — el agujero estaba abierto y no se usó.
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final sinContrato = t['contrato_id'] == null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Datos verificados?'),
        content: Text(sinContrato
            ? 'Esta orden NO tiene contrato asociado. Si el cliente ya debería '
                'tener uno, creálo antes de dar la orden por verificada.'
            : 'Confirmás que lo que dice la orden coincide con el contrato.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Volver')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Verificada')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final opId = OpLog.nuevoOpId();
    final actor = me != null
        ? await OpLog.actorDeUsuario(ps.db, me.id)
        : const OpLogActor.systemAdmin();
    final tenantId = t['tenant_id'] as String?;
    try {
      await ps.dbW.writeTransaction((tx) async {
        final antes = await tx
            .getAll('SELECT * FROM tickets WHERE id = ?', [t['id']]);
        if (antes.isEmpty) return;
        await tx.execute(
          'UPDATE tickets SET verificacion_estado = ?, verificado_por = ?, '
          'verificado_en = ?, ocurrido_en = ? WHERE id = ?',
          ['verificada', me?.id, ocurrido, ocurrido, t['id']],
        );
        final tid = tenantId ?? antes.first['tenant_id'] as String?;
        if (tid != null) {
          final despues = (await tx
                  .getAll('SELECT * FROM tickets WHERE id = ?', [t['id']]))
              .first;
          await OpLog.escribirCambioEntidad(tx,
              tenantId: tid, opId: opId, entidad: 'tickets',
              entidadId: t['id'] as String, antes: antes.first,
              despues: despues, actor: actor,
              ocurridoEn: DateTime.parse(ocurrido));
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Orden verificada')));
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
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _pendientes,
      initialData: const [],
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.fact_check_outlined,
            titulo: 'Nada por verificar',
            descripcion:
                'Acá aparecen las instalaciones cerradas para comparar la orden '
                'contra el contrato.',
          );
        }
        final soloLectura = ref.watch(soloLecturaProvider);
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final t = rows[i];
            final sinContrato = t['contrato_id'] == null;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'T-${t['correlativo']} · ${t['titulo'] ?? ''}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${t['tipo_nombre'] ?? 'Instalación'} · cerrada '
                      '${Fmt.fechaHoraNi(t['cerrado_en'] as String?)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Divider(height: 18),
                    _fila(context, 'Cliente',
                        (t['cliente_nombre'] as String?) ?? '—'),
                    _fila(context, 'Teléfono',
                        (t['cliente_telefono'] as String?) ?? '—'),
                    _fila(
                      context,
                      'Contrato',
                      sinContrato
                          ? 'sin contrato asociado'
                          : '${t['contrato_codigo'] ?? '—'} '
                              '(${t['contrato_estado'] ?? '—'})',
                      alerta: sinContrato,
                    ),
                    if ((t['cerrado_sin_confirmar'] as int?) == 1)
                      _fila(context, 'Cierre',
                          'sin confirmación del cliente', alerta: true),
                    if (!soloLectura) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text('Verificada'),
                          onPressed: () => _verificar(t),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _fila(BuildContext context, String label, String valor,
      {bool alerta = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(
              valor,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: alerta ? scheme.error : null),
            ),
          ),
        ],
      ),
    );
  }
}

class _MisSolicitudesTab extends ConsumerWidget {
  const _MisSolicitudesTab(this.solicitanteId);
  final String solicitanteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(misSolicitudesProvider(solicitanteId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            icon: Icons.approval,
            titulo: 'Sin solicitudes',
            descripcion: 'Tus solicitudes de aprobación aparecerán acá.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          itemBuilder: (_, i) => _SolicitudCard(
            solicitud: items[i],
            esAdmin: false,
          ),
        );
      },
    );
  }
}

class _PendientesTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(solicitudesPendientesProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            icon: Icons.check_circle_outline,
            titulo: 'Sin solicitudes pendientes',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          // `esAdmin` gobierna los botones Aprobar/Rechazar. Estaba fijo en
          // `true`: quien llegara a esta pestaña podía resolver la cola. El rol
          // `lectura` (0198) llega, así que se lee del rol real.
          itemBuilder: (_, i) => _SolicitudCard(
            solicitud: items[i],
            esAdmin: !ref.watch(soloLecturaProvider),
          ),
        );
      },
    );
  }
}

class _HistorialTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_todasSolicitudesProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (items) {
        final resueltas =
            items.where((s) => !s.esPendiente).toList();
        if (resueltas.isEmpty) {
          return const EmptyState(
            icon: Icons.history,
            titulo: 'Sin historial',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: resueltas.length,
          itemBuilder: (_, i) => _SolicitudCard(
            solicitud: resueltas[i],
            esAdmin: false,
          ),
        );
      },
    );
  }
}

final _todasSolicitudesProvider = StreamProvider<List<SolicitudAccion>>((ref) {
  return ps.db
      .watch('SELECT * FROM solicitudes_accion ORDER BY ocurrido_en DESC')
      .map((rows) => rows.map(SolicitudAccion.fromRow).toList());
});

/// De QUÉ cliente/contrato es una solicitud. Todo opcional: cada parte queda
/// null si no está asignada (contrato sin código, plan borrado, etc.).
typedef _InfoEntidad = ({
  String? clienteNombre,
  String? clienteCodigo,
  String? contratoCodigo,
  String? planNombre,
});

/// Resuelve contra la réplica local a qué cliente/contrato/plan apunta la
/// solicitud.
///
/// Por qué por JOIN y no leyendo `datos`: las solicitudes de cancelar/
/// suspender/reactivar se crean con `datos` VACÍO (ver `solicitarAccion` en
/// `solicitud_accion_helper.dart`), así que quien aprueba un corte de servicio
/// sólo veía "quién lo pidió". Resolviéndolo por JOIN también funciona para las
/// solicitudes YA creadas —las pendientes de hoy— sin migrar ni rellenar nada.
///
/// Devuelve null si la entidad no está en la réplica local (borrada, o el rol
/// no sincroniza esa tabla): la tarjeta degrada mostrando un aviso discreto en
/// vez de campos vacíos.
final _infoEntidadProvider = FutureProvider.autoDispose
    .family<_InfoEntidad?, ({TipoSolicitud tipo, String entidadId})>(
        (ref, key) async {
  switch (key.tipo) {
    case TipoSolicitud.cancelarContrato:
    case TipoSolicitud.suspenderContrato:
    case TipoSolicitud.reactivarContrato:
    case TipoSolicitud.cambiarPlan:
      // Para estos tipos `entidad_id` ES el contrato_id. LEFT JOIN para que un
      // plan o cliente faltante no anule el resto del detalle.
      final row = await ps.db.getOptional(
        'SELECT ct.codigo AS contrato_codigo, '
        '       c.nombre  AS cliente_nombre, '
        '       c.codigo  AS cliente_codigo, '
        '       p.nombre  AS plan_nombre '
        '  FROM contratos ct '
        '  LEFT JOIN clientes c ON c.id = ct.cliente_id '
        '  LEFT JOIN planes   p ON p.id = ct.plan_id '
        ' WHERE ct.id = ?',
        [key.entidadId],
      );
      if (row == null) return null;
      return (
        clienteNombre: _texto(row['cliente_nombre']),
        clienteCodigo: _texto(row['cliente_codigo']),
        contratoCodigo: _texto(row['contrato_codigo']),
        planNombre: _texto(row['plan_nombre']),
      );

    case TipoSolicitud.crearContrato:
    case TipoSolicitud.desconocido:
      // Tipo que esta version no conoce: no se puede adivinar de que entidad
      // habla, asi que la tarjeta degrada sin datos en vez de consultar mal.
      return null;
    case TipoSolicitud.desactivarCliente:
      // Acá `entidad_id` es el cliente_id. En `crearContrato` el contrato
      // todavía NO existe: su plan y código propuesto salen de `datos`; lo
      // único que se resuelve local es el código del cliente.
      final row = await ps.db.getOptional(
        'SELECT nombre, codigo FROM clientes WHERE id = ?',
        [key.entidadId],
      );
      if (row == null) return null;
      return (
        clienteNombre: _texto(row['nombre']),
        clienteCodigo: _texto(row['codigo']),
        contratoCodigo: null,
        planNombre: null,
      );
  }
});

/// Recalcula EN VIVO la deuda que va a quedar cobrable si se aprueba el corte.
///
/// Por qué en vivo y no el snapshot de la solicitud: entre pedir y aprobar
/// pueden pasar días. Si el cliente pagó en el medio, mostrar el número
/// congelado haría que el admin corte el servicio de alguien que ya se puso al
/// día. Éste es el número que el sistema REALMENTE va a aplicar.
///
/// Usa `SolicitudesRepo.fechaEjecucion()` y el precio VIVO del plan: exactamente
/// lo que van a usar `_ejecutarSuspenderContrato` / `_ejecutarCancelarContrato`.
///
/// Devuelve null —y la tarjeta no pinta el bloque— si el contrato o su plan no
/// están en la réplica local. Mostrar C$0 sería peor que no mostrar nada: se
/// leería como "no debe nada".
///
/// "En vivo" de verdad: se cuelga de `contratoCuotasProvider`, que es un
/// `ps.db.watch` sobre cuotas + cargos_extra. Sin eso era un `FutureProvider`
/// de un solo disparo — calculaba al montarse la tarjeta y quedaba congelado
/// mientras la pantalla siguiera abierta. La cola de aprobaciones es la pantalla
/// de trabajo del admin: la deja abierta mientras los cobradores cobran en la
/// calle, así que el pago entraba por sync y el número no se movía. Ese es
/// exactamente el escenario que esta feature existe para evitar, solo que con
/// una ventana más corta.
final _deudaVivaProvider = FutureProvider.autoDispose
    .family<DeudaSnapshot?, ({TipoSolicitud tipo, String entidadId})>(
        (ref, key) async {
  final esCorte = key.tipo == TipoSolicitud.suspenderContrato ||
      key.tipo == TipoSolicitud.cancelarContrato;
  if (!esCorte) return null;
  // Dependencia de re-cálculo, no de datos: se usa el stream de cuotas del
  // contrato como disparador (cubre pagos vía `monto_pagado`, descuentos y
  // créditos vía `cargos_neto`, y anulaciones vía `estado`).
  await ref.watch(contratoCuotasProvider(key.entidadId).future);
  final row = await ps.db.getOptional(
    'SELECT ct.dia_pago, p.precio_mensual '
    '  FROM contratos ct '
    '  JOIN planes p ON p.id = ct.plan_id '
    ' WHERE ct.id = ?',
    [key.entidadId],
  );
  final precio = (row?['precio_mensual'] as num?)?.toDouble();
  if (precio == null) return null;
  final fecha = SolicitudesRepo.fechaEjecucion();
  final d = key.tipo == TipoSolicitud.cancelarContrato
      ? await ContratosRepo().previewDeudaCancelacion(
          contratoId: key.entidadId,
          fechaCancelacion: fecha,
          precioMensual: precio)
      : await ContratosRepo().previewDeudaSuspension(
          contratoId: key.entidadId,
          fechaSuspension: fecha,
          precioMensual: precio);
  return DeudaSnapshot(
    total: d.total,
    cuotas: d.cuotas,
    diaPago: (row?['dia_pago'] as num?)?.toInt(),
    precioMensual: precio,
    fecha: fecha,
  );
});

/// ¿El código de contrato que pide esta solicitud YA lo está usando otro?
/// Devuelve el nombre de quien lo tiene, o null si está libre.
///
/// Existe porque la revalidación al aprobar (v0.31.27) llega tarde para el
/// admin: le tira el error recién cuando ya apretó Aprobar, y no le dice de
/// quién es el código. Esta es la misma familia de fallo que hizo perder 14
/// contratos —dos gestores pidiendo el mismo número para clientes distintos—
/// solo que del lado de quien decide.
///
/// Pliega los dos lados con `foldBusqueda`/`foldSqlExpr` (regla #1d): los
/// códigos pueden traer ñ y acentos, y el `lower()` de SQLite es ASCII-only, así
/// que un choque real podría pasar desapercibido.
final _codigoOcupadoProvider = FutureProvider.autoDispose
    .family<String?, ({String tenantId, String codigo})>((ref, key) async {
  final row = await ps.db.getOptional(
    'SELECT cl.nombre AS n FROM contratos ct '
    'LEFT JOIN clientes cl ON cl.id = ct.cliente_id '
    'WHERE ct.tenant_id = ? AND ${foldSqlExpr('ct.codigo')} = ? LIMIT 1',
    [key.tenantId, foldBusqueda(key.codigo)],
  );
  if (row == null) return null;
  return _texto(row['n']) ?? 'otro contrato';
});

/// ¿El cliente de esta solicitud YA tiene contrato? Devuelve su código (o
/// 'sin código') si lo tiene, null si no.
///
/// Una solicitud de alta puede quedar OBSOLETA sin que nadie se entere: el
/// contrato se creó por otra vía —a mano, o aprobando una solicitud gemela— y
/// la vieja sigue esperando en la cola. Aprobarla ahí no crea nada: el ejecutor
/// corta con "este cliente ya tiene un contrato activo con ese plan", pero el
/// admin recién se entera al apretar. Al momento de agregar esto había 3 de 10
/// pendientes en ese estado.
final _clienteYaTieneContratoProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, clienteId) async {
  final row = await ps.db.getOptional(
    "SELECT codigo FROM contratos WHERE cliente_id = ? AND estado = 'activo' "
    'LIMIT 1',
    [clienteId],
  );
  if (row == null) return null;
  return _texto(row['codigo']) ?? 'sin código';
});

/// Señala que la deuda de HOY no coincide con la del pedido, y por qué — pero
/// SOLO cuando la causa se puede probar con lo que hay en el snapshot.
///
/// La primera versión afirmaba la causa por descarte: si el precio del plan no
/// había cambiado, toda baja era "el cliente pagó" y toda suba eran "días de
/// servicio consumidos, no deuda nueva". Las dos frases pueden ser FALSAS, y en
/// una pantalla donde se decide cortar un servicio eso vale más que un texto
/// impreciso:
///
///  · Bajan el total SIN que entre un peso: un descuento aplicado a la cuota, un
///    crédito a favor imputado (que el invariante #4 define explícitamente como
///    NO-pago: no toca `pagos` ni el arqueo), o una cuota anulada, que sale del
///    filtro `estado IN ('pendiente','parcial')` del preview.
///  · Suben el total y SÍ son deuda nueva: la anulación de un pago mal
///    registrado, o un cargo de mora/reconexión. Decirle al admin "no es deuda
///    nueva" justo cuando se cayó un pago es la peor lectura posible.
///
/// Lo único que el snapshot permite afirmar con certeza es el cambio de precio
/// del plan y el cambio de día de pago (los dos se guardan). El resto se reporta
/// como lo que es: una diferencia, sin inventarle causa.
String? _porQueCambioLaDeuda(DeudaSnapshot pedido, DeudaSnapshot hoy) {
  final delta = hoy.total - pedido.total;
  if (delta.abs() < 0.01) return null;
  final monto = Fmt.cordobas(delta.abs());
  final verbo = delta < 0 ? 'Bajó' : 'Subió';

  // Cambio de día de pago: corre la ventana de servicio y reclasifica la cuota
  // en curso (regla #1c). Mueve el total sin que nadie pague ni deba de más.
  if (pedido.diaPago != null &&
      hoy.diaPago != null &&
      pedido.diaPago != hoy.diaPago) {
    return '$verbo $monto: cambió el día de pago del contrato '
        '(${pedido.diaPago} → ${hoy.diaPago}), así que se corrió el mes de '
        'servicio.';
  }
  if ((hoy.precioMensual - pedido.precioMensual).abs() >= 0.01) {
    return '$verbo $monto: cambió el precio del plan desde que se pidió.';
  }
  return '$verbo $monto desde que se pidió. Puede ser un pago, un descuento, '
      'un crédito aplicado o días de servicio corridos: revisá la ficha del '
      'contrato antes de decidir.';
}

/// Normaliza a null los vacíos: así una columna en blanco no pinta una línea
/// "Plan: " colgada.
String? _texto(dynamic valor) {
  final s = valor?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

/// Línea "Etiqueta: valor" de la tarjeta. Mismo tamaño/tono que el detalle que
/// ya se mostraba; el valor va apenas más marcado para poder barrer la lista de
/// un vistazo (que es lo que hace quien aprueba).
Widget _linea(String etiqueta, String valor) {
  return Padding(
    padding: const EdgeInsets.only(top: 3),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$etiqueta: ',
            style: TextStyle(color: Colors.grey.shade600),
          ),
          TextSpan(
            text: valor,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade800,
            ),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 13),
    ),
  );
}

class _SolicitudCard extends ConsumerStatefulWidget {
  const _SolicitudCard({
    required this.solicitud,
    required this.esAdmin,
  });
  final SolicitudAccion solicitud;
  final bool esAdmin;

  @override
  ConsumerState<_SolicitudCard> createState() => _SolicitudCardState();
}

class _SolicitudCardState extends ConsumerState<_SolicitudCard> {
  bool _procesando = false;

  Future<void> _aprobar() async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final yo = ref.read(cobradorActualProvider).valueOrNull;
    if (yo == null) return;
    setState(() => _procesando = true);
    try {
      final repo = ref.read(solicitudesRepoProvider);
      await repo.ejecutarAccionAprobada(widget.solicitud, yo.id);
      await repo.aprobar(
            solicitudId: widget.solicitud.id,
            aprobadorId: yo.id,
            tenantId: yo.tenantId,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.solicitud.tipoLabel} aprobada y ejecutada'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  Future<void> _rechazar() async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final yo = ref.read(cobradorActualProvider).valueOrNull;
    if (yo == null) return;

    final motivo = await showDialog<String>(
      context: context,
      builder: (dctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('Motivo de rechazo'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Explicá por qué se rechaza...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (ctrl.text.trim().isEmpty) return;
                Navigator.of(dctx).pop(ctrl.text.trim());
              },
              child: const Text('Rechazar'),
            ),
          ],
        );
      },
    );
    if (motivo == null || motivo.isEmpty || !mounted) return;

    setState(() => _procesando = true);
    try {
      await ref.read(solicitudesRepoProvider).rechazar(
            solicitudId: widget.solicitud.id,
            aprobadorId: yo.id,
            tenantId: yo.tenantId,
            motivo: motivo,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Solicitud rechazada')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.solicitud;
    final color = switch (s.estado) {
      EstadoSolicitud.pendiente => Colors.orange,
      EstadoSolicitud.aprobada => Colors.green,
      EstadoSolicitud.rechazada => Colors.red,
    };
    final fecha = s.ocurridoEn;

    // ── De QUÉ cliente/contrato es ─────────────────────────────────────────
    // Sin esto el admin aprobaba a ciegas un corte de servicio: la tarjeta sólo
    // decía quién lo pidió. `datos` manda cuando trae el snapshot de lo pedido
    // (crearContrato); el resto sale del JOIN local contra la réplica.
    final datos = s.datos;
    // Ya resueltos por el modelo (columnas 0222 + fallback al JSON viejo): la
    // cadena de fallback vive en un solo lugar, no repetida acá.
    final motivoSolicitud = s.motivo;
    final notasSolicitud = s.notas;
    final infoAsync = ref.watch(
      _infoEntidadProvider((tipo: s.tipo, entidadId: s.entidadId)),
    );
    final info = infoAsync.valueOrNull;

    final clienteNombre = _texto(datos['cliente_nombre']) ?? info?.clienteNombre;
    final clienteCodigo = info?.clienteCodigo;
    final contratoCodigo = _texto(datos['codigo']) ?? info?.contratoCodigo;
    final planNombre = _texto(datos['plan_nombre']) ?? info?.planNombre;

    // El contrato no está en la réplica local (borrado, o el rol no lo
    // sincroniza). Se avisa sólo cuando la query YA terminó y no encontró nada
    // —mientras carga no se muestra nada, para no parpadear.
    final esDeContrato = s.tipo == TipoSolicitud.cancelarContrato ||
        s.tipo == TipoSolicitud.suspenderContrato ||
        s.tipo == TipoSolicitud.reactivarContrato ||
        s.tipo == TipoSolicitud.cambiarPlan;
    final entidadNoDisponible =
        esDeContrato && infoAsync.hasValue && info == null;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconTipo(s.tipo), size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.tipoLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(s.estadoLabel,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: color)),
                ),
              ],
            ),
            if (s.solicitanteLabel != null) ...[
              const SizedBox(height: 4),
              Text('Solicitó: ${s.solicitanteLabel}',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade600)),
            ],
            if (clienteNombre != null) _linea('Cliente', clienteNombre),
            if (clienteCodigo != null)
              _linea('Código de cliente', clienteCodigo),
            if (contratoCodigo != null)
              _linea('Código de contrato', contratoCodigo),
            if (planNombre != null)
              _linea(s.tipo == TipoSolicitud.cambiarPlan ? 'Plan actual' : 'Plan',
                  planNombre),
            // EL DETALLE DE LO QUE SE PIDE. Sin esto la tarjeta mostraba el
            // estado ACTUAL de la entidad y nada del cambio pedido: para un
            // cambio de plan, el admin veía el plan viejo y tenía que aprobar
            // sin saber a cuál se cambia ni con qué modo.
            ..._detallePedido(s),
            ..._bloqueDeuda(s),
            if (entidadNoDisponible)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Contrato no disponible en este dispositivo',
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey.shade500,
                  ),
                ),
              ),
            if (fecha.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(Fmt.fechaHoraNi(fecha),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
            if (motivoSolicitud != null) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.chat_bubble_outline,
                        size: 16, color: Colors.blueGrey.shade700),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        notasSolicitud != null
                            ? 'Motivo: $motivoSolicitud — $notasSolicitud'
                            : 'Motivo: $motivoSolicitud',
                        style: TextStyle(
                            fontSize: 12, color: Colors.blueGrey.shade700),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (s.motivoRechazo != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: Colors.red.shade700),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Motivo: ${s.motivoRechazo}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.red.shade700)),
                    ),
                  ],
                ),
              ),
            ],
            if (widget.esAdmin && s.esPendiente) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Rechazar'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700),
                    onPressed: _procesando ? null : _rechazar,
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: _procesando
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check, size: 18),
                    label: const Text('Aprobar'),
                    onPressed: _procesando ? null : _aprobar,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Cuánta deuda queda COBRABLE si se aprueba el corte.
  ///
  /// Es el dato que faltaba para poder decidir: hasta v0.31.29 el admin aprobaba
  /// suspensiones y cancelaciones sin ver un solo número de plata.
  ///
  /// Muestra el recálculo de HOY —lo que el sistema va a aplicar— y, si difiere
  /// de lo que vio quien lo pidió, una línea que explica por qué. Solo en las
  /// PENDIENTES: en una ya resuelta, "en vivo" no significaría nada.
  List<Widget> _bloqueDeuda(SolicitudAccion s) {
    if (!s.esPendiente) return const [];
    final viva = ref
        .watch(_deudaVivaProvider((tipo: s.tipo, entidadId: s.entidadId)))
        .valueOrNull;
    if (viva == null) return const [];
    final pedido = s.deudaSnapshot;
    final porQue = pedido == null ? null : _porQueCambioLaDeuda(pedido, viva);
    return [
      const SizedBox(height: 8),
      DeudaContratoBloque(
        total: viva.total,
        cuotas: viva.cuotas,
        diaPago: viva.diaPago,
        titulo: 'Deuda que quedaría cobrable',
        vacioTexto: 'No queda deuda cobrable.',
        // Compacto: el desglose mes a mes tapaba el resto del pedido. El
        // detalle completo está en la ficha del contrato.
        compacto: true,
      ),
      if (porQue != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '$porQue  (al pedirse: ${Fmt.cordobas(pedido!.total)})',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
          ),
        ),
    ];
  }

  /// Renglones con lo que el solicitante PIDIÓ, leídos de `datos`.
  ///
  /// La tarjeta resuelve el estado ACTUAL de la entidad por JOIN, que sirve
  /// para ubicarse pero no dice qué se quiere cambiar. Acá va el pedido en sí,
  /// que es lo que el admin necesita para decidir sin abrir otra pantalla.
  List<Widget> _detallePedido(SolicitudAccion s) {
    final d = s.datos;
    switch (s.tipo) {
      case TipoSolicitud.cambiarPlan:
        final nuevo = d['plan_nuevo_nombre'] as String?;
        final precio = (d['precio_nuevo'] as num?)?.toDouble();
        final viejo = (d['precio_viejo'] as num?)?.toDouble();
        final modoHoy = d['modo_hoy'] == true;
        return [
          if (nuevo != null) _linea('Cambiar a', nuevo),
          if (precio != null)
            _linea(
                'Precio nuevo',
                viejo != null
                    ? '${Fmt.cordobas(precio)}  (antes ${Fmt.cordobas(viejo)})'
                    : Fmt.cordobas(precio)),
          _linea(
              'Desde cuándo',
              modoHoy
                  ? 'Hoy, con prorrateo del ciclo en curso'
                  : 'El próximo ciclo (sin plata en el acto)'),
        ];
      case TipoSolicitud.crearContrato:
        // Avisos de que esta solicitud NO va a poder ejecutarse, ANTES de que
        // el admin apriete Aprobar. Solo en las pendientes: en una ya resuelta
        // el código lo ocupa —correctamente— el contrato que ella misma creó, y
        // el cliente tiene contrato por la misma razón.
        if (!s.esPendiente) return const [];
        final avisos = <String>[];

        final yaTiene =
            ref.watch(_clienteYaTieneContratoProvider(s.entidadId)).valueOrNull;
        if (yaTiene != null) {
          avisos.add('Este cliente YA tiene un contrato activo ($yaTiene), así '
              'que esta solicitud quedó vieja: aprobarla no va a crear nada. '
              'Rechazala.');
        }

        final cod = _texto(d['codigo']);
        if (cod != null) {
          final duenoActual = ref
              .watch(
                  _codigoOcupadoProvider((tenantId: s.tenantId, codigo: cod)))
              .valueOrNull;
          if (duenoActual != null) {
            avisos.add('El código $cod ya lo usa el contrato de $duenoActual. '
                'Si aprobás, el contrato no se va a poder crear: pedile al '
                'solicitante que lo cambie, o rechazá esta solicitud.');
          }
        }

        if (avisos.isEmpty) return const [];
        return [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 16, color: Colors.red.shade700),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      avisos.join('\n\n'),
                      style:
                          TextStyle(fontSize: 12, color: Colors.red.shade900),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ];
      case TipoSolicitud.cancelarContrato:
      case TipoSolicitud.suspenderContrato:
      case TipoSolicitud.reactivarContrato:
      case TipoSolicitud.desactivarCliente:
      case TipoSolicitud.desconocido:
        return const [];
    }
  }

  IconData _iconTipo(TipoSolicitud tipo) {
    switch (tipo) {
      case TipoSolicitud.crearContrato:
        return Icons.note_add;
      case TipoSolicitud.cancelarContrato:
        return Icons.cancel_outlined;
      case TipoSolicitud.suspenderContrato:
        return Icons.pause_circle_outline;
      case TipoSolicitud.reactivarContrato:
        return Icons.play_circle_outline;
      case TipoSolicitud.desactivarCliente:
        return Icons.person_off;
      case TipoSolicitud.cambiarPlan:
        return Icons.swap_horiz;
      case TipoSolicitud.desconocido:
        return Icons.help_outline;
    }
  }
}
