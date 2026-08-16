import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/utils/errores.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_op_log.dart';
import 'inv_seriales_acciones.dart';
import 'inventario_comun.dart';

/// Ficha de detalle de un equipo serializado (`inv_seriales`). Vista beta del
/// rediseño: datos del serial + cliente (linkeable) + tickets donde se usó +
/// historial (op_log). **Solo lectura** en este sub-paso; las acciones
/// (asignar/devolver/transferir/baja) llegan en el sub-paso 2.
class FichaEquipoScreen extends ConsumerStatefulWidget {
  const FichaEquipoScreen({super.key, required this.serialId});
  final String serialId;

  @override
  ConsumerState<FichaEquipoScreen> createState() => _FichaEquipoScreenState();
}

class _FichaEquipoScreenState extends ConsumerState<FichaEquipoScreen> {
  late Stream<List<Map<String, dynamic>>> _detalle = _query();

  Stream<List<Map<String, dynamic>>> _query() => ps.db.watch('''
      SELECT s.id, s.serial, s.mac, s.estado, s.costo_ingreso, s.notas,
             s.producto_id, s.ubicacion_id, s.cliente_id, s.contrato_id, s.created_at,
             p.nombre  AS producto, p.codigo AS producto_codigo,
             u.nombre  AS ubicacion,
             cl.nombre AS cliente_nombre, cl.codigo AS cliente_codigo,
             ct.codigo AS contrato_codigo
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
   LEFT JOIN inv_ubicaciones u ON u.id = s.ubicacion_id
   LEFT JOIN clientes cl ON cl.id = s.cliente_id
   LEFT JOIN contratos ct ON ct.id = s.contrato_id
       WHERE s.id = ?
    ''', parameters: [widget.serialId]);

  @override
  Widget build(BuildContext context) {
    // Re-suscribir si se recreó la DB (cambio de usuario).
    ref.listen(dbEpochProvider, (_, __) => setState(() => _detalle = _query()));
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _detalle,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(mensajeErrorHumano(snap.error!)));
        }
        final rows = snap.data;
        if (rows == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.qr_code_2,
            titulo: 'Equipo no encontrado',
            descripcion: 'El equipo no existe o fue removido del inventario.',
          );
        }
        return _contenido(context, scheme, rows.first);
      },
    );
  }

  Widget _contenido(
      BuildContext context, ColorScheme scheme, Map<String, dynamic> r) {
    final estado = r['estado'] as String? ?? 'en_stock';
    final color = estadoSerialColor(estado, scheme);
    final clienteId = r['cliente_id'] as String?;
    final costo = (r['costo_ingreso'] as num?) ?? 0;

    final productoLabel = [
      r['producto'] as String?,
      if (r['producto_codigo'] != null) '(${r['producto_codigo']})',
    ].whereType<String>().join(' ');

    final filas = <(String, String?)>[
      ('Producto', productoLabel),
      ('MAC', r['mac'] as String?),
      ('Ubicación', r['ubicacion'] as String?),
      ('Contrato', r['contrato_codigo'] as String?),
      ('Costo de ingreso', costo > 0 ? Fmt.cordobas(costo) : null),
      ('Notas', r['notas'] as String?),
    ].where((f) => f.$2 != null && f.$2!.isNotEmpty).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Encabezado: serial + estado.
        Row(
          children: [
            Icon(Icons.qr_code_2, size: 30, color: scheme.outline),
            const SizedBox(width: 12),
            Expanded(
              child: Text(r['serial'] as String? ?? '',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(kEstadoSerial[estado] ?? estado,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Datos.
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                for (final f in filas)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 120,
                          child: Text(f.$1,
                              style: TextStyle(color: scheme.outline)),
                        ),
                        Expanded(child: Text(f.$2!)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Cliente (si está asignado/instalado) → link a su ficha.
        if (clienteId != null) ...[
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(r['cliente_nombre'] as String? ?? 'Cliente'),
              subtitle: r['cliente_codigo'] != null
                  ? Text(r['cliente_codigo'] as String)
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/admin/clientes/$clienteId'),
            ),
          ),
        ],
        ..._acciones(context, estado, r),
        const SizedBox(height: 22),
        Text('Tickets', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        _TicketsDelEquipo(serialId: widget.serialId),
        const SizedBox(height: 22),
        Text('Historial', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        HistorialOpLog(entidad: 'inv_seriales', entidadId: widget.serialId),
      ],
    );
  }

  /// Botones de acción gateados por estado (espejo del menú del inventario
  /// viejo). Reusan las funciones extraídas a `inv_seriales_acciones.dart`; el
  /// stream de detalle refleja el cambio al instante (reactivo).
  List<Widget> _acciones(
      BuildContext context, String estado, Map<String, dynamic> r) {
    final btns = <Widget>[];
    Widget b(IconData icon, String label, VoidCallback onTap) =>
        OutlinedButton.icon(
            icon: Icon(icon, size: 18), label: Text(label), onPressed: onTap);
    if (estado == 'en_stock') {
      btns.add(b(Icons.person_add_alt_1, 'Asignar a cliente',
          () => asignarEquipo(context, ref, r)));
      btns.add(b(Icons.swap_horiz, 'Transferir',
          () => transferirEquipo(context, ref, r)));
    }
    // Entrada al limbo de revisión: solo desde el campo (0204). Desde stock no
    // aplica —no volvió de ningún lado— y desde revisión ya está adentro.
    if (estado != 'en_stock' && estado != 'baja' && estado != 'en_revision') {
      btns.add(b(Icons.fact_check_outlined, 'Mandar a revisión',
          () => mandarARevisionEquipo(context, ref, r)));
    }
    if (estado != 'en_stock' && estado != 'baja') {
      // Desde revisión, devolver a stock ES la salida "sirve" del ciclo.
      btns.add(b(
          Icons.undo,
          estado == 'en_revision' ? 'Aprobar y devolver' : 'Devolver a stock',
          () => devolverEquipo(context, ref, r)));
    }
    if (estado != 'baja') {
      final esCambio = estado == 'danado' || estado == 'retirado';
      btns.add(b(Icons.block, esCambio ? 'Cambiar estado' : 'Mandar a descarte',
          () => darDeBajaEquipo(context, ref, r)));
    }
    if (btns.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: btns),
    ];
  }
}

/// Tickets donde se usó este equipo (vía `ticket_materiales`, la fuente
/// completa — no `inv_movimientos`, que pierde los consumos no materializados).
class _TicketsDelEquipo extends ConsumerStatefulWidget {
  const _TicketsDelEquipo({required this.serialId});
  final String serialId;
  @override
  ConsumerState<_TicketsDelEquipo> createState() => _TicketsDelEquipoState();
}

class _TicketsDelEquipoState extends ConsumerState<_TicketsDelEquipo> {
  late Stream<List<Map<String, dynamic>>> _tickets = _query();

  Stream<List<Map<String, dynamic>>> _query() => ps.db.watch('''
      SELECT DISTINCT t.id, t.correlativo, t.titulo, t.estado, t.created_at
        FROM ticket_materiales tm
        JOIN tickets t ON t.id = tm.ticket_id
       WHERE tm.serial_id = ?
       ORDER BY t.created_at DESC
    ''', parameters: [widget.serialId]);

  @override
  Widget build(BuildContext context) {
    ref.listen(dbEpochProvider, (_, __) => setState(() => _tickets = _query()));
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _tickets,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Text(mensajeErrorHumano(snap.error!));
        final rows = snap.data ?? const [];
        if (rows.isEmpty) {
          return Text('Este equipo no se usó en ningún ticket.',
              style: TextStyle(color: scheme.outline));
        }
        return Column(
          children: [
            for (final t in rows)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 2),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.support_agent),
                  title: Text(
                    ticketCodigo(t['correlativo'] as num?) +
                        (((t['titulo'] as String?)?.isNotEmpty ?? false)
                            ? ' · ${t['titulo']}'
                            : ''),
                  ),
                  subtitle: Text((t['estado'] as String?) ?? ''),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      context.push('/admin/tickets/${t['id'] as String}'),
                ),
              ),
          ],
        );
      },
    );
  }
}
