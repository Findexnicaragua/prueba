import 'escala_resumen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';

/// # Distribución de cuotas — el conteo por vigencia
///
/// ## Por qué VOLVIÓ (2026-09-02)
///
/// El 2026-09-01 esta tarjeta se fusionó dentro de "Estado actual" y quedó
/// apagada por defecto, con el argumento de que era la misma partición contada
/// dos veces. El dueño pidió recuperarla el 2026-09-02, **sabiendo que
/// comparten números**: `Al día + En gracia + Vencidas` es exactamente
/// "Cuotas por cobrar" de aquélla, y `Vencidas` es su "En mora".
///
/// Ese "exactamente" está VERIFICADO, no supuesto: un comentario que promete
/// equivalencia hay que diffearlo contra los dos cuerpos vivos, porque el otro
/// lado se mueve solo. Son **dos queries distintas** —esta tarjeta lee
/// `distribucionCuotasProvider`, aquélla `estadoActual()` de
/// `dashboard_query.dart`— y coinciden porque barren la MISMA población
/// (`FROM cuotas WHERE estado != 'anulada'`) con los MISMOS cortes de fecha
/// (`fecha_vencimiento` contra `date('now','-6 hours')`, más la gracia de
/// `diasGracia`). Si alguien toca uno solo de los dos WHERE, la igualdad se
/// rompe callada: no hay test que la cuide.
///
/// La quiere separada igual, y el motivo es lo que la otra NO trae: el **corte
/// al día / en gracia** como dos renglones propios y el **conteo de Pagadas**.
/// "Estado actual" habla de cartera VIVA —lo que falta cobrar— y su grilla son
/// cuatro KPIs (Clientes activos · Cuotas por cobrar · En mora · De eso,
/// suspendido): lo ya saldado no aparece por ningún lado ahí. Esta tarjeta
/// cuenta TODAS las cuotas no anuladas, incluidas las pagadas, y por eso el
/// total es otro.
///
/// O sea: no es una duplicación por descuido, es una decisión. Antes de
/// "simplificar" volviendo a fusionarlas, preguntarle al dueño.
///
/// ## Diseño: el de PRODUCCIÓN (v0.37.1), tipografía la nueva
///
/// El layout es el de siempre —lista con un ícono por renglón— porque es el que
/// el dueño reconoce. Lo único que cambia respecto de la versión vieja son los
/// tamaños de letra: salen de [TxtResumen] y no de números sueltos. Los `11` y
/// `12` que había escritos a mano acá quedaron obsoletos con el pedido de
/// legibilidad del 2026-09-01 (ver `escala_resumen.dart`).
///
/// Tampoco tiene botón de Excel: en producción nunca lo tuvo. El (i) sí se
/// queda, que es lo que explica de dónde sale cada bucket.
///
/// ## Los dos ejes de la tarjeta
///
/// **Al día / En gracia / Vencidas / Pagadas es el eje VIGENCIA**: una
/// partición disjunta, cada cuota cae en uno y en uno solo, y los cuatro suman
/// el total de cuotas no anuladas.
///
/// **"Con pago parcial" NO es un quinto bucket**: es un overlay TRANSVERSAL que
/// cruza a los de arriba (una cuota parcial ya está contada como al día, en
/// gracia o vencida según su fecha). Por eso va después de un `Divider` y con
/// la nota debajo — sumarlo a los otros cuatro duplica cuotas.
class DistribucionCuotasCard extends ConsumerWidget {
  const DistribucionCuotasCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(distribucionCuotasProvider);
    final pagoParcialOn = ref.watch(pagoParcialHabilitadoProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // El título queda con `titleMedium` del tema: es la convención
                // que comparten las siete tarjetas del Resumen y no se toca
                // desde acá.
                Expanded(
                  child: Text('Distribución de cuotas',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const InfoGraficaBoton(kInfoDistribucion),
              ],
            ),
            const SizedBox(height: 16),
            async.when(
              data: (k) {
                final scheme = Theme.of(context).colorScheme;
                // 'Con pago parcial' se muestra si la feature está prendida O
                // si ya hay parciales en la base. Sin la primera condición no
                // se vería nunca al recién encenderla; sin la segunda, un
                // tenant que la apagó perdería de vista los parciales que ya
                // tiene. Y con la feature apagada y cero parciales el renglón
                // diría siempre 0: puro ruido.
                final mostrarParcial = pagoParcialOn || k.parcial > 0;
                return Column(
                  children: [
                    _row('Al día', '${k.alDia}', scheme.primary, Icons.event),
                    _row('En gracia', '${k.enGracia}', Colors.amber.shade700,
                        Icons.schedule),
                    _row('Vencidas', '${k.vencida}', scheme.error,
                        Icons.warning),
                    _row('Pagadas', '${k.pagada}', scheme.outline, Icons.check),
                    if (mostrarParcial) ...[
                      // El Divider separa el eje vigencia (arriba) del overlay
                      // transversal (abajo). No es decoración: es la línea que
                      // avisa que lo de abajo NO suma con lo de arriba.
                      const Divider(height: 20),
                      _row('Con pago parcial', '${k.parcial}',
                          Colors.teal.shade700, Icons.hourglass_bottom),
                      Padding(
                        // Alineada con el texto del renglón, no con el ícono.
                        padding: const EdgeInsets.only(left: 26, bottom: 4),
                        child: Text('incluidas en los buckets de arriba',
                            style: TextStyle(
                                fontSize: TxtResumen.apoyo,
                                color: scheme.outline)),
                      ),
                    ],
                  ],
                );
              },
              loading: () => const SizedBox.shrink(),
              // M13: antes el error dejaba el card vacío en silencio.
              error: (_, __) => Text('No se pudo calcular',
                  style: TextStyle(
                      fontSize: TxtResumen.apoyo,
                      color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ),
      ),
    );
  }

  /// Un renglón de la lista: ícono de color, rótulo y conteo.
  ///
  /// **Un solo `Expanded`, y es el de la izquierda** (regla #15 del checklist):
  /// el rótulo se come todo el sobrante y el número queda pegado al borde
  /// derecho, en el mismo lugar en todos los renglones. Con un `Flexible`
  /// hermano, cada fila terminaría en un borde distinto según cuán largo sea su
  /// texto.
  Widget _row(String label, String value, Color color, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: TxtResumen.cifra))),
          // El conteo es la cifra de una fila madre: mismo cuerpo que el
          // rótulo, y el peso + el color son los que arman la jerarquía.
          Text(value,
              style: TextStyle(
                  fontSize: TxtResumen.cifra,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ],
      ),
    );
  }
}
