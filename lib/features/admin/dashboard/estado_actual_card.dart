import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart';
import '../../../data/utils/formatters.dart';
import 'escala_resumen.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';

/// # Estado actual — la foto de la cartera viva
///
/// **Es una FOTO, no una ventana de tiempo.** Las demás tarjetas del Resumen
/// miden un ciclo ("de lo facturado del 15 al 14, cuánto entró"); ésta dice qué
/// hay AHORA, sin importar de qué mes venga.
///
/// ## Por qué esto es una GRILLA de KPIs y no una lista con barra (2026-09-02)
///
/// Lo fue hasta el 2026-09-01, cuando se rehízo como lista de partes ("Al día /
/// En gracia / En mora") con barra apilada, plata y porcentaje, y de paso se
/// **comió** a la tarjeta "Distribución de cuotas". El dueño miró las dos
/// versiones y **eligió volver a la de producción (v0.37.1)**: cuatro números
/// grandes, uno por tarjeta, que se leen de un vistazo desde lejos.
///
/// Así que la partición volvió a su tarjeta: **"Distribución de cuotas"
/// (`distribucion`) es de nuevo la dueña de "Al día / En gracia / Vencidas"**,
/// y esta tarjeta no la toca.
///
/// **Ojo con el atajo fácil**: aquélla NO se alimenta de [OperativoKpis] sino
/// de `DistribucionCuotas`, otro modelo con su propia query y hasta con otros
/// nombres (`vencida`/`pagada`/`parcial`, en singular). Verificado por grep el
/// 2026-09-02: este archivo es el ÚNICO consumidor de `operativoKpisProvider`,
/// así que los campos `alDia`, `saldoAlDia`, `enGracia`, `saldoEnGracia`,
/// `pagadas` y `parciales` —que la versión de lista sí leía— hoy **no los lee
/// nadie**. Quedan en el modelo a propósito y desde acá no se tocan; si alguna
/// vez se podan, hay que podar también su SQL en `dashboard_providers.dart`.
/// Se deja escrito porque el comentario anterior decía lo contrario ("los
/// consume aquélla") y mandaba al próximo a buscar un consumidor que no existe.
///
/// **Lo único que NO volvió al original es la tipografía**: los tamaños salen
/// de [TxtResumen] (escala compartida de las siete tarjetas) en vez de estar
/// escritos a mano, para que la misma clase de dato mida lo mismo en todo el
/// Resumen. **Dentro de la grilla** quedaron iguales o MENORES que los del
/// original, así que ninguna medida de alto corre riesgo (ver [_Kpis]). La
/// única que SUBIÓ es la línea de error ("No se pudo calcular": era un 12
/// suelto, hoy `cifra` = 14) y vive FUERA de la grilla, así que no entra en esa
/// cuenta; subió a propósito, es un mensaje que el dueño tiene que poder leer.
///
/// ## Lo que hay que entender de los números
///
/// **"Cuotas por cobrar" es casi todo futuro.** La app genera 3 meses de cuotas
/// por adelantado para que el cobrador pueda cobrar adelantado sin internet, así
/// que ese número incluye meses que todavía no vencieron: es MUCHO más de lo que
/// se debe hoy. Lo que ya venció está en "En mora".
///
/// **"De eso, suspendido" NO es un cuarto bucket**: es cuánta de la deuda de
/// arriba viene de contratos sin servicio. Sumarlo la duplica.

/// La tarjeta NO se envuelve en un `Card`: cada KPI ES un `Card`, y una grilla
/// de tarjetas adentro de otra tarjeta se lee como un error de layout. Así vivía
/// en producción, suelta entre las demás del Resumen.
class EstadoActualCard extends ConsumerWidget {
  const EstadoActualCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(operativoKpisProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Encabezado suelto (sin Card que lo contenga). El título va con
        // `titleMedium` como TODAS las tarjetas del Resumen: es la convención
        // compartida y no se toca aunque la tipografía interna venga de
        // `TxtResumen`.
        Row(
          children: [
            Icon(Icons.donut_large, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Estado actual',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const InfoGraficaBoton(kInfoOperativo),
          ],
        ),
        const SizedBox(height: 8),
        async.when(
          data: (k) => _Kpis(items: [
            _KpiData('Clientes activos', '${k.clientes}', null, Icons.people),
            _KpiData('Cuotas por cobrar', '${k.cuotasPend}',
                Fmt.cordobas(k.saldo), Icons.pending),
            _KpiData(
              'En mora',
              '${k.vencidas}',
              Fmt.cordobas(k.saldoVencido),
              Icons.warning,
              error: true,
            ),
            // DESGLOSE, no un cuarto bucket: desde el 2026-08-26 esta plata ya
            // está adentro de "Cuotas por cobrar" y de "En mora". Lo que dice
            // esta tarjeta es cuánta de esa deuda no sale en la ruta del día
            // (se cobra desde "Recuperación · fuera de ruta"). El rótulo
            // arranca con "De eso" justamente para que nadie la sume aparte.
            if (k.cuotasSuspendidas > 0)
              _KpiData(
                'De eso, suspendido',
                '${k.cuotasSuspendidas}',
                Fmt.cordobas(k.saldoSuspendido),
                Icons.pause_circle_outline,
              ),
          ]),
          // `shrink()`, igual que producción. Se probó reservar 120px para que
          // las tarjetas de abajo no saltaran al llegar los números, y la cuenta
          // no cierra: la grilla mide ~350px en escritorio y ~600px en un
          // teléfono a 1 columna con los cuatro KPIs, así que 120 no evita el
          // salto —lo achica— y a cambio deja un hueco permanente que el diseño
          // aprobado no tiene. Reservar el alto REAL exigiría saber cuántos KPIs
          // vienen, que es justo lo que todavía no se sabe mientras carga.
          loading: () => const SizedBox.shrink(),
          // M13: antes el error desaparecía el KPI en silencio y la tarjeta
          // parecía "todo en cero", que es justo lo contrario de lo que
          // significa. Va a `cifra` y no al piso de la escala porque es un
          // mensaje que el dueño TIENE que poder leer.
          error: (_, __) => Text('No se pudo calcular',
              style: TextStyle(
                  fontSize: TxtResumen.cifra, color: scheme.error)),
        ),
      ],
    );
  }
}

/// La grilla responsive de KPIs.
class _Kpis extends StatelessWidget {
  const _Kpis({required this.items});
  final List<_KpiData> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 900 ? 3 : c.maxWidth >= 500 ? 2 : 1;
      return GridView.count(
        crossAxisCount: cols,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        // Vive adentro del `ListView` del Resumen: se deja medir por su
        // contenido y NO scrollea por su cuenta.
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        // Mobile (1 col): ratio 2.3 — el contenido del card (icon+label
        // row + value + sub-label + 3 spacings + padding 20×2) necesita
        // ~132px de alto. Con viewport 375px y padding del padre (~32px),
        // el ancho del card es ~343px → ratio 2.3 da ~149px de alto,
        // holgado. Probado: 4.0 → "BOTTOM OVERFLOWED BY 18 PIXELS",
        // 3.0 → "BY 23 PIXELS", 2.3 → entra OK.
        // 2 / 3 columnas (tablet/desktop) mantienen 2.2 — el ancho del
        // card es menor pero el contenido entra holgado.
        //
        // Esos números se midieron con el valor en `headlineMedium` (~28px)
        // y el sub-rótulo en 14. Hoy el valor va a `TxtResumen.gigante`
        // (24px) y el sub a `cifraSub` (13): el contenido quedó ~5px MÁS
        // BAJO, así que los mismos ratios siguen sobrando. Si alguna vez la
        // escala SUBE, esta cuenta hay que rehacerla — el desborde no lo
        // caza `flutter analyze`, aparece en el render.
        childAspectRatio: cols == 1 ? 2.3 : 2.2,
        children: items.map((k) => _KpiCard(data: k)).toList(),
      );
    });
  }
}

class _KpiData {
  const _KpiData(this.label, this.value, this.sub, this.icon,
      {this.error = false});
  final String label;
  final String value;

  /// La línea de abajo — normalmente la plata del conteo de arriba. `null` =
  /// el KPI es solo un número (Clientes activos).
  final String? sub;
  final IconData icon;

  /// Pinta el icono en color de error. Lo usa "En mora": es el único de los
  /// cuatro que señala un problema, no un dato.
  final bool error;
}

/// Un KPI = una tarjeta. Icono + rótulo arriba, el número grande abajo, y la
/// plata debajo si la hay.
///
/// De solo lectura: los `primary`/`onTap` del original —que volvían la tarjeta
/// un botón de selección— eran de los KPIs de "Caja del ciclo", que eligen la
/// ventana del desglose. Acá no hay nada que elegir, así que no se copiaron:
/// código muerto en un archivo es una promesa que nadie cumple.
class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.data});
  final _KpiData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = data.error ? scheme.error : scheme.outline;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(data.icon, size: 20, color: color),
                const SizedBox(width: 8),
                // El rótulo se trunca antes que romper la fila: en 1 columna
                // "De eso, suspendido" con el icono al lado va justo.
                Expanded(
                  child: Text(data.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: TxtResumen.cifra,
                          color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // El protagonista. Se conserva la fuente y el peso del
            // `headlineMedium` del tema —es lo que le da el aire de titular—
            // y solo se le pisa el TAMAÑO con la escala del Resumen, para que
            // el número grande mida lo mismo en las siete tarjetas.
            Text(data.value,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontSize: TxtResumen.gigante)),
            if (data.sub != null) ...[
              const SizedBox(height: 4),
              Text(data.sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: TxtResumen.cifraSub,
                      color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}
