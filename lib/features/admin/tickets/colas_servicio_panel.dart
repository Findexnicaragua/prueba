import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/colas_servicio_provider.dart';
import '../../shared/widgets/cola_card.dart';

/// Panel de acciones de facturación derivadas de las órdenes de trabajo, en la
/// LISTA DE TICKETS (admin). Las mismas colas se ven en el Centro de cobranza
/// (Cobranza → Centro), que reusa las mismas tarjetas. Vacío → no renderiza.
/// Solo navega al contrato; no toca dinero ni estado.
class ColasServicioPanel extends ConsumerWidget {
  const ColasServicioPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cortes =
        ref.watch(colaCortesPendientesProvider).valueOrNull ?? const [];
    final reactivar =
        ref.watch(colaReactivarPendientesProvider).valueOrNull ?? const [];
    if (cortes.isEmpty && reactivar.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // Cota de altura + scroll propio: el panel es un hijo FIJO del Column de la
    // pantalla (arriba del ListView de tickets). Sin la cota, expandir colas
    // largas desbordaría y taparía filtros/lista (AGENTS regla #11).
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Column(
            children: [
              if (cortes.isNotEmpty) cortesCard(scheme, cortes),
              if (reactivar.isNotEmpty) reactivarCard(scheme, reactivar),
            ],
          ),
        ),
      ),
    );
  }
}
