import 'escala_resumen.dart';
import 'bloque_parte_y_todo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart'
    show dashboardRefreshEpochProvider;
import '../../../data/providers/db_epoch_provider.dart';
import '../../../data/providers/cobrador_provider.dart' show tenantIdProvider;
import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';
import 'resumen_watch.dart';

/// # Quién cobró — tarjeta AUTOCONTENIDA
///
/// No comparte grilla, consulta ni estilos con ninguna otra tarjeta. Decisión
/// del dueño (2026-08-28): *"cada una es individual… así cada cambio en cada una
/// es independiente de los demás"*.
///
/// **SIN botón de Excel (2026-09-02).** Lo tuvo hasta hoy y se le sacó por
/// regla del dueño para el tablero entero: los únicos Excel descargables son el
/// de "Cobertura del ciclo" y el de "Mora de 6 ciclos". La tarjeta que ésta
/// reemplazó ("Top cobradores", v0.37.1 en producción) tampoco tenía uno, así
/// que el botón nunca fue algo que el dueño hubiera pedido acá. Se fueron con él
/// la consulta pago-por-pago y el armado del libro; si algún día se vuelve a
/// pedir, están en el historial de este archivo.
///
/// **Reemplaza a las DOS tarjetas "Top cobradores"** (hoy y período) que vivían
/// lado a lado. La de "hoy" salía vacía cualquier día sin cobros —medido: el
/// 28 de agosto nadie había cobrado— y una tarjeta vacía la mitad del tiempo se
/// lee como rota. Con un selector, ocupa la mitad del espacio y nunca se ve así.
///
/// **Agrupa por `pagos.cobrador_id`, quien REGISTRÓ el pago**, no por el
/// cobrador asignado del cliente (§3.5-4b de ARQUITECTURA). Y SIN filtro de
/// rol: en la práctica cobra sobre todo la oficina (admin / admin_cobranza), y
/// filtrando por `rol='cobrador'` el ranking mostraba el 21% de la plata en un
/// tenant y el 12% en otro, sin cerrar contra el arqueo.

// ── Paleta PROPIA ──
const _verde = Color(0xFF1D9E75);

/// Qué ventana mira la tarjeta.
enum VentanaCobros { hoy, ciclo }

/// Lo que cobró una persona en la ventana elegida.
class CobradorFila {
  const CobradorFila(this.id, this.nombre, this.pagos, this.monto);
  final String id;
  final String nombre;
  final int pagos;
  final num monto;
}

/// Cobros por quien los registró.
///
/// El corte de día usa `-6 hours` (Nicaragua, UTC-6 sin DST): con `date('now')`
/// pelado, entre medianoche y las 6 AM la tarjeta mostraría los cobros del día
/// siguiente. Regla #1b del checklist de audit.
final quienCobroProvider = StreamProvider.autoDispose.family<List<CobradorFila>, VentanaCobros>((ref, v) {
  ref.watch(dbEpochProvider);
  ref.watch(dashboardRefreshEpochProvider);
  final params = <Object?>[];
  String filtro;
  if (v == VentanaCobros.hoy) {
    filtro = "p.fecha_cobro = date('now','-6 hours')";
  } else {
    final p = periodoDe(Fmt.hoyNicaragua());
    filtro = 'p.fecha_cobro >= ? AND p.fecha_cobro < ?';
    params
      ..add(isoDia(inicioPeriodo(p.year, p.month)))
      ..add(isoDia(finPeriodo(p.year, p.month)));
  }
  // Filtro de empresa: sin él, el super_admin impersonando se colaba en el
  // ranking con su propia fila (tenant System) y, al cambiar de empresa,
  // también los cobradores de la anterior.
  params.add(ref.watch(tenantIdProvider));

  return watchResumen(
    '''
    SELECT co.id, co.nombre,
           COALESCE(SUM(p.monto_cordobas), 0) AS total,
           COUNT(p.id) AS qty
      FROM cobradores co
 LEFT JOIN pagos p ON p.cobrador_id = co.id
                  AND COALESCE(p.anulado, 0) = 0
                  AND COALESCE(p.en_revision, 0) = 0
                  AND $filtro
     WHERE co.activo = 1 AND co.tenant_id = ?
     GROUP BY co.id, co.nombre
     ORDER BY total DESC
    ''',
    parameters: params,
  ).map((rows) => rows
      .map((r) => CobradorFila(
            r['id'] as String,
            (r['nombre'] as String?) ?? '',
            (r['qty'] as num).toInt(),
            r['total'] as num,
          ))
      // Los que no cobraron nada NO se listan: una lista de ceros no dice
      // quién cobró, sólo alarga la tarjeta.
      .where((c) => c.pagos > 0)
      .toList());
});

class QuienCobroCard extends ConsumerStatefulWidget {
  const QuienCobroCard({super.key});

  @override
  ConsumerState<QuienCobroCard> createState() => _QuienCobroCardState();
}

class _QuienCobroCardState extends ConsumerState<QuienCobroCard> {
  VentanaCobros _v = VentanaCobros.ciclo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(quienCobroProvider(_v));
    final p = periodoDe(Fmt.hoyNicaragua());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.emoji_events_outlined,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Quién cobró',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const InfoGraficaBoton(kInfoTopCobradores),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text('La plata que entró, por quién la registró',
                  style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
            ),
            const SizedBox(height: 14),
            // El rango sale del segmento y va DEBAJO en pantalla angosta:
            // "Ciclo 15 ago – 14 sep" no entra en un segmento de teléfono y se
            // partia en dos renglones (visto en el telefono, 2026-08-29).
            Builder(builder: (context) {
              final angosto = MediaQuery.sizeOf(context).width < 600;
              final ciclo = periodoLabel(p.year, p.month);
              return Column(
                children: [
                  Center(
                    child: SegmentedButton<VentanaCobros>(
                      style: const ButtonStyle(
                          visualDensity: VisualDensity.compact),
                      segments: [
                        // "Solo hoy" y no "Hoy": hace juego con el otro
                        // segmento y no choca con el bloque "Hoy" de la
                        // tarjeta de caja, que vive en la misma pantalla.
                        const ButtonSegment(
                            value: VentanaCobros.hoy, label: Text('Solo hoy')),
                        ButtonSegment(
                            value: VentanaCobros.ciclo,
                            label: Text(angosto ? 'Este ciclo' : 'Ciclo $ciclo')),
                      ],
                      selected: {_v},
                      onSelectionChanged: (s) => setState(() => _v = s.first),
                    ),
                  ),
                  if (angosto && _v == VentanaCobros.ciclo)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(ciclo,
                          style:
                              TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
                    ),
                ],
              );
            }),
            const SizedBox(height: 14),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              ),
              // M13: antes el error dejaba el card vacio en silencio. La nota
              // se perdio al partir el Resumen en un archivo por tarjeta; sus
              // hermanas (`estado_actual_card`, `distribucion_cuotas_card`) la
              // conservan y es la que explica por que este ramal existe.
              error: (_, __) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text('No se pudo calcular',
                    style: TextStyle(fontSize: TxtResumen.cifra, color: scheme.error)),
              ),
              data: (filas) => _cuerpo(scheme, filas),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cuerpo(ColorScheme scheme, List<CobradorFila> filas) {
    if (filas.isEmpty) {
      // Vacío EXPLICADO, no una tarjeta en blanco: en un día sin cobros esto
      // es lo normal, y decirlo evita que se lea como un error de la app.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
              _v == VentanaCobros.hoy
                  ? 'Todavía nadie registró un cobro hoy.'
                  : 'No hubo cobros en este ciclo.',
              style: TextStyle(fontSize: TxtResumen.cifra, color: scheme.outline)),
        ),
      );
    }

    // El ancho de PANTALLA decide si la tabla va compacta: mide
    // `min(560, pantalla - padding)`, asi que el umbral de 600 equivale a
    // medir la tabla sin envolverla en otro `LayoutBuilder`.
    //
    // La sangria de estas cuatro lineas quedo a 14 espacios cuando se saco ese
    // `LayoutBuilder` (a9ba41b0) y nadie la volvio a bajar: el comentario y su
    // `final` colgaban en el aire, como si siguieran adentro del builder.
    final total = filas.fold<num>(0, (a, f) => a + f.monto);
    final totalPagos = filas.fold<int>(0, (a, f) => a + f.pagos);

    return Column(
      children: [
        Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: LayoutBuilder(builder: (context, cc) {
            final g = _GrillaCobros(
                scheme, MediaQuery.sizeOf(context).width, cc.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // En modo tarjeta no hay cabecera: no hay columnas sobre las
                // que caer, y cada tarjeta rotula su propio dato.
                if (!g.tarjetas) ...[
                  g.encabezado('Cobros', '% del total', 'Monto'),
                  const SizedBox(height: 4),
                ],
                if (g.tarjetas)
                  // EL TITULAR DEL BLOQUE. Aca la barra reparte la caja entre
                  // los cobradores. Todos comparten color —son la misma clase
                  // de cosa—, asi que los tramos se distinguen alternando la
                  // opacidad; un stacked bar de un solo color se leeria como
                  // un bloque.
                  TotalResumen(
                    label: 'Total cobrado',
                    color: _verde,
                    monto: total,
                    cuotas: totalPagos,
                    guionEnCero: true,
                    unidadConteo: ('cobro', 'cobros'),
                    segmentos: [
                      for (var i = 0; i < filas.length; i++)
                        (
                          fraccion: total <= 0 ? 0.0 : filas[i].monto / total,
                          color: _verde
                              .withValues(alpha: i.isEven ? 1.0 : 0.62),
                        ),
                    ],
                  )
                else
                  g.fila('Total cobrado', _verde, totalPagos,
                      total <= 0 ? null : 100, total,
                      fuerte: true),
                for (final f in filas)
                  g.fila(f.nombre, _verde, f.pagos,
                      total <= 0 ? null : (f.monto / total * 100).round(),
                      f.monto),
              ],
            );
            }),
          ),
        ),
        const SizedBox(height: 22),
        _BarrasCobros(filas: filas),
      ],
    );
  }
}

/// Barras horizontales: el eje es una lista de nombres, no el tiempo.
class _BarrasCobros extends StatelessWidget {
  const _BarrasCobros({required this.filas});
  final List<CobradorFila> filas;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compacto = MediaQuery.sizeOf(context).width < 600;
    final anchoNombre = compacto ? 96.0 : 130.0;
    final anchoMonto = compacto ? 78.0 : 92.0;
    final max = filas.fold<num>(0, (a, f) => f.monto > a ? f.monto : a);
    if (max <= 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Reparto de lo cobrado',
            style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
        const SizedBox(height: 8),
        // Anchos ADAPTADOS: en un telefono (~360px utiles) el nombre a 130 y
        // el monto a 92 dejaban ~110px para la barra, que es lo unico que la
        // gente compara de un vistazo. En compacto se achican los dos.
        for (final f in filas)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: anchoNombre,
                  child: Text(f.nombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: TxtResumen.apoyo)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, cons) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 16,
                        width: (f.monto / max * cons.maxWidth).toDouble(),
                        decoration: BoxDecoration(
                            color: _verde,
                            borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: anchoMonto,
                  child: Text(Fmt.cordobas(f.monto),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: TxtResumen.apoyo)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Ancho por debajo del cual la tabla entra en modo COMPACTO.
///
/// En un teléfono el ancho útil ronda los 360px y esta grilla está pensada para
/// 560: el rótulo fijo se comía la mitad y el `FittedBox` de las celdas achicaba
/// los montos hasta volverlos ilegibles (~8px, medido en el teléfono el
/// 2026-08-29). En compacto el rótulo pasa a ser proporcional, se oculta la
/// columna de % —es composición, no un dato que se anote— y el monto pierde el
/// sufijo "C$", que ya está en el encabezado.
const double _anchoCompacto = 600;

// ══ La GRILLA de esta tarjeta ══
// Propia y completa. Esta tabla no tiene sub-filas, así que el rótulo lleva un
// solo marcador de 14px (8 del punto + 6 de aire) — de ahí el
// `anchoRotulo - 14` de [fila].
//
// La frase estaba PARTIDA EN DOS: al agregar [_anchoCompacto] (a9ba41b0) su
// doc-comment se metió en el medio, y "solo marcador de 14px" quedaba flotando
// sobre la clase como si la explicara a ella. Se junta de nuevo; la constante
// queda arriba, entera, que es donde la busca quien quiere el umbral.
class _GrillaCobros {
  const _GrillaCobros(this.scheme, this.ancho, this.anchoTabla);
  final ColorScheme scheme;

  /// Ancho de PANTALLA. La tabla mide `min(560, pantalla - padding)`.
  final double ancho;

  /// Ancho REAL de la tabla, que es lo que decide el modo tarjeta. Los dos
  /// umbrales miden cosas distintas a proposito (ver [_GrillaMora]).
  final double anchoTabla;

  bool get compacto => ancho < _anchoCompacto;

  /// Modo TARJETA — el MISMO que las dos tablas de Cobertura.
  ///
  /// Esta tabla llevaba el criterio del 2026-08-29 (ocultar el %, sacarle el
  /// "C\$" al monto) y las de Cobertura terminaron con otro. El dueno vio los
  /// dos y eligio la TARJETA el 2026-09-03; esta es la tercera y entra por el
  /// mismo lado. Si se quedaba con su criterio propio, en una semana estabamos
  /// igual: tres tablas y dos formas.
  bool get tarjetas => anchoTabla < kAnchoTablaCompleta;

  /// El rótulo: fijo en pantalla ancha, proporcional en compacto.
  /// El 46% deja lugar a las dos columnas de números sin que ninguna
  /// tenga que encogerse.
  double get anchoRotulo =>
      compacto ? (ancho * 0.46).clamp(120.0, 190.0) : 190.0;

  static const _celdaStyle = TextStyle(fontSize: TxtResumen.cifra);

  /// El monto. En compacto sin el sufijo "C\$": ya está en el
  /// encabezado, y repetirlo en cada fila es lo que obligaba al
  /// `FittedBox` a achicar el número.
  String _monto(num m) {
    final t = Fmt.cordobas(m);
    return compacto ? t.replaceAll(' C\$', '') : t;
  }

  Widget _sep() => Container(
      width: 1,
      height: 15,
      color: scheme.outlineVariant.withValues(alpha: 0.5));

  Widget _celda(String txt, {int flex = 2, bool fuerte = false}) => Expanded(
        flex: flex,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Text(txt,
              style: fuerte
                  ? _celdaStyle.copyWith(fontWeight: FontWeight.w600)
                  : _celdaStyle),
        ),
      );

  Widget encabezado(String c1, String c2, String c3) {
    Widget t(String s, {int flex = 2, TextAlign a = TextAlign.right}) =>
        Expanded(
          flex: flex,
          child: Text(s,
              textAlign: a,
              style:
                  const TextStyle(fontSize: TxtResumen.apoyo, fontWeight: FontWeight.w500)),
        );
    return Row(
      children: [
        SizedBox(width: anchoRotulo),
        _sep(),
        const SizedBox(width: 7),
        t(c1, flex: 1),
        const SizedBox(width: 7),
        _sep(),
        const SizedBox(width: 7),
        // En compacto la columna de % no se dibuja (ver [_anchoCompacto]), asi
        // que su encabezado tampoco: si no, "% del total" queda flotando sobre
        // celdas vacias y se parte en dos renglones.
        if (compacto)
          const Expanded(flex: 2, child: SizedBox.shrink())
        else
          t(c2, a: TextAlign.center),
        const SizedBox(width: 7),
        _sep(),
        const SizedBox(width: 7),
        t(c3),
      ],
    );
  }

  Widget fila(String label, Color dot, int cobros, int? pct, num monto,
      {bool fuerte = false}) {
    if (tarjetas) {
      // El TOTAL no pasa por aca: lo dibuja `TotalResumen` en el build.
      return ParteResumen(
        label: label,
        color: dot,
        cuotas: cobros,
        pct: pct,
        monto: monto,
        // Aca no hay columna de usuarios: la fila es un COBRADOR, y su conteo
        // son COBROS. El bloque lo dice con la palabra al lado, que es lo que
        // en la tabla decia el encabezado.
        unidadConteo: ('cobro', 'cobros'),
        guionEnCero: true,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(
                color: scheme.outlineVariant
                    .withValues(alpha: fuerte ? 0.55 : 0.3))),
      ),
      child: Row(
        children: [
          // PLANO a propósito: un Row anidado se lleva el match de los tests.
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          SizedBox(
            width: anchoRotulo - 14,
            child: Text(label,
                style: fuerte
                    ? _celdaStyle.copyWith(fontWeight: FontWeight.w600)
                    : _celdaStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          _sep(),
          const SizedBox(width: 7),
          _celda(cobros == 0 ? '—' : Fmt.entero(cobros), flex: 1),
          const SizedBox(width: 7),
          _sep(),
          const SizedBox(width: 7),
          Expanded(
            flex: 2,
            child: (pct == null || compacto)
                ? const SizedBox.shrink()
                : Text('$pct%',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: TxtResumen.apoyo,
                        fontWeight: FontWeight.w500,
                        color: dot)),
          ),
          const SizedBox(width: 7),
          _sep(),
          const SizedBox(width: 7),
          _celda(_monto(monto), fuerte: fuerte),
        ],
      ),
    );
  }
}
