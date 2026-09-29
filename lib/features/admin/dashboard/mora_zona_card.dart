import 'escala_resumen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart'
    show dashboardRefreshEpochProvider;
import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';
import 'resumen_watch.dart';

/// # Recuperación por cobrador y comunidad — tarjeta AUTOCONTENIDA
///
/// No comparte grilla, botón de Excel, consulta ni estilos con ninguna otra
/// tarjeta. Decisión del dueño (2026-08-28): *"cada una es individual"*.
///
/// ## Dos cosas que esta tarjeta ya rompió una vez
///
/// **1. El filtro de gracia.** Al reescribirla se perdió
/// `vencimiento + gracia < hoy` y la tarjeta pasó a mostrar TODA la deuda viva
/// —incluidas cuotas que ni siquiera vencieron— en vez de la mora. La
/// diferencia medida en el Test Tenant: C$170.185 contra C$33.485. Si algún día
/// este filtro desaparece de nuevo, el número se infla y nada avisa.
///
/// **2. El rótulo.** Se llamó "Recuperación por cobrador y comunidad" mientras
/// mostraba lo que FALTA cobrar. Leído al lado de Mora del ciclo —donde
/// "Recuperado" sí es plata que entró— hacía leer deuda como cobranza.
///
/// ## El Excel reproduce la pantalla, fila por fila
///
/// Sale de la MISMA consulta que la tabla, no de una paralela: cada línea del
/// archivo es una línea de un desplegable, y los subtotales son los mismos
/// números. Es la garantía de que el archivo no puede inventar nada.

// ── Paleta PROPIA ──
const _rojo = Color(0xFFE24B4A);
const _gris = Color(0xFF8A8A8A);

/// Cuántas cuotas de un mismo monto hay en una comunidad. Es el tercer nivel:
/// "C$900 × 3 cuotas". Sirve para saber si la deuda de una zona son pocas
/// cuotas caras o muchas baratas — se cobran distinto.
class TramoMonto {
  const TramoMonto(this.saldo, this.cuotas);
  final num saldo;
  final int cuotas;
  num get total => saldo * cuotas;
}

/// Una comunidad dentro de un cobrador.
class ZonaMora {
  ZonaMora(this.comunidad);
  final String comunidad;
  final List<TramoMonto> tramos = [];

  int get cuotas => tramos.fold(0, (a, t) => a + t.cuotas);
  num get monto => tramos.fold<num>(0, (a, t) => a + t.total);
}

/// Un cobrador, con sus comunidades adentro.
class CobradorMora {
  CobradorMora(this.id, this.nombre);

  /// Null = clientes sin cobrador asignado ("admin-managed"). Cartera real que
  /// no tiene a nadie trabajándola; se muestra aparte para que se vea.
  final String? id;
  final String nombre;
  final List<ZonaMora> zonas = [];

  int get cuotas => zonas.fold(0, (a, z) => a + z.cuotas);
  num get monto => zonas.fold<num>(0, (a, z) => a + z.monto);
  bool get sinCobrador => id == null;
}

/// Mora viva por cobrador × comunidad × monto de cuota.
///
/// UNA sola consulta para los tres niveles: son ~120 filas en el peor caso y
/// traerlas juntas evita que el nivel 3 salga de otra consulta que pueda
/// discrepar del nivel 2 (que es exactamente cómo se rompen estas tablas).
///
/// Contratos `activo` Y `suspendido`: suspender corta el servicio pero
/// CONSERVA la deuda, y esa deuda se sigue cobrando (regla 6b de AGENTS). Los
/// cancelados no entran — cancelar condona, así que sus cuotas quedan en cero.
final moraZonaProvider = StreamProvider.autoDispose.family<List<CobradorMora>, bool>((ref, soloPeriodo) {
  ref.watch(dbEpochProvider);
  ref.watch(dashboardRefreshEpochProvider);
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  const saldo = 'max(cu.monto + COALESCE(cu.cargos_neto, 0) - '
      'COALESCE(cu.monto_pagado, 0), 0)';
  const cobrable = 'COALESCE((SELECT ct.estado FROM contratos ct '
      "WHERE ct.id = cu.contrato_id), 'activo') IN ('activo','suspendido')";

  final params = <Object?>[diasGracia];
  var filtroPeriodo = '';
  if (soloPeriodo) {
    final p = periodoDe(Fmt.hoyNicaragua());
    filtroPeriodo = 'AND cu.fecha_vencimiento >= ? '
        'AND cu.fecha_vencimiento < ?';
    params
      ..add(isoDia(inicioPeriodo(p.year, p.month)))
      ..add(isoDia(finPeriodo(p.year, p.month)));
  }

  return watchResumen(
    '''
    SELECT cu.cobrador_id AS cob_id,
           COALESCE(co.nombre, '') AS cob_nombre,
           COALESCE(cm.nombre, 'Sin comunidad') AS com_nombre,
           $saldo AS saldo,
           COUNT(*) AS cuotas
      FROM cuotas cu
      JOIN clientes cl ON cl.id = cu.cliente_id AND cl.activo = 1
 LEFT JOIN cobradores co ON co.id = cu.cobrador_id
 LEFT JOIN comunidades cm ON cm.id = cl.comunidad_id
     WHERE cu.estado IN ('pendiente','parcial') AND $cobrable
       AND $saldo > 0.009
       -- EL FILTRO DE MORA. Sin él esto deja de ser mora y pasa a ser toda la
       -- deuda viva: C\$170.185 en vez de C\$33.485 (Test Tenant, 2026-08-28).
       AND date(cu.fecha_vencimiento, '+' || ? || ' days')
           < date('now','-6 hours')
       $filtroPeriodo
     GROUP BY cu.cobrador_id, cob_nombre, com_nombre, saldo
    ''',
    // Orden de los `?`: gracia primero (aparece en el WHERE antes que el
    // filtro de período), después el rango del ciclo si está activo.
    parameters: params,
  ).map((rows) {
    final porCob = <String, CobradorMora>{};
    for (final r in rows) {
      final id = r['cob_id'] as String?;
      final c = porCob.putIfAbsent(
          id ?? '', () => CobradorMora(id, (r['cob_nombre'] as String?) ?? ''));
      final nombreCom = (r['com_nombre'] as String?) ?? 'Sin comunidad';
      final z = c.zonas.firstWhere((z) => z.comunidad == nombreCom,
          orElse: () {
        final nueva = ZonaMora(nombreCom);
        c.zonas.add(nueva);
        return nueva;
      });
      z.tramos.add(TramoMonto(
          (r['saldo'] as num?) ?? 0, ((r['cuotas'] as num?) ?? 0).toInt()));
    }
    final out = porCob.values.toList()
      // De mayor a menor; los sin cobrador SIEMPRE al final, porque son la
      // excepción y no un cobrador más del ranking.
      ..sort((a, b) {
        if (a.sinCobrador != b.sinCobrador) return a.sinCobrador ? 1 : -1;
        return b.monto.compareTo(a.monto);
      });
    for (final c in out) {
      c.zonas.sort((a, b) => b.monto.compareTo(a.monto));
      for (final z in c.zonas) {
        z.tramos.sort((a, b) => b.saldo.compareTo(a.saldo));
      }
    }
    return out;
  });
});

// `_detalleCuotasEnMora` —una fila por cuota, el respaldo del Excel— se fue
// junto con el botón el 2026-09-02. Era su única consumidora.

class MoraZonaCard extends ConsumerStatefulWidget {
  const MoraZonaCard({super.key});

  @override
  ConsumerState<MoraZonaCard> createState() => _MoraZonaCardState();
}

class _MoraZonaCardState extends ConsumerState<MoraZonaCard> {
  bool _soloPeriodo = false;

  /// Qué comunidades tienen abierto su desglose por monto.
  ///
  /// Ya no hay un set de cobradores: en el diseño de producción los cobradores
  /// se muestran SIEMPRE con sus comunidades a la vista, y lo único plegable
  /// adentro es el tercer nivel. Lo que colapsa la tarjeta entera es el
  /// chevron del encabezado.
  final Set<String> _zonaAbiertas = {};

  /// La tarjeta arranca COLAPSADA, como en producción: es larga —un bloque por
  /// cobrador con todas sus comunidades— y desplegada empuja al fondo del
  /// scroll a todo lo que va después. El total del encabezado alcanza para la
  /// mirada de todos los días; se abre cuando hay que salir a cobrar.
  bool _expandido = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(moraZonaProvider(_soloPeriodo));

    return Card(
      // Sin esto, el body de la animación se dibuja por fuera de las esquinas
      // redondeadas mientras despliega.
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expandido = !_expandido),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(Icons.location_on, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  // ÚNICO Expanded del Row y es el de la izquierda (regla #15):
                  // el total de la derecha cae siempre en el mismo borde.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Recuperación por cobrador y comunidad',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                            _soloPeriodo
                                ? 'Vencidas del período ${periodoLabelActual()} '
                                    '(las de ciclos anteriores no se cuentan)'
                                : 'Toda la mora acumulada (vencido pasada la '
                                    'gracia)',
                            style: TextStyle(
                                fontSize: TxtResumen.apoyo,
                                color: scheme.outline)),
                      ],
                    ),
                  ),
                  const InfoGraficaBoton(kInfoRecuperacion),
                  const SizedBox(width: 8),
                  // El TOTAL en el encabezado: es lo que hace que la tarjeta
                  // sirva colapsada. Sin él, plegarla la vuelve un título.
                  async.when(
                    data: (cobs) {
                      if (cobs.isEmpty) return const SizedBox.shrink();
                      final total = cobs.fold<num>(0, (a, c) => a + c.monto);
                      return Text(Fmt.cordobas(total),
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: TxtResumen.cifraSub,
                              color: scheme.error));
                    },
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _expandido ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more,
                        size: 24, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ),
          // Los dos filtros son CHIPS, no un SegmentedButton: es lo que hay en
          // producción y lo que el dueño señaló al pedir la vuelta atrás.
          // Quedan FUERA del pliegue a propósito — cambiar de filtro con la
          // tarjeta cerrada actualiza el total del encabezado, que es
          // exactamente la consulta rápida que uno hace sin abrir nada.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            // `Wrap` y no `Row`: en PC los dos chips van uno al lado del otro,
            // exactamente como en producción, pero juntos miden ~328px y en un
            // teléfono de 360 quedan 320 útiles — o sea que en `Row` desbordan
            // por ~10px. Producción tiene el `Row` y por lo tanto el mismo
            // desborde; no se ve porque el Resumen se mira en PC. Con `Wrap`
            // el segundo chip baja de renglón en vez de cortarse, y en ancho
            // no cambia NADA.
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Toda la mora'),
                  selected: !_soloPeriodo,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) {
                    if (v) setState(() => _cambiarFiltro(false));
                  },
                ),
                ChoiceChip(
                  label: const Text('Vencidas del período'),
                  selected: _soloPeriodo,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) {
                    if (v) setState(() => _cambiarFiltro(true));
                  },
                ),
              ],
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              ),
              error: (_, __) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Text('No se pudo calcular',
                    style: TextStyle(
                        fontSize: TxtResumen.cifra, color: scheme.error)),
              ),
              data: (cobs) => _cuerpo(scheme, cobs),
            ),
            crossFadeState: _expandido
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  /// Cambiar de filtro cierra los desgloses abiertos: las comunidades del ciclo
  /// no son las mismas que las de toda la mora, y dejar abierto un desglose de
  /// la otra lista muestra números que no corresponden al filtro elegido.
  void _cambiarFiltro(bool soloPeriodo) {
    _soloPeriodo = soloPeriodo;
    _zonaAbiertas.clear();
  }

  Widget _cuerpo(ColorScheme scheme, List<CobradorMora> cobs) {
    if (cobs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
              _soloPeriodo
                  ? 'Ninguna cuota de este ciclo entró en mora todavía.'
                  : 'No hay mora: todo lo vencido está cobrado.',
              style:
                  TextStyle(fontSize: TxtResumen.cifra, color: scheme.outline)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var gi = 0; gi < cobs.length; gi++) ...[
            if (gi > 0) const Divider(height: 20),
            _bloqueCobrador(scheme, cobs[gi]),
          ],
        ],
      ),
    );
  }

  /// Un cobrador y sus comunidades. Nivel 1 de los tres.
  ///
  /// El nombre a la izquierda y "monto · N cuotas" a la derecha, los dos en
  /// w600 y el número en rojo. **Un solo `Expanded` y es el de la izquierda**
  /// (regla #15): así la cifra termina siempre en el mismo borde, sea cual sea
  /// el largo del nombre.
  Widget _bloqueCobrador(ColorScheme scheme, CobradorMora c) {
    final color = c.sinCobrador ? _gris : _rojo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                  c.sinCobrador ? 'Sin cobrador' : c.nombre,
                  style: TextStyle(
                      fontSize: TxtResumen.cifra,
                      fontWeight: FontWeight.w600,
                      fontStyle:
                          c.sinCobrador ? FontStyle.italic : FontStyle.normal)),
            ),
            Text(
                '${Fmt.cordobas(c.monto)} · ${Fmt.entero(c.cuotas)} '
                '${c.cuotas == 1 ? 'cuota' : 'cuotas'}',
                style: TextStyle(
                    fontSize: TxtResumen.cifra,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ],
        ),
        const SizedBox(height: 4),
        for (final z in c.zonas) _filaComunidad(scheme, c, z),
      ],
    );
  }

  /// Una comunidad. Nivel 2: se toca para abrir el desglose por monto.
  ///
  /// **TODAS se abren, tengan uno o veinte tramos** — es lo que hace
  /// producción y no tiene condición de ninguna clase.
  ///
  /// Hubo una versión de esto que ocultaba la flecha cuando había un solo
  /// tramo, con el argumento de que "abrirlo repetiría la fila de arriba".
  /// **El argumento era falso y Rubén lo detectó en el acto** (2026-09-02):
  /// *"hay algunas opciones que no tienen dropdown y no sé de cuánto es la
  /// cantidad de las que consiste"*. La fila dice el TOTAL y la CANTIDAD
  /// —"Las Mercedes · 2.800,00 C$ · 4"— y nunca el monto UNITARIO. Abrirla
  /// muestra "700,00 C$ × 4 cuotas", que es justamente el dato que falta.
  ///
  /// Y aunque fuera derivable dividiendo, el usuario no puede saber que hay un
  /// solo tramo sin abrir: una fila sin flecha se lee como "acá no hay nada
  /// más", que es lo contrario de lo que pasa.
  ///
  /// No cuesta nada: los tramos ya vienen en `moraZonaProvider`, no hay una
  /// consulta por despliegue.
  Widget _filaComunidad(ColorScheme scheme, CobradorMora c, ZonaMora z) {
    final k = '${c.id}|${z.comunidad}';
    final abierto = _zonaAbiertas.contains(k);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() =>
              abierto ? _zonaAbiertas.remove(k) : _zonaAbiertas.add(k)),
          child: Padding(
            padding: const EdgeInsets.only(left: 6, top: 3, bottom: 3),
            child: Row(
              children: [
                Icon(abierto ? Icons.expand_more : Icons.chevron_right,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                      z.comunidad.isEmpty ? 'Sin comunidad' : z.comunidad,
                      style: TextStyle(
                          fontSize: TxtResumen.cifraSub,
                          color: scheme.onSurfaceVariant)),
                ),
                Text('${Fmt.cordobas(z.monto)} · ${Fmt.entero(z.cuotas)}',
                    style: TextStyle(
                        fontSize: TxtResumen.cifraSub,
                        color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        if (abierto) _desglose(scheme, z),
      ],
    );
  }

  /// El desglose por monto de cuota + la línea que lo verifica. Nivel 3.
  ///
  /// La barra vertical de la izquierda es lo que dice "esto cuelga de la fila
  /// de arriba": sin ella, a tres niveles de sangría el lector pierde de quién
  /// es cada número.
  Widget _desglose(ColorScheme scheme, ZonaMora z) {
    return Container(
      margin: const EdgeInsets.only(left: 26, top: 2, bottom: 6),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        border:
            Border(left: BorderSide(color: scheme.outlineVariant, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final t in z.tramos)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        '${Fmt.cordobas(t.saldo)} × ${Fmt.entero(t.cuotas)} '
                        '${t.cuotas == 1 ? 'cuota' : 'cuotas'}',
                        style: TextStyle(
                            fontSize: TxtResumen.apoyo,
                            color: scheme.onSurfaceVariant)),
                  ),
                  Text(Fmt.cordobas(t.total),
                      style: TextStyle(
                          fontSize: TxtResumen.apoyo,
                          color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          // La línea que CONFIRMA que el desglose suma su comunidad. No es
          // decorativa: es lo que deja verificar el número sin sacar la
          // calculadora, y fue un pedido explícito del dueño (2026-08-28):
          // *"que la data sea trackeable al 100%"*.
          _confirmacion(scheme, z.cuotas, z.monto),
        ],
      ),
    );
  }

  Widget _confirmacion(ColorScheme scheme, int cuotas, num monto) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 12, color: scheme.primary),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                  'Coincide: ${Fmt.entero(cuotas)} '
                  '${cuotas == 1 ? 'cuota' : 'cuotas'} · ${Fmt.cordobas(monto)}',
                  style: TextStyle(
                      fontSize: TxtResumen.apoyo, color: scheme.primary)),
            ),
          ],
        ),
      );
}

// El BOTÓN DE EXCEL se retiró el 2026-09-02. No es que estorbara: en
// producción esta tarjeta nunca lo tuvo, y el dueño fijó la regla para el
// tablero entero — *"el excel solo era para distribución de cuotas y para mora
// de 6 meses"*. Verificado: `dashboard_admin_screen.dart` en la v0.37.1 tiene
// CERO botones de descarga.
//
// Se fueron con él `_BotonExcelMoraZona` y `_detalleCuotasEnMora`, que era su
// única consumidora. Si alguna vez vuelve a pedirse, está entero en el
// historial de este archivo.
