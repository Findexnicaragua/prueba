import 'dart:math' as math;

import 'escala_resumen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/periodo_dashboard.dart';
import 'dashboard_export.dart';
import 'dashboard_query.dart';
import 'info_grafica.dart';
import 'info_grafica_textos.dart';
import 'bloque_parte_y_todo.dart';
import 'resumen_watch.dart';

/// # Mora del ciclo — tarjeta AUTOCONTENIDA
///
/// Este archivo no comparte NADA con la tarjeta de Cobertura: ni grilla, ni
/// botón de descarga, ni estilos. Es una decisión explícita del dueño
/// (2026-08-28): *"cada grafica va a tener su propia codificacion y
/// customizacion… con eso quiero asegurarme que un cambio que se haga en una
/// grafica no modifique otras sin querer"*.
///
/// **Trade-off aceptado:** un ajuste que sirva a las dos hay que hacerlo dos
/// veces. A cambio, tocar Mora no puede romper Cobertura, que ya está cerrada y
/// aprobada. Si algún día se vuelve a compartir, que sea una decisión y no un
/// descuido.
///
/// Lo único que entra de afuera son las CONSULTAS (`dashboard_query.dart`) y el
/// armado del Excel (`dashboard_export.dart`), donde Mora tiene sus PROPIAS
/// funciones: `serieMoraPorCiclo`, `desgloseMora`, `exportarMora`.

/// Cuántos ciclos abarca la gráfica de barras. El dueño la quiere como la
/// evolución del semestre: *"la grafica de barras que siempre tenga los ultimos
/// 6 ciclos de mora"*.
const int kCiclosMora = 6;

// ── Paleta PROPIA de esta tarjeta ──
// Coinciden con las de Cobertura a propósito (verde = entró, rojo = falta), pero
// se declaran acá: cambiarlas no debe alcanzar a la otra tarjeta.
const _azul = Color(0xFF185FA5);
const _verde = Color(0xFF1D9E75);
const _rojo = Color(0xFFE24B4A);
const _ambar = Color(0xFFD98829);

/// Una barra: la mora de un ciclo y cuánto se recuperó de ella.
///
/// Por construcción de [serieMoraPorCiclo], `recMonto + pendMonto = moraMonto`.
/// Eso es lo que permite apilar el verde sobre el rojo sin que la barra mienta:
/// las dos partes SON el total, no dos medidas distintas que se parecen.
class CicloMora {
  const CicloMora({
    required this.anio,
    required this.mes,
    required this.moraCuotas,
    required this.moraMonto,
    required this.recCuotas,
    required this.recMonto,
    required this.pendCuotas,
    required this.pendMonto,
    required this.enCurso,
    this.moraUsuarios = 0,
    this.recUsuarios = 0,
    this.pendUsuarios = 0,
  });

  final int anio, mes;
  final int moraCuotas, recCuotas, pendCuotas;

  /// PERSONAS distintas de cada fila (2026-09-02). Se cuentan con el MISMO
  /// predicado que sus cuotas, así que las dos columnas hablan del mismo
  /// conjunto: cuando difieren es que alguien tiene más de un contrato en el
  /// ciclo, que es para lo que el dueño mira la columna.
  ///
  /// Default 0 porque los ciclos VACÍOS que rellenan la ventana de la gráfica
  /// no traen fila de la consulta — y ahí cero es la verdad.
  final int moraUsuarios, recUsuarios, pendUsuarios;
  final num moraMonto, recMonto, pendMonto;

  /// El ciclo todavía no cerró. Se dibuja rayado y con itálica: su porcentaje
  /// bajo NO es un mal resultado, es un ciclo al que le faltan semanas. Sin
  /// esta marca la última barra se lee como un derrumbe.
  final bool enCurso;

  /// El ciclo vacío que rellena un hueco de la ventana. Sin esto la gráfica
  /// mostraría 4 barras cuando un mes no tuvo mora y el eje se correría.
  factory CicloMora.vacio(int anio, int mes, {required bool enCurso}) =>
      CicloMora(
          anio: anio,
          mes: mes,
          moraCuotas: 0,
          moraMonto: 0,
          recCuotas: 0,
          recMonto: 0,
          pendCuotas: 0,
          pendMonto: 0,
          enCurso: enCurso);

  String get etiqueta => periodoLabel(anio, mes);
  String get etiquetaCorta => mesCortoPeriodo(mes);

  /// Qué parte de la mora del ciclo se terminó recuperando.
  double get cumplimiento => moraMonto <= 0 ? 0 : recMonto / moraMonto;
  int get cumplimientoPct => (cumplimiento * 100).round();

  /// Lee las filas de [serieMoraPorCiclo] y las completa hasta cubrir la
  /// ventana entera, en orden cronológico.
  static List<CicloMora> deFilas(
    List<Map<String, dynamic>>? filas, {
    required int anioFin,
    required int mesFin,
    required int cantidad,
    required int anioActual,
    required int mesActual,
  }) {
    num n(Map<String, dynamic> r, String k) => (r[k] as num?) ?? 0;
    final porClave = <String, Map<String, dynamic>>{};
    for (final r in filas ?? const <Map<String, dynamic>>[]) {
      // La consulta devuelve el ciclo como el primer día de su mes de período.
      final s = '${r['ciclo']}';
      if (s.length >= 7) porClave[s.substring(0, 7)] = r;
    }
    final out = <CicloMora>[];
    for (var i = cantidad - 1; i >= 0; i--) {
      final d = DateTime(anioFin, mesFin - i, 1);
      final enCurso = d.year == anioActual && d.month == mesActual;
      final clave = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}';
      final r = porClave[clave];
      if (r == null) {
        out.add(CicloMora.vacio(d.year, d.month, enCurso: enCurso));
      } else {
        out.add(CicloMora(
          anio: d.year,
          mes: d.month,
          moraCuotas: n(r, 'mora_c').toInt(),
          moraMonto: n(r, 'mora_m'),
          recCuotas: n(r, 'rec_c').toInt(),
          recMonto: n(r, 'rec_m'),
          pendCuotas: n(r, 'pend_c').toInt(),
          pendMonto: n(r, 'pend_m'),
          moraUsuarios: n(r, 'mora_u').toInt(),
          recUsuarios: n(r, 'rec_u').toInt(),
          pendUsuarios: n(r, 'pend_u').toInt(),
          enCurso: enCurso,
        ));
      }
    }
    return out;
  }
}

/// Una línea del desglose de la tabla (el segundo nivel, bajo Recuperado o bajo
/// Por recuperar).
class LineaMora {
  const LineaMora(this.clave, this.cuotas, this.monto);
  final String clave;
  final int cuotas;
  final num monto;

  /// El rótulo dice CUÁNDO entró o POR QUÉ falta, en palabras del negocio.
  String get rotulo => switch (clave) {
        'dentro' => 'cobradas dentro del ciclo',
        'despues' => 'cobradas en un ciclo posterior',
        'parcial' => 'con abono parcial',
        _ => 'sin ningún pago',
      };

  static List<LineaMora> deFilas(
      List<Map<String, dynamic>>? filas, String fila) {
    num n(Map<String, dynamic> r, String k) => (r[k] as num?) ?? 0;
    // Orden fijo: el recorrido temporal / de gravedad, no el del GROUP BY.
    const orden = ['dentro', 'despues', 'nada', 'parcial'];
    final propias = (filas ?? const <Map<String, dynamic>>[])
        .where((r) => r['fila'] == fila)
        .toList();
    final out = <LineaMora>[];
    for (final k in orden) {
      final r = propias.where((x) => '${x['clave']}' == k).firstOrNull;
      if (r == null) continue;
      final c = n(r, 'cuotas').toInt();
      final m = n(r, 'monto');
      if (c == 0 && m <= 0.009) continue;
      out.add(LineaMora(k, c, m));
    }
    return out;
  }
}

/// Mora del ciclo: la tabla de UN ciclo, con la gráfica de los últimos 6 abajo.
///
/// Sigue el ORDEN de Cobertura —encabezado, navegación centrada, tabla,
/// gráfica— por pedido del dueño (2026-08-28): las dos tarjetas se leen igual
/// aunque no compartan una línea de código.
class MoraCiclosCard extends ConsumerStatefulWidget {
  const MoraCiclosCard({super.key, this.ocultarRecaudado = false});

  /// Esconde lo COBRADO y deja lo PENDIENTE. Lo usa `admin_cobranza`, que por
  /// definición no ve montos recolectados pero SÍ gestiona mora y recuperación
  /// de cartera — que es literalmente su trabajo.
  final bool ocultarRecaudado;

  @override
  ConsumerState<MoraCiclosCard> createState() => _MoraCiclosCardState();
}

class _MoraCiclosCardState extends ConsumerState<MoraCiclosCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int _ultimoRefreshEpoch = 0;

  /// El ciclo en curso. La gráfica se ancla acá: son los últimos
  /// [kCiclosMora] ciclos, siempre. Desde el 2026-09-02 no hay selector en
  /// esta tarjeta —se mudó a Cobertura— así que ya no existe un "ciclo
  /// elegido" distinto del actual.
  late int _anioHoy, _mesHoy;

  /// Cuántos ciclos hacia ATRÁS está corrida la ventana. 0 = los 6 que
  /// terminan en el ciclo actual, que es donde arranca.
  ///
  /// Vive SEPARADO del ancla (`_anioHoy`/`_mesHoy`) a propósito: el refresco de
  /// medianoche re-ancla a la fecha del día, y si el desplazamiento estuviera
  /// metido ahí, la ventana saltaría sola mientras alguien la mira.
  int _offset = 0;

  /// El vencimiento más viejo que existe. Es el tope hacia atrás: más allá no
  /// hay nada que dibujar. Null hasta que llega la consulta.
  DateTime? _primerVence;

  /// Null hasta que cargan los settings; sin el fallback el primer frame decía
  /// "los null días de gracia".
  int? _diasGracia;

  /// El día de corte con el que están armados los streams. El Excel recibe ESTE
  /// valor: si cada uno resolviera su propio "hoy", cruzar la medianoche con el
  /// dashboard abierto haría que el archivo trajera cuotas que la pantalla
  /// todavía no cuenta.
  String _hoy = isoDia(Fmt.hoyNicaragua());

  Stream<List<Map<String, dynamic>>> _serieStream = const Stream.empty();

  /// La columna que el mouse está tocando. Null = ninguna.
  int? _barraHover;

  @override
  void initState() {
    super.initState();
    final p = periodoDe(Fmt.hoyNicaragua());
    _anioHoy = p.year;
    _mesHoy = p.month;
  }

  /// El último ciclo de la ventana. Con `_offset = 0` es el actual.
  int get _mesFin => _mesHoy + _offset;

  /// Los 6 ciclos que terminan en [_mesFin].
  ///
  /// Era FIJA hasta el 2026-09-02: los 6 que terminan hoy, sin forma de mirar
  /// atrás. Rubén lo pidió — *"el selector de meses también tiene que estar
  /// para los últimos 6 meses de mora, para avanzar y retroceder"*.
  String get _inicioVentana =>
      isoDia(inicioPeriodo(_anioHoy, _mesFin - (kCiclosMora - 1)));
  String get _finVentana => isoDia(finPeriodo(_anioHoy, _mesFin));

  /// Hacia ADELANTE se para en la ventana actual: un ciclo futuro no puede
  /// tener mora —requiere que la gracia ya haya vencido—, así que avanzar más
  /// no mostraría nada.
  bool get _puedeAvanzar => _offset < 0;

  /// Hacia ATRÁS, hasta que la ventana deje de tocar datos.
  bool get _puedeRetroceder {
    final p = _primerVence;
    if (p == null) return true; // sin el tope, no se bloquea de más
    return !inicioPeriodo(_anioHoy, _mesFin - (kCiclosMora - 1))
        .isBefore(inicioPeriodo(p.year, p.month));
  }

  /// "Abr – Sep 2026". Nombra los DOS extremos de la ventana: decir sólo el
  /// último dejaba adivinando cuántos meses atrás llega.
  String _rangoVentana() {
    final ini = DateTime(_anioHoy, _mesFin - (kCiclosMora - 1));
    final fin = DateTime(_anioHoy, _mesFin);
    String mes(DateTime d) {
      final m = Fmt.mes(d);
      return '${m[0].toUpperCase()}${m.substring(1)}';
    }
    // `Fmt.mes` ya trae el año; en el primero se recorta cuando coinciden,
    // para no decir "Abril 2026 – Septiembre 2026" en un espacio angosto.
    final a = mes(ini), b = mes(fin);
    if (ini.year == fin.year) {
      return '${a.split(' ').first} – $b';
    }
    return '$a – $b';
  }

  void _correrVentana(int delta) {
    if (delta > 0 && !_puedeAvanzar) return;
    if (delta < 0 && !_puedeRetroceder) return;
    setState(() {
      _offset += delta;
      _rebuildStreams();
    });
  }

  void _rebuildStreams() {
    final g = _diasGracia!;
    // La serie NO depende del ciclo elegido: ventana fija.
    final serie = serieMoraPorCiclo(
        inicio: _inicioVentana, fin: _finVentana, diasGracia: g, hoy: _hoy);
    _serieStream = watchResumen(serie.sql, parameters: serie.parametros);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final cargaron = ref.watch(settingsMapProvider).hasValue;
    final diasGracia =
        ref.watch(appSettingsProvider.select((s) => s.diasGracia));

    // A medianoche de Nicaragua entran cuotas nuevas a la mora. `db.watch` no
    // se entera solo —solo re-consulta cuando cambian `cuotas`/`pagos`—, así
    // que este provider AVISA que cambió el día. Avisa nomás: el corte sale del
    // RELOJ, no de su valor.
    ref.watch(diaNicaraguaProvider);
    final hoy = isoDia(Fmt.hoyNicaragua());

    // Límites de ciclo cacheados centralmente en Riverpod
    final limites = ref.watch(limitesCiclosProvider).valueOrNull;
    if (limites?.primero != null) {
      _primerVence = limites!.primero;
    }

    final refreshEpoch = ref.watch(dashboardRefreshEpochProvider);
    final huboRefresh = refreshEpoch != _ultimoRefreshEpoch;
    if (huboRefresh) {
      _ultimoRefreshEpoch = refreshEpoch;
    }

    if (cargaron && (diasGracia != _diasGracia || hoy != _hoy || huboRefresh)) {
      _diasGracia = diasGracia;
      _hoy = hoy;
      final p = periodoDe(Fmt.hoyNicaragua());
      _anioHoy = p.year;
      _mesHoy = p.month;
      _rebuildStreams();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _encabezado(scheme),
            // La TABLA y el selector se mudaron a Cobertura del ciclo
            // (2026-09-02): habia dos selectores en el Resumen y podian quedar
            // en meses distintos mirando lo mismo. Aca queda la serie, que
            // nunca dependio del selector — es una ventana fija de los ultimos
            // `kCiclosMora` ciclos.
            const SizedBox(height: 14),
            _grafica(),
          ],
        ),
      ),
    );
  }

  // ── Encabezado ──
  // Mismo orden que Cobertura: título a la izquierda, descarga y DESPUÉS el (i)
  // a la derecha. Estaban al revés y el ojo saltaba entre las dos tarjetas.
  Widget _encabezado(ColorScheme scheme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Mora del ciclo',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (_diasGracia != null)
                _BotonExcelMora(
                  // Los MISMOS ciclos que dibujan las barras. Antes tomaba
                  // el ciclo del selector, que era una ventana distinta de la
                  // que se estaba viendo: navegando a julio, las barras seguian
                  // mostrando los ultimos 6 y el Excel exportaba 6 terminando
                  // en julio. El principio del export es que el archivo traiga
                  // lo que la pantalla muestra (ver `libroMora`), asi que esto
                  // lo alinea.
                  onExportar: () => exportarMora(
                    anio: _anioHoy,
                    // `_mesFin`, NO `_mesHoy`: desde que la ventana se puede
                    // correr (2026-09-02), el ancla y lo que se ve dejaron de
                    // ser lo mismo. Con `_mesHoy` el Excel bajaba los 6 ciclos
                    // que terminan HOY mientras la pantalla mostraba otros
                    // seis — el mismo desalineo que este comentario ya
                    // advertía para el selector viejo.
                    mes: _mesFin,
                    ciclos: kCiclosMora,
                    diasGracia: _diasGracia!,
                    // El MISMO corte con el que están armados los streams, no
                    // uno recalculado al hacer clic.
                    hoy: _hoy,
                  ),
                ),
              const InfoGraficaBoton(kInfoMora),
            ],
          ),
          // El EJE de la tarjeta en la cara, no detrás del (i).
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Text(
              _diasGracia == null
                  ? 'Cuotas que vencieron y pasaron los días de gracia'
                  : 'Cuotas que vencieron y pasaron los $_diasGracia días de '
                      'gracia',
              style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline),
            ),
          ),
          // EL SELECTOR DE VENTANA (2026-09-02). Antes la gráfica estaba
          // clavada a los 6 ciclos que terminan hoy y no había forma de mirar
          // atrás — que es justo lo que hace falta cuando aparece una mora
          // vieja y hay que ver de dónde viene.
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Seis ciclos anteriores',
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      _puedeRetroceder ? () => _correrVentana(-1) : null,
                ),
                // `Flexible` y no ancho fijo: el rango que cruza años
                // ("Octubre 2025 – Marzo 2026") mide casi el doble que uno
                // dentro del mismo año, y en un teléfono de 360 con las dos
                // flechas al lado queda al límite. No hay `Expanded` hermano,
                // así que la regla #15 no aplica: es el único flex del Row.
                Flexible(
                  child: Text(_rangoVentana(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: TxtResumen.apoyo,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface)),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Seis ciclos siguientes',
                  visualDensity: VisualDensity.compact,
                  onPressed: _puedeAvanzar ? () => _correrVentana(1) : null,
                ),
              ],
            ),
          ),
        ],
      );

  // ── Gráfica de los 6 ciclos ──
  Widget _grafica() => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _serieStream,
        builder: (context, snap) {
          final ciclos = CicloMora.deFilas(
            snap.data,
            anioFin: _anioHoy,
            // `_mesFin`, NO `_mesHoy` — la MISMA razón que en el Excel (:401).
            // El stream ya baja la ventana desplazada (`_inicioVentana`/
            // `_finVentana` usan `_mesFin`); si acá se arman los baldes con el
            // ancla fija, las filas que bajaron no caen en ninguno y las barras
            // dibujan otros 6 meses que el encabezado. Audit 2026-09-03: se
            // arregló el Excel y quedó mintiendo la gráfica de al lado.
            mesFin: _mesFin,
            cantidad: kCiclosMora,
            // `_mesHoy` SÍ: esto marca cuál es el ciclo EN CURSO (la barra
            // rayada), que no se mueve con el selector. Cuando la ventana se
            // corre y el mes actual queda afuera, ningún ciclo matchea y
            // `seleccionado` da -1 — que es el caso que `_BarrasMora` ya
            // contempla.
            anioActual: _anioHoy,
            mesActual: _mesHoy,
          );
          return _BarrasMora(
            ciclos: ciclos,
            // El CICLO EN CURSO, que es el ultimo. Antes marcaba el ciclo
            // elegido en el selector; desde que la tabla se mudo a Cobertura
            // (2026-09-02) no hay un "elegido" distinto del actual, y dejar la
            // barra resaltada sirve igual como ancla visual.
            seleccionado: ciclos
                .indexWhere((c) => c.anio == _anioHoy && c.mes == _mesHoy),
            hover: _barraHover,
            ocultarRecaudado: widget.ocultarRecaudado,
            // Solo re-dibuja si la columna CAMBIÓ: `onHover` dispara en cada
            // pixel de movimiento y un `setState` por pixel tira la tarjeta
            // entera a repintar 60 veces por segundo.
            onHover: (i) {
              if (i != _barraHover) setState(() => _barraHover = i);
            },
            // El TAP no navega (esa tabla ya no vive aca): entra por el mismo
            // `onHover`, que es lo que abre el globo en un telefono. Ver el
            // `onTapUp` de `_BarrasMora`.
          );
        },
      );
}

// ══ La GRILLA de esta tarjeta ══
//
// Propia y completa. Copia deliberada del patrón de Cobertura, NO una
// referencia a él: el dueño pidió que tocar una no pueda mover la otra.
//
// El contrato de anchos no se puede cambiar de a una fila. El rótulo va en una
// caja de ancho FIJO y cada nivel descuenta EXACTAMENTE lo que ocupa su
// marcador, o las líneas verticales dejan de caer en la misma columna:
/// Ancho por debajo del cual la tabla entra en modo COMPACTO.
///
/// En un teléfono el ancho útil ronda los 360px y esta grilla está pensada para
/// 560: el rótulo fijo se comía la mitad y el `FittedBox` de las celdas achicaba
/// los montos hasta volverlos ilegibles (~8px, medido en el teléfono el
/// 2026-08-29). En compacto el rótulo pasa a ser proporcional, se oculta la
/// columna de % —es composición, no un dato que se anote— y el monto pierde el
/// sufijo "C$", que ya está en el encabezado.

/// La tabla de mora de UN ciclo, para enchufarla donde haga falta.
///
/// **Por qué es un widget suelto (2026-09-02).** Vivía adentro de
/// `MoraCiclosCard` con su propio selector de ciclo, así que había DOS
/// selectores en el Resumen —el de Cobertura y el de Mora— y podían quedar en
/// meses distintos mirando lo mismo. Rubén la pidió arriba, bajo el selector de
/// Cobertura: un solo control manda sobre la curva y las dos tablas.
///
/// **El cálculo no cambió.** Las dos tarjetas resuelven su rango con las MISMAS
/// funciones (`inicioPeriodo`/`finPeriodo` sobre año y mes), así que recibir el
/// ciclo de Cobertura da exactamente las mismas fechas que daba su propio
/// selector. Las consultas son las de antes, con los mismos parámetros.
class MoraTablaCiclo extends StatefulWidget {
  const MoraTablaCiclo({
    super.key,
    required this.anio,
    required this.mes,
    required this.diasGracia,
    required this.hoy,
    this.ocultarRecaudado = false,
    this.maxWidth = 560,
  });

  /// El ciclo a mostrar. Lo manda el dueño del selector.
  final int anio, mes;

  final int diasGracia;

  /// El día de corte con el que se arman los streams. Viene de afuera por lo
  /// mismo que el Excel: si cada widget resolviera su propio "hoy", cruzar la
  /// medianoche con el dashboard abierto haría que dos partes de la MISMA
  /// pantalla contaran cuotas distintas.
  final String hoy;

  final bool ocultarRecaudado;

  /// Tope de ancho. 560 suelta; más angosto cuando comparte fila con otra tabla.
  final double maxWidth;

  @override
  State<MoraTablaCiclo> createState() => _MoraTablaCicloState();
}

class _MoraTablaCicloState extends State<MoraTablaCiclo> {
  Stream<List<Map<String, dynamic>>> _cicloStream = const Stream.empty();
  Stream<List<Map<String, dynamic>>> _desgloseStream = const Stream.empty();

  /// Filas desplegadas. Arrancan cerradas y se cierran al cambiar de ciclo:
  /// dejarlas abiertas mostraba el desglose del ciclo anterior por un frame.
  bool _abiertoRec = false, _abiertoPend = false;

  /// Con qué parámetros están armados los streams. Sin esto habría que
  /// re-armarlos en cada `build`, y `db.watch` devuelve un stream NUEVO cada
  /// vez: el `StreamBuilder` se re-suscribiría y la tabla parpadearía.
  int? _anioArmado, _mesArmado, _graciaArmada;
  String? _hoyArmado;

  void _armar() {
    final ini = isoDia(inicioPeriodo(widget.anio, widget.mes));
    final fin = isoDia(finPeriodo(widget.anio, widget.mes));
    final c = serieMoraPorCiclo(
        inicio: ini, fin: fin, diasGracia: widget.diasGracia, hoy: widget.hoy);
    _cicloStream = watchResumen(c.sql, parameters: c.parametros);
    final d = desgloseMora(
        inicio: ini, fin: fin, diasGracia: widget.diasGracia, hoy: widget.hoy);
    _desgloseStream = watchResumen(d.sql, parameters: d.parametros);
    _anioArmado = widget.anio;
    _mesArmado = widget.mes;
    _graciaArmada = widget.diasGracia;
    _hoyArmado = widget.hoy;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.anio != _anioArmado ||
        widget.mes != _mesArmado ||
        widget.diasGracia != _graciaArmada ||
        widget.hoy != _hoyArmado) {
      // Cambió el ciclo → las filas abiertas eran del anterior.
      _abiertoRec = false;
      _abiertoPend = false;
      _armar();
    }
    final anioHoy = periodoDe(Fmt.hoyNicaragua()).year;
    final mesHoy = periodoDe(Fmt.hoyNicaragua()).month;

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cicloStream,
      builder: (context, snapCiclo) =>
          StreamBuilder<List<Map<String, dynamic>>>(
        stream: _desgloseStream,
        builder: (context, snapDesglose) {
          final c = CicloMora.deFilas(
            snapCiclo.data,
            anioFin: widget.anio,
            mesFin: widget.mes,
            cantidad: 1,
            anioActual: anioHoy,
            mesActual: mesHoy,
          ).first;
          final detRec = LineaMora.deFilas(snapDesglose.data, 'rec');
          final detPend = LineaMora.deFilas(snapDesglose.data, 'pend');

          // El % es COMPOSICIÓN: qué parte de la mora del ciclo es esta fila.
          // El de "Por recuperar" se calcula por RESTA para que las dos sumen
          // 100 exacto — redondeando cada una por su cuenta, un cociente que
          // cae en x,5 sube en las dos y la columna imprime 101%.
          final pctRec =
              c.moraMonto <= 0 ? 0 : (c.recMonto / c.moraMonto * 100).round();
          final pctPend = c.moraMonto <= 0 ? 0 : 100 - pctRec;

          return ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            // El ancho REAL de la tabla, que es lo que decide el modo tarjeta.
            // `MediaQuery` no sirve: lado a lado esta tabla mide la mitad de
            // la pantalla, y suelta mide 560 aunque la pantalla tenga 1900.
            child: LayoutBuilder(builder: (context, cc) {
            final g = _GrillaMora(scheme, MediaQuery.sizeOf(context).width,
                cc.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Sin prefijo: `Fmt.cordobas` ya trae el sufijo, y ponerlo de
                // los dos lados imprimía "C$24.455,00 C$".
                //
                // MISMO ENVOLTORIO QUE LA TABLA DE COBERTURA —altura fija,
                // padding de 4 y `Divider`— y no es cosmético: van lado a lado,
                // así que cualquier diferencia de altura acá corre todas las
                // filas de una respecto de la otra.
                // En modo tarjeta NO hay cabecera de columnas: no hay columnas
                // sobre las que caer, y cada tarjeta rotula su propio dato
                // ("4.434 usuarios · 4.445 cuotas"). Dejarla dibujada era un
                // encabezado flotando sobre nada.
                if (!g.tarjetas) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: SizedBox(
                      height: kAltoCabeceraTabla,
                      // Solo "%": la frase con el monto no entraba con las
                      // dos tablas lado a lado. El denominador es la fila
                      // "Total en mora" de esta misma tabla.
                      child: g.encabezado('Usuarios', 'Cuotas', '%', 'Monto'),
                    ),
                  ),
                  Divider(height: 1, color: scheme.outlineVariant),
                ],
                if (g.tarjetas)
                  // EL TITULAR DEL BLOQUE. La barra reparte la mora del ciclo
                  // entre lo recuperado y lo que falta: dice lo mismo que la
                  // columna de %, pero se entiende sin leer un numero.
                  //
                  // Con `ocultarRecaudado` el tramo verde NO se dibuja y queda
                  // como canaleta gris: ese rol no ve montos cobrados, y la
                  // barra tiene que decir lo mismo que las filas.
                  TotalResumen(
                    label: 'Total en mora',
                    color: _azul,
                    monto: c.moraMonto,
                    usuarios: c.moraUsuarios,
                    cuotas: c.moraCuotas,
                    guionEnCero: true,
                    segmentos: [
                      if (!widget.ocultarRecaudado)
                        (fraccion: pctRec / 100, color: _verde),
                      (fraccion: pctPend / 100, color: _rojo),
                    ],
                  )
                else
                  g.fila('Total en mora', _azul, c.moraCuotas,
                      c.moraMonto <= 0 ? null : 100, c.moraMonto,
                      usuarios: c.moraUsuarios, fuerte: true),
                if (!widget.ocultarRecaudado)
                  g.fila('Recuperado', _verde, c.recCuotas, pctRec, c.recMonto,
                      usuarios: c.recUsuarios,
                      // El chevron aparece SOLO si hay dos o más categorías:
                      // con una sola no abriría nada.
                      abierto: detRec.length > 1 ? _abiertoRec : null,
                      onTap: detRec.length > 1
                          ? () => setState(() => _abiertoRec = !_abiertoRec)
                          : null),
                if (!widget.ocultarRecaudado && _abiertoRec)
                  for (final d in detRec)
                    g.fila(d.rotulo, _verde, d.cuotas, null, d.monto,
                        sub: true),
                g.fila('Por recuperar', _rojo, c.pendCuotas, pctPend,
                    c.pendMonto,
                    usuarios: c.pendUsuarios,
                    abierto: detPend.length > 1 ? _abiertoPend : null,
                    onTap: detPend.length > 1
                        ? () => setState(() => _abiertoPend = !_abiertoPend)
                        : null),
                if (_abiertoPend)
                  for (final d in detPend)
                    g.fila(d.rotulo, _rojo, d.cuotas, null, d.monto, sub: true),
                if (widget.ocultarRecaudado)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Tu rol no muestra montos cobrados. Acá ves la mora del '
                      'ciclo y lo que falta recuperar.',
                      style: TextStyle(
                          fontSize: TxtResumen.apoyo, color: scheme.outline),
                    ),
                  ),
              ],
            );
            }),
          );
        },
      ),
    );
  }
}

const double _anchoCompacto = 600;

//   madre  8+6 = 14   ·   sub 4+2+8 = 14
class _GrillaMora {
  const _GrillaMora(this.scheme, this.ancho, this.anchoTabla);
  final ColorScheme scheme;

  /// Ancho de PANTALLA. La tabla mide `min(560, pantalla - padding)`.
  final double ancho;

  /// Ancho REAL de esta tabla, que no es lo mismo: lado a lado en PC cada una
  /// mide ~507px con la pantalla en 1200. Los dos umbrales miden cosas
  /// distintas a proposito — mezclarlos apagaria la columna de % en PC.
  final double anchoTabla;

  bool get compacto => ancho < _anchoCompacto;

  /// Modo TARJETA: abajo de este ancho la tabla deja de ser tabla.
  /// Ver [TarjetaFilaResumen] — es la opcion que el dueno eligio el
  /// 2026-09-03, y la comparte con la tabla de Cobertura para que las dos no
  /// puedan volver a divergir.
  bool get tarjetas => anchoTabla < kAnchoTablaCompleta;

  /// El rótulo: fijo en pantalla ancha, proporcional en compacto.
  /// El 46% deja lugar a las dos columnas de números sin que ninguna
  /// tenga que encogerse.
  double get anchoRotulo =>
      compacto ? (ancho * 0.46).clamp(120.0, 170.0) : 170.0;

  static const _estiloCelda = TextStyle(fontSize: TxtResumen.cifra);

  TextStyle get _mudo => TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline);

  /// El monto. En compacto SIN el sufijo "C\$": ya esta en el encabezado,
  /// y repetirlo en cada fila es lo que obligaba al `FittedBox` a achicar
  /// el numero hasta ~8px en el telefono.
  String _monto(num m) {
    final t = Fmt.cordobas(m);
    return compacto ? t.replaceAll(' C\$', '') : t;
  }

  Widget _separador() => Container(
      width: 1,
      height: 15,
      color: scheme.outlineVariant.withValues(alpha: 0.5));

  Widget _celda(String txt,
          {int flex = 2, bool fuerte = false, bool mudo = false}) =>
      Expanded(
        flex: flex,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Text(txt,
              style: mudo
                  ? _mudo
                  : (fuerte
                      ? _estiloCelda.copyWith(fontWeight: FontWeight.w600)
                      : _estiloCelda)),
        ),
      );

  /// La fila de encabezados, con los MISMOS anchos y separadores que [fila]. Si
  /// no comparte el ancho del rótulo, el encabezado deja de caer sobre su
  /// columna.
  Widget encabezado(String colUsuarios, String colCuotas, String colPct,
      String colMonto) {
    // `maxLines: 1` y la altura fija de abajo: ver `kAltoCabeceraTabla`. Esta
    // tabla comparte fila con la de cobertura, y una cabecera que envuelve
    // corre todas sus filas respecto de la otra.
    Widget t(String s, {int flex = 2, TextAlign a = TextAlign.right}) => Expanded(
          flex: flex,
          child: Text(s,
              textAlign: a,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: TxtResumen.apoyo, fontWeight: FontWeight.w500)),
        );
    return Row(
      children: [
        SizedBox(width: anchoRotulo),
        _separador(),
        const SizedBox(width: 7),
        t(colUsuarios, flex: 1),
        const SizedBox(width: 7),
        _separador(),
        const SizedBox(width: 7),
        t(colCuotas, flex: 1),
        const SizedBox(width: 7),
        _separador(),
        const SizedBox(width: 7),
        // En compacto la columna de % no se dibuja (ver [_anchoCompacto]), asi
        // que su encabezado tampoco: si no, "% del total" queda flotando sobre
        // celdas vacias y se parte en dos renglones.
        if (compacto) const Expanded(flex: 1, child: SizedBox.shrink())
        else t(colPct, flex: 1, a: TextAlign.center),
        const SizedBox(width: 7),
        _separador(),
        const SizedBox(width: 7),
        t(colMonto),
      ],
    );
  }

  /// Una fila: rótulo · cuotas · % · monto.
  ///
  /// [sub] = sub-fila de desglose (fondo gris tenue, sin punto de color).
  /// [abierto] no-null dibuja el chevron; null lo omite.
  Widget fila(String label, Color dot, int cuotas, int? pct, num monto,
      {int? usuarios,
      bool fuerte = false,
      bool sub = false,
      bool? abierto,
      VoidCallback? onTap}) {
    if (tarjetas) {
      // El TOTAL no pasa por aca: lo dibuja `TotalResumen` en el build, que es
      // lo que le da su barra de composicion y su tamano de titular.
      return ParteResumen(
        label: label,
        color: dot,
        cuotas: cuotas,
        pct: pct,
        monto: monto,
        usuarios: usuarios,
        nivel: sub ? 1 : 0,
        // Esta tabla imprime "—" en los ceros; la de Cobertura imprime "0".
        // Es diferencia de CONTENIDO y se conserva.
        guionEnCero: true,
        abierto: abierto,
        onTap: onTap,
      );
    }
    final f = Container(
      padding: EdgeInsets.symmetric(vertical: sub ? 3 : 7),
      decoration: BoxDecoration(
        color: sub
            ? scheme.onSurface.withValues(alpha: 0.028)
            : Colors.transparent,
        border: Border(
            top: BorderSide(
                color: scheme.outlineVariant
                    .withValues(alpha: fuerte ? 0.55 : 0.3))),
      ),
      child: Row(
        children: [
          // PLANO a propósito: nada de un Row anidado para el rótulo. Los tests
          // localizan una fila con `find.ancestor(... byType(Row))` y toman el
          // PRIMERO; un Row interno se lleva ese match y la fila "encontrada"
          // ya no contiene las celdas de números.
          if (sub) ...[
            const SizedBox(width: 4),
            // La GUÍA: una barra del color de su fila madre, para saber a cuál
            // pertenece cada número.
            Container(width: 2, height: 13, color: dot.withValues(alpha: 0.4)),
            const SizedBox(width: 8),
          ] else ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          // El chevron va como WIDGET, no metido en el string del rótulo: los
          // tests buscan `find.text('Recuperado')` y meterlo adentro rompe el
          // match.
          //
          // SU LUGAR SE RESERVA SIEMPRE (2026-09-02). Antes se dibujaba solo
          // cuando la fila era desplegable y se le restaban sus 12px al ancho
          // del rótulo: las columnas de números no se movían —eso ya estaba
          // resuelto— pero el TEXTO sí, así que dentro de la misma tabla
          // convivían dos márgenes izquierdos. Con "Total en mora" y
          // "Recuperado" sin chevron y "Por recuperar" con él, se veía
          // torcido. Reservar el hueco cuesta 12px y alinea las seis filas.
          SizedBox(
            width: 12,
            child: abierto == null
                ? null
                : Icon(abierto ? Icons.expand_more : Icons.chevron_right,
                    size: 12, color: scheme.outline),
          ),
          SizedBox(
            width: anchoRotulo - 14 - 12,
            child: Text(label,
                style: sub
                    ? _mudo
                    : (fuerte
                        ? _estiloCelda.copyWith(fontWeight: FontWeight.w600)
                        : _estiloCelda),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          // Línea vertical que separa el QUÉ del CUÁNTO.
          _separador(),
          const SizedBox(width: 7),
          // USUARIOS: personas distintas, contra las CUOTAS de al lado.
          // Vacía en las sub-filas: el desglose parte CUOTAS, y repartir
          // personas entre sus líneas contaría a la misma dos veces.
          usuarios == null
              ? const Expanded(flex: 1, child: SizedBox.shrink())
              : _celda(usuarios == 0 ? '—' : Fmt.entero(usuarios),
                  flex: 1, mudo: sub),
          const SizedBox(width: 7),
          _separador(),
          const SizedBox(width: 7),
          _celda(cuotas == 0 ? '—' : Fmt.entero(cuotas), flex: 1, mudo: sub),
          const SizedBox(width: 7),
          _separador(),
          const SizedBox(width: 7),
          // El % NO es un semáforo: es COMPOSICIÓN — qué parte del total es esta
          // fila. El color dice DE QUÉ FILA es, no si está bien o mal.
          Expanded(
            // flex 1 desde que el encabezado dice solo "%": lo mas ancho que
            // aloja es "100%". El ancho liberado es el que necesita la columna
            // de Usuarios para verse entera.
            flex: 1,
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
          _separador(),
          const SizedBox(width: 7),
          _celda(_monto(monto), fuerte: fuerte, mudo: sub),
        ],
      ),
    );
    if (onTap == null) return f;
    return InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(4), child: f);
  }
}

// ══ Las 6 barras ══

/// La barra entera es la mora del ciclo; el verde, lo recuperado.
///
/// La altura es proporcional al MONTO, no al porcentaje: normalizando todas al
/// mismo alto se perdería que un ciclo tuvo mucha más mora que los otros — que
/// es la mitad del dato.
class _BarrasMora extends StatelessWidget {
  const _BarrasMora({
    required this.ciclos,
    required this.seleccionado,
    required this.hover,
    required this.ocultarRecaudado,
    required this.onHover,
  });

  final List<CicloMora> ciclos;

  /// Índice del ciclo que muestra la tabla, o -1 si está fuera de la ventana
  /// (se puede navegar más atrás de los 6; ahí no hay barra que marcar).
  final int seleccionado;
  final int? hover;
  final bool ocultarRecaudado;
  final void Function(int?) onHover;

  static const _alto = 150.0;
  static const _anchoEje = 56.0;
  /// Ancho del globo.
  ///
  /// Era 208 y NO alcanzaba: adentro va una fila de "rotulo · numero" con
  /// `spaceBetween` y sin nada flexible, asi que con un monto de siete digitos
  /// —"Por recuperar" + "2.860 · C\$2.555.200,23"— el `Row` desbordaba y el
  /// numero se PINTABA FUERA de la caja del globo, sobre la grafica. No
  /// dependia del ancho de pantalla (el globo mide fijo), asi que pasaba
  /// tambien en PC: es parte de lo que el dueno fotografio como *"un overlap
  /// del tooltip que el background es transparente"*.
  ///
  /// Lo cazo el test de 360px del 2026-09-03, no `flutter analyze`: un
  /// desborde de layout no rompe la compilacion.
  static const _anchoGlobo = 268.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxMonto =
        ciclos.fold<double>(0, (a, c) => math.max(a, c.moraMonto.toDouble()));
    final tope = maxMonto <= 0 ? 1.0 : _redondearEje(maxMonto);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // `Wrap` y no `Row` con `Spacer`: el titulo mas las dos referencias no
        // entran en el ancho de un telefono y desbordaban 190px. Con `Wrap`
        // las referencias bajan solas a la linea de abajo (test de 360px,
        // 2026-08-29).
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Últimos $kCiclosMora ciclos',
                style: TextStyle(fontSize: TxtResumen.apoyo, color: scheme.outline)),
            if (!ocultarRecaudado) _leyenda(_verde, 'Recuperado'),
            _leyenda(_rojo, 'Por recuperar'),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Eje Y: solo el tope y el cero. Más marcas en 150px es ruido.
            SizedBox(
              width: _anchoEje,
              height: _alto,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(Fmt.cordobas(tope),
                      style: TextStyle(fontSize: TxtResumen.minimo, color: scheme.outline)),
                  Text('0',
                      style: TextStyle(fontSize: TxtResumen.minimo, color: scheme.outline)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: LayoutBuilder(
                builder: (context, cons) {
                  // UNA sola región para las 6 columnas, no una por barra.
                  //
                  // Con un `MouseRegion` por barra, el `setState` del primer
                  // `onEnter` reconstruye el árbol, los `MouseRegion` nuevos no
                  // reciben los eventos que ya estaban en vuelo y el globo se
                  // queda clavado en la barra por la que el mouse PASÓ, no en
                  // la que está: el cursor sobre junio y el globo diciendo
                  // marzo (reportado por el dueño, 2026-08-28).
                  //
                  // Resolviendo la columna por posición no hay carrera: cada
                  // movimiento dice exactamente dónde está el mouse.
                  final ancho = cons.maxWidth / ciclos.length;
                  int columnaDe(Offset p) =>
                      (p.dx / ancho).floor().clamp(0, ciclos.length - 1);
                  return MouseRegion(
                    // `onEnter` ADEMAS de `onHover`: `onHover` solo dispara si
                    // el puntero se MUEVE dentro de la zona. Entrando de un
                    // salto —desde fuera de la ventana, o volviendo el foco a
                    // la app con el mouse ya encima— no llegaba ningun evento y
                    // el globo no aparecia hasta mover un pixel.
                    onEnter: (e) => onHover(columnaDe(e.localPosition)),
                    onHover: (e) => onHover(columnaDe(e.localPosition)),
                    onExit: (_) => onHover(null),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // EL TAP ABRE EL GLOBO (2026-09-03).
                      //
                      // El 2026-09-02 se saco el `onTapUp` porque tocar una
                      // columna llevaba la tabla del ciclo a ese mes y esa
                      // tabla se habia mudado a Cobertura. Cierto — pero al
                      // sacarlo quedo SOLO el hover, y en un telefono no hay
                      // hover: *"en el grafico de mora de 6 meses me sigue sin
                      // mostrar informacion al pulsar una barra, no aparece el
                      // tooltip"* (el dueno, dos veces).
                      //
                      // El tap NO navega: hace lo mismo que el hover. Y
                      // ALTERNA, porque en Android no hay `onExit` que cierre
                      // el globo: tocar la misma columna otra vez lo cierra, y
                      // tocar otra cambia de columna.
                      onTapUp: (d) {
                        final i = columnaDe(d.localPosition);
                        onHover(hover == i ? null : i);
                      },
                      child: SizedBox(
                        height: _alto,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border(
                                  left:
                                      BorderSide(color: scheme.outlineVariant),
                                  bottom:
                                      BorderSide(color: scheme.outlineVariant),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  for (var i = 0; i < ciclos.length; i++)
                                    Expanded(child: _barra(context, i, tope)),
                                ],
                              ),
                            ),
                            // El globo CUELGA de su columna, con la flecha
                            // apuntándola. Flotando en una esquina fija había
                            // que adivinar de cuál barra hablaba — que es parte
                            // de lo que se leía como "la data no corresponde".
                            if (hover != null && hover! < ciclos.length)
                              _globo(context, ciclos[hover!], hover!, ancho,
                                  cons.maxWidth, tope),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const SizedBox(width: _anchoEje + 6),
            for (var i = 0; i < ciclos.length; i++)
              Expanded(
                child: Text(
                  ciclos[i].etiquetaCorta,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: TxtResumen.minimo,
                    color:
                        i == seleccionado ? scheme.onSurface : scheme.outline,
                    fontWeight: i == seleccionado
                        ? FontWeight.w600
                        : FontWeight.normal,
                    fontStyle: ciclos[i].enCurso
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _leyenda(Color c, String txt) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          Text(txt, style: const TextStyle(fontSize: TxtResumen.minimo)),
        ],
      );

  Widget _barra(BuildContext context, int i, double tope) {
    final scheme = Theme.of(context).colorScheme;
    final c = ciclos[i];
    final total = (c.moraMonto / tope * _alto).clamp(0.0, _alto).toDouble();
    final verde = ocultarRecaudado
        ? 0.0
        : (c.recMonto / tope * _alto).clamp(0.0, _alto).toDouble();
    final rojo = (total - verde).clamp(0.0, _alto).toDouble();
    final activo = i == seleccionado;
    // El ciclo EN CURSO va rayado: su cumplimiento bajo no es un mal resultado,
    // es un ciclo al que le faltan semanas de cobro.
    final rayado = c.enCurso;
    // Las columnas que NO son la del cursor bajan de intensidad: la que el globo
    // describe queda evidente sin necesidad de leer el rótulo.
    final apagada = hover != null && hover != i;

    return Container(
      height: _alto,
      // La selección se marca con un FONDO tenue de columna, no con un borde:
      // encuadrar la columna entera dibujaba una caja vacía de 150px alrededor
      // de una barra de 27 y se leía como un error de render.
      color:
          activo ? scheme.primary.withValues(alpha: 0.07) : Colors.transparent,
      alignment: Alignment.bottomCenter,
      child: Opacity(
        opacity: apagada ? 0.45 : 1,
        child: ConstrainedBox(
          // Tope de ancho: sin él, 6 barras se reparten todo el ancho de la
          // tarjeta y salen bloques de 180px que no se leen como barras.
          constraints: const BoxConstraints(maxWidth: 54),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (rojo > 0) _tramo(rojo, _rojo, rayado: rayado, arriba: true),
                if (verde > 0) _tramo(verde, _verde, arriba: rojo <= 0),
                // Una barra de altura 0 (ciclo sin mora) deja igual una marca de
                // 2px: sin ella el hueco parece un error de dibujo.
                if (total <= 0)
                  Container(height: 2, color: scheme.outlineVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tramo(double alto, Color color,
          {bool rayado = false, bool arriba = false}) =>
      Container(
        height: alto,
        decoration: BoxDecoration(
          color: rayado ? color.withValues(alpha: 0.13) : color,
          border: rayado
              ? Border.all(color: color.withValues(alpha: 0.75), width: 1.5)
              : null,
          borderRadius: arriba
              ? const BorderRadius.vertical(top: Radius.circular(3))
              : BorderRadius.zero,
        ),
        // Las diagonales del ciclo en curso. Un relleno translúcido solo no
        // alcanzaba: a 27px de alto se leía como un color más claro, no como
        // "esto todavía no terminó".
        child: rayado
            ? CustomPaint(
                painter: _RayadoMora(color), child: const SizedBox.expand())
            : null,
      );

  /// El globo, anclado a SU columna.
  ///
  /// Lee la misma fila que la tabla: no recalcula nada, así que no pueden
  /// discrepar ni por redondeo.
  Widget _globo(BuildContext context, CicloMora c, int i, double anchoCol,
      double anchoTotal, double tope) {
    final scheme = Theme.of(context).colorScheme;
    final centro = anchoCol * (i + 0.5);
    // En un telefono el area de la grafica puede ser mas angosta que el globo.
    // Sin este tope el globo se salia por la derecha ademas de desbordar por
    // dentro.
    final ancho = math.min(_anchoGlobo, anchoTotal);
    // Se centra sobre la columna, pero sin salirse del área de la gráfica.
    final izq = (centro - ancho / 2)
        .clamp(0.0, math.max(0.0, anchoTotal - ancho))
        .toDouble();
    // Cuelga por encima de la barra. Con la barra muy alta el globo se sale por
    // arriba del área; el `Stack` no recorta (`Clip.none`) y la tarjeta tiene
    // 22px de aire encima, así que se ve entero.
    final altoBarra = (c.moraMonto / tope * _alto).clamp(0.0, _alto).toDouble();

    return Positioned(
      left: izq,
      bottom: altoBarra + 8.0,
      width: ancho,
      child: IgnorePointer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 4)),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(c.etiqueta,
                      style: const TextStyle(
                          fontSize: TxtResumen.cifra, fontWeight: FontWeight.w600)),
                  Text(c.enCurso ? 'Ciclo en curso' : 'Ciclo cerrado',
                      style: TextStyle(fontSize: TxtResumen.minimo, color: scheme.outline)),
                  const SizedBox(height: 7),
                  _tipFila(
                      'En mora', c.moraCuotas, c.moraMonto, scheme.onSurface),
                  if (!ocultarRecaudado)
                    _tipFila('Recuperado', c.recCuotas, c.recMonto, _verde),
                  _tipFila('Por recuperar', c.pendCuotas, c.pendMonto, _rojo),
                  if (!ocultarRecaudado) ...[
                    const SizedBox(height: 5),
                    Divider(height: 1, color: scheme.outlineVariant),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        // Mismo criterio que `_tipFila`: el que cede es el
                        // rotulo, nunca la cifra.
                        const Expanded(
                          child: Text('Cumplimiento',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: TxtResumen.apoyo)),
                        ),
                        const SizedBox(width: 8),
                        Text('${c.cumplimientoPct}%',
                            style: TextStyle(
                                fontSize: TxtResumen.apoyo,
                                fontWeight: FontWeight.w600,
                                color: _colorCumplimiento(c.cumplimiento))),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // La flecha que apunta a la columna. Se dibuja en la posición
            // relativa del centro de la barra DENTRO del globo, así sigue
            // apuntando bien aunque el globo se haya corrido para no salirse.
            Padding(
              padding: EdgeInsets.only(
                  left: (centro - izq - 7).clamp(10.0, math.max(10.0, ancho - 24))),
              child: CustomPaint(
                size: const Size(14, 7),
                painter: _FlechaGlobo(
                    scheme.surfaceContainerHighest, scheme.outlineVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Una fila del globo: rotulo a la izquierda, "cuotas · monto" a la derecha.
  ///
  /// UN SOLO `Expanded`, y es el de la IZQUIERDA (regla 15 del checklist).
  /// Antes eran dos `Text` sueltos con `spaceBetween`: ninguno cedia, asi que
  /// con un monto largo el `Row` desbordaba y el numero se pintaba fuera del
  /// globo. Ahora el que cede es el ROTULO —que se puede leer cortado y
  /// ademas se repite en la leyenda de la grafica—, nunca la cifra.
  Widget _tipFila(String label, int cuotas, num monto, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: TxtResumen.apoyo, color: color)),
            ),
            const SizedBox(width: 8),
            Text('${cuotas == 0 ? '—' : cuotas} · ${Fmt.cordobas(monto)}',
                style: TextStyle(
                    fontSize: TxtResumen.apoyo, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      );

  Color _colorCumplimiento(double pct) =>
      pct >= 0.7 ? _verde : (pct >= 0.3 ? _ambar : _rojo);
}

/// Diagonales para la barra del ciclo EN CURSO.
///
/// Es la marca de "este ciclo todavía se está llenando". Con solo bajarle la
/// opacidad al relleno, una barra corta se leía como un verde/rojo más claro y
/// no como una categoría distinta.
class _RayadoMora extends CustomPainter {
  const _RayadoMora(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 1.4;
    const paso = 6.0;
    canvas.clipRect(Offset.zero & size);
    // De abajo-izquierda hacia arriba-derecha, arrancando fuera del rect para
    // que la primera diagonal no quede cortada a la mitad.
    for (var x = -size.height; x < size.width; x += paso) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_RayadoMora old) => old.color != color;
}

/// La puntita del globo, para que se vea de qué columna cuelga.
class _FlechaGlobo extends CustomPainter {
  const _FlechaGlobo(this.relleno, this.borde);
  final Color relleno, borde;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = relleno);
    canvas.drawPath(
        path,
        Paint()
          ..color = borde
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_FlechaGlobo old) =>
      old.relleno != relleno || old.borde != borde;
}

/// Botón de descarga PROPIO de esta tarjeta.
///
/// Estado de carga propio, sin `showDialog`: un diálogo de loading que no se
/// cierra por una excepción deja la pantalla negra sin salida (regla #7 del
/// checklist de audit).
class _BotonExcelMora extends StatefulWidget {
  const _BotonExcelMora({required this.onExportar});
  final Future<String?> Function() onExportar;

  @override
  State<_BotonExcelMora> createState() => _BotonExcelMoraState();
}

class _BotonExcelMoraState extends State<_BotonExcelMora> {
  bool _bajando = false;

  Future<void> _bajar() async {
    if (_bajando) return;
    setState(() => _bajando = true);
    String? ruta;
    Object? error;
    try {
      ruta = await widget.onExportar();
    } catch (e) {
      error = e;
    } finally {
      // Cleanup GARANTIZADO: sin esto una excepción deja el spinner para
      // siempre y el botón inservible.
      if (mounted) setState(() => _bajando = false);
    }
    if (!mounted) return;
    final msg = error != null
        ? 'No se pudo bajar el detalle: $error'
        : (ruta == null ? 'Descarga cancelada' : 'Detalle guardado en $ruta');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) => _bajando
      ? const Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
        )
      : IconButton(
          // `file_download_outlined`, el MISMO que Cobertura. Con
          // `download_outlined` los dos botones se veian distintos uno arriba
          // del otro (reportado por el dueno, 2026-08-28): que las tarjetas
          // sean independientes por dentro no significa que el usuario tenga
          // que ver dos iconos para la misma accion.
          icon: const Icon(Icons.file_download_outlined, size: 20),
          tooltip: 'Descargar el detalle en Excel',
          onPressed: _bajar,
        );
}

/// Sube el tope del eje al siguiente número redondo, para que la barra más alta
/// no toque el techo y el rótulo del tope sea legible.
double _redondearEje(double max) {
  if (max <= 0) return 1;
  final magnitud = math.pow(10, (math.log(max) / math.ln10).floor()).toDouble();
  final paso = magnitud / 2;
  return ((max / paso).ceil()) * paso;
}
