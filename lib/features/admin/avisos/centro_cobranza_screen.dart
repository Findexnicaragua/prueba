import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/centro_cobranza_providers.dart';
import '../../../data/providers/colas_servicio_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../shared/widgets/cola_card.dart';
import 'avisos_screen.dart' show avisosGraciaProvider, avisosMoraProvider;

/// Centro de cobranza: el "home base" del admin / admin_cobranza. Junta en UNA
/// pantalla todo lo accionable — **Cobrar** (vencen hoy · gracia · mora),
/// **Servicio** (suspender · reactivar) y **Créditos a favor** — con métricas
/// arriba para el pantallazo. Reusa los providers ya existentes (gracia/mora de
/// Avisos, cortes/reactivar de Fase 1) + 2 nuevos (vencen hoy, créditos). Cada
/// bloque solo NAVEGA (a Avisos o al contrato); no toca dinero ni estado.
class CentroCobranzaScreen extends ConsumerWidget {
  const CentroCobranzaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final vencenHoy = ref.watch(vencenHoyProvider).valueOrNull ?? const [];
    // Gracia/mora solo si Avisos está habilitado (su flujo vive ahí). Sin esto,
    // tocar "Ver en Avisos" con el toggle off rebota al menú (audit 2026-06-29).
    final avisosOn = ref.watch(appSettingsProvider).avisosHabilitado;
    final gracia = avisosOn
        ? (ref.watch(avisosGraciaProvider).valueOrNull ?? const [])
        : const <Map<String, dynamic>>[];
    final mora = avisosOn
        ? (ref.watch(avisosMoraProvider).valueOrNull ?? const [])
        : const <Map<String, dynamic>>[];
    final cortes =
        ref.watch(colaCortesPendientesProvider).valueOrNull ?? const [];
    final reactivar =
        ref.watch(colaReactivarPendientesProvider).valueOrNull ?? const [];
    final creditos = ref.watch(creditosFavorProvider).valueOrNull ?? const [];
    // Métricas: el TOTAL/cantidad REAL (sin LIMIT) — la lista de abajo muestra los
    // 50 mayores, pero la métrica suma TODO; sin esto subestima en tenant grande
    // con día de pago concentrado (audit QA 2026-06-30).
    final vencenHoyTot = ref.watch(vencenHoyTotalProvider).valueOrNull;
    final creditosTot = ref.watch(creditosFavorTotalProvider).valueOrNull;
    // Total de "a suspender" SIN LIMIT (la lista topa en 50 → la métrica
    // subestimaba en un corte masivo — audit 2026-06-30).
    final cortesTot = ref.watch(colaCortesTotalProvider).valueOrNull;
    // Loading inicial: los watch de arriba usan valueOrNull (null hasta el 1er
    // emit). Sin distinguirlo se pintaba "Nada pendiente" por un instante antes de
    // cargar (audit 2026-06-30). StreamProviders sobre SQLite local → isLoading es
    // true solo hasta el primer emit.
    final cargando = ref.watch(vencenHoyProvider).isLoading ||
        ref.watch(colaCortesPendientesProvider).isLoading ||
        ref.watch(colaReactivarPendientesProvider).isLoading ||
        ref.watch(creditosFavorProvider).isLoading ||
        (avisosOn &&
            (ref.watch(avisosGraciaProvider).isLoading ||
                ref.watch(avisosMoraProvider).isLoading));
    final hayAlgo = vencenHoy.isNotEmpty ||
        gracia.isNotEmpty ||
        mora.isNotEmpty ||
        cortes.isNotEmpty ||
        reactivar.isNotEmpty ||
        creditos.isNotEmpty;

    double suma(List<Map<String, dynamic>> rows, String k) =>
        rows.fold(0.0, (a, r) => a + ((r[k] as num?)?.toDouble() ?? 0));

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Fila de métricas (pantallazo). FittedBox en el valor → no desborda en
        // pantallas angostas (Android).
        Row(
          children: [
            // Las 4 se leen IGUAL: el número grande es la PLATA en las de cobro,
            // y la cantidad de clientes va de sub en las 4 (audit UX 2026-06-30).
            // "A suspender" es un conteo (no hay plata) → número = cantidad.
            _metric(scheme, 'Vencen hoy',
                Fmt.cordobas(vencenHoyTot?.total ?? 0),
                _nClientes(vencenHoyTot?.cant ?? 0)),
            const SizedBox(width: 8),
            _metric(scheme, 'En mora', Fmt.cordobas(suma(mora, 'total_cobrable')),
                _nClientes(mora.length),
                color: const Color(0xFFA32D2D)),
            const SizedBox(width: 8),
            _metric(scheme, 'A suspender', '${cortesTot ?? cortes.length}',
                'ya cortados'),
            const SizedBox(width: 8),
            _metric(scheme, 'A favor', Fmt.cordobas(creditosTot?.total ?? 0),
                _nClientes(creditosTot?.cant ?? 0),
                color: const Color(0xFF1B7A43)),
          ],
        ),
        const SizedBox(height: 12),
        if (cargando && !hayAlgo)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (!hayAlgo)
          Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Center(
              child: Column(children: [
                Icon(Icons.check_circle_outline,
                    size: 48, color: scheme.outline),
                const SizedBox(height: 8),
                Text('Nada pendiente de cobranza',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
            ),
          ),
        if (vencenHoy.isNotEmpty || gracia.isNotEmpty || mora.isNotEmpty) ...[
          _seccion(scheme, 'Cobrar'),
          if (vencenHoy.isNotEmpty) vencenHoyCard(scheme, vencenHoy),
          if (gracia.isNotEmpty) graciaCard(gracia),
          if (mora.isNotEmpty) moraCard(mora),
        ],
        if (cortes.isNotEmpty || reactivar.isNotEmpty) ...[
          _seccion(scheme, 'Servicio'),
          // Cada fila lleva al contrato y se resuelve de a UNA. El botón
          // "Suspender los N" / "Reactivar los N" se eliminó el 2026-08-09
          // (decisión de Rubén): cada suspensión es individual sin importar
          // cuántas sean, y el admin las tiene que ver una por una.
          if (cortes.isNotEmpty) cortesCard(scheme, cortes),
          if (reactivar.isNotEmpty) reactivarCard(scheme, reactivar),
        ],
        if (creditos.isNotEmpty) ...[
          _seccion(scheme, 'Créditos'),
          creditosCard(scheme, creditos),
        ],
      ],
    );
  }

  // "1 cliente" / "N clientes" — sub de las métricas.
  String _nClientes(int n) => n == 1 ? '1 cliente' : '$n clientes';

  Widget _seccion(ColorScheme scheme, String t) => Padding(
        padding: const EdgeInsets.only(left: 4, top: 8, bottom: 6),
        child: Text(t,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant)),
      );

  Widget _metric(ColorScheme scheme, String label, String value, String sub,
          {Color? color}) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: color ?? scheme.onSurface)),
              ),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
}
