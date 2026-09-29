import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../dashboard/dashboard_tarjetas.dart';

/// Ajustes → Avanzado → **Tarjetas del Resumen**.
///
/// Arrastrar para reordenar, interruptor para encender o apagar. Pedido de
/// Rubén (2026-08-29), sólo para el super_admin y **por empresa**: configurarlo
/// impersonando a Telecable cambia sólo Telecable, igual que el resto de los
/// ajustes del CRM.
///
/// **Se guarda al Aceptar, no a cada toque.** Reordenar es una serie de pasos
/// intermedios —se mueve una fila, después otra— y escribir cada uno mandaría
/// órdenes a medias a la base y al resto de los dispositivos.
class DashboardTarjetasScreen extends ConsumerStatefulWidget {
  const DashboardTarjetasScreen({super.key});

  @override
  ConsumerState<DashboardTarjetasScreen> createState() =>
      _DashboardTarjetasScreenState();
}

class _DashboardTarjetasScreenState
    extends ConsumerState<DashboardTarjetasScreen> {
  List<TarjetaConfig>? _filas;
  bool _guardando = false;

  /// Lo que había al abrir, para saber si hay cambios sin guardar.
  String? _original;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);

    // Se carga UNA vez: si se re-leyera en cada build, el sync de otro
    // dispositivo pisaría lo que se está reordenando acá.
    _filas ??= leerOrdenTarjetas(settings.dashTarjetasOrden);
    _original ??= escribirOrdenTarjetas(_filas!);

    final filas = _filas!;
    final hayCambios = escribirOrdenTarjetas(filas) != _original;
    final encendidas = filas.where((f) => f.encendida).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tarjetas del Resumen'),
        actions: [
          TextButton(
            onPressed: _guardando
                ? null
                : () => setState(() => _filas = ordenPorDefecto),
            child: const Text('Restablecer'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Arrastrá con ⠿ para cambiar el orden. El interruptor la '
                    'muestra o la esconde.',
                    style: TextStyle(fontSize: 12.5, color: scheme.outline)),
                const SizedBox(height: 6),
                Text(
                    encendidas == 0
                        ? 'Ninguna encendida: el Resumen va a quedar vacío.'
                        : '$encendidas de ${filas.length} encendidas · el orden '
                            'es de arriba hacia abajo',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: encendidas == 0 ? scheme.error : scheme.outline)),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: filas.length,
              onReorder: (viejo, nuevo) => setState(() {
                // `ReorderableListView` entrega el índice destino ANTES de
                // sacar el elemento: si va hacia abajo hay que restar uno o la
                // fila cae una posición más allá de donde se soltó.
                if (nuevo > viejo) nuevo -= 1;
                final f = filas.removeAt(viejo);
                filas.insert(nuevo, f);
              }),
              itemBuilder: (context, i) {
                final f = filas[i];
                return ListTile(
                  key: ValueKey(f.id),
                  leading: ReorderableDragStartListener(
                    index: i,
                    child: Icon(Icons.drag_indicator, color: scheme.outline),
                  ),
                  title: Text(f.nombre,
                      style: TextStyle(
                          fontSize: 14,
                          color: f.encendida ? null : scheme.outline)),
                  subtitle: f.tarjeta.soloAdmin
                      // El gate de rol manda sobre el ajuste: encenderla acá no
                      // se la muestra igual a quien no ve montos cobrados.
                      ? Text('No la ve admin_cobranza (muestra montos cobrados)',
                          style: TextStyle(fontSize: 11, color: scheme.outline))
                      : null,
                  trailing: Switch(
                    value: f.encendida,
                    onChanged: _guardando
                        ? null
                        : (v) => setState(() => filas[i] = f.conEncendida(v)),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        hayCambios
                            ? 'Hay cambios sin guardar'
                            : 'Sin cambios',
                        style: TextStyle(
                            fontSize: 12,
                            color: hayCambios ? scheme.primary : scheme.outline)),
                  ),
                  FilledButton(
                    onPressed: (!hayCambios || _guardando) ? null : _guardar,
                    child: _guardando
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Guardar'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _guardar() async {
    setState(() => _guardando = true);
    // El String es para COMPARAR; lo que se guarda es la lista cruda. `update`
    // hace el `jsonEncode`, así que mandarle el String ya serializado lo
    // codifica dos veces y el Resumen ignora el resultado — la pantalla decía
    // "guardado" y no pasaba nada (bug encontrado el 2026-09-01).
    final valor = escribirOrdenTarjetas(_filas!);
    Object? error;
    try {
      await ref.read(settingsRepoProvider).update(
            ref.read(tenantIdProvider) ?? '',
            'dashboard.tarjetas',
            ordenTarjetasCrudo(_filas!),
            // Atribuir el cambio al admin real: sin `usuarioId` el op_log lo
            // registra como "System Admin". `op_log` es el ÚNICO change log
            // desde 0140.
            usuarioId: ref.read(cobradorActualProvider).valueOrNull?.id,
          );
    } catch (e) {
      error = e;
    } finally {
      // Cleanup GARANTIZADO: sin esto una excepción deja el botón en spinner
      // para siempre (regla #9 del checklist de audit).
      if (mounted) setState(() => _guardando = false);
    }
    if (!mounted) return;
    if (error == null) _original = valor;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error == null
          ? 'Orden guardado'
          : 'No se pudo guardar: $error'),
    ));
  }
}
