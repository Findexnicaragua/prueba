import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/utils/ticket_sla.dart';

/// Chip con la CUENTA REGRESIVA viva del SLA de un ticket ("2h 15m restantes" →
/// ámbar "por vencer" → rojo "vencido hace 30m"). Se auto-actualiza con un
/// `Timer.periodic` y es matemática pura sobre data local → TICKEA OFFLINE.
///
/// `slaHoras` debe ser el SLA EFECTIVO ([slaHorasEfectivas]: min tipo/prioridad).
/// Render por situación:
///   - en plazo / por vencer / vencido → chip con el restante (color por estado)
///   - en_espera → chip estático "SLA pausado" (no ticker)
///   - sin SLA / cerrado → nada (`SizedBox.shrink`) — el estado ya se ve aparte
///
/// `tick`: 1 min en listas (suficiente para SLAs en horas), 1 s en el detalle
/// (donde ver el número bajar construye urgencia). El reloj del device es la
/// fuente — un device con la hora mal verá un restante mal (fuera de alcance;
/// los timestamps del server siguen siendo la verdad).
///
/// `compact`: en listas (trailing angosto) muestra "2h 15m" / "Pausado" sin las
/// palabras "restantes"/"hace"/"SLA" — el color del chip ya comunica el estado.
class TicketSlaCountdown extends StatefulWidget {
  const TicketSlaCountdown({
    super.key,
    required this.estado,
    required this.createdAt,
    required this.slaHoras,
    this.prioridad,
    this.segundosPausado = 0,
    this.tick = const Duration(minutes: 1),
    this.compact = false,
  });

  final String estado;
  final DateTime createdAt;
  final int? slaHoras; // EFECTIVO (min tipo/prioridad)
  final String? prioridad;
  final int segundosPausado;
  final Duration tick;
  final bool compact;

  @override
  State<TicketSlaCountdown> createState() => _TicketSlaCountdownState();
}

class _TicketSlaCountdownState extends State<TicketSlaCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.tick, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estadoSla = ticketSlaEstado(
      estado: widget.estado,
      createdAt: widget.createdAt,
      slaHoras: widget.slaHoras,
      prioridad: widget.prioridad,
      segundosPausado: widget.segundosPausado,
    );
    if (estadoSla == SlaEstado.sinSla || estadoSla == SlaEstado.cerrado) {
      return const SizedBox.shrink();
    }
    final color = slaColor(estadoSla, scheme);
    final String texto;
    if (estadoSla == SlaEstado.pausado) {
      texto = widget.compact ? 'Pausado' : 'SLA pausado';
    } else {
      final restante = ticketSlaRestante(
        estado: widget.estado,
        createdAt: widget.createdAt,
        slaHoras: widget.slaHoras,
        segundosPausado: widget.segundosPausado,
      );
      texto = restante == null
          ? slaLabel(estadoSla)
          : formatSlaRestante(restante, compact: widget.compact);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        texto,
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
