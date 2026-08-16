import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/utils/busqueda_cliente.dart'
    show foldBusqueda, foldSqlExpr;
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/selector_buscable.dart';
import '../reportes/excel/reporte_excel.dart' show descargarExcel;
import 'invariantes_detalle.dart';

/// Panel "Operaciones de datos" — SOLO super_admin. Corrige errores de carga
/// borrando data con PREVIEW + confirmación por tipeo + BACKUP (server) +
/// registro (data_ops_log). Tres operaciones predefinidas:
///
///   · limpiar_cliente   — conserva el cliente, borra su cobranza.
///   · eliminar_contrato — borra un contrato y su cobranza; cliente intacto.
///   · eliminar_cliente  — borra TODO + el cliente.
///
/// Cada borrado es atómico server-side (función SECURITY DEFINER 0147):
/// snapshot → borrado en orden FK → limpieza de op_log → log. El gate
/// is_super_admin() lo enforça también el server (defensa en profundidad).
///
/// Anti-pantalla-negra (regla #7 del audit): NADA de showDialog como loading;
/// el estado de carga es un flag local + overlay en el Stack. Guards `mounted`
/// tras cada await.
class DataOpsScreen extends ConsumerWidget {
  const DataOpsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;

    // Defensa en profundidad: aunque la ruta solo la alcanza el super_admin, si
    // un rol distinto llega acá, no mostramos las operaciones destructivas.
    if (!esSuperAdmin) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Sección exclusiva del Dev.'),
        ),
      );
    }

    final tenantId = ref.watch(tenantIdProvider) ?? '';
    final actorLabel = cobrador?.nombre;

    // Módulos opcionales habilitados para el tenant (impersonado). Las
    // operaciones de Tickets/Inventario solo aparecen si su módulo está ON.
    final modulos =
        ref.watch(modulosHabilitadosProvider).valueOrNull ?? const <String>{};
    final tickets = modulos.contains('tickets');
    final inventario = modulos.contains('inventario');

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _Intro(),
            const SizedBox(height: 12),
            // Diagnóstico (read-only): el cierre obligatorio de todo fix de dinero.
            _VerificarInvariantesCard(tenantId: tenantId),
            const SizedBox(height: 12),
            // Fix no-destructivo: generar el recibo de los pagos que quedaron
            // sin él (bajas de la colisión de correlativo — INV5).
            _GenerarRecibosFaltantesCard(
                tenantId: tenantId, actorLabel: actorLabel),
            const SizedBox(height: 12),
            if (inventario) ...[
              // Diagnóstico del stock: seriales + ledger de movimientos.
              _VerificarInvariantesCard(
                tenantId: tenantId,
                rpc: 'super_admin_verificar_invariantes_inventario',
                titulo: 'Verificar invariantes de inventario',
                descripcion:
                    'Corre chequeos de integridad del stock (seriales, '
                    'ubicaciones, ledger de movimientos). Solo lectura. Corrélo '
                    'después de cualquier corrección de inventario.',
                icono: Icons.inventory_2_outlined,
                mensajeSano: 'El inventario está estructuralmente sano.',
              ),
              const SizedBox(height: 12),
            ],
            if (tickets) ...[
              // Diagnóstico de tickets: estado, SLA, vínculo a incidentes.
              _VerificarInvariantesCard(
                tenantId: tenantId,
                rpc: 'super_admin_verificar_invariantes_tickets',
                titulo: 'Verificar invariantes de tickets',
                descripcion:
                    'Corre chequeos de tickets e incidentes (fecha de creación, '
                    'SLA, técnico asignado, tickets colgados de un incidente '
                    'resuelto). Solo lectura.',
                icono: Icons.confirmation_number_outlined,
                mensajeSano: 'Los tickets están consistentes.',
              ),
              const SizedBox(height: 12),
            ],
            // Operación masiva (organizativa, no toca dinero ni el historial de
            // quién cobró): reasignar todos los clientes de un cobrador a otro.
            _ReasignarCobradorCard(tenantId: tenantId, actorLabel: actorLabel),
            const SizedBox(height: 12),
            // ───────── TICKETS (solo si el módulo está habilitado) ─────────
            if (tickets) ...[
              _ReasignarMasivoCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Reasignar técnico en masa',
                descripcion:
                    'Mueve los tickets ACTIVOS de un técnico a otro (los '
                    'terminados conservan quién los resolvió). Útil cuando un '
                    'técnico se va o se balancea la carga.',
                icono: Icons.engineering_outlined,
                labelOrigen: 'Técnico de origen',
                labelDestino: 'Técnico de destino',
                fuente: _FuenteSel.cobradores,
                rpcPreview: 'super_admin_preview_reasignar_tecnico',
                rpcEjecutar: 'super_admin_ejecutar_reasignar_tecnico',
                unidadPlural: 'tickets',
                verboPasado: 'reasignados',
                verboBoton: 'Reasignar',
              ),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Cerrar tickets viejos sin actividad',
                descripcion:
                    'Cancela en masa los tickets abiertos/en proceso que llevan '
                    'más de N días sin ningún cambio. No toca los resueltos. '
                    'Reversible (reabrir).',
                icono: Icons.auto_delete_outlined,
                tipo: _OpInputTipo.numero,
                inputLabel: 'Días sin actividad',
                valorInicial: '90',
                paramName: 'p_dias',
                rpcPreview: 'super_admin_preview_cerrar_tickets_viejos',
                rpcEjecutar: 'super_admin_ejecutar_cerrar_tickets_viejos',
                verboBoton: 'Cancelar tickets',
                peligroso: true,
              ),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Reabrir un ticket cerrado',
                descripcion:
                    'Vuelve a abrir un ticket cerrado o cancelado por error, '
                    'identificándolo por su número (#).',
                icono: Icons.lock_open_outlined,
                tipo: _OpInputTipo.numero,
                inputLabel: 'Número de ticket (#)',
                paramName: 'p_correlativo',
                rpcPreview: 'super_admin_preview_reabrir_ticket',
                rpcEjecutar: 'super_admin_ejecutar_reabrir_ticket',
                verboBoton: 'Reabrir',
              ),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Resolver incidente y cerrar sus tickets',
                descripcion:
                    'Marca un incidente (corte) como resuelto y cierra todos sus '
                    'tickets activos de una sola vez.',
                icono: Icons.cell_tower_outlined,
                tipo: _OpInputTipo.selector,
                inputLabel: 'Incidente abierto',
                fuente: _FuenteSel.incidentesAbiertos,
                paramName: 'p_incidente',
                rpcPreview: 'super_admin_preview_resolver_incidente',
                rpcEjecutar: 'super_admin_ejecutar_resolver_incidente',
                verboBoton: 'Resolver y cerrar',
              ),
              const SizedBox(height: 12),
              // Toca un material de ticket → vive bajo Tickets (si no hay
              // consumos, el selector queda vacío).
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Reversar un consumo de material',
                descripcion:
                    'Devuelve al stock un material que se cargó por error en un '
                    'ticket, sin cancelar el ticket.',
                icono: Icons.settings_backup_restore_outlined,
                tipo: _OpInputTipo.selector,
                inputLabel: 'Consumo reciente',
                fuente: _FuenteSel.consumosRecientes,
                paramName: 'p_material',
                rpcPreview: 'super_admin_preview_reversar_consumo',
                rpcEjecutar: 'super_admin_ejecutar_reversar_consumo',
                verboBoton: 'Reversar',
              ),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Corregir fecha / SLA de un ticket',
                descripcion:
                    'Reancla la fecha de creación de un ticket cuyo SLA quedó roto '
                    'por un reloj de device mal. Verificá el SLA en la app después.',
                icono: Icons.event_repeat_outlined,
                tipo: _OpInputTipo.numero,
                inputLabel: 'Número de ticket (#)',
                paramName: 'p_correlativo',
                segundoLabel: 'Fecha correcta (AAAA-MM-DD)',
                segundoParam: 'p_fecha',
                rpcPreview: 'super_admin_preview_corregir_sla',
                rpcEjecutar: 'super_admin_ejecutar_corregir_sla',
                verboBoton: 'Corregir fecha',
                peligroso: true,
              ),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Anular un ticket (devolver materiales)',
                descripcion:
                    'Cancela un ticket creado por error y devuelve al stock los '
                    'materiales que se le habían consumido. Solo tickets activos.',
                icono: Icons.cancel_outlined,
                tipo: _OpInputTipo.numero,
                inputLabel: 'Número de ticket (#)',
                paramName: 'p_correlativo',
                rpcPreview: 'super_admin_preview_anular_ticket',
                rpcEjecutar: 'super_admin_ejecutar_anular_ticket',
                verboBoton: 'Anular ticket',
                peligroso: true,
              ),
              const SizedBox(height: 12),
            ],
            // ───────── INVENTARIO (solo si el módulo está habilitado) ─────────
            if (inventario) ...[
              _ReasignarMasivoCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Transferir equipos entre ubicaciones',
                descripcion:
                    'Mueve TODOS los equipos en stock de una ubicación a otra, en '
                    'una sola operación (con su movimiento en el ledger). Solo '
                    'equipos en stock; los instalados no se transfieren.',
                icono: Icons.move_down_outlined,
                labelOrigen: 'Ubicación de origen',
                labelDestino: 'Ubicación de destino',
                fuente: _FuenteSel.ubicaciones,
                rpcPreview: 'super_admin_preview_transferir_serial',
                rpcEjecutar: 'super_admin_ejecutar_transferir_serial',
                unidadPlural: 'equipos',
                verboPasado: 'transferidos',
                verboBoton: 'Transferir',
              ),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Dar de baja un equipo',
                descripcion:
                    'Marca un equipo como dado de baja (terminal) por su número '
                    'de serie. Lo saca del stock y lo desvincula del cliente.',
                icono: Icons.do_not_disturb_on_outlined,
                tipo: _OpInputTipo.texto,
                inputLabel: 'Número de serie',
                paramName: 'p_serial',
                rpcPreview: 'super_admin_preview_baja_serial',
                rpcEjecutar: 'super_admin_ejecutar_baja_serial',
                verboBoton: 'Dar de baja',
                peligroso: true,
              ),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Recuperar un equipo dañado',
                descripcion:
                    'Devuelve a stock un equipo que estaba marcado como dañado '
                    '(tras repararlo), por su número de serie.',
                icono: Icons.healing_outlined,
                tipo: _OpInputTipo.texto,
                inputLabel: 'Número de serie',
                paramName: 'p_serial',
                rpcPreview: 'super_admin_preview_recuperar_serial',
                rpcEjecutar: 'super_admin_ejecutar_recuperar_serial',
                verboBoton: 'Recuperar',
              ),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Reconciliar equipos huérfanos',
                descripcion:
                    'Devuelve a stock los equipos que figuran "instalados" pero '
                    'cuyo cliente ya no existe (quedaron colgados al borrar un '
                    'cliente). Sin esto inflan el conteo de stock.',
                icono: Icons.link_off_outlined,
                tipo: _OpInputTipo.ninguno,
                inputLabel: 'Equipos huérfanos',
                paramName: 'p_none',
                rpcPreview: 'super_admin_preview_reconciliar_huerfanos',
                rpcEjecutar: 'super_admin_ejecutar_reconciliar_huerfanos',
                verboBoton: 'Reconciliar',
              ),
              const SizedBox(height: 12),
              _AjusteConteoCard(tenantId: tenantId, actorLabel: actorLabel),
              const SizedBox(height: 12),
              _OpInputCard(
                tenantId: tenantId,
                actorLabel: actorLabel,
                titulo: 'Reversar un movimiento de stock',
                descripcion:
                    'Corrige un movimiento de granel mal cargado (ingreso/egreso/'
                    'ajuste) insertando el inverso. El stock se reajusta solo.',
                icono: Icons.undo_outlined,
                tipo: _OpInputTipo.selector,
                inputLabel: 'Movimiento (granel)',
                fuente: _FuenteSel.movimientosGranel,
                paramName: 'p_movimiento',
                rpcPreview: 'super_admin_preview_reversar_movimiento',
                rpcEjecutar: 'super_admin_ejecutar_reversar_movimiento',
                verboBoton: 'Reversar',
              ),
              const SizedBox(height: 12),
              _CorregirVinculoCard(tenantId: tenantId, actorLabel: actorLabel),
              const SizedBox(height: 12),
              _CorregirEstadoSerialCard(
                  tenantId: tenantId, actorLabel: actorLabel),
              const SizedBox(height: 12),
            ],
            _OperacionCard(
              tenantId: tenantId,
              actorLabel: actorLabel,
              titulo: 'Limpiar cliente',
              descripcion:
                  'Borra TODA la cobranza del cliente (contratos, cuotas, pagos, '
                  'recibos, suspensiones). El cliente se conserva.',
              labelTarget: 'Código de cliente',
              icono: Icons.cleaning_services_outlined,
              tipo: _TipoTarget.cliente,
              rpcPreview: 'super_admin_preview_limpiar_cliente',
              rpcEjecutar: 'super_admin_ejecutar_limpiar_cliente',
              paramTarget: 'p_cliente',
            ),
            const SizedBox(height: 12),
            _OperacionCard(
              tenantId: tenantId,
              actorLabel: actorLabel,
              titulo: 'Eliminar contrato',
              descripcion:
                  'Borra UN contrato y su cobranza (cuotas, pagos, recibos, '
                  'suspensiones). El cliente se conserva.',
              labelTarget: 'Código de contrato',
              icono: Icons.description_outlined,
              tipo: _TipoTarget.contrato,
              rpcPreview: 'super_admin_preview_eliminar_contrato',
              rpcEjecutar: 'super_admin_ejecutar_eliminar_contrato',
              paramTarget: 'p_contrato',
            ),
            const SizedBox(height: 12),
            _OperacionCard(
              tenantId: tenantId,
              actorLabel: actorLabel,
              titulo: 'Eliminar cliente',
              descripcion:
                  'Borra TODO: el cliente, sus contratos, cuotas, pagos, '
                  'recibos, etiquetas, fotos y visitas. Inventario y tickets '
                  'quedan desvinculados (no se borran).',
              labelTarget: 'Código de cliente',
              icono: Icons.person_remove_outlined,
              tipo: _TipoTarget.cliente,
              rpcPreview: 'super_admin_preview_eliminar_cliente',
              rpcEjecutar: 'super_admin_ejecutar_eliminar_cliente',
              paramTarget: 'p_cliente',
            ),
            const SizedBox(height: 12),
            if (tickets) ...[
              // Exportar (read-only): tickets del tenant a Excel.
              _ExportarCard(
                tenantId: tenantId,
                titulo: 'Exportar tickets a Excel',
                descripcion:
                    'Descarga todos los tickets del tenant (estado, cliente, '
                    'técnico, tipo, fechas) en una planilla.',
                icono: Icons.file_download_outlined,
                fileNamePrefix: 'tickets',
                hojaNombre: 'Tickets',
                headers: const [
                  '#',
                  'Título',
                  'Estado',
                  'Prioridad',
                  'Cliente',
                  'Tipo',
                  'Técnico',
                  'Creado',
                  'Resuelto'
                ],
                cargarFilas: (t) async {
                  final rows = await ps.db.getAll(
                    'SELECT t.correlativo, t.titulo, t.estado, t.prioridad, '
                    'c.nombre AS cliente, ti.nombre AS tipo, cob.nombre AS tecnico, '
                    'substr(t.created_at,1,10) AS creado, '
                    'substr(t.resuelto_en,1,10) AS resuelto FROM tickets t '
                    'LEFT JOIN clientes c ON c.id = t.cliente_id '
                    'LEFT JOIN ticket_tipos ti ON ti.id = t.tipo_id '
                    'LEFT JOIN cobradores cob ON cob.id = t.asignado_a '
                    'WHERE t.tenant_id = ? ORDER BY t.correlativo DESC',
                    [t],
                  );
                  return [
                    for (final r in rows)
                      [
                        r['correlativo'],
                        r['titulo'],
                        r['estado'],
                        r['prioridad'],
                        r['cliente'],
                        r['tipo'],
                        r['tecnico'],
                        r['creado'],
                        r['resuelto']
                      ],
                  ];
                },
              ),
              const SizedBox(height: 12),
            ],
            if (inventario) ...[
              // Exportar (read-only): inventario serializado del tenant a Excel.
              _ExportarCard(
                tenantId: tenantId,
                titulo: 'Exportar inventario a Excel',
                descripcion:
                    'Descarga el inventario serializado del tenant (equipo, estado, '
                    'ubicación, cliente, costo) en una planilla.',
                icono: Icons.inventory_outlined,
                fileNamePrefix: 'inventario',
                hojaNombre: 'Inventario',
                headers: const [
                  'Serie',
                  'MAC',
                  'Producto',
                  'Estado',
                  'Ubicación',
                  'Cliente',
                  'Costo'
                ],
                cargarFilas: (t) async {
                  final rows = await ps.db.getAll(
                    'SELECT s.serial, s.mac, p.nombre AS producto, s.estado, '
                    'u.nombre AS ubicacion, c.nombre AS cliente, s.costo_ingreso '
                    'FROM inv_seriales s '
                    'JOIN inv_productos p ON p.id = s.producto_id '
                    'LEFT JOIN inv_ubicaciones u ON u.id = s.ubicacion_id '
                    'LEFT JOIN clientes c ON c.id = s.cliente_id '
                    'WHERE s.tenant_id = ? ORDER BY p.nombre, s.serial',
                    [t],
                  );
                  return [
                    for (final r in rows)
                      [
                        r['serial'],
                        r['mac'],
                        r['producto'],
                        r['estado'],
                        r['ubicacion'],
                        r['cliente'],
                        r['costo_ingreso']
                      ],
                  ];
                },
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            _HistorialOperaciones(tenantId: tenantId, actorLabel: actorLabel),
          ],
        ),
      ),
    );
  }
}

enum _TipoTarget { cliente, contrato }

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: scheme.error),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Operaciones de corrección de errores de carga. Cada borrado '
                'guarda un respaldo restaurable y queda registrado. Usalas solo '
                'para arreglar data mal importada.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card del módulo Operaciones (super_admin): corre los 20 invariantes de dinero
/// del tenant en contexto vía RPC `super_admin_verificar_invariantes` (0153;
/// INV18-INV20 se sumaron en 0220) y muestra el resultado. SOLO LECTURA — es el
/// cierre obligatorio de todo fix de dinero, ahora sin abrir el SQL Editor del
/// Dashboard. Anti-pantalla-negra (regla #7): flag local + render inline, nada
/// de showDialog.
class _VerificarInvariantesCard extends ConsumerStatefulWidget {
  const _VerificarInvariantesCard({
    required this.tenantId,
    this.rpc = 'super_admin_verificar_invariantes',
    this.titulo = 'Verificar invariantes de dinero',
    this.descripcion =
        'Corre 20 chequeos de integridad contable sobre este tenant '
            '(pagos, cuotas, recibos, cargos, saldo a favor, clientes). '
            'Solo lectura. Corrélo después de cualquier corrección de datos.',
    this.icono = Icons.health_and_safety_outlined,
    this.mensajeSano = 'El tenant está contablemente sano.',
  });
  final String tenantId;
  final String rpc;
  final String titulo;
  final String descripcion;
  final IconData icono;
  final String mensajeSano;
  @override
  ConsumerState<_VerificarInvariantesCard> createState() =>
      _VerificarInvariantesCardState();
}

class _VerificarInvariantesCardState
    extends ConsumerState<_VerificarInvariantesCard> {
  bool _isLoading = false;
  bool _isFixing = false;
  String? _error;
  List<Map<String, dynamic>>? _resultado;
  Map<String, int>? _fixResult;

  // Registros resueltos por código INV (se cargan después del RPC).
  final Map<String, List<RegistroResuelto>> _resueltos = {};

  String _mensajeError(Object e) {
    if (e is PostgrestException) return e.message;
    return e.toString().replaceFirst('Exception: ', '');
  }

  int _viol(Map<String, dynamic> f) => (f['violaciones'] as num?)?.toInt() ?? 0;

  bool get _hayAutoFixeables {
    final filas = _resultado;
    if (filas == null) return false;
    return filas.any((f) {
      if (_viol(f) == 0) return false;
      final codigo = extraerCodigoInv(f['invariante'] as String? ?? '');
      return codigo != null && kAutoFixCodes.contains(codigo);
    });
  }

  int get _totalAutoFixeables {
    final filas = _resultado;
    if (filas == null) return 0;
    var total = 0;
    for (final f in filas) {
      if (_viol(f) == 0) continue;
      final codigo = extraerCodigoInv(f['invariante'] as String? ?? '');
      if (codigo != null && kAutoFixCodes.contains(codigo)) {
        total += _viol(f);
      }
    }
    return total;
  }

  Future<void> _verificar() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _resultado = null;
      _resueltos.clear();
      _fixResult = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        widget.rpc,
        params: {'p_tenant': widget.tenantId},
      );
      if (!mounted) return;
      final filas = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() => _resultado = filas);

      for (final f in filas) {
        if (_viol(f) == 0) continue;
        final invStr = f['invariante'] as String? ?? '';
        final codigo = extraerCodigoInv(invStr);
        final ids = f['ejemplo_ids'] as String? ?? '';
        if (codigo != null && ids.isNotEmpty) {
          try {
            final registros = await resolverIds(codigo, ids);
            if (mounted) {
              setState(() => _resueltos[codigo] = registros);
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _corregirTodo() async {
    setState(() {
      _isFixing = true;
      _error = null;
      _fixResult = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'super_admin_corregir_invariantes',
        params: {'p_tenant': widget.tenantId},
      );
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      final result = <String, int>{};
      for (final e in map.entries) {
        result[e.key] = (e.value as num?)?.toInt() ?? 0;
      }
      setState(() => _fixResult = result);

      final total = result.values.fold<int>(0, (a, b) => a + b);
      if (mounted && total > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1B7A3D),
            content: Text('$total registro(s) corregido(s). '
                'Verificá de nuevo para confirmar.'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isFixing = false);
    }
  }

  Color _colorSeveridad(String sev) {
    switch (sev) {
      case 'critica':
        return const Color(0xFFD32F2F);
      case 'alta':
        return const Color(0xFFE65100);
      case 'media':
        return const Color(0xFFF9A825);
      default:
        return const Color(0xFF1565C0);
    }
  }

  String _labelSeveridad(String sev) {
    switch (sev) {
      case 'critica':
        return 'CRÍTICA';
      case 'alta':
        return 'ALTA';
      case 'media':
        return 'MEDIA';
      default:
        return 'INFO';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filas = _resultado;
    final fallidas = filas?.where((f) => _viol(f) > 0).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.icono, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.titulo,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.descripcion,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: (_isLoading || _isFixing) ? null : _verificar,
                icon: _isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 18),
                label: Text(_isLoading ? 'Verificando…' : 'Verificar ahora'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
            if (_fixResult != null) ...[
              const SizedBox(height: 12),
              _FixResultBanner(fixResult: _fixResult!),
            ],
            if (filas != null && fallidas != null) ...[
              const SizedBox(height: 12),
              if (fallidas.isEmpty)
                _ResultBanner(
                  ok: true,
                  icono: Icons.check_circle_outline,
                  texto:
                      'Todo OK — ${filas.length} invariantes, 0 violaciones. '
                      '${widget.mensajeSano}',
                )
              else ...[
                _ResultBanner(
                  ok: false,
                  icono: Icons.warning_amber_rounded,
                  texto:
                      '${fallidas.length} de ${filas.length} invariantes con '
                      'violaciones.',
                ),
                for (final f in fallidas)
                  _InvarianteDetalleCard(
                    fila: f,
                    resueltos: _resueltos,
                    colorSeveridad: _colorSeveridad,
                    labelSeveridad: _labelSeveridad,
                  ),
                if (_hayAutoFixeables && widget.rpc == 'super_admin_verificar_invariantes') ...[
                  const SizedBox(height: 14),
                  const Divider(),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: (_isLoading || _isFixing) ? null : _corregirTodo,
                        icon: _isFixing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.auto_fix_high, size: 18),
                        label: Text(_isFixing
                            ? 'Corrigiendo…'
                            : 'Corregir todo ($_totalAutoFixeables)'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Corrige INV2, INV3, INV14 y INV17 automáticamente. '
                          'Las demás requieren revisión manual.',
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Card expandible que muestra el detalle humanizado de una violación.
class _InvarianteDetalleCard extends StatelessWidget {
  const _InvarianteDetalleCard({
    required this.fila,
    required this.resueltos,
    required this.colorSeveridad,
    required this.labelSeveridad,
  });

  final Map<String, dynamic> fila;
  final Map<String, List<RegistroResuelto>> resueltos;
  final Color Function(String) colorSeveridad;
  final String Function(String) labelSeveridad;

  int get _viol => (fila['violaciones'] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final invStr = fila['invariante'] as String? ?? '';
    final codigo = extraerCodigoInv(invStr);
    final info = codigo != null ? kInvInfo[codigo] : null;
    final registros = codigo != null ? resueltos[codigo] : null;
    final idsRaw = fila['ejemplo_ids'] as String? ?? '';

    if (info == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$invStr  ·  $_viol '
              '${_viol == 1 ? 'violación' : 'violaciones'}',
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            if (idsRaw.isNotEmpty)
              Text('IDs: $idsRaw',
                  style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'monospace')),
          ],
        ),
      );
    }

    final sevColor = colorSeveridad(info.severidad);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding:
                const EdgeInsets.fromLTRB(14, 0, 14, 14),
            initiallyExpanded: true,
            leading: Icon(Icons.warning_amber_rounded,
                size: 20, color: sevColor),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    info.titulo,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: sevColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    labelSeveridad(info.severidad),
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: sevColor),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              '${codigo ?? "?"} · $_viol '
              '${_viol == 1 ? 'violación' : 'violaciones'}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            children: [
              // Qué pasa
              _SeccionDetalle(
                icono: Icons.help_outline,
                titulo: 'Qué pasa',
                contenido: info.explicacion,
              ),
              const SizedBox(height: 10),

              // Registros afectados
              if (registros != null && registros.isNotEmpty) ...[
                const _SeccionDetalle(
                  icono: Icons.people_outline,
                  titulo: 'Registros afectados',
                ),
                const SizedBox(height: 4),
                for (final r in registros)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('  •  ',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.descripcion,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500)),
                              if (r.detalle != null)
                                Text(r.detalle!,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
              ] else if (idsRaw.isNotEmpty) ...[
                _SeccionDetalle(
                  icono: Icons.people_outline,
                  titulo: 'Registros afectados',
                  contenido: idsRaw,
                  mono: true,
                ),
                const SizedBox(height: 10),
              ],

              // Cómo corregir
              _SeccionDetalle(
                icono: Icons.build_outlined,
                titulo: 'Cómo corregir',
                contenido: info.correccion,
                destacado: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mini-sección dentro del detalle de un invariante.
class _SeccionDetalle extends StatelessWidget {
  const _SeccionDetalle({
    required this.icono,
    required this.titulo,
    this.contenido,
    this.mono = false,
    this.destacado = false,
  });

  final IconData icono;
  final String titulo;
  final String? contenido;
  final bool mono;
  final bool destacado;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icono, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(titulo,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ],
        ),
        if (contenido != null) ...[
          const SizedBox(height: 3),
          Container(
            width: double.infinity,
            padding: destacado ? const EdgeInsets.all(8) : null,
            decoration: destacado
                ? BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(6),
                  )
                : null,
            child: Text(
              contenido!,
              style: TextStyle(
                fontSize: mono ? 10.5 : 12,
                color: destacado
                    ? const Color(0xFF1B5E20)
                    : scheme.onSurfaceVariant,
                fontFamily: mono ? 'monospace' : null,
                height: 1.4,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Card del módulo Operaciones (super_admin): genera el recibo de los pagos que
/// quedaron SIN recibo en el tenant en contexto (bajas de la colisión de
/// correlativo → INV5). Preview (cuántos faltan) → generar. NO destructivo, no
/// toca la plata (el recibo no cambia monto_pagado ni recaudado). Idempotente.
/// Anti-pantalla-negra (regla #7): flag local + render inline, sin showDialog.
class _GenerarRecibosFaltantesCard extends ConsumerStatefulWidget {
  const _GenerarRecibosFaltantesCard({required this.tenantId, this.actorLabel});
  final String tenantId;
  final String? actorLabel;
  @override
  ConsumerState<_GenerarRecibosFaltantesCard> createState() =>
      _GenerarRecibosFaltantesCardState();
}

class _GenerarRecibosFaltantesCardState
    extends ConsumerState<_GenerarRecibosFaltantesCard> {
  bool _isLoading = false;
  String? _error;
  int? _generables; // resultado del preview (null = no consultado aún)
  int? _sinPrefijo; // huérfanos sin prefijo de cobrador (no auto-generables)
  int? _generados; // resultado de la ejecución (null = no ejecutado aún)
  List<String> _numeros = const [];

  String _mensajeError(Object e) {
    if (e is PostgrestException) {
      // Concurrencia: otra corrida (u otro super_admin) generó los mismos
      // recibos primero → el UNIQUE de correlativo aborta esta corrida limpio
      // (rollback, sin parciales). Mensaje amable en vez del 23505 crudo.
      if (e.code == '23505') {
        return 'Otra corrida acaba de generar estos recibos. '
            'Tocá "Buscar faltantes" de nuevo para ver el estado.';
      }
      return e.message;
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _buscar() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _generables = null;
      _sinPrefijo = null;
      _generados = null;
      _numeros = const [];
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'super_admin_preview_recibos_faltantes',
        params: {'p_tenant': widget.tenantId},
      );
      if (!mounted) return;
      final m = Map<String, dynamic>.from(res as Map);
      setState(() {
        _generables = (m['generables'] as num?)?.toInt() ?? 0;
        _sinPrefijo = (m['sin_prefijo'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _generar() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'super_admin_generar_recibos_faltantes',
        params: {
          'p_tenant': widget.tenantId,
          'p_actor_label': widget.actorLabel,
        },
      );
      if (!mounted) return;
      final m = Map<String, dynamic>.from(res as Map);
      final nums = (m['numeros'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[];
      setState(() {
        _generados = (m['generados'] as num?)?.toInt() ?? 0;
        _numeros = nums;
        // La RPC procesa DE A TANDAS (0203) y devuelve cuántos quedan: antes
        // se asumía 0 porque era todo-o-nada. Si sobran, el botón sigue
        // disponible para la vuelta siguiente en vez de mentir "ya está".
        _generables = (m['restantes'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _rango() {
    if (_numeros.isEmpty) return '';
    if (_numeros.length == 1) return _numeros.first;
    return '${_numeros.first} … ${_numeros.last}';
  }

  // Aviso de huérfanos NO auto-generables (cobrador sin prefijo). Se muestra
  // tanto en el preview como tras generar (para que el remanente no desaparezca).
  Widget _bannerSinPrefijo() {
    final n = _sinPrefijo ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: _ResultBanner(
        ok: false,
        icono: Icons.warning_amber_rounded,
        texto: '$n pago${n == 1 ? '' : 's'} sin recibo con un cobrador sin '
            'prefijo → no se pueden auto-generar. Asignale un prefijo de recibo '
            'a ese cobrador y volvé a generar.',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pendientes = _generables ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.receipt_long_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Generar recibos faltantes',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Crea el recibo de los pagos que quedaron sin comprobante (INV5). '
              'No toca la plata: solo agrega el número que faltaba, con el '
              'correlativo siguiente por cobrador. Corré "Verificar invariantes '
              'de dinero" después.\n\nImportante: corrélo con los dispositivos '
              'sincronizados y sin cobros en curso — si un cobrador tiene recibos '
              'sin subir, su número podría re-crear un huérfano al reconectar.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _isLoading ? null : _buscar,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search, size: 18),
                  label: Text(_isLoading ? 'Procesando…' : 'Buscar faltantes'),
                ),
                if (pendientes > 0)
                  FilledButton.icon(
                    onPressed: _isLoading ? null : _generar,
                    icon: const Icon(Icons.playlist_add_check, size: 18),
                    label: Text(
                        'Generar $pendientes recibo${pendientes == 1 ? '' : 's'}'),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
            // Resultado de la ejecución (tiene prioridad sobre el preview).
            if (_generados != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                ok: true,
                icono: Icons.check_circle_outline,
                texto: _generados == 0
                    ? 'No había recibos faltantes para generar.'
                    : 'Listo: $_generados recibo${_generados == 1 ? '' : 's'} '
                        'generado${_generados == 1 ? '' : 's'} (${_rango()}). '
                        'Corré "Verificar invariantes de dinero" para confirmar.',
              ),
              // El remanente no auto-generable sigue visible tras generar.
              if ((_sinPrefijo ?? 0) > 0) _bannerSinPrefijo(),
            ] else if (_generables != null) ...[
              const SizedBox(height: 12),
              // Verde SOLO si de verdad no queda nada (ni auto-generable ni
              // sin-prefijo) — si no, se contradiría con el aviso ámbar.
              if (pendientes == 0 && (_sinPrefijo ?? 0) == 0)
                const _ResultBanner(
                  ok: true,
                  icono: Icons.check_circle_outline,
                  texto: 'No hay pagos sin recibo en este tenant.',
                )
              else if (pendientes > 0)
                Text(
                  '$pendientes pago${pendientes == 1 ? '' : 's'} sin recibo. '
                  'Tocá "Generar" para crear el comprobante de cada uno.',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                      height: 1.35),
                ),
              if ((_sinPrefijo ?? 0) > 0) _bannerSinPrefijo(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Banner de resultado: verde (todo OK) o rojo (error / violaciones).
class _ResultBanner extends StatelessWidget {
  const _ResultBanner({
    required this.ok,
    required this.icono,
    required this.texto,
  });

  final bool ok;
  final IconData icono;
  final String texto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Verde explícito para el OK (mismo criterio que el snackbar de éxito del
    // archivo); errorContainer del tema para el rojo.
    final bg = ok ? const Color(0xFFE1F5EE) : scheme.errorContainer;
    final fg = ok ? const Color(0xFF0F6E56) : scheme.onErrorContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(fontSize: 12.5, color: fg, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner que muestra el detalle de qué invariantes se corrigieron.
class _FixResultBanner extends StatelessWidget {
  const _FixResultBanner({required this.fixResult});
  final Map<String, int> fixResult;

  @override
  Widget build(BuildContext context) {
    final total = fixResult.values.fold<int>(0, (a, b) => a + b);
    final partes = <String>[];
    for (final e in fixResult.entries) {
      if (e.value > 0) partes.add('${e.key}: ${e.value}');
    }
    return _ResultBanner(
      ok: true,
      icono: Icons.auto_fix_high,
      texto: total == 0
          ? 'No había registros que corregir. Verificá de nuevo.'
          : 'Corregidos $total registro(s): ${partes.join(', ')}. '
              'Verificá de nuevo para confirmar.',
    );
  }
}

/// Centinela de la opción "Sin cobrador (admin)" en los selectores (regla #10:
/// centinela, no `valor: null` — null = cancelar el diálogo del SelectorBuscable).
const _kSinCobrador = '__sin_cobrador__';

/// Card del módulo Operaciones (super_admin): reasigna TODOS los clientes de un
/// cobrador (o de "sin cobrador") a otro, de un golpe (RPC 0154). El UPDATE
/// dispara el trigger 0002 que propaga a contratos/cuotas (INV8/INV9 OK).
/// ORGANIZATIVO: no toca dinero ni el historial de quién cobró. Preview → Reasignar.
class _ReasignarCobradorCard extends ConsumerStatefulWidget {
  const _ReasignarCobradorCard(
      {required this.tenantId, required this.actorLabel});
  final String tenantId;
  final String? actorLabel;
  @override
  ConsumerState<_ReasignarCobradorCard> createState() =>
      _ReasignarCobradorCardState();
}

class _ReasignarCobradorCardState
    extends ConsumerState<_ReasignarCobradorCard> {
  String? _origen, _origenLabel, _destino, _destinoLabel;
  bool _isLoading = false;
  String? _error;
  Map<String, dynamic>? _preview;

  String _mensajeError(Object e) {
    if (e is PostgrestException) return e.message;
    return e.toString().replaceFirst('Exception: ', '');
  }

  String? _idParam(String? sel) => sel == _kSinCobrador ? null : sel;

  /// Origen incluye inactivos (se puede reasignar away de un cobrador
  /// desactivado); destino solo activos. `activo = 1` (SQLite local).
  Future<void> _elegir({required bool esOrigen}) async {
    final rows = await ps.db.getAll(
      'SELECT id, nombre FROM cobradores WHERE tenant_id = ? '
      "${esOrigen ? '' : 'AND activo = 1 '}ORDER BY nombre",
      [widget.tenantId],
    );
    final opciones = <OpcionSelector<String>>[
      const OpcionSelector(
          valor: _kSinCobrador, nombre: 'Sin cobrador (admin)'),
      for (final r in rows)
        OpcionSelector(valor: r['id'] as String, nombre: r['nombre'] as String),
    ];
    if (!mounted) return;
    final elegido = await elegirConBuscador<String>(
      context,
      titulo: esOrigen ? 'Cobrador de origen' : 'Cobrador de destino',
      opciones: opciones,
    );
    if (elegido == null) return;
    final label = opciones.firstWhere((o) => o.valor == elegido).nombre;
    setState(() {
      if (esOrigen) {
        _origen = elegido;
        _origenLabel = label;
      } else {
        _destino = elegido;
        _destinoLabel = label;
      }
      _preview = null;
      _error = null;
    });
  }

  Future<void> _verPreview() async {
    if (_origen == null || _destino == null) {
      setState(() => _error = 'Elegí cobrador de origen y de destino.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _preview = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'super_admin_preview_reasignar_cobrador',
        params: {
          'p_tenant': widget.tenantId,
          'p_origen': _idParam(_origen),
          'p_destino': _idParam(_destino),
        },
      );
      if (!mounted) return;
      setState(() => _preview = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _ejecutar() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'super_admin_ejecutar_reasignar_cobrador',
        params: {
          'p_tenant': widget.tenantId,
          'p_origen': _idParam(_origen),
          'p_destino': _idParam(_destino),
          'p_actor_label': widget.actorLabel,
        },
      );
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      final n = (map['afectados'] as Map)['clientes'];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1B7A3D),
          content: Text('$n cliente(s) reasignados a ${map['destino_label']}.'),
          duration: const Duration(seconds: 4),
        ),
      );
      setState(() {
        _origen = null;
        _destino = null;
        _origenLabel = null;
        _destinoLabel = null;
        _preview = null;
      });
      ref.invalidate(_dataOpsLogProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final afectados =
        _preview == null ? null : (_preview!['afectados'] as num).toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.swap_horizontal_circle_outlined,
                    color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Reasignar cobrador en masa',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Mueve TODOS los clientes de un cobrador a otro. Es organizativo '
              '(quién los ve/cobra): no toca pagos ni el historial de quién '
              'cobró. Reversible corriéndolo al revés.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            _SelectorField(
              label: 'De (origen)',
              valor: _origenLabel,
              onTap: _isLoading ? null : () => _elegir(esOrigen: true),
            ),
            const SizedBox(height: 8),
            _SelectorField(
              label: 'A (destino)',
              valor: _destinoLabel,
              onTap: _isLoading ? null : () => _elegir(esOrigen: false),
            ),
            const SizedBox(height: 12),
            if (_preview == null)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _isLoading ? null : _verPreview,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search, size: 18),
                  label: const Text('Ver cuántos'),
                ),
              )
            else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(afectados! > 0 ? Icons.info_outline : Icons.block,
                        size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        afectados > 0
                            ? '$afectados cliente(s) pasan de "${_preview!['origen_label']}" '
                                'a "${_preview!['destino_label']}".'
                            : 'No hay clientes asignados a "${_preview!['origen_label']}".',
                        style: const TextStyle(fontSize: 12.5, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (afectados > 0)
                    FilledButton.icon(
                      onPressed: _isLoading ? null : _ejecutar,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check, size: 18),
                      label: const Text('Reasignar'),
                    ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => setState(() => _preview = null),
                    child: const Text('Cambiar'),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Fuente de opciones DB para los selectores de Operaciones.
enum _FuenteSel {
  cobradores,
  ubicaciones,
  incidentesAbiertos,
  productosGranel,
  movimientosGranel,
  consumosRecientes
}

/// Carga las opciones de una [_FuenteSel] desde el SQLite local (tenant en
/// contexto). Reusado por [_ReasignarMasivoCard] y [_OpInputCard].
Future<List<OpcionSelector<String>>> _cargarFuente(
    _FuenteSel fuente, String tenantId) async {
  switch (fuente) {
    case _FuenteSel.cobradores:
      final rows = await ps.db.getAll(
          'SELECT id, nombre FROM cobradores WHERE tenant_id = ? AND activo = 1 '
          'ORDER BY nombre',
          [tenantId]);
      return [
        for (final r in rows)
          OpcionSelector(
              valor: r['id'] as String, nombre: r['nombre'] as String)
      ];
    case _FuenteSel.ubicaciones:
      final rows = await ps.db.getAll(
          'SELECT id, nombre FROM inv_ubicaciones WHERE tenant_id = ? AND activa = 1 '
          'ORDER BY nombre',
          [tenantId]);
      return [
        for (final r in rows)
          OpcionSelector(
              valor: r['id'] as String, nombre: r['nombre'] as String)
      ];
    case _FuenteSel.incidentesAbiertos:
      final rows = await ps.db.getAll(
          'SELECT id, titulo, alcance_label FROM incidentes '
          "WHERE tenant_id = ? AND estado = 'abierto' ORDER BY inicio DESC",
          [tenantId]);
      return [
        for (final r in rows)
          OpcionSelector(
              valor: r['id'] as String,
              nombre: ((r['alcance_label'] as String?)?.isNotEmpty ?? false)
                  ? '${r['titulo']} — ${r['alcance_label']}'
                  : (r['titulo'] as String? ?? 'Incidente')),
      ];
    case _FuenteSel.productosGranel:
      final rows = await ps.db.getAll(
          'SELECT id, nombre FROM inv_productos '
          'WHERE tenant_id = ? AND es_serializado = 0 AND activo = 1 ORDER BY nombre',
          [tenantId]);
      return [
        for (final r in rows)
          OpcionSelector(
              valor: r['id'] as String, nombre: r['nombre'] as String)
      ];
    case _FuenteSel.movimientosGranel:
      // Movimientos de granel recientes (serial_id NULL); los serializados se
      // corrigen con baja/recuperar/estado, no con reversa de movimiento.
      // Excluye consumos (se corrigen por "Reversar consumo"), devoluciones y
      // reversas ya hechas → evita reversa-de-reversa y el cruce con 0171.
      final rows = await ps.db.getAll(
          'SELECT m.id, m.tipo, m.cantidad, substr(m.ocurrido_en,1,10) AS f, p.nombre '
          'FROM inv_movimientos m JOIN inv_productos p ON p.id = m.producto_id '
          'WHERE m.tenant_id = ? AND m.serial_id IS NULL '
          "AND m.tipo NOT IN ('consumo','devolucion') "
          "AND (m.motivo IS NULL OR m.motivo NOT LIKE 'Reversa%') "
          'ORDER BY m.ocurrido_en DESC LIMIT 80',
          [tenantId]);
      return [
        for (final r in rows)
          OpcionSelector(
              valor: r['id'] as String,
              nombre:
                  '${r['tipo']} ${r['cantidad']} ${r['nombre']} · ${r['f']}'),
      ];
    case _FuenteSel.consumosRecientes:
      // Excluye los consumos ya reversados (la devolución embebe [tm.id] en su motivo).
      final rows = await ps.db.getAll(
          'SELECT tm.id, t.correlativo, p.nombre AS producto, s.serial, tm.cantidad, '
          'substr(tm.ocurrido_en,1,10) AS f FROM ticket_materiales tm '
          'JOIN tickets t ON t.id = tm.ticket_id '
          'JOIN inv_productos p ON p.id = tm.producto_id '
          'LEFT JOIN inv_seriales s ON s.id = tm.serial_id '
          'WHERE tm.tenant_id = ? AND NOT EXISTS (SELECT 1 FROM inv_movimientos mr '
          "WHERE mr.tenant_id = tm.tenant_id AND mr.motivo LIKE '%[' || tm.id || ']%') "
          'ORDER BY tm.ocurrido_en DESC LIMIT 80',
          [tenantId]);
      return [
        for (final r in rows)
          OpcionSelector(
              valor: r['id'] as String,
              nombre: 'Ticket #${r['correlativo']}: '
                  '${r['serial'] ?? '${r['producto']} ${r['cantidad']}'} · ${r['f']}'),
      ];
  }
}

/// Card genérica "mover TODO de A a B" (2 selectores → preview de cuántos →
/// ejecutar). Reusa el patrón de [_ReasignarCobradorCard] para técnicos (tickets)
/// y transferencias (equipos entre ubicaciones). Ambos selectores son listas DB
/// (SelectorBuscable, regla #10). El RPC preview devuelve {afectados, origen_label,
/// destino_label}; el ejecutar registra en data_ops_log. Reversible al revés.
class _ReasignarMasivoCard extends ConsumerStatefulWidget {
  const _ReasignarMasivoCard({
    required this.tenantId,
    required this.actorLabel,
    required this.titulo,
    required this.descripcion,
    required this.icono,
    required this.labelOrigen,
    required this.labelDestino,
    required this.fuente,
    required this.rpcPreview,
    required this.rpcEjecutar,
    required this.unidadPlural,
    required this.verboPasado,
    required this.verboBoton,
  });

  final String tenantId;
  final String? actorLabel;
  final String titulo;
  final String descripcion;
  final IconData icono;
  final String labelOrigen;
  final String labelDestino;
  final _FuenteSel fuente;
  final String rpcPreview;
  final String rpcEjecutar;
  final String unidadPlural; // 'tickets' / 'equipos'
  final String verboPasado; // 'reasignados' / 'transferidos'
  final String verboBoton; // 'Reasignar' / 'Transferir'

  @override
  ConsumerState<_ReasignarMasivoCard> createState() =>
      _ReasignarMasivoCardState();
}

class _ReasignarMasivoCardState extends ConsumerState<_ReasignarMasivoCard> {
  String? _origen, _origenLabel, _destino, _destinoLabel;
  bool _isLoading = false;
  String? _error;
  Map<String, dynamic>? _preview;

  String _mensajeError(Object e) {
    if (e is PostgrestException) return e.message;
    return e.toString().replaceFirst('Exception: ', '');
  }

  // Singular/plural para que diga "1 ticket reasignado" y no "1 tickets...".
  String _uni(int n) => n == 1 && widget.unidadPlural.endsWith('s')
      ? widget.unidadPlural.substring(0, widget.unidadPlural.length - 1)
      : widget.unidadPlural;
  String _verbo(int n) => n == 1 && widget.verboPasado.endsWith('s')
      ? widget.verboPasado.substring(0, widget.verboPasado.length - 1)
      : widget.verboPasado;

  Future<void> _elegir({required bool esOrigen}) async {
    final opciones = await _cargarFuente(widget.fuente, widget.tenantId);
    if (!mounted) return;
    final elegido = await elegirConBuscador<String>(
      context,
      titulo: esOrigen ? widget.labelOrigen : widget.labelDestino,
      opciones: opciones,
    );
    if (elegido == null) return;
    final label = opciones.firstWhere((o) => o.valor == elegido).nombre;
    setState(() {
      if (esOrigen) {
        _origen = elegido;
        _origenLabel = label;
      } else {
        _destino = elegido;
        _destinoLabel = label;
      }
      _preview = null;
      _error = null;
    });
  }

  Future<void> _verPreview() async {
    if (_origen == null || _destino == null) {
      setState(() => _error =
          'Elegí ${widget.labelOrigen.toLowerCase()} y ${widget.labelDestino.toLowerCase()}.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _preview = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        widget.rpcPreview,
        params: {
          'p_tenant': widget.tenantId,
          'p_origen': _origen,
          'p_destino': _destino,
        },
      );
      if (!mounted) return;
      setState(() => _preview = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _ejecutar() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        widget.rpcEjecutar,
        params: {
          'p_tenant': widget.tenantId,
          'p_origen': _origen,
          'p_destino': _destino,
          'p_actor_label': widget.actorLabel,
        },
      );
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      final af = Map<String, dynamic>.from(map['afectados'] as Map);
      final n =
          af.values.whereType<num>().fold<int>(0, (a, b) => a + b.toInt());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1B7A3D),
          content:
              Text('$n ${_uni(n)} ${_verbo(n)} a ${map['destino_label']}.'),
          duration: const Duration(seconds: 4),
        ),
      );
      setState(() {
        _origen = null;
        _destino = null;
        _origenLabel = null;
        _destinoLabel = null;
        _preview = null;
      });
      ref.invalidate(_dataOpsLogProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final afectados =
        _preview == null ? null : (_preview!['afectados'] as num).toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.icono, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.titulo,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.descripcion,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            _SelectorField(
              label: widget.labelOrigen,
              valor: _origenLabel,
              onTap: _isLoading ? null : () => _elegir(esOrigen: true),
            ),
            const SizedBox(height: 8),
            _SelectorField(
              label: widget.labelDestino,
              valor: _destinoLabel,
              onTap: _isLoading ? null : () => _elegir(esOrigen: false),
            ),
            const SizedBox(height: 12),
            if (_preview == null)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _isLoading ? null : _verPreview,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search, size: 18),
                  label: const Text('Ver cuántos'),
                ),
              )
            else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(afectados! > 0 ? Icons.info_outline : Icons.block,
                        size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        afectados > 0
                            ? '$afectados ${_uni(afectados)} ${afectados == 1 ? 'pasa' : 'pasan'} de "${_preview!['origen_label']}" '
                                'a "${_preview!['destino_label']}".'
                            : 'No hay ${widget.unidadPlural} en "${_preview!['origen_label']}".',
                        style: const TextStyle(fontSize: 12.5, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (afectados > 0)
                    FilledButton.icon(
                      onPressed: _isLoading ? null : _ejecutar,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check, size: 18),
                      label: Text(widget.verboBoton),
                    ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => setState(() => _preview = null),
                    child: const Text('Cambiar'),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tipo de input de [_OpInputCard]. `ninguno` = sin input (solo preview→ejecutar).
enum _OpInputTipo { numero, texto, selector, ninguno }

/// Card genérica "un input → preview → ejecutar". El input es un número (días),
/// un texto (código) o un selector de lista DB (incidente). Contrato del RPC:
/// preview(p_tenant, p_<param>) → {afectados:int, label:text};
/// ejecutar(p_tenant, p_<param>, p_actor_label) → {afectados:int, mensaje:text}.
/// Reusa el patrón loading/banner. Si afectados=0, no muestra el botón ejecutar.
class _OpInputCard extends ConsumerStatefulWidget {
  const _OpInputCard({
    required this.tenantId,
    required this.actorLabel,
    required this.titulo,
    required this.descripcion,
    required this.icono,
    required this.tipo,
    required this.inputLabel,
    required this.paramName,
    required this.rpcPreview,
    required this.rpcEjecutar,
    required this.verboBoton,
    this.valorInicial,
    this.fuente,
    this.peligroso = false,
    this.segundoLabel,
    this.segundoParam,
  });

  final String tenantId;
  final String? actorLabel;
  final String titulo;
  final String descripcion;
  final IconData icono;
  final _OpInputTipo tipo;
  final String inputLabel;
  final String paramName;
  final String rpcPreview;
  final String rpcEjecutar;
  final String verboBoton;
  final String? valorInicial;
  final _FuenteSel? fuente;
  final bool peligroso;
  final String? segundoLabel; // 2º campo de texto opcional (ej. fecha)
  final String? segundoParam; // nombre del param del 2º campo (ej. p_fecha)

  @override
  ConsumerState<_OpInputCard> createState() => _OpInputCardState();
}

class _OpInputCardState extends ConsumerState<_OpInputCard> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.valorInicial ?? '');
  final TextEditingController _ctrl2 = TextEditingController();
  String? _selId, _selLabel;
  bool _isLoading = false;
  String? _error;
  Map<String, dynamic>? _preview;

  @override
  void dispose() {
    _ctrl.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  String _mensajeError(Object e) {
    if (e is PostgrestException) return e.message;
    return e.toString().replaceFirst('Exception: ', '');
  }

  Object? _valorParam() {
    switch (widget.tipo) {
      case _OpInputTipo.numero:
        return int.tryParse(_ctrl.text.trim());
      case _OpInputTipo.texto:
        final t = _ctrl.text.trim();
        return t.isEmpty ? null : t;
      case _OpInputTipo.selector:
        return _selId;
      case _OpInputTipo.ninguno:
        return true; // centinela no-null: la operación no necesita input
    }
  }

  Future<void> _elegirSelector() async {
    final opciones = await _cargarFuente(widget.fuente!, widget.tenantId);
    if (!mounted) return;
    final elegido = await elegirConBuscador<String>(context,
        titulo: widget.inputLabel, opciones: opciones);
    if (elegido == null) return;
    setState(() {
      _selId = elegido;
      _selLabel = opciones.firstWhere((o) => o.valor == elegido).nombre;
      _preview = null;
      _error = null;
    });
  }

  Future<void> _verPreview() async {
    final valor = _valorParam();
    if (valor == null) {
      setState(() => _error = 'Completá ${widget.inputLabel.toLowerCase()}.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _preview = null;
    });
    try {
      final params = <String, dynamic>{'p_tenant': widget.tenantId};
      if (widget.tipo != _OpInputTipo.ninguno) params[widget.paramName] = valor;
      if (widget.segundoParam != null) {
        params[widget.segundoParam!] = _ctrl2.text.trim();
      }
      final res =
          await Supabase.instance.client.rpc(widget.rpcPreview, params: params);
      if (!mounted) return;
      setState(() => _preview = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _ejecutar() async {
    final valor = _valorParam();
    if (valor == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final params = <String, dynamic>{
        'p_tenant': widget.tenantId,
        'p_actor_label': widget.actorLabel,
      };
      if (widget.tipo != _OpInputTipo.ninguno) params[widget.paramName] = valor;
      if (widget.segundoParam != null) {
        params[widget.segundoParam!] = _ctrl2.text.trim();
      }
      final res = await Supabase.instance.client
          .rpc(widget.rpcEjecutar, params: params);
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF1B7A3D),
        content: Text(map['mensaje']?.toString() ?? 'Operación completada.'),
        duration: const Duration(seconds: 4),
      ));
      setState(() {
        _preview = null;
        _selId = null;
        _selLabel = null;
        if (widget.tipo != _OpInputTipo.numero) _ctrl.clear();
        _ctrl2.clear();
      });
      ref.invalidate(_dataOpsLogProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final afectados = _preview == null
        ? null
        : (_preview!['afectados'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.icono,
                    color: widget.peligroso ? scheme.error : scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(widget.titulo,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(widget.descripcion,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            if (widget.tipo == _OpInputTipo.selector) ...[
              _SelectorField(
                  label: widget.inputLabel,
                  valor: _selLabel,
                  onTap: _isLoading ? null : _elegirSelector),
              const SizedBox(height: 12),
            ] else if (widget.tipo != _OpInputTipo.ninguno) ...[
              TextField(
                controller: _ctrl,
                keyboardType: widget.tipo == _OpInputTipo.numero
                    ? TextInputType.number
                    : TextInputType.text,
                decoration: InputDecoration(
                    labelText: widget.inputLabel,
                    isDense: true,
                    border: const OutlineInputBorder()),
                onChanged: (_) {
                  if (_preview != null || _error != null) {
                    setState(() {
                      _preview = null;
                      _error = null;
                    });
                  }
                },
              ),
              const SizedBox(height: 12),
            ],
            if (widget.segundoLabel != null) ...[
              TextField(
                controller: _ctrl2,
                decoration: InputDecoration(
                    labelText: widget.segundoLabel,
                    isDense: true,
                    border: const OutlineInputBorder()),
                onChanged: (_) {
                  if (_preview != null || _error != null) {
                    setState(() {
                      _preview = null;
                      _error = null;
                    });
                  }
                },
              ),
              const SizedBox(height: 12),
            ],
            if (_preview == null)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _isLoading ? null : _verPreview,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search, size: 18),
                  label: const Text('Ver qué pasa'),
                ),
              )
            else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                        (afectados ?? 0) > 0 ? Icons.info_outline : Icons.block,
                        size: 18,
                        color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(_preview!['label']?.toString() ?? '',
                            style:
                                const TextStyle(fontSize: 12.5, height: 1.35))),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if ((afectados ?? 0) > 0)
                    FilledButton.icon(
                      style: widget.peligroso
                          ? FilledButton.styleFrom(
                              backgroundColor: scheme.error,
                              foregroundColor: scheme.onError)
                          : null,
                      onPressed: _isLoading ? null : _ejecutar,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check, size: 18),
                      label: Text(widget.verboBoton),
                    ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => setState(() => _preview = null),
                    child: const Text('Cambiar'),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Card de ajuste por conteo físico (granel): producto + ubicación + cantidad
/// contada → preview de la diferencia vs el stock derivado del ledger → aplicar
/// el ajuste (un movimiento 'ajuste' por la diferencia, append-only).
class _AjusteConteoCard extends ConsumerStatefulWidget {
  const _AjusteConteoCard({required this.tenantId, required this.actorLabel});
  final String tenantId;
  final String? actorLabel;
  @override
  ConsumerState<_AjusteConteoCard> createState() => _AjusteConteoCardState();
}

class _AjusteConteoCardState extends ConsumerState<_AjusteConteoCard> {
  final _cantCtrl = TextEditingController();
  String? _prod, _prodLabel, _ubic, _ubicLabel;
  bool _isLoading = false;
  String? _error;
  Map<String, dynamic>? _preview;

  @override
  void dispose() {
    _cantCtrl.dispose();
    super.dispose();
  }

  String _mensajeError(Object e) {
    if (e is PostgrestException) return e.message;
    return e.toString().replaceFirst('Exception: ', '');
  }

  num? _cantidad() => num.tryParse(_cantCtrl.text.trim().replaceAll(',', '.'));

  Future<void> _elegir({required bool esProducto}) async {
    final opciones = await _cargarFuente(
        esProducto ? _FuenteSel.productosGranel : _FuenteSel.ubicaciones,
        widget.tenantId);
    if (!mounted) return;
    final elegido = await elegirConBuscador<String>(context,
        titulo: esProducto ? 'Producto (granel)' : 'Ubicación',
        opciones: opciones);
    if (elegido == null) return;
    final label = opciones.firstWhere((o) => o.valor == elegido).nombre;
    setState(() {
      if (esProducto) {
        _prod = elegido;
        _prodLabel = label;
      } else {
        _ubic = elegido;
        _ubicLabel = label;
      }
      _preview = null;
      _error = null;
    });
  }

  Future<void> _verPreview() async {
    if (_prod == null || _ubic == null) {
      setState(() => _error = 'Elegí producto y ubicación.');
      return;
    }
    final cant = _cantidad();
    if (cant == null) {
      setState(() => _error = 'Ingresá la cantidad contada.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _preview = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('super_admin_preview_ajuste_conteo', params: {
        'p_tenant': widget.tenantId,
        'p_producto': _prod,
        'p_ubicacion': _ubic,
        'p_contado': cant,
      });
      if (!mounted) return;
      setState(() => _preview = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _ejecutar() async {
    final cant = _cantidad();
    if (cant == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('super_admin_ejecutar_ajuste_conteo', params: {
        'p_tenant': widget.tenantId,
        'p_producto': _prod,
        'p_ubicacion': _ubic,
        'p_contado': cant,
        'p_actor_label': widget.actorLabel,
      });
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF1B7A3D),
        content: Text(map['mensaje']?.toString() ?? 'Ajuste aplicado.'),
        duration: const Duration(seconds: 4),
      ));
      setState(() {
        _prod = null;
        _ubic = null;
        _prodLabel = null;
        _ubicLabel = null;
        _cantCtrl.clear();
        _preview = null;
      });
      ref.invalidate(_dataOpsLogProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final afectados = _preview == null
        ? null
        : (_preview!['afectados'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.fact_check_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text('Ajuste por conteo físico',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 4),
            Text(
                'Para productos a granel: ingresá lo que contaste físicamente y '
                'la app registra el ajuste por la diferencia con el sistema.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            _SelectorField(
                label: 'Producto (granel)',
                valor: _prodLabel,
                onTap: _isLoading ? null : () => _elegir(esProducto: true)),
            const SizedBox(height: 8),
            _SelectorField(
                label: 'Ubicación',
                valor: _ubicLabel,
                onTap: _isLoading ? null : () => _elegir(esProducto: false)),
            const SizedBox(height: 8),
            TextField(
              controller: _cantCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Cantidad contada',
                  isDense: true,
                  border: OutlineInputBorder()),
              onChanged: (_) {
                if (_preview != null || _error != null) {
                  setState(() {
                    _preview = null;
                    _error = null;
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            if (_preview == null)
              Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                      onPressed: _isLoading ? null : _verPreview,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.search, size: 18),
                      label: const Text('Ver diferencia')))
            else ...[
              Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10)),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                            (afectados ?? 0) > 0
                                ? Icons.info_outline
                                : Icons.check_circle_outline,
                            size: 18,
                            color: scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_preview!['label']?.toString() ?? '',
                                style: const TextStyle(
                                    fontSize: 12.5, height: 1.35))),
                      ])),
              const SizedBox(height: 10),
              Row(children: [
                if ((afectados ?? 0) > 0)
                  FilledButton.icon(
                      onPressed: _isLoading ? null : _ejecutar,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check, size: 18),
                      label: const Text('Aplicar ajuste')),
                const SizedBox(width: 8),
                TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => setState(() => _preview = null),
                    child: const Text('Cambiar')),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Centinela "sin contrato" para el selector de [_CorregirVinculoCard].
const _kSinContrato = '__sin_contrato__';

/// Card para corregir el cliente/contrato de un equipo instalado: número de serie
/// + cliente (selector) + contrato del cliente (selector, opcional). Corrección
/// de metadato (sin movimiento). RPC 0166 (bypassa el guard de transiciones).
class _CorregirVinculoCard extends ConsumerStatefulWidget {
  const _CorregirVinculoCard(
      {required this.tenantId, required this.actorLabel});
  final String tenantId;
  final String? actorLabel;
  @override
  ConsumerState<_CorregirVinculoCard> createState() =>
      _CorregirVinculoCardState();
}

class _CorregirVinculoCardState extends ConsumerState<_CorregirVinculoCard> {
  final _serialCtrl = TextEditingController();
  String? _cliente, _clienteLabel, _contrato, _contratoLabel;
  bool _isLoading = false;
  String? _error;
  Map<String, dynamic>? _preview;

  @override
  void dispose() {
    _serialCtrl.dispose();
    super.dispose();
  }

  String _mensajeError(Object e) {
    if (e is PostgrestException) return e.message;
    return e.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _elegirCliente() async {
    final rows = await ps.db.getAll(
      'SELECT id, codigo, nombre FROM clientes WHERE tenant_id = ? ORDER BY nombre',
      [widget.tenantId],
    );
    final opciones = [
      for (final r in rows)
        OpcionSelector(
            valor: r['id'] as String,
            nombre: '${r['codigo'] ?? ''} — ${r['nombre'] ?? ''}'.trim()),
    ];
    if (!mounted) return;
    final elegido = await elegirConBuscador<String>(context,
        titulo: 'Cliente correcto', opciones: opciones);
    if (elegido == null) return;
    setState(() {
      _cliente = elegido;
      _clienteLabel = opciones.firstWhere((o) => o.valor == elegido).nombre;
      _contrato = null; // el contrato depende del cliente → reset
      _contratoLabel = null;
      _preview = null;
      _error = null;
    });
  }

  Future<void> _elegirContrato() async {
    if (_cliente == null) {
      setState(() => _error = 'Elegí primero el cliente.');
      return;
    }
    final rows = await ps.db.getAll(
      'SELECT id, codigo FROM contratos WHERE cliente_id = ? AND tenant_id = ? ORDER BY codigo',
      [_cliente, widget.tenantId],
    );
    final opciones = <OpcionSelector<String>>[
      const OpcionSelector(valor: _kSinContrato, nombre: 'Sin contrato'),
      for (final r in rows)
        OpcionSelector(
            valor: r['id'] as String,
            nombre: (r['codigo'] as String?) ?? 'Contrato'),
    ];
    if (!mounted) return;
    final elegido = await elegirConBuscador<String>(context,
        titulo: 'Contrato del cliente', opciones: opciones);
    if (elegido == null) return;
    setState(() {
      _contrato = elegido == _kSinContrato ? null : elegido;
      _contratoLabel = opciones.firstWhere((o) => o.valor == elegido).nombre;
      _preview = null;
      _error = null;
    });
  }

  Future<void> _verPreview() async {
    final serial = _serialCtrl.text.trim();
    if (serial.isEmpty || _cliente == null) {
      setState(() => _error = 'Completá el número de serie y el cliente.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _preview = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('super_admin_preview_corregir_vinculo', params: {
        'p_tenant': widget.tenantId,
        'p_serial': serial,
        'p_cliente': _cliente,
        'p_contrato': _contrato,
      });
      if (!mounted) return;
      setState(() => _preview = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _ejecutar() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('super_admin_ejecutar_corregir_vinculo', params: {
        'p_tenant': widget.tenantId,
        'p_serial': _serialCtrl.text.trim(),
        'p_cliente': _cliente,
        'p_contrato': _contrato,
        'p_actor_label': widget.actorLabel,
      });
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF1B7A3D),
        content: Text(map['mensaje']?.toString() ?? 'Vínculo corregido.'),
        duration: const Duration(seconds: 4),
      ));
      setState(() {
        _serialCtrl.clear();
        _cliente = null;
        _clienteLabel = null;
        _contrato = null;
        _contratoLabel = null;
        _preview = null;
      });
      ref.invalidate(_dataOpsLogProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final afectados = _preview == null
        ? null
        : (_preview!['afectados'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.link_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text('Corregir cliente de un equipo',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 4),
            Text(
                'Reasigna un equipo instalado al cliente correcto (por ejemplo si '
                'quedó vinculado a un homónimo). No mueve el equipo, solo corrige '
                'el vínculo.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            TextField(
              controller: _serialCtrl,
              decoration: const InputDecoration(
                  labelText: 'Número de serie',
                  isDense: true,
                  border: OutlineInputBorder()),
              onChanged: (_) {
                if (_preview != null || _error != null) {
                  setState(() {
                    _preview = null;
                    _error = null;
                  });
                }
              },
            ),
            const SizedBox(height: 8),
            _SelectorField(
                label: 'Cliente correcto',
                valor: _clienteLabel,
                onTap: _isLoading ? null : _elegirCliente),
            const SizedBox(height: 8),
            _SelectorField(
                label: 'Contrato (opcional)',
                valor: _contratoLabel,
                onTap: _isLoading ? null : _elegirContrato),
            const SizedBox(height: 12),
            if (_preview == null)
              Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                      onPressed: _isLoading ? null : _verPreview,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.search, size: 18),
                      label: const Text('Ver qué pasa')))
            else ...[
              Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10)),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                            (afectados ?? 0) > 0
                                ? Icons.info_outline
                                : Icons.block,
                            size: 18,
                            color: scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_preview!['label']?.toString() ?? '',
                                style: const TextStyle(
                                    fontSize: 12.5, height: 1.35))),
                      ])),
              const SizedBox(height: 10),
              Row(children: [
                if ((afectados ?? 0) > 0)
                  FilledButton.icon(
                      onPressed: _isLoading ? null : _ejecutar,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check, size: 18),
                      label: const Text('Corregir')),
                const SizedBox(width: 8),
                TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => setState(() => _preview = null),
                    child: const Text('Cambiar')),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Estados serializados corregibles por [_CorregirEstadoSerialCard] (sin
/// 'instalado', que exige cliente → se usa "Corregir cliente de un equipo").
const _estadosCorregibles = <(String, String)>[
  ('en_stock', 'En stock'),
  ('danado', 'Dañado'),
  ('retirado', 'Retirado'),
  ('baja', 'Baja (terminal)'),
];

/// Card para corregir el estado de un equipo serializado mal importado (ALTO
/// RIESGO: bypassa el guard). Número de serie + estado (enum fijo → dropdown OK).
class _CorregirEstadoSerialCard extends ConsumerStatefulWidget {
  const _CorregirEstadoSerialCard(
      {required this.tenantId, required this.actorLabel});
  final String tenantId;
  final String? actorLabel;
  @override
  ConsumerState<_CorregirEstadoSerialCard> createState() =>
      _CorregirEstadoSerialCardState();
}

class _CorregirEstadoSerialCardState
    extends ConsumerState<_CorregirEstadoSerialCard> {
  final _serialCtrl = TextEditingController();
  String _estado = _estadosCorregibles.first.$1;
  bool _isLoading = false;
  String? _error;
  Map<String, dynamic>? _preview;

  @override
  void dispose() {
    _serialCtrl.dispose();
    super.dispose();
  }

  String _mensajeError(Object e) {
    if (e is PostgrestException) return e.message;
    return e.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _verPreview() async {
    final serial = _serialCtrl.text.trim();
    if (serial.isEmpty) {
      setState(() => _error = 'Ingresá el número de serie.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _preview = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('super_admin_preview_corregir_estado_serial', params: {
        'p_tenant': widget.tenantId,
        'p_serial': serial,
        'p_estado': _estado,
      });
      if (!mounted) return;
      setState(() => _preview = Map<String, dynamic>.from(res as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _ejecutar() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('super_admin_ejecutar_corregir_estado_serial', params: {
        'p_tenant': widget.tenantId,
        'p_serial': _serialCtrl.text.trim(),
        'p_estado': _estado,
        'p_actor_label': widget.actorLabel,
      });
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF1B7A3D),
        content: Text(map['mensaje']?.toString() ?? 'Estado corregido.'),
        duration: const Duration(seconds: 4),
      ));
      setState(() {
        _serialCtrl.clear();
        _preview = null;
      });
      ref.invalidate(_dataOpsLogProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final afectados = _preview == null
        ? null
        : (_preview!['afectados'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.tune_outlined, color: scheme.error),
              const SizedBox(width: 10),
              Expanded(
                  child: Text('Corregir estado de un equipo',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 4),
            Text(
                'Para datos mal importados: fuerza el estado de un equipo por su '
                'número de serie. Úsalo con cuidado.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            TextField(
              controller: _serialCtrl,
              decoration: const InputDecoration(
                  labelText: 'Número de serie',
                  isDense: true,
                  border: OutlineInputBorder()),
              onChanged: (_) {
                if (_preview != null || _error != null) {
                  setState(() {
                    _preview = null;
                    _error = null;
                  });
                }
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _estado,
              isDense: true,
              decoration: const InputDecoration(
                  labelText: 'Nuevo estado', border: OutlineInputBorder()),
              items: [
                for (final e in _estadosCorregibles)
                  DropdownMenuItem(value: e.$1, child: Text(e.$2)),
              ],
              onChanged: (v) => setState(() {
                _estado = v ?? _estado;
                _preview = null;
              }),
            ),
            const SizedBox(height: 12),
            if (_preview == null)
              Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                      onPressed: _isLoading ? null : _verPreview,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.search, size: 18),
                      label: const Text('Ver qué pasa')))
            else ...[
              Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10)),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                            (afectados ?? 0) > 0
                                ? Icons.info_outline
                                : Icons.block,
                            size: 18,
                            color: scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_preview!['label']?.toString() ?? '',
                                style: const TextStyle(
                                    fontSize: 12.5, height: 1.35))),
                      ])),
              const SizedBox(height: 10),
              Row(children: [
                if ((afectados ?? 0) > 0)
                  FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: scheme.error,
                          foregroundColor: scheme.onError),
                      onPressed: _isLoading ? null : _ejecutar,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check, size: 18),
                      label: const Text('Corregir estado')),
                const SizedBox(width: 8),
                TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => setState(() => _preview = null),
                    child: const Text('Cambiar')),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Card de exportación read-only a Excel: corre una query del tenant en contexto
/// y descarga un .xlsx (reusa descargarExcel de reportes). No usa RPC ni registra
/// en data_ops_log (es solo lectura).
class _ExportarCard extends ConsumerStatefulWidget {
  const _ExportarCard({
    required this.tenantId,
    required this.titulo,
    required this.descripcion,
    required this.icono,
    required this.fileNamePrefix,
    required this.hojaNombre,
    required this.headers,
    required this.cargarFilas,
  });

  final String tenantId;
  final String titulo;
  final String descripcion;
  final IconData icono;
  final String fileNamePrefix;
  final String hojaNombre;
  final List<String> headers;
  final Future<List<List<Object?>>> Function(String tenantId) cargarFilas;

  @override
  ConsumerState<_ExportarCard> createState() => _ExportarCardState();
}

class _ExportarCardState extends ConsumerState<_ExportarCard> {
  bool _isLoading = false;
  String? _error;

  Future<void> _exportar() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final filas = await widget.cargarFilas(widget.tenantId);
      if (!mounted) return;
      if (filas.isEmpty) {
        setState(() => _error = 'No hay datos para exportar.');
        return;
      }
      final hoy = DateTime.now();
      String dos(int n) => n.toString().padLeft(2, '0');
      final fecha = '${hoy.year}${dos(hoy.month)}${dos(hoy.day)}';
      final ruta = await descargarExcel(
        fileName: '${widget.fileNamePrefix}-$fecha',
        hojaNombre: widget.hojaNombre,
        headers: widget.headers,
        filas: filas,
        titulo: widget.titulo,
      );
      if (!mounted) return;
      if (ruta != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFF1B7A3D),
          content: Text('${filas.length} fila(s) exportadas.'),
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(widget.icono, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(widget.titulo,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 4),
            Text(widget.descripcion,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _isLoading ? null : _exportar,
                icon: _isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download, size: 18),
                label: Text(_isLoading ? 'Generando…' : 'Exportar a Excel'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ResultBanner(
                  ok: false, icono: Icons.error_outline, texto: _error!),
            ],
          ],
        ),
      ),
    );
  }
}

/// Campo read-only que abre un [elegirConBuscador] al tocarlo (muestra el label
/// elegido o un placeholder). Para selectores de lista DB (regla #10).
class _SelectorField extends StatelessWidget {
  const _SelectorField({
    required this.label,
    required this.valor,
    required this.onTap,
  });

  final String label;
  final String? valor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          valor ?? 'Tocá para elegir',
          style: TextStyle(
            color: valor == null ? scheme.onSurfaceVariant : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// Tarjeta de una operación: input del código → "Ver qué afecta" (preview) →
/// panel de impacto → confirmación por tipeo → "Ejecutar" (rojo, deshabilitado
/// hasta que el texto coincida).
class _OperacionCard extends ConsumerStatefulWidget {
  const _OperacionCard({
    required this.tenantId,
    required this.actorLabel,
    required this.titulo,
    required this.descripcion,
    required this.labelTarget,
    required this.icono,
    required this.tipo,
    required this.rpcPreview,
    required this.rpcEjecutar,
    required this.paramTarget,
  });

  final String tenantId;
  final String? actorLabel;
  final String titulo;
  final String descripcion;
  final String labelTarget;
  final IconData icono;
  final _TipoTarget tipo;
  final String rpcPreview;
  final String rpcEjecutar;
  final String paramTarget;

  @override
  ConsumerState<_OperacionCard> createState() => _OperacionCardState();
}

class _OperacionCardState extends ConsumerState<_OperacionCard> {
  final _codigoCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _isLoading = false;

  // Resultado del preview pendiente de ejecutar.
  String? _targetId; // id resuelto del código (cliente/contrato)
  String?
      _targetCodigo; // el código EXACTO que se previsualizó (para confirmar)
  String? _targetLabel; // label legible que devolvió el server
  Map<String, dynamic>? _afectados; // counts
  String? _conserva; // qué se conserva
  String? _error; // error a mostrar inline

  @override
  void dispose() {
    _codigoCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _targetId = null;
      _targetCodigo = null;
      _targetLabel = null;
      _afectados = null;
      _conserva = null;
      _error = null;
      _confirmCtrl.clear();
    });
  }

  /// Resuelve el código → id contra el SQLite local (datos del tenant en
  /// contexto). El super_admin opera dentro del tenant impersonado, así que su
  /// data está sincronizada. Devuelve null si no encuentra.
  Future<String?> _resolverId(String codigo) async {
    final tabla = widget.tipo == _TipoTarget.cliente ? 'clientes' : 'contratos';
    // upper() de SQLite es ASCII-only → no matchea códigos con ñ/acentos.
    // Plegamos ambos lados a la forma canónica (igual que la búsqueda).
    // Traemos hasta 2: el plegado es accent-insensitive, así que dos códigos que
    // solo difieren por acento (p.ej. JÑ0048 vs JN0048) colapsan a la misma
    // forma. En una operación DESTRUCTIVA no podemos elegir uno a ciegas → si
    // hay ambigüedad, abortamos y que el super_admin desambigüe.
    final rows = await ps.db.getAll(
      'SELECT id FROM $tabla '
      'WHERE tenant_id = ? AND ${foldSqlExpr('codigo')} = ? LIMIT 2',
      [widget.tenantId, foldBusqueda(codigo)],
    );
    if (rows.isEmpty) return null;
    if (rows.length > 1) {
      throw Exception(
          'El código "$codigo" coincide con varios registros (ambiguo por '
          'mayúsculas o acentos). Verificá el código exacto antes de borrar.');
    }
    return rows.first['id'] as String;
  }

  /// Extrae el mensaje legible de un error de RPC. Las funciones tiran
  /// `raise exception` con texto en español ('No autorizado…', 'Cliente no
  /// existe') → lo queremos mostrar tal cual, no el genérico.
  String _mensajeError(Object e) {
    if (e is PostgrestException) return e.message;
    return e.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _verQueAfecta() async {
    final codigo = _codigoCtrl.text.trim();
    if (codigo.isEmpty) {
      setState(() => _error = 'Ingresá un código.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final id = await _resolverId(codigo);
      if (!mounted) return;
      if (id == null) {
        setState(() {
          _error = 'No se encontró "$codigo" en este tenant.';
          _targetId = null;
          _afectados = null;
        });
        return;
      }
      final res = await Supabase.instance.client.rpc(
        widget.rpcPreview,
        params: {widget.paramTarget: id, 'p_tenant': widget.tenantId},
      );
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      setState(() {
        _targetId = id;
        _targetCodigo = codigo;
        _targetLabel = map['target_label'] as String?;
        _afectados = Map<String, dynamic>.from(map['afectados'] as Map);
        _conserva = map['conserva'] as String?;
        _confirmCtrl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _mensajeError(e);
        _targetId = null;
        _afectados = null;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _ejecutar() async {
    // Validación cliente: el texto de confirmación debe coincidir EXACTO con el
    // código RESUELTO en el preview (no el texto vivo del campo — invariante
    // explícito e independiente del reset; no confiar solo en el server).
    if (_targetId == null || _targetCodigo == null) return;
    if (_confirmCtrl.text.trim() != _targetCodigo) {
      setState(() => _error = 'La confirmación no coincide con el código.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        widget.rpcEjecutar,
        params: {
          widget.paramTarget: _targetId,
          'p_tenant': widget.tenantId,
          'p_actor_label': widget.actorLabel,
        },
      );
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      final afectados = Map<String, dynamic>.from(map['afectados'] as Map);
      final total = afectados.values
          .whereType<num>()
          .fold<int>(0, (a, b) => a + b.toInt());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1B7A3D),
          content: Text(
            '${widget.titulo}: $total registro(s) borrados. '
            'Respaldo guardado.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      _codigoCtrl.clear();
      _reset();
      // Refresca el historial de operaciones.
      ref.invalidate(_dataOpsLogProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mensajeError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final codigo = _codigoCtrl.text.trim();
    // La confirmación valida contra el código RESUELTO en el preview, no el
    // texto vivo del campo (que el reset igual sincroniza, pero lo hacemos
    // explícito — fix audit #5).
    final confirmacionOk = _targetId != null &&
        _targetCodigo != null &&
        _confirmCtrl.text.trim() == _targetCodigo;

    return Stack(
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(widget.icono, color: scheme.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.titulo,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  widget.descripcion,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _codigoCtrl,
                        decoration: InputDecoration(
                          labelText: widget.labelTarget,
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                        // Al cambiar el código, invalida el preview anterior.
                        onChanged: (_) {
                          if (_targetId != null || _error != null) _reset();
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.tonalIcon(
                      onPressed: _isLoading ? null : _verQueAfecta,
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('Ver qué afecta'),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  _PanelError(mensaje: _error!),
                ],
                if (_afectados != null) ...[
                  const SizedBox(height: 14),
                  _PanelImpacto(
                    targetLabel: _targetLabel ?? codigo,
                    afectados: _afectados!,
                    conserva: _conserva,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Para confirmar, escribí "${_targetCodigo ?? codigo}" abajo:',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _confirmCtrl,
                    decoration: InputDecoration(
                      hintText: _targetCodigo ?? codigo,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                      ),
                      onPressed:
                          (_isLoading || !confirmacionOk) ? null : _ejecutar,
                      icon: const Icon(Icons.delete_forever, size: 18),
                      label: Text('Ejecutar ${widget.titulo.toLowerCase()}'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_isLoading)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.06),
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

/// Panel rojo con los counts de lo que se va a borrar + (verde) lo que se
/// conserva.
class _PanelImpacto extends StatelessWidget {
  const _PanelImpacto({
    required this.targetLabel,
    required this.afectados,
    required this.conserva,
  });

  final String targetLabel;
  final Map<String, dynamic> afectados;
  final String? conserva;

  static const _orden = [
    'cliente',
    'contratos',
    'cuotas',
    'pagos',
    'recibos',
    'cargos',
    'suspensiones',
    'etiquetas',
    'fotos',
    'visitas',
    'historial',
  ];

  static const _labels = {
    'cliente': 'Cliente',
    'contratos': 'Contratos',
    'cuotas': 'Cuotas',
    'pagos': 'Pagos',
    'recibos': 'Recibos',
    'cargos': 'Cargos extra',
    'suspensiones': 'Suspensiones',
    'etiquetas': 'Etiquetas',
    'fotos': 'Fotos',
    'visitas': 'Visitas',
    'historial': 'Eventos de historial',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entradas = <MapEntry<String, num>>[];
    for (final k in _orden) {
      final v = afectados[k];
      if (v is num && v > 0) entradas.add(MapEntry(k, v));
    }
    // Cualquier key no prevista, por las dudas.
    for (final e in afectados.entries) {
      if (!_orden.contains(e.key) && e.value is num && (e.value as num) > 0) {
        entradas.add(MapEntry(e.key, e.value as num));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.delete_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Se borrará — $targetLabel',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (entradas.isEmpty)
                Text('Sin registros que borrar.',
                    style: TextStyle(color: scheme.onErrorContainer))
              else
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  children: [
                    for (final e in entradas)
                      Text(
                        '${_labels[e.key] ?? e.key}: ${e.value}',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        if (conserva != null && conserva!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F4E8),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check_circle_outline,
                    size: 18, color: Color(0xFF1B7A3D)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    conserva!,
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFF0E4D27)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _PanelError extends StatelessWidget {
  const _PanelError({required this.mensaje});
  final String mensaje;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 6),
          Expanded(
            child: Text(mensaje,
                style: TextStyle(fontSize: 13, color: scheme.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}

/// Provider del historial: lee data_ops_log por REST (super_admin only por RLS),
/// SCOPEADO al tenant en contexto (tenantIdProvider = el impersonado), ordenado
/// por created_at desc. autoDispose → se refresca al re-entrar.
/// La RLS de la tabla es tenant-agnóstica (solo is_super_admin()), así que el
/// aislamiento por-tenant del historial es client-side, igual que el resto del
/// panel: sin el .eq, mostraría operaciones de TODOS los tenants mezcladas y el
/// botón Restaurar podría aparecer en filas de otro tenant (el RPC las rechaza).
final _dataOpsLogProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final tenantId = ref.watch(tenantIdProvider);
  if (tenantId == null || tenantId.isEmpty) return <Map<String, dynamic>>[];
  final res = await Supabase.instance.client
      .from('data_ops_log')
      .select(
          'id, operacion, target_label, afectados, backup_id, actor_label, created_at')
      .eq('tenant_id', tenantId)
      .order('created_at', ascending: false)
      .limit(100);
  return (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
});

/// Lista del historial de operaciones ejecutadas (con botón Restaurar en los
/// borrados que tienen respaldo).
class _HistorialOperaciones extends ConsumerWidget {
  const _HistorialOperaciones(
      {required this.tenantId, required this.actorLabel});

  final String tenantId;
  final String? actorLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(_dataOpsLogProvider);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Historial de operaciones',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Actualizar',
                  onPressed: () => ref.invalidate(_dataOpsLogProvider),
                ),
              ],
            ),
            const Divider(height: 16),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No se pudo cargar el historial.',
                    style: TextStyle(color: scheme.error)),
              ),
              data: (rows) {
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('Sin operaciones registradas.',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  );
                }
                return Column(
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0) const Divider(height: 12),
                      _HistorialFila(
                        row: rows[i],
                        tenantId: tenantId,
                        actorLabel: actorLabel,
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Una fila del historial. Stateful por el botón Restaurar (loading + RPC 0155).
/// Solo los borrados (limpiar/eliminar) con respaldo muestran "Restaurar".
class _HistorialFila extends ConsumerStatefulWidget {
  const _HistorialFila({
    required this.row,
    required this.tenantId,
    required this.actorLabel,
  });

  final Map<String, dynamic> row;
  final String tenantId;
  final String? actorLabel;

  @override
  ConsumerState<_HistorialFila> createState() => _HistorialFilaState();
}

class _HistorialFilaState extends ConsumerState<_HistorialFila> {
  bool _restaurando = false;

  // op -> (label, ícono, verbo, esBorradoRestaurable)
  static const _meta = <String, (String, IconData, String, bool)>{
    'limpiar_cliente': (
      'Limpiar cliente',
      Icons.cleaning_services_outlined,
      'borrados',
      true
    ),
    'eliminar_contrato': (
      'Eliminar contrato',
      Icons.description_outlined,
      'borrados',
      true
    ),
    'eliminar_cliente': (
      'Eliminar cliente',
      Icons.person_remove_outlined,
      'borrados',
      true
    ),
    'reasignar_cobrador': (
      'Reasignar cobrador',
      Icons.swap_horizontal_circle_outlined,
      'reasignados',
      false
    ),
    'reasignar_tecnico': (
      'Reasignar técnico',
      Icons.engineering_outlined,
      'reasignados',
      false
    ),
    'transferir_serial': (
      'Transferir equipos',
      Icons.swap_horiz,
      'transferidos',
      false
    ),
    'cerrar_tickets_viejos': (
      'Cerrar tickets viejos',
      Icons.auto_delete_outlined,
      'cancelados',
      false
    ),
    'reabrir_ticket': (
      'Reabrir ticket',
      Icons.lock_open_outlined,
      'reabiertos',
      false
    ),
    'resolver_incidente': (
      'Resolver incidente',
      Icons.cell_tower_outlined,
      'cerrados',
      false
    ),
    'baja_serial': (
      'Dar de baja',
      Icons.do_not_disturb_on_outlined,
      'dados de baja',
      false
    ),
    'recuperar_serial': (
      'Recuperar equipo',
      Icons.healing_outlined,
      'recuperados',
      false
    ),
    'reconciliar_huerfanos': (
      'Reconciliar huérfanos',
      Icons.link_off_outlined,
      'reconciliados',
      false
    ),
    'ajuste_conteo': (
      'Ajuste por conteo',
      Icons.fact_check_outlined,
      'unidades de ajuste',
      false
    ),
    'reversar_movimiento': (
      'Reversar movimiento',
      Icons.undo_outlined,
      'reversados',
      false
    ),
    'reversar_consumo': (
      'Reversar consumo',
      Icons.settings_backup_restore_outlined,
      'reversados',
      false
    ),
    'corregir_vinculo': (
      'Corregir vínculo de equipo',
      Icons.link_outlined,
      'corregidos',
      false
    ),
    'corregir_estado_serial': (
      'Corregir estado de equipo',
      Icons.tune_outlined,
      'corregidos',
      false
    ),
    'corregir_sla': (
      'Corregir SLA de ticket',
      Icons.event_repeat_outlined,
      'corregidos',
      false
    ),
    'anular_ticket': (
      'Anular ticket',
      Icons.cancel_outlined,
      'materiales devueltos',
      false
    ),
    'restaurar': ('Restaurar', Icons.restore, 'restaurados', false),
  };

  Future<void> _restaurar() async {
    final backupId = widget.row['backup_id'] as String?;
    if (backupId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restaurar respaldo'),
        content: Text(
          'Se va a re-insertar todo lo que borró "${widget.row['target_label']}". '
          'No pisa la data actual (lo que ya exista se conserva). Después conviene '
          'correr "Verificar invariantes" para confirmar que quedó sano.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restaurar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _restaurando = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'super_admin_restaurar_backup',
        params: {
          'p_backup_id': backupId,
          'p_tenant': widget.tenantId,
          'p_actor_label': widget.actorLabel,
        },
      );
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1B7A3D),
          content:
              Text('${map['total']} registro(s) restaurados. Corré "Verificar '
                  'invariantes" para confirmar.'),
          duration: const Duration(seconds: 5),
        ),
      );
      ref.invalidate(_dataOpsLogProvider);
    } catch (e) {
      if (!mounted) return;
      final msg = e is PostgrestException
          ? e.message
          : e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).colorScheme.error,
        content: Text(msg),
      ));
    } finally {
      if (mounted) setState(() => _restaurando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = widget.row;
    final op = row['operacion'] as String? ?? '';
    final meta = _meta[op] ?? (op, Icons.bolt, 'afectados', false);
    final target = row['target_label'] as String? ?? '';
    final actor = row['actor_label'] as String?;
    final afectados = row['afectados'] is Map
        ? Map<String, dynamic>.from(row['afectados'] as Map)
        : <String, dynamic>{};
    final total =
        afectados.values.whereType<num>().fold<int>(0, (a, b) => a + b.toInt());
    final cuando = _fechaHist(row['created_at']);
    final tieneBackup = (row['backup_id'] as String?) != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(meta.$2,
                  size: 18, color: meta.$4 ? scheme.error : scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${meta.$1} — $target',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      '$total registro(s) ${meta.$3}'
                      '${actor != null && actor.isNotEmpty ? ' · por $actor' : ''}',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(cuando,
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ),
          if (meta.$4 && tieneBackup)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _restaurando ? null : _restaurar,
                  icon: _restaurando
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.restore, size: 16),
                  label: Text(_restaurando ? 'Restaurando…' : 'Restaurar'),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _fechaHist(dynamic raw) {
  if (raw == null) return '';
  final dt = DateTime.tryParse(raw.toString())?.toLocal();
  if (dt == null) return raw.toString();
  String dos(int n) => n.toString().padLeft(2, '0');
  return '${dos(dt.day)}/${dos(dt.month)}/${dt.year} ${dos(dt.hour)}:${dos(dt.minute)}';
}
