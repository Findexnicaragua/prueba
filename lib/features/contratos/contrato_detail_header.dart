// Tarjeta-resumen del contrato (header reutilizable): plan + estado, datos,
// rango de cuotas y panel Total/Recaudado/Pendiente. Se usa en el detalle del
// contrato y como vista previa en el detalle del cliente (sin la lista de
// cuotas). Antes era `ContratoHeaderCard` (part of contrato_detail_screen).
//
// Los números de plata salen de `contratoRecaudadoProvider` con las fórmulas
// canónicas — invariante #10. NO recalcular a mano acá.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/contrato_providers.dart';
import '../../data/utils/formatters.dart';

String _duracionLabelHelper(DateTime inicio, DateTime? fin) {
  if (fin == null) return 'Indefinido';
  final meses = (fin.year - inicio.year) * 12 + (fin.month - inicio.month);
  if (meses <= 0) return '—';
  if (meses == 1) return '1 mes';
  if (meses == 12) return '1 año';
  if (meses == 24) return '2 años';
  if (meses % 12 == 0) return '${meses ~/ 12} años';
  return '$meses meses';
}

class ContratoHeaderCard extends StatelessWidget {
  const ContratoHeaderCard({super.key, 
    required this.contrato,
    required this.esAdmin,
    required this.contratoId,
    required this.enImpersonacion,
    this.esAdminCobranza = false,
    this.onEstadoChanged,
    this.footer,
  });
  final Map<String, dynamic> contrato;
  final bool esAdmin;
  final bool esAdminCobranza;
  final String contratoId;
  final bool enImpersonacion;
  final ValueChanged<String>? onEstadoChanged;
  // Contenido extra opcional al pie de la tarjeta (ej. "Pagadas X/Y" en el
  // preview del detalle del cliente). En el detalle de contrato va null.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estado = contrato['estado'] as String? ?? 'activo';
    final planNombre = contrato['plan_nombre'] as String? ?? '—';
    final precio = (contrato['precio_mensual'] as num?)?.toDouble() ?? 0;
    final fechaInicio = DateTime.parse(contrato['fecha_inicio'] as String);
    final fechaFin = contrato['fecha_fin'] != null
        ? DateTime.parse(contrato['fecha_fin'] as String)
        : null;
    final diaPago = contrato['dia_pago'] as int? ?? 1;
    final clienteNombre = contrato['cliente_nombre'] as String? ?? '—';
    final costoInstalacion =
        (contrato['costo_instalacion'] as num?)?.toDouble();
    final codigo = contrato['codigo'] as String?;

    // 'completado' se eliminó como estado: era lo mismo que 'cancelado' (el
    // contrato terminó) y si quedó saldado o no es un dato DERIVADO de las
    // cuotas, no un estado guardado. Se mapea junto a 'cancelado' para que las
    // filas viejas que todavía no migraron no muestren el valor crudo.
    final (Color badgeColor, String badgeLabel) = switch (estado) {
      'activo' => (scheme.primary, 'Activo'),
      'suspendido' => (Colors.orange.shade800, 'Suspendido'),
      'cancelado' || 'completado' => (scheme.error, 'Cancelado'),
      _ => (scheme.outline, estado),
    };
    final esTerminal = estado == 'cancelado' || estado == 'completado';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fila: plan + badge estado
            Row(
              children: [
                Icon(Icons.assignment, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    planNombre,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                // B2: 'cancelado' es TERMINAL — un contrato cancelado no se
                // reactiva (servicio terminado; para reanudar se crea uno
                // nuevo). Por eso si ya está cancelado no se muestra el menú.
                // Y al impersonar se oculta TODO el dropdown (ningún cambio de
                // estado del tenant debe atribuirse al super_admin).
                if (esAdmin &&
                    onEstadoChanged != null &&
                    !esTerminal &&
                    estado != 'suspendido' &&
                    !enImpersonacion)
                  PopupMenuButton<String>(
                    tooltip: 'Cambiar estado',
                    onSelected: onEstadoChanged,
                    itemBuilder: (_) => [
                      if (estado != 'activo')
                        const PopupMenuItem(
                            value: 'activo', child: Text('Activo')),
                      // Única salida desde acá: cancelar. 'Completado' se quitó
                      // (era un alias de cancelado que además NO aplicaba a los
                      // contratos indefinidos, que nunca "se completan").
                      const PopupMenuItem(
                          value: 'cancelado', child: Text('Cancelado')),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(badgeLabel,
                              style: TextStyle(
                                color: badgeColor,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              )),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_drop_down,
                              size: 18, color: badgeColor),
                        ],
                      ),
                    ),
                  )
                else
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(badgeLabel,
                        style: TextStyle(
                          color: badgeColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        )),
                  ),
              ],
            ),
            if (codigo != null && codigo.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.tag, size: 16, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text(codigo,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ],
            const SizedBox(height: 12),
            // Cliente
            Row(
              children: [
                Icon(Icons.person, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text(clienteNombre,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 8),
            // Precio
            Row(
              children: [
                Icon(Icons.monetization_on, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text('${Fmt.cordobas(precio)} / mes',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    )),
              ],
            ),
            // Duración (legible: 1 año / 2 años / N meses / Indefinido)
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.timelapse, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text('Duración: ${_duracionLabelHelper(fechaInicio, fechaFin)}',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            // Fecha de instalación (referencia; = fecha_inicio del contrato). NO
            // cambia al reactivar / cambiar fecha — es histórica.
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.build_circle_outlined, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text('Instalación: ${Fmt.fechaCorta(fechaInicio)}',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const Divider(height: 20),
            // Detalle inferior — fila 1: rango REAL de cuotas + día de pago.
            // Primera/Última = venc de la 1ª y última cuota no anulada → refleja
            // el rango facturable vigente (cambia al reactivar / cambiar fecha).
            _ContratoFechasChips(
              contratoId: contratoId,
              diaPago: diaPago,
              indefinido: fechaFin == null,
            ),
            // Costo de instalación (si se registró). Dato informativo —
            // no genera un cobro automático.
            if (costoInstalacion != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.build, size: 16, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text('Costo de instalación: ${Fmt.cordobas(costoInstalacion)}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            ],
            // La nota del contrato SE MUDÓ a `_NotaContratoCard` (más abajo en
            // el detalle), que además la deja editar. Acá se sacó para no
            // pintarla dos veces en la misma pantalla con dos estilos
            // distintos, que se leía como si fueran dos notas y una estuviera
            // desactualizada.
            const SizedBox(height: 12),
            // Resumen financiero del contrato.
            // Total contrato MOSTRADO = Σ cuotas vivas (= recaudado + pendiente),
            // NO precio×meses (#5 redefinido por R22 — robusto al cambio de plan).
            // Recaudado = SUM(pagos no anulados) del contrato.
            // Pendiente = deuda cobrable = SUM(saldos de cuotas vivas) — igual que
            // los reportes; tras una suspensión refleja lo que queda por cobrar (#10).
            _ContratoResumen(
              contratoId: contratoId,
              precioMensual: precio,
              fechaInicio: fechaInicio,
              fechaFin: fechaFin,
              duracionMeses: (contrato['duracion_meses'] as num?)?.toInt(),
              esAdminCobranza: esAdminCobranza,
            ),
            if (footer != null) ...[
              const SizedBox(height: 12),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Resumen financiero del contrato
// ---------------------------------------------------------------------------

class _ContratoResumen extends ConsumerWidget {
  const _ContratoResumen({
    required this.contratoId,
    required this.precioMensual,
    required this.fechaInicio,
    required this.fechaFin,
    required this.duracionMeses,
    this.esAdminCobranza = false,
  });
  final String contratoId;
  final double precioMensual;
  final DateTime fechaInicio;
  final DateTime? fechaFin;
  final int? duracionMeses;
  final bool esAdminCobranza;

  /// Nominal precio_mensual × meses — se usa SOLO como discriminador
  /// fijo-vs-indefinido (null = indefinido), NO como el Total mostrado (que es
  /// Σ cuotas vivas = recaudado + pendiente, invariante #5 redefinido por R22).
  /// Para contratos indefinidos retorna null.
  double? _calcularTotalContrato() {
    // Fuente de verdad: duracion_meses guardada al crear (invariante #5).
    // Fallback a derivar de fechas solo para contratos viejos sin la columna
    // backfilleada (no debería pasar tras la migración 0072).
    final meses = duracionMeses ??
        (fechaFin != null
            ? (fechaFin!.year - fechaInicio.year) * 12 +
                (fechaFin!.month - fechaInicio.month)
            : null);
    if (meses == null || meses <= 0) return null;
    return precioMensual * meses;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // El rol se lee ACÁ ADENTRO, no por parámetro: así quedan cubiertos los DOS
    // lugares que dibujan este panel (el detalle del contrato y el preview del
    // detalle del cliente), que mostraban el mismo número falso.
    //
    // `admin_usuarios` NO sincroniza `pagos` (bucket todo_tenant_admin_usuarios),
    // así que "Recaudado" le daba 0 — y como Total = recaudado + pendiente, el
    // 0 arrastraba al Total. En un contrato real: veía 8.240,00 C$ donde iban
    // 19.776,00 C$, un 58% menos, presentado como el total del contrato. No es
    // un dato faltante, es un número inventado. Se le muestra el avance en
    // CONTEO de cuotas, que sale de `cuotas` (tabla que sí baja) y es exacto.
    final esAdminUsuarios = ref
            .watch(cobradorActualProvider)
            .valueOrNull
            ?.esAdminUsuarios ??
        false;
    final totalContrato = _calcularTotalContrato();
    final esIndefinido = totalContrato == null;
    // Indefinido → solo "Total recaudado" (no hay total nominal). Un CANCELADO
    // (0123) ahora deja deuda viva cobrable → se trata como activo y muestra
    // Total/Recaudado/Pendiente (consistencia cross-pantalla #10).
    final soloRecaudado = esIndefinido;
    return ref.watch(contratoRecaudadoProvider(contratoId)).when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (rows) {
        final recaudado = rows.isEmpty
            ? 0.0
            : ((rows.first['recaudado'] as num?) ?? 0).toDouble();
        // Pendiente = deuda COBRABLE real (suma de saldos de cuotas vivas), la
        // misma fórmula canónica que usan todos los reportes → consistente tras
        // una suspensión (los meses anulados no se cobran) y con cargos extra
        // (invariante #10). "Total contrato" = Σ cuotas vivas (= `real`, abajo),
        // NO el nominal precio×meses (#5 redefinido — robusto al cambio de plan).
        final cobrable = rows.isEmpty
            ? 0.0
            : ((rows.first['cobrable'] as num?) ?? 0).toDouble();
        final pendiente = (soloRecaudado && !esAdminCobranza) ? 0.0 : cobrable;
        // "Total contrato" muestra el REAL facturable = recaudado + pendiente
        // (cobrable) = Σ de las cuotas vivas (incluye cargos). Tras un cambio de
        // plan refleja el precio nuevo en las futuras (las cuotas son snapshots).
        final real = recaudado + pendiente;
        // "Ajustado (meses anulados)": un fijo con MENOS cuotas vivas que su
        // duración pasó por una suspensión/cancelación. Señal por CONTEO de
        // cuotas, NO por precio×meses → robusta a un cambio de plan (el nominal
        // ya no aplica y haría misfire el hint). #5 redefinido: Total = Σ cuotas
        // vivas (= `real`), no el nominal precio×meses.
        final vivas =
            rows.isEmpty ? null : (rows.first['vivas'] as num?)?.toInt();
        final dm = duracionMeses;
        final ajustado = dm != null && vivas != null && vivas < dm;

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (esAdminUsuarios) ...[
                Expanded(
                  child: _ResumenItem(
                    label: 'Cuotas pagadas',
                    value: vivas == null
                        ? '${(rows.isEmpty ? 0 : (rows.first['pagadas'] as num?)?.toInt() ?? 0)}'
                        : '${(rows.first['pagadas'] as num?)?.toInt() ?? 0}/$vivas',
                    color: Colors.green.shade700,
                  ),
                ),
                Container(
                    width: 1, height: 36, color: scheme.outline.withValues(alpha: 0.3)),
                Expanded(
                  child: _ResumenItem(
                    label: 'Cuotas pendientes',
                    value: '${(vivas ?? 0) - ((rows.isEmpty ? 0 : (rows.first['pagadas'] as num?)?.toInt() ?? 0))}',
                    color: scheme.onSurface,
                  ),
                ),
              ] else if (soloRecaudado) ...[
                if (!esAdminCobranza)
                  Expanded(
                    child: _ResumenItem(
                      label: 'Total recaudado',
                      value: Fmt.cordobas(recaudado),
                      color: Colors.green.shade700,
                    ),
                  ),
                if (esAdminCobranza)
                  Expanded(
                    child: _ResumenItem(
                      label: 'Total pendiente',
                      value: Fmt.cordobas(pendiente),
                      color: pendiente > 0 ? scheme.error : scheme.outline,
                    ),
                  ),
              ] else if (esAdminCobranza) ...[
                Expanded(
                  child: _ResumenItem(
                    label: 'Total pendiente',
                    value: Fmt.cordobas(pendiente),
                    color: pendiente > 0 ? scheme.error : scheme.outline,
                  ),
                ),
              ] else ...[
                Expanded(
                  child: _ResumenItem(
                    label: 'Total contrato',
                    value: Fmt.cordobas(real),
                    color: scheme.onSurface,
                    hint: ajustado ? 'ajustado (meses anulados)' : null,
                  ),
                ),
                Container(
                    width: 1, height: 36, color: scheme.outline.withValues(alpha: 0.3)),
                Expanded(
                  child: _ResumenItem(
                    label: 'Recaudado',
                    value: Fmt.cordobas(recaudado),
                    color: Colors.green.shade700,
                  ),
                ),
                Container(
                    width: 1, height: 36, color: scheme.outline.withValues(alpha: 0.3)),
                Expanded(
                  child: _ResumenItem(
                    label: 'Pendiente',
                    value: Fmt.cordobas(pendiente),
                    color: pendiente > 0 ? scheme.error : scheme.outline,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ResumenItem extends StatelessWidget {
  const _ResumenItem({
    required this.label,
    required this.value,
    required this.color,
    this.hint,
  });
  final String label;
  final String value;
  final Color color;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label,
            style: TextStyle(fontSize: 10, color: scheme.outline),
            textAlign: TextAlign.center),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 13, color: color),
            textAlign: TextAlign.center),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(hint!,
                style: TextStyle(fontSize: 9, color: scheme.outline),
                textAlign: TextAlign.center),
          ),
      ],
    );
  }
}

// Chips de fechas: Primera cuota / Última cuota (venc min/max de cuotas NO
// anuladas) + Día de pago. Lee las cuotas del provider para reflejar el rango
// facturable VIGENTE (tras reactivar / cambiar fecha cambia; la instalación no).
class _ContratoFechasChips extends ConsumerWidget {
  const _ContratoFechasChips({
    required this.contratoId,
    required this.diaPago,
    required this.indefinido,
  });
  final String contratoId;
  final int diaPago;
  final bool indefinido;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows =
        ref.watch(contratoCuotasProvider(contratoId)).valueOrNull ?? const [];
    DateTime? primera;
    DateTime? ultima;
    for (final r in rows) {
      if ((r['estado'] as String?) == 'anulada') continue;
      final v = r['fecha_vencimiento'] as String?;
      if (v == null) continue;
      final d = DateTime.tryParse(v);
      if (d == null) continue;
      if (primera == null || d.isBefore(primera)) primera = d;
      if (ultima == null || d.isAfter(ultima)) ultima = d;
    }
    return Row(
      children: [
        _DetailChip(
          icon: Icons.calendar_today,
          label: 'Primera cuota',
          value: primera != null ? Fmt.fechaCorta(primera) : '—',
        ),
        const SizedBox(width: 16),
        _DetailChip(
          icon: Icons.event_available,
          label: 'Última cuota',
          value: indefinido
              ? 'Indefinido'
              : (ultima != null ? Fmt.fechaCorta(ultima) : '—'),
        ),
        const SizedBox(width: 16),
        _DetailChip(
          icon: Icons.today,
          label: 'Día de pago',
          value: '$diaPago',
        ),
      ],
    );
  }
}

class _DetailChip extends StatelessWidget {
  const _DetailChip({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: scheme.outline),
              const SizedBox(width: 4),
              Flexible(
                child: Text(label,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seccion de cuotas
// ---------------------------------------------------------------------------

