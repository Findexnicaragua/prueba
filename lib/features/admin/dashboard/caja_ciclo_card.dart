import 'escala_resumen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart'
    show diaNicaraguaProvider, dashboardRefreshEpochProvider;
import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';
import 'resumen_watch.dart';

/// # Caja del ciclo — tarjeta AUTOCONTENIDA
///
/// No comparte grilla, consulta ni estilos con ninguna otra. Decisión del dueño
/// (2026-08-28): *"cada una es individual"*.
///
/// Cada uno de los tres bloques —día, semana, período— tiene **su propio
/// retroceso**: se puede mirar el martes pasado, la semana antepasada y el
/// ciclo de hace tres meses al mismo tiempo. Pedido del dueño el 2026-08-28.
///
/// **Sin Excel, a propósito** (también pedido): es una tarjeta de lectura
/// rápida; el detalle exportable vive en las otras.

// ── Paleta PROPIA ──
const _azul = Color(0xFF185FA5);

/// Cuántas opciones hacia atrás ofrece cada bloque.
const _kDias = 7, _kSemanas = 6, _kPeriodos = 6;

/// Cuál de los tres bloques manda sobre el desglose de abajo.
enum BloqueCaja { dia, semana, periodo }

/// Una ventana concreta de tiempo, ya resuelta a fechas.
///
/// Las fechas se calculan en DART y viajan como parámetros. Antes los cortes
/// estaban escritos en el SQL (`date('now','-6 hours')` y compañía), que sirve
/// para "hoy" pero no deja retroceder. Con las fechas afuera, el mismo SQL
/// responde por cualquier ventana y no hay dos formas de calcular un límite de
/// día — que es justo donde se cuela un desfase.
class VentanaCaja {
  const VentanaCaja({
    required this.desde,
    required this.hasta,
    required this.etiqueta,
    required this.rango,
    required this.cicloRef,
  });

  /// Inclusive.
  final DateTime desde;

  /// EXCLUSIVE.
  final DateTime hasta;

  /// Lo que dice el encabezado del bloque: "Hoy", "Semana pasada", "15 jul –
  /// 14 ago".
  final String etiqueta;

  /// Las fechas, para el pie del bloque.
  final String rango;

  /// Si la ventana es EXACTAMENTE un ciclo (el bloque de período), y no un día
  /// o una semana sueltos.
  ///
  /// Sólo entonces tiene sentido el puente con Cobertura: comparar lo cobrado
  /// en un martes contra el "Recuperado" de un ciclo entero no cierra ninguna
  /// cuenta.
  bool get esCicloCompleto => desde == cicloRef && hasta == finDeCiclo;

  /// El fin del ciclo de referencia, para [esCicloCompleto].
  DateTime get finDeCiclo =>
      DateTime(cicloRef.year, cicloRef.month + 1, cicloRef.day);

  /// El ciclo contra el que se clasifica el desglose (del ciclo / atrasos /
  /// adelantos).
  ///
  /// **Es el ciclo que contiene el INICIO de la ventana, no el ciclo actual.**
  /// Sin esto, al elegir "15 jun – 14 jul" el desglose seguiría comparando
  /// contra el ciclo en curso y esas cuotas aparecerían todas como "atrasos"
  /// — que es exactamente el tipo de número que después nadie puede explicar.
  final DateTime cicloRef;
}

/// El domingo de la semana de [d]. `DateTime.weekday` da lunes=1…domingo=7, así
/// que `% 7` manda el domingo a 0 y la semana arranca ahí — el mismo criterio
/// que usaba el SQL viejo con `strftime('%w')`.
DateTime _domingoDe(DateTime d) =>
    DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday % 7));

String _dm(DateTime d) => '${d.day} ${mesCortoPeriodo(d.month)}';

/// Las opciones de un bloque, de la más reciente a la más vieja.
List<VentanaCaja> opcionesDe(BloqueCaja b, DateTime hoy) {
  final h = DateTime(hoy.year, hoy.month, hoy.day);
  switch (b) {
    case BloqueCaja.dia:
      return [
        for (var i = 0; i < _kDias; i++)
          () {
            final d = h.subtract(Duration(days: i));
            final p = periodoDe(d);
            return VentanaCaja(
              desde: d,
              hasta: d.add(const Duration(days: 1)),
              etiqueta: i == 0 ? 'Hoy' : (i == 1 ? 'Ayer' : _dm(d)),
              rango: _dm(d),
              cicloRef: inicioPeriodo(p.year, p.month),
            );
          }(),
      ];
    case BloqueCaja.semana:
      final dom = _domingoDe(h);
      return [
        for (var i = 0; i < _kSemanas; i++)
          () {
            final d = dom.subtract(Duration(days: 7 * i));
            final f = d.add(const Duration(days: 7));
            final p = periodoDe(d);
            return VentanaCaja(
              desde: d,
              hasta: f,
              etiqueta: i == 0
                  ? 'Esta semana'
                  : (i == 1
                      ? 'Semana pasada'
                      : '${_dm(d)} – ${_dm(f.subtract(const Duration(days: 1)))}'),
              rango:
                  '${_dm(d)} – ${_dm(f.subtract(const Duration(days: 1)))}',
              cicloRef: inicioPeriodo(p.year, p.month),
            );
          }(),
      ];
    case BloqueCaja.periodo:
      final p = periodoDe(h);
      return [
        for (var i = 0; i < _kPeriodos; i++)
          () {
            final ini = inicioPeriodo(p.year, p.month - i);
            final fin = finPeriodo(p.year, p.month - i);
            return VentanaCaja(
              desde: ini,
              hasta: fin,
              etiqueta: i == 0
                  ? 'Este período'
                  : (i == 1
                      ? 'Período anterior'
                      : periodoLabel(p.year, p.month - i)),
              rango: periodoLabel(p.year, p.month - i),
              cicloRef: ini,
            );
          }(),
      ];
  }
}

/// Lo que entró en una ventana: plata y cuántas CUOTAS la recibieron.
class CajaVentana {
  const CajaVentana(this.monto, this.cuotas);
  final num monto;
  final int cuotas;
}

typedef _RangoArgs = ({String desde, String hasta});

/// Total cobrado en un rango.
///
/// Cuenta **cuotas distintas**, no filas de `pagos`: dos abonos a la misma
/// cuota son un cobro para el negocio, y contar filas decía 2 donde el dueño
/// esperaba 1.
final cajaVentanaProvider = StreamProvider.autoDispose.family<CajaVentana, _RangoArgs>((ref, r) {
  ref.watch(dbEpochProvider);
  // "Hoy" y "esta semana" se mueven a medianoche aunque no entre ningún pago.
  ref.watch(diaNicaraguaProvider);
  ref.watch(dashboardRefreshEpochProvider);
  return watchResumen(
    '''
    SELECT COALESCE(SUM(p.monto_cordobas), 0) AS monto,
           COUNT(DISTINCT p.cuota_id) AS cuotas
      FROM pagos p
     WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
       AND p.fecha_cobro >= ? AND p.fecha_cobro < ?
    ''',
    parameters: [r.desde, r.hasta],
  ).map((rows) => rows.isEmpty
      ? const CajaVentana(0, 0)
      : CajaVentana(
          (rows.first['monto'] as num?) ?? 0,
          ((rows.first['cuotas'] as num?) ?? 0).toInt()));
});

/// De qué cuotas era la plata que entró en la ventana.
class DesgloseVentana {
  const DesgloseVentana({
    required this.total,
    required this.delCiclo,
    required this.atrasos,
    required this.adelantos,
    required this.sinCuota,
    required this.pagadoAntes,
  });
  final num total, delCiclo, atrasos, adelantos, sinCuota;

  /// Plata de cuotas de ESTE ciclo que se cobró ANTES de que el ciclo abriera
  /// (pagos adelantados). Queda FUERA de la ventana a propósito: es la pieza
  /// que falta para llegar al "Recuperado" de Cobertura del ciclo.
  ///
  /// `delCiclo + pagadoAntes` = lo cobrado del ciclo según Cobertura. Sin esta
  /// cifra las dos tarjetas muestran números distintos del mismo ciclo y no hay
  /// forma de explicar la diferencia.
  final num pagadoAntes;
}

typedef _DesgloseArgs = ({String desde, String hasta, String ciclo});

/// Clasifica lo cobrado según a qué ciclo pertenecía la CUOTA.
///
/// El ciclo de referencia lo manda el widget ([VentanaCaja.cicloRef]) y es el
/// de la ventana elegida, NO el actual: mirando "15 jun – 14 jul", sus propias
/// cuotas tienen que salir como "del ciclo" y no como atrasos.
final desgloseVentanaProvider = StreamProvider.autoDispose.family<DesgloseVentana, _DesgloseArgs>((ref, a) {
  ref.watch(dbEpochProvider);
  ref.watch(diaNicaraguaProvider);
  ref.watch(dashboardRefreshEpochProvider);
  return watchResumen(
    '''
    SELECT
      COALESCE(SUM(p.monto_cordobas), 0) AS total,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento >= ?
                         AND cu.fecha_vencimiento < date(?, '+1 month')
                        THEN p.monto_cordobas ELSE 0 END), 0) AS del_ciclo,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento < ?
                        THEN p.monto_cordobas ELSE 0 END), 0) AS atrasos,
      COALESCE(SUM(CASE WHEN cu.fecha_vencimiento >= date(?, '+1 month')
                        THEN p.monto_cordobas ELSE 0 END), 0) AS adelantos,
      -- Un cobro puntual no cuelga de ninguna cuota: no es del ciclo ni
      -- atraso ni adelanto, y sin esta fila el desglose no sumaría el total.
      COALESCE(SUM(CASE WHEN cu.id IS NULL
                        THEN p.monto_cordobas ELSE 0 END), 0) AS sin_cuota,
      -- FUERA del WHERE de abajo a propósito: son pagos ANTERIORES a la
      -- ventana. Es lo que cierra el puente con Cobertura del ciclo.
      COALESCE((SELECT SUM(p2.monto_cordobas) FROM pagos p2
                  JOIN cuotas cu2 ON cu2.id = p2.cuota_id
                 WHERE COALESCE(p2.anulado, 0) = 0
                   AND COALESCE(p2.en_revision, 0) = 0
                   AND cu2.estado != 'anulada'
                   AND cu2.fecha_vencimiento >= ?
                   AND cu2.fecha_vencimiento < date(?, '+1 month')
                   AND p2.fecha_cobro < ?), 0) AS pagado_antes
      FROM pagos p
 LEFT JOIN cuotas cu ON cu.id = p.cuota_id
     WHERE COALESCE(p.anulado, 0) = 0 AND COALESCE(p.en_revision, 0) = 0
       AND p.fecha_cobro >= ? AND p.fecha_cobro < ?
    ''',
    parameters: [
      a.ciclo, a.ciclo, // del_ciclo
      a.ciclo, // atrasos
      a.ciclo, // adelantos
      a.ciclo, a.ciclo, a.ciclo, // pagado_antes
      a.desde, a.hasta, // la ventana
    ],
  ).map((rows) {
    num v(String k) =>
        rows.isEmpty ? 0 : ((rows.first[k] as num?) ?? 0);
    return DesgloseVentana(
      total: v('total'),
      delCiclo: v('del_ciclo'),
      atrasos: v('atrasos'),
      adelantos: v('adelantos'),
      sinCuota: v('sin_cuota'),
      pagadoAntes: v('pagado_antes'),
    );
  });
});

class CajaCicloCard extends ConsumerStatefulWidget {
  const CajaCicloCard({super.key});

  @override
  ConsumerState<CajaCicloCard> createState() => _CajaCicloCardState();
}

class _CajaCicloCardState extends ConsumerState<CajaCicloCard> {
  /// Qué opción tiene elegida cada bloque (0 = la más reciente).
  final Map<BloqueCaja, int> _sel = {
    BloqueCaja.dia: 0,
    BloqueCaja.semana: 0,
    BloqueCaja.periodo: 0,
  };

  /// Cuál manda sobre el desglose de abajo.
  BloqueCaja _activo = BloqueCaja.periodo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Redibuja a medianoche: "Hoy" pasa a ser otro día aunque no entre un pago.
    ref.watch(diaNicaraguaProvider);
    final hoy = Fmt.hoyNicaragua();

    final ventanas = {
      for (final b in BloqueCaja.values)
        b: opcionesDe(b, hoy)[_sel[b]!.clamp(0, opcionesDe(b, hoy).length - 1)]
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.account_balance_wallet_outlined,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Caja del ciclo',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const InfoGraficaBoton(kInfoCobrosKpis),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text(
                  'La plata que entró. Cada bloque se puede mover a un día, '
                  'una semana o un ciclo anteriores',
                  style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, cons) {
                final bloques = [
                  for (final b in BloqueCaja.values)
                    _Bloque(
                      // Clave estable para que los tests puedan mirar UN bloque
                      // en vez de toda la pantalla: "2 cobros" puede ser
                      // legítimo en semana y un error en día.
                      key: ValueKey('caja-bloque-${b.name}'),
                      titulo: switch (b) {
                        BloqueCaja.dia => 'Día',
                        BloqueCaja.semana => 'Semana',
                        BloqueCaja.periodo => 'Período',
                      },
                      icono: switch (b) {
                        BloqueCaja.dia => Icons.today_outlined,
                        BloqueCaja.semana => Icons.date_range_outlined,
                        BloqueCaja.periodo => Icons.calendar_month_outlined,
                      },
                      ventana: ventanas[b]!,
                      opciones: opcionesDe(b, hoy),
                      seleccion: _sel[b]!,
                      activo: _activo == b,
                      onElegir: (i) => setState(() {
                        _sel[b] = i;
                        // Elegir una ventana la vuelve la activa: si no, se
                        // cambia el bloque y el desglose de abajo sigue
                        // hablando de otro — que es peor que no moverlo.
                        _activo = b;
                      }),
                      onActivar: () => setState(() => _activo = b),
                    ),
                ];
                // En pantalla angosta van apilados: tres tarjetas de 120px de
                // ancho no dejan leer ni el monto.
                if (cons.maxWidth < 620) {
                  return Column(
                    // `stretch`: apilados, cada tarjeta tomaba el ancho de SU
                    // texto y las tres quedaban de largos distintos, escalonadas
                    // (se veia clarito en el telefono, 2026-08-29). Acá el eje
                    // cruzado es horizontal y la Column SÍ tiene cota, así que
                    // el stretch no pide infinito — no es el caso de la regla
                    // #11, que habla del stretch en un Row dentro de un scroll.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < bloques.length; i++) ...[
                        if (i > 0) const SizedBox(height: 10),
                        bloques[i],
                      ],
                    ],
                  );
                }
                // `IntrinsicHeight` OBLIGATORIO (regla #11 del checklist de
                // audit): un `Row` con `crossAxisAlignment.stretch` adentro de
                // un scroll reclama altura INFINITA —el eje cruzado es vertical
                // y el scroll no le pone cota— y tira el layout de la pantalla
                // entera. Con `IntrinsicHeight` la altura es la del bloque más
                // alto y el stretch iguala los tres, que es lo que se quiere:
                // las tres tarjetas parejas aunque una tenga el rótulo largo.
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < bloques.length; i++) ...[
                        if (i > 0) const SizedBox(width: 12),
                        Expanded(child: bloques[i]),
                      ],
                    ],
                  ),
                );
              },
            ),
            _Desglose(ventana: ventanas[_activo]!),
            _Puente(ventana: ventanas[_activo]!),
          ],
        ),
      ),
    );
  }
}

/// Un bloque: su monto, su ventana y el menú para retroceder.
class _Bloque extends ConsumerWidget {
  const _Bloque({
    super.key,
    required this.titulo,
    required this.icono,
    required this.ventana,
    required this.opciones,
    required this.seleccion,
    required this.activo,
    required this.onElegir,
    required this.onActivar,
  });

  final String titulo;
  final IconData icono;
  final VentanaCaja ventana;
  final List<VentanaCaja> opciones;
  final int seleccion;
  final bool activo;
  final void Function(int) onElegir;
  final VoidCallback onActivar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(cajaVentanaProvider(
        (desde: isoDia(ventana.desde), hasta: isoDia(ventana.hasta))));
    final fg = activo ? scheme.onPrimary : scheme.onSurface;
    final fgTenue = activo
        ? scheme.onPrimary.withValues(alpha: 0.85)
        : scheme.outline;

    return InkWell(
      onTap: onActivar,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 11, 10, 13),
        decoration: BoxDecoration(
          color: activo ? _azul : Colors.transparent,
          border: Border.all(
              color: activo ? _azul : scheme.outlineVariant),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // El menú va en el ENCABEZADO y no sobre toda la tarjeta: tocar el
            // cuerpo elige qué bloque manda sobre el desglose, tocar el rótulo
            // cambia su ventana. Son dos acciones distintas y conviene que se
            // vean distintas.
            _MenuVentana(
              icono: icono,
              titulo: titulo,
              etiqueta: ventana.etiqueta,
              opciones: opciones,
              seleccion: seleccion,
              color: fgTenue,
              onElegir: onElegir,
            ),
            const SizedBox(height: 6),
            async.when(
              loading: () => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: fgTenue)),
              ),
              error: (_, __) => Text('—',
                  style: TextStyle(fontSize: TxtResumen.gigante, color: fg)),
              data: (c) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(Fmt.cordobas(c.monto),
                        style: TextStyle(
                            fontSize: TxtResumen.gigante,
                            fontWeight: FontWeight.w500,
                            color: fg)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                      '${c.cuotas} ${c.cuotas == 1 ? 'cobro' : 'cobros'} · '
                      '${ventana.rango}',
                      style: TextStyle(fontSize: TxtResumen.apoyo, color: fgTenue),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// El encabezado clickeable con el menú de ventanas.
///
/// Cada opción muestra SU MONTO al lado: se elige sabiendo qué se va a ver, en
/// vez de tener que abrir una por una para encontrar el día que tuvo cobros.
class _MenuVentana extends ConsumerWidget {
  const _MenuVentana({
    required this.icono,
    required this.titulo,
    required this.etiqueta,
    required this.opciones,
    required this.seleccion,
    required this.color,
    required this.onElegir,
  });

  final IconData icono;
  final String titulo, etiqueta;
  final List<VentanaCaja> opciones;
  final int seleccion;
  final Color color;
  final void Function(int) onElegir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<int>(
      tooltip: 'Cambiar la ventana de $titulo',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: onElegir,
      itemBuilder: (context) => [
        for (var i = 0; i < opciones.length; i++)
          PopupMenuItem(
            value: i,
            height: 38,
            child: _ItemVentana(
                ventana: opciones[i], elegida: i == seleccion),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(etiqueta,
                style: TextStyle(fontSize: TxtResumen.apoyo, color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 2),
          Icon(Icons.arrow_drop_down, size: 16, color: color),
        ],
      ),
    );
  }
}

class _ItemVentana extends ConsumerWidget {
  const _ItemVentana({required this.ventana, required this.elegida});
  final VentanaCaja ventana;
  final bool elegida;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(cajaVentanaProvider(
        (desde: isoDia(ventana.desde), hasta: isoDia(ventana.hasta))));
    return Row(
      children: [
        Expanded(
          child: Text(ventana.etiqueta,
              style: TextStyle(
                  fontSize: TxtResumen.cifra,
                  fontWeight: elegida ? FontWeight.w600 : FontWeight.normal,
                  color: elegida ? scheme.primary : null)),
        ),
        const SizedBox(width: 14),
        async.maybeWhen(
          data: (c) => Text(
              // Guion y no "0,00 C$": una lista de ceros se lee como error de
              // carga. El guion dice "no hubo cobros" sin gritar.
              c.monto <= 0 ? '—' : Fmt.cordobas(c.monto),
              style: TextStyle(
                  fontSize: TxtResumen.apoyo,
                  color: elegida ? scheme.primary : scheme.outline)),
          orElse: () => const SizedBox(width: 10),
        ),
      ],
    );
  }
}

/// **El desglose de la caja, como DESPLEGABLE** (repuesto 2026-08-31).
///
/// Historia corta, porque explica la forma: este bloque existió, el dueño lo
/// mandó sacar el 2026-08-29 —*"eso es totalmente innecesario"*— y lo volvió a
/// pedir el 31, al revisar que el Resumen nuevo no perdiera nada de lo que el
/// anterior mostraba.
///
/// **No vuelve igual: vuelve cerrado.** La objeción no era el dato sino el
/// lugar que ocupaba — cuatro números más en una tarjeta que se mira de un
/// vistazo. Detrás de un chevron, el que lo necesita lo abre y el que no ni lo
/// ve. Y el cuerpo no se construye hasta que se abre, así que su consulta
/// tampoco corre de más.
class _Desglose extends StatefulWidget {
  const _Desglose({required this.ventana});
  final VentanaCaja ventana;

  @override
  State<_Desglose> createState() => _DesgloseState();
}

class _DesgloseState extends State<_Desglose> {
  bool _abierto = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        InkWell(
          onTap: () => setState(() => _abierto = !_abierto),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
            child: Row(
              children: [
                Icon(_abierto ? Icons.expand_more : Icons.chevron_right,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                // `Expanded`, no un `Text` suelto: a 360 px el rótulo no entra
                // al lado del chevron y desbordaba 145 px. Lo cazó el test de
                // teléfono al reponer este bloque — que es exactamente para lo
                // que existe.
                Expanded(
                  child: Text('¿De qué cuotas era esta plata?',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: TxtResumen.cifra,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ),
        // El cuerpo NO se construye cerrado: sin esto su consulta correría
        // igual en cada ventana, para algo que nadie está mirando.
        if (_abierto) _DesgloseCuerpo(ventana: widget.ventana),
      ],
    );
  }
}

/// El cuerpo del desglose: de qué cuotas era la plata del bloque activo.
///
/// Vive detrás del desplegable [_Desglose] y no se dibuja hasta que alguien lo
/// abre — que es lo que resuelve la objeción original.
class _DesgloseCuerpo extends ConsumerWidget {
  const _DesgloseCuerpo({required this.ventana});
  final VentanaCaja ventana;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(desgloseVentanaProvider((
      desde: isoDia(ventana.desde),
      hasta: isoDia(ventana.hasta),
      ciclo: isoDia(ventana.cicloRef),
    )));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              '${ventana.rango} · clasificado contra el ciclo '
              '${periodoLabel(ventana.cicloRef.year, ventana.cicloRef.month + 1)}',
              style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
          const SizedBox(height: 9),
          async.when(
            loading: () => const SizedBox(
                height: 18,
                child: Center(
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)))),
            error: (_, __) => Text('No se pudo calcular',
                style: TextStyle(fontSize: TxtResumen.cifra, color: scheme.error)),
            data: (d) {
              if (d.total <= 0) {
                return Text('No entró plata en esta ventana.',
                    style: TextStyle(fontSize: TxtResumen.cifra, color: scheme.outline));
              }
              Widget linea(String txt, num monto, Color c,
                  {bool fuerte = false}) {
                final pct = (monto / d.total * 100).round();
                final st = TextStyle(
                    fontSize: TxtResumen.cifra,
                    fontWeight: fuerte ? FontWeight.w600 : FontWeight.normal);
                // PLANO a propósito: los tests localizan una fila con
                // `find.ancestor(..., byType(Row))` y toman el PRIMERO; un Row
                // anidado se lleva ese match.
                return Padding(
                  padding: EdgeInsets.only(
                      top: fuerte ? 0 : 2, bottom: 2),
                  child: Row(
                    children: [
                      Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                              color: c, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Expanded(child: Text(txt, style: st)),
                      Text(fuerte ? '' : '$pct%',
                          style: TextStyle(fontSize: TxtResumen.apoyo, color: c)),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 96,
                        child: Text(Fmt.cordobas(monto),
                            textAlign: TextAlign.right, style: st),
                      ),
                    ],
                  ),
                );
              }

              return Column(
                children: [
                  // La fila MADRE: el desglose de abajo tiene que sumarla. Sin
                  // ella hay cuatro números sueltos y nada que verificar.
                  linea('Total que entró', d.total, scheme.onSurface,
                      fuerte: true),
                  if (d.delCiclo > 0)
                    linea('Cuotas del ciclo', d.delCiclo,
                        const Color(0xFF1D9E75)),
                  if (d.atrasos > 0)
                    linea('Atrasos de ciclos anteriores', d.atrasos,
                        const Color(0xFFE24B4A)),
                  if (d.adelantos > 0)
                    linea('Adelantos de ciclos siguientes', d.adelantos,
                        const Color(0xFF185FA5)),
                  if (d.sinCuota > 0)
                    linea('Cobros puntuales (sin cuota)', d.sinCuota,
                        const Color(0xFFD98829)),
                  // EL PUENTE con Cobertura del ciclo. Sólo cuando la ventana
                  // es un ciclo completo: lo cobrado un martes no se compara
                  // con el "Recuperado" de un ciclo entero.
                  if (ventana.esCicloCompleto && d.pagadoAntes > 0) ...[
                    const SizedBox(height: 9),
                    Divider(height: 1, color: scheme.outlineVariant),
                    const SizedBox(height: 8),
                    Text(
                        'De este ciclo entraron ${Fmt.cordobas(d.delCiclo)} '
                        'ahora, y otros ${Fmt.cordobas(d.pagadoAntes)} ya se '
                        'habían cobrado antes. Juntos dan '
                        '${Fmt.cordobas(d.delCiclo + d.pagadoAntes)}, que es '
                        'lo cobrado en "Cobertura del ciclo".',
                        style:
                            TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// El pie de la tarjeta: SÓLO el puente con Cobertura del ciclo.
///
/// Acá vivía el desglose "¿De qué cuotas era esta plata?" (Total / Cuotas del
/// ciclo / Atrasos / Adelantos). El dueño lo sacó el 2026-08-29: *"eso es
/// totalmente innecesario"*. Esa clasificación ya se lee en las tarjetas de
/// Cobertura y de Mora, cada una con su propio corte y su Excel; repetirla acá
/// agregaba cuatro números más a una tarjeta que se mira de un vistazo.
///
/// **Lo que SÍ se queda es el puente**, porque no está en ninguna otra parte:
/// es la única línea que explica por qué esta tarjeta y Cobertura muestran
/// números distintos del mismo ciclo. Ya se había perdido una vez al
/// reescribir la tarjeta y hubo que reponerlo.
class _Puente extends ConsumerWidget {
  const _Puente({required this.ventana});
  final VentanaCaja ventana;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Sólo tiene sentido con un ciclo COMPLETO elegido: lo cobrado un martes
    // no se compara con el "Recuperado" de un ciclo entero.
    if (!ventana.esCicloCompleto) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(desgloseVentanaProvider((
      desde: isoDia(ventana.desde),
      hasta: isoDia(ventana.hasta),
      ciclo: isoDia(ventana.cicloRef),
    )));

    return async.maybeWhen(
      data: (d) {
        if (d.pagadoAntes <= 0 || d.delCiclo <= 0) {
          return const SizedBox.shrink();
        }
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.fromLTRB(13, 10, 13, 11),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
              'De este ciclo entraron ${Fmt.cordobas(d.delCiclo)} ahora, y '
              'otros ${Fmt.cordobas(d.pagadoAntes)} ya se habían cobrado '
              'antes. Juntos dan ${Fmt.cordobas(d.delCiclo + d.pagadoAntes)}, '
              'que es lo cobrado en "Cobertura del ciclo".',
              style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}
