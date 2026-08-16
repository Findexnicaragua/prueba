import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../data/utils/formatters.dart';

/// Un ítem de una "cola" de acciones pendientes: lo que se muestra + a dónde
/// navega su botón de próximo paso (la acción real vive en la pantalla destino).
class ColaItem {
  const ColaItem({
    required this.titulo,
    this.subtitulo,
    required this.ruta,
    this.accionLabel = 'Ir al contrato',
    this.badgeTexto,
    this.badgeColor,
  });
  final String titulo;
  final String? subtitulo;
  final String ruta;
  final String accionLabel;

  /// Línea de urgencia opcional (ej. "En mora hace 8 días"), coloreada por
  /// antigüedad. Solo la usan las colas de servicio (cortes/reactivar).
  final String? badgeTexto;
  final Color? badgeColor;
}

/// Tarjeta colapsable de una cola: header (ícono + título + contador) y una
/// lista de ítems, cada uno con su botón de próximo paso que NAVEGA. Compartida
/// por el panel de tickets y el "Pendientes de cobranza" del home.
class ColaCard extends StatelessWidget {
  const ColaCard({
    super.key,
    required this.icon,
    required this.color,
    required this.onColor,
    required this.titulo,
    required this.subtitulo,
    required this.items,
    this.count,
  });
  final IconData icon;
  final Color color;
  final Color onColor;
  final String titulo;
  final String subtitulo;
  final List<ColaItem> items;

  /// Número del badge. Por defecto = cantidad de ítems; se sobreescribe cuando
  /// el badge cuenta otra cosa (ej. clientes en mora resumidos en 1 ítem).
  final int? count;

  // Acá vivía un botón de acción en LOTE ("Suspender los N" / "Reactivar los
  // N") que el Centro de cobranza usaba para cortar decenas de contratos de un
  // click. Se eliminó el 2026-08-09 por decisión de Rubén: cada suspensión es
  // individual sin importar cuántas sean, y el admin las tiene que ver de a
  // una. Además bypasseaba el circuito de aprobación de v0.31.28 — el mismo rol
  // no podía suspender UN contrato pero sí treinta.

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(titulo,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(subtitulo, style: const TextStyle(fontSize: 12)),
        trailing: CircleAvatar(
          radius: 13,
          backgroundColor: color,
          child: Text('${count ?? items.length}',
              style: TextStyle(
                  color: onColor, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        childrenPadding: const EdgeInsets.only(bottom: 4),
        children: [
          for (final it in items)
            ListTile(
              dense: true,
              title: Text(it.titulo),
              subtitle: (it.subtitulo == null && it.badgeTexto == null)
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (it.subtitulo != null) Text(it.subtitulo!),
                        if (it.badgeTexto != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(it.badgeTexto!,
                                style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                    color: it.badgeColor)),
                          ),
                      ],
                    ),
              trailing: TextButton(
                onPressed: () => _navegarCola(context, it.ruta),
                child: Text(it.accionLabel),
              ),
            ),
        ],
      ),
    );
  }
}

/// Navega a la ruta de un ítem de cola con el método correcto: los detalles/forms
/// (contrato/cliente/ticket, con guard de descarte) se PUSHean (el volver del
/// shell hace maybePop); las secciones del shell (Avisos) van con `go` — con
/// `push` romperían el título/volver del shell (regla #12). audit 2026-06-30.
void _navegarCola(BuildContext context, String ruta) {
  const detalle = ['/admin/contratos/', '/admin/clientes/', '/admin/tickets/'];
  if (detalle.any((p) => ruta.startsWith(p))) {
    context.push(ruta);
  } else {
    context.go(ruta);
  }
}

// ── Builders de las tarjetas de cobranza (DRY: tickets + home) ───────────────

// Helpers de presentación de las colas de servicio (Fase 2).
String _idNombre(Object? codigo, Object? nombre) {
  final c = (codigo as String?)?.trim();
  final n = (nombre as String?)?.trim();
  if (c != null && c.isNotEmpty) return (n == null || n.isEmpty) ? c : '$c · $n';
  return (n == null || n.isEmpty) ? 'Cliente' : n;
}

String _idPlan(Object? codigo, Object? plan) {
  final c = (codigo as String?)?.trim();
  final p = (plan as String?)?.trim();
  final partes = [
    if (c != null && c.isNotEmpty) c,
    if (p != null && p.isNotEmpty) p,
  ];
  return partes.isEmpty ? 'Contrato' : partes.join(' · ');
}

String? _diasTexto(String prefijo, Object? dias) {
  final d = (dias as num?)?.toInt();
  if (d == null || d < 0) return null;
  final base = '$prefijo $d ${d == 1 ? 'día' : 'días'}';
  // Que el texto cargue la urgencia (no solo el color rojo): +1 semana = atrasado
  // (audit UX 2026-06-30 — el color sin leyenda no comunicaba).
  return d > 7 ? '$base · atrasado' : base;
}

Color _diasColor(ColorScheme scheme, Object? dias) {
  final d = (dias as num?)?.toInt() ?? 0;
  if (d > 7) return scheme.error;
  if (d > 3) return const Color(0xFF854F0B);
  return scheme.onSurfaceVariant;
}

/// Cortes ejecutados (ticket efecto='corte' resuelto) sobre contrato activo →
/// falta suspender. Filas de `colaCortesPendientesProvider`. Cada fila lleva al
/// contrato: se suspende de a UNO, con su deuda a la vista (ya no hay
/// "Suspender los N" — ver el porqué en `ColaCard`).
ColaCard cortesCard(ColorScheme scheme, List<Map<String, dynamic>> rows) =>
    ColaCard(
      icon: Icons.power_off_outlined,
      color: scheme.error,
      onColor: scheme.onError,
      titulo: 'Ya cortados — falta suspender el contrato',
      subtitulo: 'El técnico cortó pero el contrato sigue facturándose.',
      items: [
        for (final r in rows)
          ColaItem(
            titulo: _idNombre(r['cliente_codigo'], r['cliente_nombre']),
            subtitulo: _idPlan(r['contrato_codigo'], r['plan_nombre']),
            ruta: '/admin/contratos/${r['contrato_id']}',
            accionLabel: 'Ver contrato',
            badgeTexto: _diasTexto('En mora hace', r['dias_mora']),
            badgeColor: _diasColor(scheme, r['dias_mora']),
          ),
      ],
    );

/// Contratos suspendidos con la deuda saldada → listo para reactivar. Filas de
/// `colaReactivarPendientesProvider`. Se reactiva de a uno desde el contrato.
ColaCard reactivarCard(ColorScheme scheme, List<Map<String, dynamic>> rows) =>
    ColaCard(
      icon: Icons.power_outlined,
      color: scheme.primary,
      onColor: scheme.onPrimary,
      titulo: 'Deuda saldada — listo para reactivar',
      subtitulo: 'Contrato suspendido con la deuda saldada. Reactivá el servicio.',
      items: [
        for (final r in rows)
          ColaItem(
            titulo: _idNombre(r['cliente_codigo'], r['cliente_nombre']),
            subtitulo: _idPlan(r['contrato_codigo'], r['plan_nombre']),
            ruta: '/admin/contratos/${r['contrato_id']}',
            accionLabel: 'Ver contrato',
            badgeTexto: _diasTexto('Suspendido hace', r['dias_suspendido']),
            badgeColor: _diasColor(scheme, r['dias_suspendido']),
          ),
      ],
    );

/// Clientes en mora (resumidos en 1 ítem con el total) → avisar. El flujo
/// completo (WhatsApp, plantillas) vive en Avisos; acá solo el recordatorio.
/// Filas de `avisosMoraProvider`.
ColaCard moraCard(List<Map<String, dynamic>> rows) {
  final total = rows.fold<double>(
      0, (a, r) => a + ((r['total_cobrable'] as num?)?.toDouble() ?? 0));
  return ColaCard(
    icon: Icons.notifications_active_outlined,
    color: const Color(0xFFA32D2D),
    onColor: Colors.white,
    titulo: 'En mora — avisar',
    subtitulo: 'Clientes vencidos pasada la gracia.',
    count: rows.length,
    items: [
      ColaItem(
        titulo: '${Fmt.cordobas(total)} por cobrar',
        ruta: '/admin/avisos',
        accionLabel: 'Ver en Avisos',
      ),
    ],
  );
}

// ── Bloques EXTRA del Centro de cobranza (no van en el panel del home) ───────

/// Cuotas que vencen HOY → cobrar antes de que se atrasen. Filas de
/// `vencenHoyProvider` (1 por contrato). Persona + monto; navega al contrato.
ColaCard vencenHoyCard(ColorScheme scheme, List<Map<String, dynamic>> rows) =>
    ColaCard(
      icon: Icons.event_available_outlined,
      color: const Color(0xFF475569),
      onColor: Colors.white,
      titulo: 'Vencen hoy',
      subtitulo: 'Cobralos antes de que se atrasen.',
      items: [
        for (final r in rows)
          ColaItem(
            titulo: r['cliente_nombre'] as String? ?? 'Cliente',
            subtitulo:
                'Vence hoy · ${Fmt.cordobas((r['total'] as num?)?.toDouble() ?? 0)}',
            ruta: '/admin/contratos/${r['contrato_id']}',
            accionLabel: 'Ver contrato',
          ),
      ],
    );

/// Clientes EN GRACIA (próximos a corte), resumidos en 1 ítem → avisar. El
/// flujo (WhatsApp) vive en Avisos. Filas de `avisosGraciaProvider`.
ColaCard graciaCard(List<Map<String, dynamic>> rows) {
  final total = rows.fold<double>(
      0, (a, r) => a + ((r['total_cobrable'] as num?)?.toDouble() ?? 0));
  return ColaCard(
    icon: Icons.hourglass_bottom_outlined,
    color: const Color(0xFF854F0B),
    onColor: Colors.white,
    titulo: 'Próximos a corte — en gracia',
    subtitulo: 'Vencidos, dentro del período de gracia.',
    count: rows.length,
    items: [
      ColaItem(
        titulo: '${Fmt.cordobas(total)} por cobrar',
        ruta: '/admin/avisos',
        accionLabel: 'Ver en Avisos',
      ),
    ],
  );
}

/// Contratos con crédito a favor sin aplicar (pagaron de más). Filas de
/// `creditosFavorProvider`. Solo superficie: navega al contrato (el crédito se
/// aplica en el próximo cobro/reactivar, no acá).
ColaCard creditosCard(ColorScheme scheme, List<Map<String, dynamic>> rows) =>
    ColaCard(
      icon: Icons.savings_outlined,
      color: const Color(0xFF1B7A43),
      onColor: Colors.white,
      titulo: 'Créditos a favor sin aplicar',
      subtitulo: 'Pagaron de más — aplicá al saldo o devolvé.',
      items: [
        for (final r in rows)
          ColaItem(
            titulo: r['cliente_nombre'] as String? ?? 'Cliente',
            subtitulo:
                'A favor · ${Fmt.cordobas((r['disponible'] as num?)?.toDouble() ?? 0)}',
            // El crédito es client-level (cruza contratos) → navega al cliente.
            ruta: '/admin/clientes/${r['cliente_id']}',
            accionLabel: 'Ver cliente',
          ),
      ],
    );
