import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart'
    show dashboardRefreshEpochProvider;
import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import 'escala_resumen.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';
import 'resumen_watch.dart';

/// # Proyección de cobros por cobrador — tarjeta AUTOCONTENIDA
///
/// No comparte grilla, consulta ni estilos con ninguna otra tarjeta del
/// Resumen. Decisión del dueño (2026-08-28): *"cada una es individual… así cada
/// cambio en cada una es independiente de los demás y no deberían afectarlos"*.
///
/// **Dónde está la línea:** cada tarjeta se queda con su presentación y sus
/// consultas. Lo que sí se comparte es infraestructura NEUTRAL — formato de
/// números (`Fmt`), la escala tipográfica ([TxtResumen]), el corte horario de
/// Nicaragua. Duplicar el corte horario sería contraproducente: si algún día
/// cambia, un olvido dejaría dos tarjetas cortando el día en horas distintas,
/// que es un bug de dinero, no de estilo.
///
/// ## Por qué esta tarjeta volvió a las BARRAS (2026-09-02)
///
/// Entre medio se le puso una tabla de tres columnas —"Cuotas · % del total ·
/// Monto"— con desglose colapsable y botón de Excel. El dueño la mandó de vuelta
/// a la forma que tiene en producción (v0.37.1): **una barra por cobrador,
/// ordenadas de mayor a menor, con un switch que suma las cuotas próximas.**
/// El motivo es de lectura, no de gusto: acá la pregunta es *"a quién mando a
/// cobrar"*, y una barra contesta de un vistazo quién carga más. Una tabla de
/// porcentajes obliga a leer números para llegar a la misma conclusión.
///
/// **Y horizontales, no verticales** (motivo que venía de la versión anterior y
/// se conserva porque sigue valiendo): el eje de esta tarjeta es una LISTA DE
/// NOMBRES, no el tiempo. Un nombre de cobrador no entra debajo de una barra
/// angosta; al lado, sí.
///
/// Lo que NO volvió del pasado: los tamaños de letra. Los `fontSize: 12/13`
/// sueltos que tenía la pantalla vieja se reemplazaron por los roles de
/// [TxtResumen] — el mismo dato tiene que medir lo mismo en las siete tarjetas.
///
/// **El botón de Excel se sacó**: en producción esta tarjeta nunca lo tuvo, y
/// con él se fueron el armado del libro y los imports de `dashboard_export` /
/// `reporte_excel` / `periodo_dashboard`, que sólo existían para alimentarlo.
/// El botón (i) se queda: explica qué mide la tarjeta y qué deja afuera.
///
/// **🔴 Superficie conectada que quedó MINTIENDO** (regla de oro §1, pendiente
/// al 2026-09-02): la única `InfoOpcion` de `kInfoProyeccion`
/// (`info_grafica_textos.dart`) describe *"la flecha ▸ de un cobrador"*, que era
/// el desglose colapsable del diseño intermedio y acá ya no existe. El control
/// de hoy es el switch "Incluir cuotas próximas". Hay que reescribir esa opción
/// —el `eje`, el `incluye`/`noIncluye` y la `nota` siguen siendo correctos—, y
/// no se hizo desde acá porque ese archivo lo comparten todas las tarjetas.

/// El día de hoy en Nicaragua (UTC-6, sin DST). Regla #1b del checklist: toda
/// lógica de límite de día usa este corte, NUNCA `date('now')` pelado.
const _hoyNi = "date('now','-6 hours')";

/// Lo que un cobrador tiene por delante.
class ProyeccionFila {
  const ProyeccionFila({
    required this.id,
    required this.nombre,
    required this.cuotasHoy,
    required this.montoHoy,
    required this.cuotasProx,
    required this.montoProx,
  });

  /// Null = las cuotas de clientes SIN cobrador asignado. No es un error: son
  /// "admin-managed", cartera que sólo ven admin y admin_cobranza. Se muestran
  /// como fila propia para que el total cierre y se vea cuánta cartera no tiene
  /// dueño (30 cuotas / C$20.800 en el Test Tenant).
  final String? id;
  final String nombre;
  final int cuotasHoy, cuotasProx;
  final num montoHoy, montoProx;

  int get cuotas => cuotasHoy + cuotasProx;
  num get monto => montoHoy + montoProx;
  bool get sinCobrador => id == null;
}

/// Lo que falta cobrar de HOY EN ADELANTE, por cobrador asignado.
///
/// **No incluye lo vencido, a propósito.** Contesta "a quién mando a cobrar",
/// no "cuánto me deben": lo atrasado vive en la tarjeta de Mora y en la de
/// Recuperación por cobrador y comunidad. Confirmado con el dueño el 2026-08-28;
/// la tarjeta volvió a llamarse así el 2026-09-02.
///
/// Sólo clientes y contratos ACTIVOS: a un contrato sin servicio no se lo
/// visita por su cuota nueva.
///
/// La consulta trae SIEMPRE las dos patas (hoy y próximos días) aunque el switch
/// esté apagado: prenderlo no puede disparar una consulta nueva ni un parpadeo,
/// es sólo elegir qué columna se suma.
final proyeccionCobrosCardProvider = StreamProvider.autoDispose<List<ProyeccionFila>>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB
  ref.watch(dashboardRefreshEpochProvider);
  final diasProx =
      ref.watch(appSettingsProvider.select((s) => s.diasCuotasVisibles));
  const saldo = 'max(cu.monto + COALESCE(cu.cargos_neto, 0) - '
      'COALESCE(cu.monto_pagado, 0), 0)';
  const contratoActivo = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') = 'activo'";
  return watchResumen(
    '''
    SELECT cu.cobrador_id AS cob_id, co.nombre AS cob_nombre,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento = $_hoyNi
                        THEN $saldo ELSE 0 END), 0) AS monto_hoy,
      COUNT(CASE WHEN cu.fecha_vencimiento = $_hoyNi THEN 1 END)
        AS cuotas_hoy,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento > $_hoyNi
                        AND cu.fecha_vencimiento
                            <= date('now','-6 hours','+' || ? || ' days')
                        THEN $saldo ELSE 0 END), 0) AS monto_prox,
      COUNT(CASE WHEN cu.fecha_vencimiento > $_hoyNi
                 AND cu.fecha_vencimiento
                     <= date('now','-6 hours','+' || ? || ' days')
                 THEN 1 END) AS cuotas_prox
      FROM cuotas cu
      JOIN clientes c ON c.id = cu.cliente_id AND c.activo = 1
 LEFT JOIN cobradores co ON co.id = cu.cobrador_id
     WHERE cu.estado IN ('pendiente','parcial') AND $contratoActivo
     GROUP BY cu.cobrador_id, co.nombre
    ''',
    parameters: [diasProx, diasProx],
  ).map((rows) {
    final out = rows
        .map((r) => ProyeccionFila(
              id: r['cob_id'] as String?,
              nombre: (r['cob_nombre'] as String?) ?? '',
              cuotasHoy: (r['cuotas_hoy'] as num).toInt(),
              montoHoy: r['monto_hoy'] as num,
              cuotasProx: (r['cuotas_prox'] as num).toInt(),
              montoProx: r['monto_prox'] as num,
            ))
        .where((p) => p.cuotas > 0)
        .toList()
      // De mayor a menor: la primera fila es a quién hay que empujar.
      ..sort((a, b) => b.monto.compareTo(a.monto));
    return out;
  });
});

/// Proyección de cobros por cobrador. Por defecto muestra lo que cada cobrador
/// asignado debería cobrar HOY; el switch suma las cuotas que vencen dentro de
/// los próximos `dias_cuotas_visibles` días.
class ProyeccionCobrosCard extends ConsumerStatefulWidget {
  const ProyeccionCobrosCard({super.key});

  @override
  ConsumerState<ProyeccionCobrosCard> createState() =>
      _ProyeccionCobrosCardState();
}

class _ProyeccionCobrosCardState extends ConsumerState<ProyeccionCobrosCard> {
  /// Arranca APAGADO: la pregunta del día a día es "a quién mando hoy". El
  /// horizonte largo es la excepción, y por eso se pide con un gesto.
  bool _incluirProximas = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(proyeccionCobrosCardProvider);
    final diasProx =
        ref.watch(appSettingsProvider.select((s) => s.diasCuotasVisibles));

    // El switch no filtra la consulta: elige QUÉ pata de cada fila se suma. Las
    // dos ya vinieron del provider, así que prenderlo y apagarlo es instantáneo
    // y no vuelve a la base.
    num montoDe(ProyeccionFila p) =>
        _incluirProximas ? p.montoHoy + p.montoProx : p.montoHoy;
    int cuotasDe(ProyeccionFila p) =>
        _incluirProximas ? p.cuotasHoy + p.cuotasProx : p.cuotasHoy;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Título en `titleMedium`: la convención COMPARTIDA por las
                // siete tarjetas del Resumen, y no se toca desde acá.
                //
                // El ícono va a 20 y NO a los 18 que tenía en producción, que
                // es la única desviación deliberada del layout viejo. Motivo
                // medido, no supuesto: hoy el Resumen está partido —"Caja del
                // ciclo", "Quién cobró", "Mora de 6 ciclos" y "Tendencia" usan
                // 20; "Estado actual" y "Recuperación" quedaron en 18—. Se
                // sigue a la mayoría para que el renglón de encabezados no
                // baile al scrollear. Si algún día se unifican en 18, esta
                // línea baja con ellas.
                Icon(Icons.event_available, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Proyección de cobros por cobrador',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const InfoGraficaBoton(kInfoProyeccion),
              ],
            ),
            const SizedBox(height: 4),
            // El subtítulo cambia con el switch a propósito: sin él, dos
            // números muy distintos se leerían bajo el mismo rótulo y nadie
            // sabría si está mirando el día o la semana.
            Text(
              _incluirProximas
                  ? 'Esperado a cobrar: vence hoy + próximos $diasProx días'
                  : 'Esperado a cobrar: cuotas que vencen hoy',
              style:
                  TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline),
            ),
            Row(
              children: [
                Switch(
                  value: _incluirProximas,
                  onChanged: (v) => setState(() => _incluirProximas = v),
                ),
                // Un solo hijo flexible y CERO `Flexible` (regla #15). Acá el
                // `Expanded` va a la derecha y no a la izquierda como en las
                // filas de cifras, porque lo que hay del otro lado es el
                // `Switch` —ancho fijo, se dibuja igual— y no hay ningún número
                // que tenga que quedar pegado al borde. Lo que la regla prohíbe
                // es el reparto en partes iguales entre dos flex, y con uno
                // solo no puede pasar.
                Expanded(
                  child: Text('Incluir cuotas próximas ($diasProx días)',
                      style: const TextStyle(fontSize: TxtResumen.cifraSub)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            async.when(
              data: (filas) {
                // El provider ya descartó a quien no tiene NADA por delante;
                // acá se descarta además a quien no tiene nada en la pata que
                // el switch está mirando, y se reordena por ESA pata: con el
                // switch apagado, el que más debe cobrar hoy puede no ser el
                // que más debe cobrar en la semana.
                final visibles = filas.where((p) => cuotasDe(p) > 0).toList()
                  ..sort((a, b) => montoDe(b).compareTo(montoDe(a)));
                if (visibles.isEmpty) {
                  return Text(
                    _incluirProximas
                        ? 'Nada por cobrar en el rango'
                        : 'Nada vence hoy',
                    style: TextStyle(
                        fontSize: TxtResumen.cifra, color: scheme.outline),
                  );
                }
                // La barra se mide contra el MÁXIMO, no contra el total: así el
                // primero llena la fila y el resto se lee como "la mitad que
                // él". Contra el total, con seis cobradores parejos, todas
                // quedarían cortitas e indistinguibles.
                final maxMonto = visibles
                    .map((p) => montoDe(p).toDouble())
                    .reduce((a, b) => a > b ? a : b);
                final total = visibles.fold<num>(0, (a, p) => a + montoDe(p));
                return Column(
                  children: [
                    ...visibles.map((p) {
                      final m = montoDe(p).toDouble();
                      final pct = maxMonto > 0 ? m / maxMonto : 0.0;
                      final esSin = p.sinCobrador;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    // Cartera real, pero sin nadie que la esté
                                    // trabajando: se nombra entera y en gris
                                    // para que se note que es una excepción.
                                    esSin ? 'Sin cobrador asignado' : p.nombre,
                                    style: TextStyle(
                                        fontSize: TxtResumen.cifra,
                                        color: esSin ? scheme.outline : null),
                                  ),
                                ),
                                // Separación mínima: sin ella un nombre largo
                                // queda pegado al conteo y se leen como una
                                // sola palabra.
                                const SizedBox(width: 8),
                                Text('${cuotasDe(p)} cuotas',
                                    style: TextStyle(
                                        fontSize: TxtResumen.apoyo,
                                        color: scheme.outline)),
                                const SizedBox(width: 8),
                                Text(Fmt.cordobas(montoDe(p)),
                                    style: const TextStyle(
                                        fontSize: TxtResumen.cifra,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: pct,
                                minHeight: 6,
                                backgroundColor: scheme.surfaceContainerHighest,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const Divider(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Total esperado',
                              style: TextStyle(
                                  fontSize: TxtResumen.cifra,
                                  color: scheme.onSurfaceVariant)),
                        ),
                        const SizedBox(width: 8),
                        // El único número que el dueño se lleva de memoria al
                        // cerrar la tarjeta: va en el rol de total.
                        Text(Fmt.cordobas(total),
                            style: const TextStyle(
                                fontSize: TxtResumen.grande,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],
                );
              },
              // Sin spinner: la tarjeta resuelve en un parpadeo contra el
              // SQLite local y un indicador que aparece y desaparece salta más
              // que el hueco.
              loading: () => const SizedBox.shrink(),
              error: (_, __) => Text('No se pudo calcular',
                  style: TextStyle(
                      fontSize: TxtResumen.cifra, color: scheme.error)),
            ),
          ],
        ),
      ),
    );
  }
}
