import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../data/models/deuda_snapshot.dart';
import '../../data/models/pago.dart';
import '../../data/providers/aprobaciones_provider.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/contrato_providers.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/providers/modulos_provider.dart';
import '../../data/repositories/contratos_repo.dart';
import '../../data/repositories/cuotas_repo.dart';
import '../../data/repositories/pagos_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/repositories/solicitudes_repo.dart';
import '../../data/services/imagen_compresion.dart';
import '../../data/utils/cuota_estado_visual.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../admin/inventario/equipos_en_baja.dart';
import '../admin/reportes/descarga_archivo.dart';
import '../admin/reportes/pdf/reporte_deuda_suspension_pdf.dart';
import '../cobro/cambio_fecha_dialog.dart';
import 'cambio_plan_dialog.dart';
import 'suspension_dialogs.dart';
import '../shared/widgets/cargo_dialog.dart';
import '../shared/widgets/descuento_dialog.dart';
import '../shared/widgets/deuda_contrato_bloque.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/foto_comprobante_view.dart';
import '../shared/widgets/impersonation_banner.dart';
import '../shared/widgets/historial_op_log.dart';
import '../../data/models/solicitud_accion.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/op_log.dart';
import '../shared/widgets/solicitud_accion_helper.dart';

import 'contrato_detail_header.dart' show ContratoHeaderCard;
import 'cuota_detalle_lectura.dart';
part 'contrato_detail_cuotas.dart';
part 'contrato_detail_pagos.dart';
part 'contrato_detail_documento.dart';

/// Lee el snapshot de la suspensión vigente del contrato y manda a imprimir el
/// PDF de la deuda. Compartido por el botón "Reimprimir deuda" de la tarjeta de
/// suspensión y por el prompt que aparece al confirmar una suspensión.
/// Re-consulta el snapshot (siempre fresco) y maneja errores con snackbar; no
/// usa showDialog de carga, así que nunca deja la UI trabada.
Future<void> imprimirDeudaSuspension({
  required BuildContext context,
  required WidgetRef ref,
  required String contratoId,
  String? clienteNombre,
  String? codigo,
  String? planNombre,
}) async {
  final rows = await ps.db.getAll(
    '''
    SELECT motivo, notas, suspendido_en, deuda_snapshot
      FROM contrato_suspensiones
     WHERE contrato_id = ? AND reactivado_en IS NULL
     ORDER BY date(suspendido_en) DESC LIMIT 1
    ''',
    [contratoId],
  );
  if (rows.isEmpty || !context.mounted) return;
  final row = rows.first;
  var total = 0.0;
  var cuotas = const <Map<String, dynamic>>[];
  int? diaPagoSnap;
  final snapRaw = row['deuda_snapshot'] as String?;
  if (snapRaw != null) {
    try {
      final snap = decodeSnapshotMap(snapRaw);
      total = (snap['total'] as num?)?.toDouble() ?? 0;
      diaPagoSnap = (snap['dia_pago'] as num?)?.toInt();
      cuotas = ((snap['cuotas'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {}
  }
  final empresa = ref.read(appSettingsProvider).empresaNombre;
  try {
    final doc = await buildPdfDeudaSuspension(
      empresaNombre: empresa.isEmpty ? 'ISP' : empresa,
      clienteNombre: clienteNombre ?? '—',
      codigo: codigo,
      planNombre: planNombre,
      suspendidoEn: row['suspendido_en'] as String? ?? '',
      motivo: row['motivo'] as String? ?? '',
      notas: row['notas'] as String?,
      diaPago: diaPagoSnap,
      cuotas: cuotas,
      total: total,
    );
    if (!context.mounted) return;
    // "Guardar como" (mismo flujo que los reportes). El nombre lleva timestamp
    // central → cada reimpresión sale como archivo distinto.
    await guardarPdfConAviso(
      // Doble cobertura: el `if (!context.mounted) return;` de arriba, y
      // `guardarPdfConAviso` que vuelve a chequear antes de su unico uso. El
      // aviso lo dispara el await ANIDADO en los argumentos (`await doc.save()`).
      // ignore: use_build_context_synchronously
      context,
      fileName: 'deuda_suspension${codigo != null ? '_$codigo' : ''}.pdf',
      bytes: await doc.save(),
      mensaje: 'PDF de deuda guardado',
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(mensajeErrorHumano(e, contexto: 'generar el PDF'))),
      );
    }
  }
}

/// Reimprime el documento de deuda de un contrato CANCELADO. Lee el snapshot
/// guardado en la propia fila del contrato (no hay tabla de suspensión). Mismo
/// PDF que la suspensión, parametrizado para "Cancelación".
Future<void> imprimirDeudaCancelacion({
  required BuildContext context,
  required WidgetRef ref,
  required String contratoId,
  String? clienteNombre,
  String? codigo,
  String? planNombre,
}) async {
  final rows = await ps.db.getAll(
    '''
    SELECT ct.motivo_cancelacion, ct.cancelado_en,
           ct.cancelacion_deuda_snapshot, ct.codigo,
           p.nombre AS plan_nombre, c.nombre AS cliente_nombre
      FROM contratos ct
 LEFT JOIN planes p ON p.id = ct.plan_id
 LEFT JOIN clientes c ON c.id = ct.cliente_id
     WHERE ct.id = ? LIMIT 1
    ''',
    [contratoId],
  );
  if (rows.isEmpty || !context.mounted) return;
  final row = rows.first;
  var total = 0.0;
  var cuotas = const <Map<String, dynamic>>[];
  int? diaPagoSnap;
  final snapRaw = row['cancelacion_deuda_snapshot'] as String?;
  if (snapRaw != null) {
    try {
      final snap = decodeSnapshotMap(snapRaw);
      total = (snap['total'] as num?)?.toDouble() ?? 0;
      diaPagoSnap = (snap['dia_pago'] as num?)?.toInt();
      cuotas = ((snap['cuotas'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {}
  }
  final empresa = ref.read(appSettingsProvider).empresaNombre;
  try {
    final doc = await buildPdfDeudaSuspension(
      empresaNombre: empresa.isEmpty ? 'ISP' : empresa,
      clienteNombre: clienteNombre ?? row['cliente_nombre'] as String? ?? '—',
      codigo: codigo ?? row['codigo'] as String?,
      planNombre: planNombre ?? row['plan_nombre'] as String?,
      suspendidoEn: row['cancelado_en'] as String? ?? '',
      motivo: row['motivo_cancelacion'] as String? ?? '',
      diaPago: diaPagoSnap,
      cuotas: cuotas,
      total: total,
      titulo: 'Estado de deuda — Cancelación de contrato',
      fechaPrefijo: 'Cancelación',
      fechaKvLabel: 'Cancelado el',
      pieNota:
          'Contrato cancelado. La deuda detallada sigue siendo cobrable. '
          'Documento informativo.',
    );
    if (!context.mounted) return;
    await guardarPdfConAviso(
      // Igual que el de arriba, en el PDF de cancelacion.
      // ignore: use_build_context_synchronously
      context,
      fileName: 'deuda_cancelacion${codigo != null ? '_$codigo' : ''}.pdf',
      bytes: await doc.save(),
      mensaje: 'PDF de deuda guardado',
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(mensajeErrorHumano(e, contexto: 'generar el PDF'))),
      );
    }
  }
}

/// Acciones rápidas del contrato: "Pagar" (cuota más vieja pendiente) y
/// "Cambiar fecha" (gateado por puedeCambiarFechaPagoProvider). Mismo flujo que
/// la lista de cobros y el mapa.
class _AccionesContrato extends ConsumerWidget {
  const _AccionesContrato({
    required this.contratoId,
    required this.estado,
    required this.diaPago,
    required this.precioMensual,
    this.planActualId,
    this.clienteNombre,
    this.codigo,
    this.planNombre,
    this.cobradorIdContrato,
  });

  final String contratoId;
  final String estado;
  final int? diaPago;
  final double? precioMensual;
  final String? planActualId;
  final String? clienteNombre;
  final String? codigo;
  final String? planNombre;
  // cobrador_id del contrato (denormalizado) — para el owner-scope del cobrador
  // en "Cambiar fecha".
  final String? cobradorIdContrato;

  /// Pide autorización para SUSPENDER o CANCELAR, con la deuda a la vista.
  ///
  /// Antes de v0.31.29 esto mandaba la solicitud pelada: quien pedía no veía
  /// cuánta deuda quedaba cobrable (el camino DIRECTO sí la muestra) y al admin
  /// le llegaba una tarjeta sin un solo número. Se pedía cortar el servicio a
  /// ciegas y se aprobaba a ciegas.
  ///
  /// La fecha del cálculo es `SolicitudesRepo.fechaEjecucion()` — la MISMA que
  /// va a usar el aprobador. Con `Fmt.hoyNicaragua()` (truncada a medianoche) o
  /// con la fecha cruda del dispositivo, el número mostrado no sería el que el
  /// sistema aplica, y la comparación contra el recálculo en vivo marcaría una
  /// diferencia permanente que no es un cambio real de deuda.
  ///
  /// Si algo falla —plan sin replicar, precio nulo, error del preview— la
  /// solicitud se manda IGUAL, sin bloque de deuda: perder la autorización por
  /// no poder pintar un número sería peor que el problema que resuelve.
  Future<void> _solicitarCorte(
      BuildContext context, WidgetRef ref, TipoSolicitud tipo) async {
    final esCancelar = tipo == TipoSolicitud.cancelarContrato;
    DeudaSnapshot? snap;
    final precio = precioMensual;
    if (precio != null) {
      try {
        final fecha = SolicitudesRepo.fechaEjecucion();
        final repo = ContratosRepo();
        // Las dos delegan en el MISMO cálculo; se usa cada nombre por claridad
        // en el call-site. `previewDeudaCancelacion` estaba escrita desde su
        // creación pero sin un solo consumidor: éste es el primero.
        final d = esCancelar
            ? await repo.previewDeudaCancelacion(
                contratoId: contratoId,
                fechaCancelacion: fecha,
                precioMensual: precio)
            : await repo.previewDeudaSuspension(
                contratoId: contratoId,
                fechaSuspension: fecha,
                precioMensual: precio);
        snap = DeudaSnapshot(
          total: d.total,
          cuotas: d.cuotas,
          diaPago: diaPago,
          precioMensual: precio,
          fecha: fecha,
        );
      } catch (_) {
        snap = null;
      }
    }
    if (!context.mounted) return;
    await solicitarAccion(
      context: context,
      ref: ref,
      tipo: tipo,
      entidadId: contratoId,
      descripcionExtra:
          clienteNombre != null ? 'Cliente: $clienteNombre' : null,
      deuda: snap,
    );
  }

  Future<void> _suspender(BuildContext context, WidgetRef ref) async {
    if (precioMensual == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => SuspenderContratoDialog(
        contratoId: contratoId,
        precioMensual: precioMensual!,
        diaPago: diaPago,
        clienteNombre: clienteNombre,
      ),
    );
    if (ok != true || !context.mounted) return;
    // Prompt de impresión: el cobrador puede entregarle al cliente el detalle
    // de la deuda congelada en el acto. Diálogo de confirmación (lo cierra el
    // usuario); el pop usa el context del builder.
    final imprimir = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Contrato suspendido'),
        content: const Text(
            '¿Imprimir el detalle de la deuda para entregárselo al cliente?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Ahora no'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.print_outlined, size: 18),
            label: const Text('Imprimir'),
            onPressed: () => Navigator.of(dctx).pop(true),
          ),
        ],
      ),
    );
    if (imprimir == true && context.mounted) {
      await imprimirDeudaSuspension(
        context: context,
        ref: ref,
        contratoId: contratoId,
        clienteNombre: clienteNombre,
        codigo: codigo,
        planNombre: planNombre,
      );
    }
  }

  Future<void> _pagar(BuildContext context) async {
    final rows = await ps.db.getAll(
      'SELECT id FROM cuotas WHERE contrato_id = ? '
      "AND estado IN ('pendiente','parcial') "
      'ORDER BY date(fecha_vencimiento) ASC, date(periodo) ASC LIMIT 1',
      [contratoId],
    );
    if (!context.mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay cuotas pendientes.')),
      );
      return;
    }
    context.push('/cobro/${rows.first['id']}');
  }

  Future<void> _cambiarFecha(BuildContext context) async {
    if (diaPago == null || precioMensual == null) return;
    final reciboId = await showDialog<String>(
      context: context,
      builder: (_) => CambioFechaDialog(
        contratoId: contratoId,
        diaPagoActual: diaPago!,
        precioMensual: precioMensual!,
        clienteNombre: clienteNombre,
      ),
    );
    if (reciboId != null && context.mounted) {
      context.push('/recibo/$reciboId');
    }
  }

  /// Pedir el cambio de plan (0226). Mismo diálogo que el camino directo —así
  /// el que pide VE la misma vista previa de la matemática— pero en modo
  /// selección: no toca nada y devuelve qué se pidió. Después va al helper
  /// común, que exige motivo y notas.
  Future<void> _solicitarCambioPlan(BuildContext context, WidgetRef ref) async {
    if (diaPago == null || precioMensual == null) return;
    final sel = await showDialog<
        ({String planId, String? planNombre, double precio, bool modoHoy})>(
      context: context,
      builder: (_) => CambioPlanDialog(
        contratoId: contratoId,
        diaPago: diaPago!,
        planActualId: planActualId,
        precioActual: precioMensual!,
        planActualNombre: planNombre,
        clienteNombre: clienteNombre,
        soloSeleccionar: true,
      ),
    );
    if (sel == null || !context.mounted) return;
    await solicitarAccion(
      context: context,
      ref: ref,
      tipo: TipoSolicitud.cambiarPlan,
      entidadId: contratoId,
      descripcionExtra: [
        if (clienteNombre != null) 'Cliente: $clienteNombre',
        'De ${planNombre ?? 'plan actual'} a ${sel.planNombre ?? 'plan nuevo'}',
        sel.modoHoy ? 'Desde hoy, con prorrateo' : 'Desde el próximo ciclo',
      ].join(' · '),
      datos: {
        'plan_nuevo_id': sel.planId,
        'plan_nuevo_nombre': sel.planNombre,
        'precio_nuevo': sel.precio,
        'modo_hoy': sel.modoHoy,
        'plan_viejo_id': planActualId,
        'plan_viejo_nombre': planNombre,
        'precio_viejo': precioMensual,
      },
    );
  }

  Future<void> _cambiarPlan(BuildContext context, WidgetRef ref) async {
    if (diaPago == null || precioMensual == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => CambioPlanDialog(
        contratoId: contratoId,
        diaPago: diaPago!,
        planActualId: planActualId,
        precioActual: precioMensual!,
        planActualNombre: planNombre,
        clienteNombre: clienteNombre,
      ),
    );
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Plan cambiado')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mismos gates que Suspender/Cambiar plan (no impersonando + estado activo)
    // MÁS el owner-scope del cobrador que ya tienen la lista de Cobros y el mapa:
    // el server (RLS 0119) sólo deja re-fechar cuotas PROPIAS, así que sin este
    // gate un cobrador re-fecharía un cliente ajeno → cobra el "puente" pero el
    // re-anclaje se rechaza al sincronizar = cobro fantasma (audit Fable 5).
    final yo = ref.watch(cobradorActualProvider).valueOrNull;
    final esCobradorPuro = yo?.esCobrador ?? false;
    final esAdminUsuarios = yo?.esAdminUsuarios ?? false;
    // `lectura` (0198) no ejecuta NINGUNA acción. Se suma explícito porque
    // estos flags están escritos como denylist ("todos menos admin_usuarios"):
    // sin esto un rol nuevo hereda permiso por omisión.
    final soloLectura = ref.watch(soloLecturaProvider);
    final contratoEsMio = cobradorIdContrato == yo?.id;
    // admin_usuarios no cobra ni cambia fecha — ocultar ambos.
    final mostrarPagar = !esAdminUsuarios && !soloLectura;
    final mostrarCambioFecha = !esAdminUsuarios && !soloLectura &&
        ref.watch(puedeCambiarFechaPagoProvider) &&
        !ref.watch(estaImpersonandoProvider) &&
        estado == 'activo' &&
        diaPago != null &&
        precioMensual != null &&
        (!esCobradorPuro || contratoEsMio);
    // Gate del "Cambiar plan": feature ON (super_admin) + contrato activo + no
    // impersonando. El ROL ya no decide si lo VE, decide si lo EJECUTA o lo
    // PIDE: antes `puedeCambiarPlanProvider` exigía admin, así que el
    // admin_cobranza ni siquiera lo veía — y terminaba cancelando y recreando
    // el contrato, que es como se hacen hoy 3 de cada 4 "cancelaciones".
    final mostrarCambiarPlan = ref.watch(puedeVerCambiarPlanProvider) &&
        !ref.watch(estaImpersonandoProvider) &&
        estado == 'activo' &&
        diaPago != null &&
        precioMensual != null;
    final mostrarSuspender = ref.watch(puedeSuspenderProvider) &&
        !ref.watch(estaImpersonandoProvider) &&
        estado == 'activo' &&
        precioMensual != null;
    // ¿Pide aprobación? Se decide por ACCIÓN, no por rol (ver
    // aprobaciones_provider.dart). Antes cada botón preguntaba
    // `esAdminUsuarios ? solicitar : directo`, así que el admin_cobranza —y
    // cualquier rol futuro— ejecutaba directo POR DESCARTE.
    final pideAprobacionSuspender =
        ref.watch(requiereAprobacionProvider(AccionSensible.suspenderContrato));
    final pideAprobacionCancelar =
        ref.watch(requiereAprobacionProvider(AccionSensible.cancelarContrato));
    final pideAprobacionPlan =
        ref.watch(requiereAprobacionProvider(AccionSensible.cambiarPlan));
    return Column(
      children: [
        if (mostrarPagar) Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.payments, size: 18),
                label: const Text('Pagar'),
                onPressed: () => _pagar(context),
              ),
            ),
            if (mostrarCambioFecha) ...[
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                  label: const Text('Cambiar fecha'),
                  onPressed: () => _cambiarFecha(context),
                ),
              ),
            ],
          ],
        ),
        if (mostrarSuspender) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: Icon(
                pideAprobacionSuspender
                    ? Icons.approval
                    : Icons.pause_circle_outline,
                size: 18,
              ),
              label: Text(pideAprobacionSuspender
                  ? 'Solicitar suspensión'
                  : 'Suspender contrato'),
              style:
                  OutlinedButton.styleFrom(foregroundColor: Colors.orange.shade800),
              onPressed: pideAprobacionSuspender
                  ? () => _solicitarCorte(
                      context, ref, TipoSolicitud.suspenderContrato)
                  : () => _suspender(context, ref),
            ),
          ),
        ],
        if (mostrarCambiarPlan) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: Icon(
                pideAprobacionPlan ? Icons.approval : Icons.swap_horiz,
                size: 18,
              ),
              label: Text(pideAprobacionPlan
                  ? 'Solicitar cambio de plan'
                  : 'Cambiar plan'),
              onPressed: pideAprobacionPlan
                  ? () => _solicitarCambioPlan(context, ref)
                  : () => _cambiarPlan(context, ref),
            ),
          ),
        ],
        // Cancelar por SOLICITUD: antes esta rama era solo para admin_usuarios
        // y el admin_cobranza cancelaba directo desde el dropdown del header.
        // En producción resultó ser quien decide el 55% de las bajas.
        if (pideAprobacionCancelar &&
            ref.watch(puedeGestionarEstadoContratoProvider) &&
            !ref.watch(estaImpersonandoProvider) &&
            estado == 'activo') ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: const Text('Solicitar cancelación'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade700),
              onPressed: () => _solicitarCorte(
                  context, ref, TipoSolicitud.cancelarContrato),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tarjeta de suspensión vigente (Feature A): info + Reactivar.
// ---------------------------------------------------------------------------

class _SuspensionCard extends ConsumerStatefulWidget {
  const _SuspensionCard({
    required this.contratoId,
    required this.precioMensual,
    this.clienteNombre,
    this.codigo,
    this.planNombre,
  });
  final String contratoId;
  final double precioMensual;
  final String? clienteNombre;
  final String? codigo;
  final String? planNombre;

  @override
  ConsumerState<_SuspensionCard> createState() => _SuspensionCardState();
}

class _SuspensionCardState extends ConsumerState<_SuspensionCard> {
  // getAll en initState (no watch inline en build) — la tarjeta solo se muestra
  // mientras el contrato está suspendido; al reactivar el padre la quita.
  late final Future<List<Map<String, dynamic>>> _future = ps.db.getAll(
    '''
    SELECT motivo, notas, suspendido_en, deuda_snapshot
      FROM contrato_suspensiones
     WHERE contrato_id = ? AND reactivado_en IS NULL
     ORDER BY date(suspendido_en) DESC LIMIT 1
    ''',
    [widget.contratoId],
  );

  Future<void> _reactivar() async {
    final row = (await _future).isNotEmpty ? (await _future).first : null;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ReactivarContratoDialog(
        contratoId: widget.contratoId,
        precioMensual: widget.precioMensual,
        suspendidoEn: row?['suspendido_en'] != null
            ? DateTime.parse(row!['suspendido_en'] as String)
            : null,
      ),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contrato reactivado')),
      );
    }
  }

  /// Deshace una suspensión hecha por error: restaura el estado EXACTO previo
  /// (≠ Reactivar). El repo bloquea si se cobró algo después de suspender.
  Future<void> _revertir() async {
    if (bloqueadoPorImpersonacion(context, ref)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('¿Revertir la suspensión?'),
        content: const Text(
          'Vuelve al estado EXACTO previo: reactiva las cuotas que se anularon, '
          'restaura sus montos y el contrato vuelve a activo. Usalo solo si la '
          'suspensión fue un error. Queda registrado en el historial.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Volver')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Revertir')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;
    try {
      await ContratosRepo().revertirSuspension(
        contratoId: widget.contratoId,
        cobradorId: me.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Suspensión revertida — estado previo restaurado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(e is StateError
                  ? e.message
                  : 'No se pudo revertir la suspensión: $e')),
        );
      }
    }
  }

  Future<void> _reimprimir() => imprimirDeudaSuspension(
        context: context,
        ref: ref,
        contratoId: widget.contratoId,
        clienteNombre: widget.clienteNombre,
        codigo: widget.codigo,
        planNombre: widget.planNombre,
      );

  /// Cobra la cuota pendiente MÁS VIEJA del contrato (mora previa o el mes
  /// prorrateado), una a la vez, reusando el cobro normal (un recibo por cuota).
  /// Al saldar todas (0 pendiente), se habilita Reactivar.
  Future<void> _cobrarPendiente() async {
    final rows = await ps.db.getAll(
      'SELECT id FROM cuotas WHERE contrato_id = ? '
      "AND estado IN ('pendiente','parcial') "
      'ORDER BY date(fecha_vencimiento) ASC, date(periodo) ASC LIMIT 1',
      [widget.contratoId],
    );
    if (!mounted) return;
    if (rows.isEmpty) return;
    context.push('/cobro/${rows.first['id']}');
  }

  @override
  Widget build(BuildContext context) {
    final amber = Colors.orange.shade800;
    final amberDark = Colors.orange.shade900;
    final esAdminUsr =
        ref.watch(cobradorActualProvider).valueOrNull?.esAdminUsuarios ?? false;
    // Reactivar es acción de administración: solo admin/admin_cobranza y no al
    // impersonar (espeja mostrarSuspender). Otros ven la info pero sin botones;
    // RLS es el backstop server-side.
    final puedeAccionar = ref.watch(puedeSuspenderProvider) &&
        !ref.watch(estaImpersonandoProvider);
    // Deuda viva del contrato (mora previa + mes prorrateado). Mientras carga
    // (null) NO ofrecemos Reactivar. Reactivar exige 0 pendiente (cobrá primero).
    final recRows =
        ref.watch(contratoRecaudadoProvider(widget.contratoId)).valueOrNull;
    final cobrable = recRows == null
        ? null
        : (recRows.isEmpty
            ? 0.0
            : ((recRows.first['cobrable'] as num?) ?? 0).toDouble());
    final alDia = cobrable != null && cobrable < 0.01;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snap) {
        final row = (snap.data?.isNotEmpty ?? false) ? snap.data!.first : null;
        final motivo = row?['motivo'] as String?;
        final notas = row?['notas'] as String?;
        final suspendidoEn = row?['suspendido_en'] as String?;
        double? deudaTotal;
        if (row?['deuda_snapshot'] != null) {
          try {
            deudaTotal = ((jsonDecode(row!['deuda_snapshot'] as String)
                    as Map)['total'] as num?)
                ?.toDouble();
          } catch (_) {}
        }
        final desde = suspendidoEn != null
            ? Fmt.fechaCorta(DateTime.parse(suspendidoEn))
            : null;
        return Card(
          color: Colors.orange.withValues(alpha: 0.10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.pause_circle_outline, size: 18, color: amber),
                    const SizedBox(width: 6),
                    Text('Suspensión vigente',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, color: amber)),
                  ],
                ),
                const SizedBox(height: 6),
                if (desde != null || motivo != null)
                  Text(
                    [
                      if (desde != null) 'Desde el $desde',
                      if (motivo != null) 'Motivo: $motivo',
                    ].join(' · '),
                    style: TextStyle(fontSize: 13, color: amberDark),
                  ),
                if (notas != null && notas.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(notas, style: TextStyle(fontSize: 12, color: amberDark)),
                ],
                if (deudaTotal != null) ...[
                  const SizedBox(height: 2),
                  Text('Deuda al suspender: ${Fmt.cordobas(deudaTotal)}',
                      style: TextStyle(fontSize: 13, color: amberDark)),
                ],
                if (puedeAccionar) ...[
                  const SizedBox(height: 10),
                  if (!esAdminUsr && cobrable != null && !alDia)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                          'Cobrá lo pendiente (${Fmt.cordobas(cobrable)}) para reactivar — más vieja primero.',
                          style: TextStyle(fontSize: 12, color: amberDark)),
                    ),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (!esAdminUsr)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.print_outlined, size: 18),
                          label: const Text('Reimprimir deuda'),
                          style:
                              OutlinedButton.styleFrom(foregroundColor: amber),
                          onPressed: _reimprimir,
                        ),
                      if (!esAdminUsr &&
                          !ref.watch(requiereAprobacionProvider(
                              AccionSensible.suspenderContrato)))
                        OutlinedButton.icon(
                          icon: const Icon(Icons.undo, size: 18),
                          label: const Text('Revertir'),
                          style:
                              OutlinedButton.styleFrom(foregroundColor: amber),
                          onPressed: _revertir,
                        ),
                      if (alDia)
                        // Esta rama seguía preguntando por rol: el
                        // admin_cobranza reactivaba directo. Reactivar además
                        // MUEVE el día de pago del contrato, así que no es una
                        // acción menor.
                        ref.watch(requiereAprobacionProvider(
                                AccionSensible.reactivarContrato))
                            ? FilledButton.icon(
                                icon: const Icon(Icons.approval, size: 18),
                                label: const Text('Solicitar reactivación'),
                                onPressed: () => solicitarAccion(
                                  context: context,
                                  ref: ref,
                                  tipo: TipoSolicitud.reactivarContrato,
                                  entidadId: widget.contratoId,
                                ),
                              )
                            : FilledButton.icon(
                                icon: const Icon(
                                    Icons.play_circle_outline, size: 18),
                                label: const Text('Reactivar'),
                                onPressed: _reactivar,
                              )
                      else if (!esAdminUsr)
                        FilledButton.icon(
                          icon: const Icon(Icons.payments_outlined, size: 18),
                          label: const Text('Cobrar pendiente'),
                          onPressed: _cobrarPendiente,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// ContratoDetailScreen — detalle de contrato con cuotas y pagos.
// ---------------------------------------------------------------------------

/// Nota interna del CONTRATO (`contratos.notas`) — contexto del SERVICIO
/// ("instalación con cable extra, 40 m"). No confundir con `clientes.notas`,
/// que describe a la PERSONA y sobrevive a sus contratos.
///
/// Historia del campo: existía desde el principio y el formulario de alta lo
/// escribía, pero NUNCA se mostró en ninguna pantalla ni hubo forma de
/// editarlo — al momento de este cambio había 48 contratos en producción con
/// Historia del campo: el formulario de alta lo escribía y el header del
/// contrato lo mostraba en gris, pero NO había forma de editarlo — una nota mal
/// escrita al crear el contrato quedaba petrificada. Esta tarjeta reemplaza esa
/// vista del header (se sacó de ahí para no pintarla dos veces) y suma el
/// editor.
///
/// El editor es un diálogo acotado de UNA columna, NO se reabre
/// `ContratoFormScreen`: la edición del contrato se quitó a propósito porque
/// reabrir el form hacía divergir el contrato de sus cuotas. `notas` no
/// participa de ningún cálculo de plata, así que tocarla es inocuo.
class _NotaContratoCard extends ConsumerStatefulWidget {
  const _NotaContratoCard({
    required this.contratoId,
    required this.tenantId,
    required this.nota,
  });

  final String contratoId;
  final String tenantId;
  final String? nota;

  @override
  ConsumerState<_NotaContratoCard> createState() => _NotaContratoCardState();
}

class _NotaContratoCardState extends ConsumerState<_NotaContratoCard> {
  bool _guardando = false;

  Future<void> _editar() async {
    if (_guardando) return;
    final ctrl = TextEditingController(text: widget.nota ?? '');
    // Diálogo de CONFIRMACIÓN del usuario (lo cierra él) — uso válido de
    // showDialog. El guardado NO va acá adentro: corre después, con un flag de
    // estado, para no dejar una barrera colgada si falla (regla #7 del audit).
    final texto = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Nota del contrato'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          maxLength: 500,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Ej. Instalación con 40 m de cable adicional.',
            helperText: 'Uso interno: no sale en el recibo ni en ningún PDF.',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            // `dctx` (el context del builder), NO el del State: con GoRouter el
            // del State puede apuntar a otro navigator (regla #8 del audit).
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (texto == null) return; // canceló
    final nuevo = texto.isEmpty ? null : texto;
    if (nuevo == (widget.nota?.trim().isEmpty ?? true ? null : widget.nota)) {
      return; // sin cambios: no ensuciamos el historial
    }
    // El diálogo estuvo abierto un rato: si el contrato dejó de resolver en el
    // stream (borrado desde otro dispositivo, o el rol dejó de sincronizarlo),
    // este State ya está muerto y el setState de abajo explota (checklist #9).
    if (!mounted) return;

    setState(() => _guardando = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final me = ref.read(cobradorActualProvider).valueOrNull;
      final ahora = DateTime.now().toUtc();
      final actor = me != null
          ? await OpLog.actorDeUsuario(ps.db, me.id)
          : const OpLogActor.systemAdmin();
      await ps.dbW.writeTransaction((tx) async {
        // Ver el gemelo en `_NotaClienteCard`: sin el guard, `.first` sobre una
        // fila que ya no está tira StateError('No element') y ese texto le
        // llega crudo al usuario.
        final antesRows = await tx
            .getAll('SELECT * FROM contratos WHERE id = ?', [widget.contratoId]);
        if (antesRows.isEmpty) {
          throw StateError(
              'El contrato ya no está disponible en este dispositivo.');
        }
        final antes = antesRows.first;
        await tx.execute(
          'UPDATE contratos SET notas = ?, ocurrido_en = ? WHERE id = ?',
          [nuevo, ahora.toIso8601String(), widget.contratoId],
        );
        final despues = (await tx.getAll(
                'SELECT * FROM contratos WHERE id = ?', [widget.contratoId]))
            .first;
        // El diff sale por la allowlist: 'notas' se agregó a `contratos` en
        // audit_changelog.dart, y 0228 se lo sumó al override de los tenants
        // que ya tenían el setting guardado (si no, quedaba filtrado).
        await OpLog.escribirCambioEntidad(tx,
            tenantId: widget.tenantId,
            opId: OpLog.nuevoOpId(),
            entidad: 'contratos',
            entidadId: widget.contratoId,
            antes: antes,
            despues: despues,
            actor: actor,
            ocurridoEn: ahora);
      });
      if (mounted) {
        messenger.showSnackBar(SnackBar(
            content: Text(nuevo == null ? 'Nota borrada' : 'Nota guardada')));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Todos menos `lectura` — y ahora la base lo respalda. Este gate estuvo un
    // rato limitado a admin/admin_cobranza porque la RLS de `contratos` no
    // dejaba escribir al resto: escribían la nota, veían "Nota guardada" y el
    // server descartaba el UPDATE, así que la nota desaparecía sola al
    // siguiente checkpoint. **0230** cerró esa brecha: policy de UPDATE para
    // cualquier miembro del tenant + trigger que revierte TODA columna que no
    // sea `notas`. Sin ese trigger, abrir la fila para la nota habría abierto
    // también `precio_mensual`, `plan_id` y `estado` (la RLS es row-level, no
    // protege columnas).
    final puedeEditar = !ref.watch(soloLecturaProvider);
    final t = widget.nota?.trim() ?? '';

    // Sin nota y sin poder escribirla: no ocupamos espacio con una tarjeta vacía.
    if (t.isEmpty && !puedeEditar) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sticky_note_2_outlined,
                    size: 18, color: scheme.outline),
                const SizedBox(width: 8),
                Text('Nota del contrato',
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
                const Spacer(),
                if (puedeEditar)
                  _guardando
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton.icon(
                          onPressed: _editar,
                          icon: Icon(t.isEmpty ? Icons.add : Icons.edit,
                              size: 16),
                          label: Text(t.isEmpty ? 'Agregar' : 'Editar'),
                        ),
              ],
            ),
            if (t.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(t, style: const TextStyle(fontSize: 13)),
            ] else
              Text('Sin nota.',
                  style: TextStyle(fontSize: 13, color: scheme.outline)),
          ],
        ),
      ),
    );
  }
}

class ContratoDetailScreen extends ConsumerStatefulWidget {
  const ContratoDetailScreen({super.key, required this.contratoId});
  final String contratoId;

  @override
  ConsumerState<ContratoDetailScreen> createState() =>
      _ContratoDetailScreenState();
}

class _ContratoDetailScreenState extends ConsumerState<ContratoDetailScreen> {
  // Los 4 streams del detalle viven ahora en `contrato_providers.dart` como
  // `StreamProvider.autoDispose.family` keyed por contratoId. Cada sección los
  // consume vía `ref.watch(...)`. Ver el comment del provider para el por qué
  // (fix definitivo del "Stream has already been listened to").

  // --- multi-select ---
  final Set<String> _selected = {};
  _CuotaFiltro _filtro = _CuotaFiltro.todas;

  // Reentrancy guard: evita que un doble-tap del menú de estado dispare dos
  // cancelaciones concurrentes (cada una insertaría su propio descuento sobre
  // la misma cuota parcial → doble descuento).
  bool _procesandoEstado = false;

  // --- multi-select helpers ---

  void _toggleSelect(String cuotaId, List<String> orderedPendingIds) {
    setState(() {
      if (_selected.contains(cuotaId)) {
        // Al deseleccionar, quitar esta y todas las posteriores.
        final idx = orderedPendingIds.indexOf(cuotaId);
        for (var i = idx; i < orderedPendingIds.length; i++) {
          _selected.remove(orderedPendingIds[i]);
        }
      } else {
        // Solo permitir seleccionar si es la primera o la anterior ya
        // está seleccionada (consecutivas desde la más vieja).
        final idx = orderedPendingIds.indexOf(cuotaId);
        if (idx == 0 || (idx > 0 && _selected.contains(orderedPendingIds[idx - 1]))) {
          _selected.add(cuotaId);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cobrá primero las cuotas más antiguas (de la más vieja a la más nueva).'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    });
  }

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  // --- estado del contrato ---

  Future<void> _cambiarEstado(String nuevoEstado) async {
    if (_procesandoEstado) return;
    // A3/B2: cambiar el estado de un contrato es gestión del admin del tenant.
    // Mientras se impersona NO se permite NINGUNA transición — cancelar toca
    // dinero (prorratea/anula cuotas), y cualquier cambio de estado se auditaría
    // bajo la fila System del super_admin, no bajo el admin real. El dropdown
    // además se oculta del header al impersonar (defensa en profundidad).
    if (bloqueadoPorImpersonacion(context, ref)) return;
    // Confirmación (fix audit #8): 'cancelado' es PERMANENTE y toca dinero
    // (cancelar = dinámica de suspensión, 0123: deja viva la deuda real,
    // prorratea el mes en curso, anula futuras). Un tap equivocado en el
    // PopupMenu no puede ejecutarlo directo — exige motivo en un diálogo.
    CancelacionResultado? cancelRes;
    var precioCancelacion = 0.0;
    if (nuevoEstado == 'cancelado') {
      final pRows = await ps.db.getAll(
        'SELECT p.precio_mensual, ct.dia_pago FROM contratos ct '
        'JOIN planes p ON p.id = ct.plan_id WHERE ct.id = ?',
        [widget.contratoId],
      );
      precioCancelacion = pRows.isEmpty
          ? 0.0
          : ((pRows.first['precio_mensual'] as num?)?.toDouble() ?? 0);
      final diaPagoCancelacion =
          pRows.isEmpty ? null : (pRows.first['dia_pago'] as num?)?.toInt();
      final creditoOn = ref.read(appSettingsProvider).creditoExcedenteHabilitado;
      if (!mounted) return;
      final res = await showDialog<CancelacionResultado>(
        context: context,
        builder: (ctx) => _CancelarContratoDialog(
          contratoId: widget.contratoId,
          precioMensual: precioCancelacion,
          diaPago: diaPagoCancelacion,
          creditoOn: creditoOn,
        ),
      );
      if (res == null || res.motivo.isEmpty || !mounted) return;
      cancelRes = res;
    }
    _procesandoEstado = true;
    try {
      if (nuevoEstado == 'cancelado') {
        final me = ref.read(cobradorActualProvider).valueOrNull;
        final tenantId = ref.read(tenantIdProvider);
        if (me == null || tenantId == null) {
          throw Exception(
              'No se pudo identificar el usuario o el tenant activo');
        }
        // UTC-6 (Nicaragua) para el corte de prorrateo — igual que
        // cambio_plan_dialog. Con DateTime.now() device-local, un timezone ≠
        // Nicaragua (o entre 00-06h) podía clasificar mal el mes en curso y
        // sub/sobre-prorratear (audit 2026-06-30, regla #1b/#1c).
        final fechaCancelacion =
            DateTime.now().toUtc().subtract(const Duration(hours: 6));
        // Cancelar = dinámica de suspensión pero permanente (deuda viva cobrable,
        // prorrateo del mes en curso, anula futuras). Sin reactivación.
        await ContratosRepo().cancelarContrato(
          tenantId: tenantId,
          contratoId: widget.contratoId,
          cobradorId: me.id,
          fechaCancelacion: fechaCancelacion,
          precioMensual: precioCancelacion,
          motivo: cancelRes!.motivo,
        );
        // Decisión sobre el excedente (no-op si no hay o el setting está OFF).
        // Cancelación → sin fila de evento: origenEventoId = null.
        if (ref.read(appSettingsProvider).creditoExcedenteHabilitado) {
          await ContratosRepo().registrarDisposicionExcedente(
            contratoId: widget.contratoId,
            fechaCorte: fechaCancelacion,
            precioMensual: precioCancelacion,
            disposicion: cancelRes.disposicion,
            cobradorId: me.id,
            origenEventoId: null,
            motivo: cancelRes.motivoExcedente,
          );
        }
      } else {
        // Transición simple (volver a 'activo'): el repo hace el UPDATE y
        // emite op_log → la transición queda en el historial del contrato.
        final me = ref.read(cobradorActualProvider).valueOrNull;
        if (me == null) {
          throw Exception('No se pudo identificar el usuario');
        }
        await ContratosRepo().cambiarEstadoSimple(
          contratoId: widget.contratoId,
          cobradorId: me.id,
          nuevoEstado: nuevoEstado,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Estado cambiado a $nuevoEstado')),
        );
      }
      // Al cancelar: imprimir el documento de deuda + ofrecer gestionar equipos.
      if (nuevoEstado == 'cancelado' && mounted) {
        await imprimirDeudaCancelacion(
          context: context,
          ref: ref,
          contratoId: widget.contratoId,
        );
      }
      if (nuevoEstado == 'cancelado' && mounted) {
        await ofrecerGestionEquiposEnBaja(context, ref,
            contratoId: widget.contratoId, entidad: 'contrato');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e, contexto: 'cambiar el estado'))),
        );
      }
    } finally {
      _procesandoEstado = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esAdmin = cobrador != null &&
        (cobrador.esAdmin || cobrador.esAdminCobranza || cobrador.esSuperAdmin);
    final esAdminUsuarios = cobrador?.esAdminUsuarios ?? false;
    // El change-log / auditoría se oculta al cobrador puro (least-privilege:
    // si el rol aún no cargó → null → oculto). admin/admin_cobranza/super sí.
    final verHistorial = cobrador != null && !cobrador.esCobrador;
    // El AdminShell ya dibuja el banner de impersonación en /admin/*; evitamos
    // duplicarlo (solo lo ponemos inline en la variante push fuera del shell).
    final enAdminShell =
        GoRouterState.of(context).uri.path.startsWith('/admin');
    final settings = ref.watch(appSettingsProvider);
    final multiCuotaEnabled = !esAdminUsuarios &&
        !ref.watch(soloLecturaProvider) &&
        settings.pagoAdelantadoPermitido;
    final diasGracia = settings.diasGracia;
    // Equipos: solo admin con el módulo inventario activo (las inv_ no
    // sincronizan al cobrador).
    final inventarioOn = ref
            .watch(modulosHabilitadosProvider)
            .valueOrNull
            ?.contains('inventario') ??
        false;
    // A3: el super_admin impersonando no cancela contratos (se oculta la opción
    // del menú; el guard de `_cambiarEstado` lo refuerza).
    final enImpersonacion = ref.watch(estaImpersonandoProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Detalle del contrato'),
        actions: [
          if (verHistorial)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Historial de cambios',
              onPressed: () => _showChangeLog(context),
            ),
        ],
      ),
      body: ref.watch(contratoDetalleProvider(widget.contratoId)).when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(mensajeErrorHumano(e))),
        data: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.assignment_outlined,
              titulo: 'Contrato no encontrado',
            );
          }
          final contrato = rows.first;

          return Stack(
            children: [
              // En pantallas anchas centramos el contenido con un maxWidth
              // razonable (no estira la lectura infinitamente). Mobile/tablet
              // chico usan el ancho completo.
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: ListView(
                padding: EdgeInsets.only(
                  left: 16, right: 16, top: 16,
                  bottom: _selected.isNotEmpty ? 96 : 16,
                ),
                children: [
                  if (!enAdminShell) const ImpersonationBanner(),
                  ContratoHeaderCard(
                    contrato: contrato,
                    esAdmin: esAdmin,
                    esAdminCobranza: ref.watch(cobradorActualProvider).valueOrNull?.esAdminCobranza ?? false,
                    // El dropdown de estado del header ejecuta el cambio
                    // DIRECTO (incluido "Cancelado"). Era la puerta de al lado
                    // del botón "Solicitar cancelación": el admin_cobranza
                    // pedía permiso por un lado y cancelaba por el otro — y es
                    // quien decide el 55% de las bajas. Quien necesita
                    // aprobación ya no lo ve; usa el botón de solicitud.
                    onEstadoChanged: esAdmin &&
                            !ref.watch(requiereAprobacionProvider(
                                AccionSensible.cancelarContrato))
                        ? _cambiarEstado
                        : null,
                    contratoId: widget.contratoId,
                    enImpersonacion: enImpersonacion,
                  ),
                  const SizedBox(height: 12),
                  _AccionesContrato(
                    contratoId: widget.contratoId,
                    estado: contrato['estado'] as String? ?? 'activo',
                    diaPago: (contrato['dia_pago'] as num?)?.toInt(),
                    precioMensual:
                        (contrato['precio_mensual'] as num?)?.toDouble(),
                    planActualId: contrato['plan_id'] as String?,
                    clienteNombre: contrato['cliente_nombre'] as String?,
                    codigo: contrato['codigo'] as String?,
                    planNombre: contrato['plan_nombre'] as String?,
                    cobradorIdContrato: contrato['cobrador_id'] as String?,
                  ),
                  if ((contrato['estado'] as String?) == 'suspendido') ...[
                    const SizedBox(height: 12),
                    _SuspensionCard(
                      contratoId: widget.contratoId,
                      precioMensual:
                          (contrato['precio_mensual'] as num?)?.toDouble() ?? 0,
                      clienteNombre: contrato['cliente_nombre'] as String?,
                      codigo: contrato['codigo'] as String?,
                      planNombre: contrato['plan_nombre'] as String?,
                    ),
                  ],
                  if ((contrato['estado'] as String?) == 'cancelado') ...[
                    const SizedBox(height: 12),
                    _CancelacionCard(
                      contratoId: widget.contratoId,
                      clienteNombre: contrato['cliente_nombre'] as String?,
                      codigo: contrato['codigo'] as String?,
                      planNombre: contrato['plan_nombre'] as String?,
                    ),
                  ],
                  const SizedBox(height: 12),
                  _NotaContratoCard(
                    contratoId: widget.contratoId,
                    tenantId: contrato['tenant_id'] as String,
                    nota: contrato['notas'] as String?,
                  ),
                  const SizedBox(height: 24),
                  // Cuotas + Historial de pagos: en desktop (ancho) lado a lado
                  // (doble panel); en pantallas angostas se apilan. Mismo
                  // contenido, filtros y badges de siempre.
                  LayoutBuilder(
                    builder: (ctx, c) {
                      final cuotas = _CuotasSection(
                        contratoId: widget.contratoId,
                        diasGracia: diasGracia,
                        multiSelect: multiCuotaEnabled,
                        selected: _selected,
                        filtro: _filtro,
                        onFiltroChanged: (f) {
                          setState(() => _filtro = f);
                          _clearSelection();
                        },
                        onToggle: _toggleSelect,
                        // `lectura` no va a /cobro (es el form de cobro y el
                        // router se lo bloquea): abre el detalle en solo
                        // lectura, para poder revisar la cuota igual.
                        onTapCuota: esAdminUsuarios
                            ? null
                            : ref.watch(soloLecturaProvider)
                                ? (cuotaId) =>
                                    mostrarCuotaSoloLectura(context, cuotaId)
                                : (cuotaId) => context.push('/cobro/$cuotaId'),
                        onLongPressCuota: multiCuotaEnabled
                            ? (cuotaId, orderedIds) =>
                                _toggleSelect(cuotaId, orderedIds)
                            : null,
                      );
                      final panelDerecho = esAdminUsuarios
                          ? const SizedBox.shrink()
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _PagosSection(
                                  contratoId: widget.contratoId,
                                  esAdmin: esAdmin,
                                ),
                                _SaldoFavorContratoSection(
                                    contratoId: widget.contratoId),
                              ],
                            );
                      if (c.maxWidth >= 820) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: cuotas),
                            const SizedBox(width: 20),
                            Expanded(child: panelDerecho),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          cuotas,
                          const SizedBox(height: 24),
                          panelDerecho,
                        ],
                      );
                    },
                  ),
                  // `lectura` (0198) también ve los equipos: es consulta.
                  if (inventarioOn &&
                      (esAdmin || ref.watch(soloLecturaProvider))) ...[
                    const SizedBox(height: 24),
                    _EquiposContratoSection(contratoId: widget.contratoId),
                  ],
                  // Documento del contrato: movido al final (fuera del medio).
                  const SizedBox(height: 24),
                  _DocumentoContratoSection(
                    contratoId: widget.contratoId,
                    documentoPath: contrato['documento_path'] as String?,
                    tenantId: contrato['tenant_id'] as String? ?? '',
                    esAdmin: esAdmin,
                  ),
                ],
              ),
                ),
              ),
              // FAB multi-cobro
              // FAB multi-cobro: respeta el mismo maxWidth (1100) que el
              // contenido para no estirarse en pantallas anchas.
              if (_selected.isNotEmpty)
                Positioned(
                  left: 0, right: 0, bottom: 16,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            IconButton.filledTonal(
                              icon: const Icon(Icons.close),
                              onPressed: _clearSelection,
                              tooltip: 'Cancelar selección',
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                icon: const Icon(Icons.payment),
                                label: Text(_selected.length == 1
                                    ? 'Cobrar cuota'
                                    : 'Cobrar ${_selected.length} cuotas'),
                                onPressed: () {
                                  final ids = _selected.join(',');
                                  _clearSelection();
                                  context.push('/cobro/$ids');
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _showChangeLog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Historial de cambios',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: ctrl,
                child: HistorialOpLog(
                  entidad: 'contratos',
                  entidadId: widget.contratoId,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Equipos de inventario instalados bajo este contrato (gateado por módulo+admin)
// ---------------------------------------------------------------------------
class _EquiposContratoSection extends StatefulWidget {
  const _EquiposContratoSection({required this.contratoId});
  final String contratoId;

  @override
  State<_EquiposContratoSection> createState() =>
      _EquiposContratoSectionState();
}

class _EquiposContratoSectionState extends State<_EquiposContratoSection> {
  late final Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(
      '''
      SELECT s.id, s.serial, s.mac, p.nombre AS producto
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
       WHERE s.contrato_id = ? AND s.estado = 'instalado'
       ORDER BY p.nombre, s.serial
      ''',
      parameters: [widget.contratoId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stream,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text(mensajeErrorHumano(snap.error!)),
            );
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.router, size: 18, color: scheme.outline),
                  const SizedBox(width: 8),
                  Text('Sin equipos instalados',
                      style: TextStyle(color: scheme.outline)),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Icon(Icons.router, size: 20, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text('Equipos instalados',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(width: 8),
                    Text('(${rows.length})',
                        style: TextStyle(color: scheme.outline, fontSize: 13)),
                  ],
                ),
              ),
              ...rows.map((r) {
                final mac = r['mac'] as String?;
                return ListTile(
                  dense: true,
                  leading:
                      Icon(Icons.qr_code_2, color: scheme.outline, size: 22),
                  title: Text(r['serial'] as String),
                  subtitle: Text([
                    r['producto'] as String? ?? '',
                    if (mac != null && mac.isNotEmpty) 'MAC $mac',
                  ].join(' · ')),
                );
              }),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

/// Tarjeta de un contrato CANCELADO (dinámica de suspensión permanente):
/// motivo + fecha + deuda al cancelar + "Reimprimir documento". La deuda viva
/// se cobra desde la lista de cuotas del propio contrato (las cumplidas/en-curso
/// sobreviven). NO hay "Reactivar" (es permanente).
/// Deshace una cancelación hecha por error: restaura el estado EXACTO previo
/// (cuotas + mora) y reactiva el contrato. El repo bloquea si se cobró algo de
/// la deuda después de cancelar.
Future<void> _revertirCancelacion(
    BuildContext context, WidgetRef ref, String contratoId) async {
  if (bloqueadoPorImpersonacion(context, ref)) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text('¿Revertir la cancelación?'),
      content: const Text(
        'Vuelve al estado EXACTO previo: reactiva las cuotas que se anularon, '
        'restaura sus montos y el contrato vuelve a activo. Usalo solo si la '
        'cancelación fue un error. Queda registrado en el historial.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Volver')),
        FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Revertir')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final me = ref.read(cobradorActualProvider).valueOrNull;
  if (me == null) return;
  try {
    await ContratosRepo()
        .revertirCancelacion(contratoId: contratoId, cobradorId: me.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Cancelación revertida — contrato reactivado')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(e is StateError
                ? e.message
                : 'No se pudo revertir la cancelación: $e')),
      );
    }
  }
}

class _CancelacionCard extends ConsumerWidget {
  const _CancelacionCard({
    required this.contratoId,
    this.clienteNombre,
    this.codigo,
    this.planNombre,
  });
  final String contratoId;
  final String? clienteNombre;
  final String? codigo;
  final String? planNombre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Revertir es acción de admin/admin_cobranza y NO al impersonar (se
    // atribuiría al super_admin); el repo es el backstop. Reimprimir, en cambio,
    // lo puede ver cualquiera que vea el detalle.
    final puedeAccionar = ref.watch(puedeSuspenderProvider) &&
        !ref.watch(estaImpersonandoProvider);
    final esAdminUsr =
        ref.watch(cobradorActualProvider).valueOrNull?.esAdminUsuarios ?? false;
    return ref.watch(contratoDetalleProvider(contratoId)).maybeWhen(
          data: (rows) {
            if (rows.isEmpty) return const SizedBox.shrink();
            final c = rows.first;
            final motivo = c['motivo_cancelacion'] as String?;
            final canceladoEn = c['cancelado_en'] as String?;
            double total = 0;
            final snapRaw = c['cancelacion_deuda_snapshot'] as String?;
            if (snapRaw != null) {
              try {
                total = (decodeSnapshotMap(snapRaw)['total'] as num?)
                        ?.toDouble() ??
                    0;
              } catch (_) {}
            }
            final fecha =
                canceladoEn != null ? DateTime.tryParse(canceladoEn)?.toLocal() : null;
            final fechaLabel = fecha != null ? Fmt.fechaCorta(fecha) : '—';
            return Card(
              color: scheme.errorContainer.withValues(alpha: 0.3),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.cancel_outlined, size: 18, color: scheme.error),
                        const SizedBox(width: 8),
                        Text('Contrato cancelado · $fechaLabel',
                            style: TextStyle(
                                fontWeight: FontWeight.w600, color: scheme.error)),
                      ],
                    ),
                    if (motivo != null && motivo.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Motivo: $motivo',
                          style: TextStyle(
                              color: scheme.onSurfaceVariant, fontSize: 13)),
                    ],
                    const SizedBox(height: 4),
                    Text('Deuda al cancelar (cobrable): ${Fmt.cordobas(total)}',
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(
                      'Permanente: no se reactiva. La deuda se sigue cobrando '
                      'desde las cuotas del contrato (abajo).',
                      style: TextStyle(color: scheme.outline, fontSize: 11),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.print, size: 18),
                          label: const Text('Reimprimir documento'),
                          onPressed: () => imprimirDeudaCancelacion(
                            context: context,
                            ref: ref,
                            contratoId: contratoId,
                            clienteNombre: clienteNombre,
                            codigo: codigo,
                            planNombre: planNombre,
                          ),
                        ),
                        // Revertir una cancelación revive las cuotas anuladas
                        // y restaura montos: es un evento de dinero y no pide
                        // motivo por ningún camino. Queda para quien no
                        // necesita aprobación.
                        if (puedeAccionar &&
                            !esAdminUsr &&
                            !ref.watch(requiereAprobacionProvider(
                                AccionSensible.cancelarContrato)))
                          OutlinedButton.icon(
                            icon: const Icon(Icons.undo, size: 18),
                            label: const Text('Revertir cancelación'),
                            onPressed: () =>
                                _revertirCancelacion(context, ref, contratoId),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
          orElse: () => const SizedBox.shrink(),
        );
  }
}

/// Resultado del diálogo de cancelación: motivo + qué hacer con el excedente.
typedef CancelacionResultado = ({
  String motivo,
  String disposicion,
  String? motivoExcedente,
});

class _CancelarContratoDialog extends StatefulWidget {
  const _CancelarContratoDialog({
    required this.contratoId,
    required this.precioMensual,
    required this.diaPago,
    required this.creditoOn,
  });
  final String contratoId;
  final double precioMensual;
  final int? diaPago;
  final bool creditoOn;

  @override
  State<_CancelarContratoDialog> createState() => _CancelarContratoDialogState();
}

class _CancelarContratoDialogState extends State<_CancelarContratoDialog> {
  final _controller = TextEditingController();
  bool _valido = false;
  // Crédito por excedente (0127): decisión sobre lo pagado por adelantado.
  Future<({double total, List<Map<String, dynamic>> cuotas})>? _excedenteFuture;
  // Deuda que queda COBRABLE después de cancelar. Faltaba: el diálogo describía
  // el efecto en prosa ("deja viva la deuda real") sin un solo número, y
  // `previewDeudaCancelacion` existía desde su creación sin un solo consumidor.
  // O sea que el admin —que decide más de la mitad de las bajas— cancelaba a
  // ciegas mientras el que PEDÍA la cancelación sí veía el monto.
  late final Future<({double total, List<Map<String, dynamic>> cuotas})>
      _deudaFuture;
  String _disposicion = 'acreditar';
  final _motivoExcedenteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_actualizarValido);
    // UTC-6 (#1b): los previews deben clasificar el mes en curso por el MISMO
    // día de negocio que el corte real (_cambiarEstado usa UTC-6), sino el
    // número mostrado para decidir difiere del registrado (audit 2026-07-04).
    final fechaCorte =
        DateTime.now().toUtc().subtract(const Duration(hours: 6));
    _deudaFuture = ContratosRepo().previewDeudaCancelacion(
      contratoId: widget.contratoId,
      fechaCancelacion: fechaCorte,
      precioMensual: widget.precioMensual,
    );
    if (widget.creditoOn) {
      _excedenteFuture = ContratosRepo().previewExcedente(
        contratoId: widget.contratoId,
        fechaCorte: fechaCorte,
        precioMensual: widget.precioMensual,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _motivoExcedenteCtrl.dispose();
    super.dispose();
  }

  void _actualizarValido() {
    final v = _controller.text.trim().isNotEmpty;
    if (v != _valido) {
      setState(() => _valido = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('¿Cancelar este contrato?'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Es PERMANENTE: el servicio termina y el contrato NO se puede '
                'reactivar. La deuda real (meses cumplidos + lo consumido del mes '
                'en curso) queda COBRABLE; los meses futuros se anulan. Se imprime '
                'un documento con la deuda.',
              ),
              const SizedBox(height: 8),
              Text(
                'Si fue un error, podés Revertirla desde la tarjeta del contrato, '
                'mientras no hayas cobrado nada de la deuda.',
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.outline),
              ),
              const SizedBox(height: 12),
              // Cuánto queda cobrable, en números: el párrafo de arriba lo
              // describe en prosa y eso no alcanza para decidir.
              FutureBuilder<({double total, List<Map<String, dynamic>> cuotas})>(
                future: _deudaFuture,
                builder: (context, snap) => DeudaContratoBloque(
                  total: snap.data?.total ?? 0,
                  cuotas: snap.data?.cuotas ?? const [],
                  diaPago: widget.diaPago,
                  pieExtra: 'se imprime el documento de deuda',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Motivo de la cancelación (obligatorio)',
                  hintText: 'Ej. Mudanza, insatisfacción del servicio',
                  border: OutlineInputBorder(),
                ),
              ),
              if (widget.creditoOn)
                FutureBuilder<
                    ({double total, List<Map<String, dynamic>> cuotas})>(
                  future: _excedenteFuture,
                  builder: (context, snap) {
                    final total = snap.data?.total ?? 0;
                    if (total <= 0.005) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: DisposicionExcedenteSelector(
                        total: total,
                        disposicion: _disposicion,
                        onDisposicion: (v) => setState(() => _disposicion = v),
                        motivoController: _motivoExcedenteCtrl,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Volver'),
        ),
        FilledButton(
          onPressed: _valido
              ? () => Navigator.pop(
                    context,
                    (
                      motivo: _controller.text.trim(),
                      disposicion: _disposicion,
                      motivoExcedente: _motivoExcedenteCtrl.text.trim().isEmpty
                          ? null
                          : _motivoExcedenteCtrl.text.trim(),
                    ),
                  )
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: _valido ? Theme.of(context).colorScheme.error : null,
            foregroundColor: _valido ? Theme.of(context).colorScheme.onError : null,
          ),
          child: const Text('Cancelar contrato'),
        ),
      ],
    );
  }
}

