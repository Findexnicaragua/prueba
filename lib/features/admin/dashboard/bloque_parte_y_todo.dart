/// # El TOTAL arriba y sus PARTES abajo — la forma de teléfono del Resumen
///
/// Abajo de [kAnchoTablaCompleta] las tablas del Resumen dejan de ser una
/// grilla y pasan a contar lo que el dato significa: **esto es lo que vence,
/// esto ya entró, esto falta**. Es la opción que el dueño eligió el 2026-09-03
/// sobre un mockup de cuatro enfoques.
///
/// ## Por qué hubo que cambiar de FORMA y no de tamaño
///
/// La cuenta, medida con la fuente real de la app sobre un teléfono de 360px
/// (la tabla dispone de **312px**):
///
/// | pieza | necesita |
/// |---|---|
/// | punto + chevron + 4 separadores | 79 px |
/// | Usuarios `4.434` · Cuotas `4.445` | 72 px |
/// | `100%` | 31 px |
/// | Monto `4.032.022,92 C$` | 105 px |
/// | **sin contar el rótulo** | **287 px** |
///
/// Quedan **25px** para un rótulo que necesita 84. Por eso el `FittedBox`
/// dibujaba el monto al 34% — **4,8px**, que es lo que el dueño fotografió.
/// Mientras la forma sea "una fila por concepto y una columna por métrica",
/// algo tiene que achicarse o cortarse: no es un problema de ajuste fino.
///
/// Se probaron y se descartaron, en este orden: ocultar la columna de %
/// (2026-08-29), bajar el monto a una segunda línea (2026-09-01), una tarjeta
/// por fila (2026-09-03) y abreviar los encabezados (2026-09-03, *"se sigue
/// sin entender"*). Esta forma es la primera que cumple las tres condiciones a
/// la vez: **toda la información**, **las mismas dos tablas** y **la letra al
/// tamaño del resto de la app**.
///
/// ## La escala es la de siempre
///
/// No se inventa ningún tamaño nuevo — se usan los roles que ya existen en
/// [TxtResumen]: [TxtResumen.gigante] para el total (es el número
/// protagonista del bloque), [TxtResumen.grande] para cada parte,
/// [TxtResumen.cifra] para el desglose y [TxtResumen.apoyo] para los rótulos.
/// Ningún `FittedBox`: si algo no entra, se acomoda, no se encoge.
///
/// ## Por qué esto vive en UN archivo compartido
///
/// La tarjeta de mora abre con una regla del dueño (2026-08-28): *"cada
/// grafica va a tener su propia codificacion… con eso quiero asegurarme que un
/// cambio que se haga en una grafica no modifique otras sin querer"*. Este
/// archivo es una **excepción deliberada y acotada**, porque esa regla
/// aplicada al modo teléfono es justo lo que produjo el bug que el dueño
/// reportó tres veces: se propuso un criterio el 08-29 y otro el 09-01, nunca
/// se eligió entre los dos, y quedaron **los dos vivos, uno en cada tabla**.
/// Desde el 09-02 van lado a lado y la diferencia se ve de un vistazo.
///
/// Con un solo renderer no hay dónde volver a divergir. **Lo compartido es
/// ESTO y nada más**: el modo PC de cada tabla sigue siendo suyo, en su
/// archivo, sin tocar.
library;

import 'package:flutter/material.dart';

import '../../../data/utils/formatters.dart';
import 'escala_resumen.dart';

/// Un tramo de la barra de composición: qué fracción del total ocupa y de qué
/// color es la parte que representa.
typedef SegmentoResumen = ({double fraccion, Color color});

/// El encabezado del bloque: el TOTAL, en grande, con su barra.
///
/// Es la fila que en la tabla lleva el 100% — "Cobros", "Total en mora",
/// "Total cobrado". Acá deja de ser una fila más y pasa a ser el titular: es
/// el número que el dueño viene a buscar cuando abre el Resumen.
class TotalResumen extends StatelessWidget {
  const TotalResumen({
    super.key,
    required this.label,
    required this.monto,
    required this.cuotas,
    required this.segmentos,
    this.usuarios,
    this.color,
    this.guionEnCero = false,
    this.unidadConteo = ('cuota', 'cuotas'),
  });

  /// "Cobros" · "Total en mora" · "Total cobrado".
  final String label;

  final num monto;
  final int cuotas;

  /// Personas distintas. Null cuando la tabla no tiene esa columna.
  final int? usuarios;

  /// Los tramos de la barra, en orden. Su suma puede ser menor que 1: lo que
  /// falta queda como canaleta gris, y eso ES el dato cuando un rol no ve los
  /// montos cobrados (`ocultarRecaudado`) o cuando el total es cero.
  final List<SegmentoResumen> segmentos;

  /// El punto de color del rótulo. Null = sin punto.
  final Color? color;

  /// La grilla de mora imprime "—" en los ceros; la de cobertura imprime "0".
  /// Es diferencia de CONTENIDO y se conserva.
  final bool guionEnCero;

  /// Cómo se llama lo que cuenta [cuotas]. En "Quién cobró" son COBROS.
  final (String, String) unidadConteo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = _meta(
      usuarios: usuarios,
      cuotas: cuotas,
      unidad: unidadConteo,
      guionEnCero: guionEnCero,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (color != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              // UN SOLO `Expanded`, y es el de la izquierda (regla 15 del
              // checklist): absorbe el sobrante para que lo de la derecha
              // quede siempre en el mismo lugar.
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: TxtResumen.apoyo, color: scheme.outline),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // EL NÚMERO PROTAGONISTA. Sin `FittedBox`: a 24px, un monto de siete
          // dígitos mide ~144px sobre los 312 disponibles, así que entra con
          // lugar de sobra. Era el que se dibujaba a 4,8px.
          Text(Fmt.cordobas(monto),
              style: const TextStyle(
                  fontSize: TxtResumen.gigante, fontWeight: FontWeight.w600)),
          if (meta != null) ...[
            const SizedBox(height: 1),
            Text(meta,
                style: TextStyle(
                    fontSize: TxtResumen.apoyo, color: scheme.outline)),
          ],
          const SizedBox(height: 9),
          _BarraComposicion(segmentos: segmentos),
          const SizedBox(height: 2),
        ],
      ),
    );
  }
}

/// La barra de composición: dice lo mismo que la columna de %, pero se entiende
/// sin leer un número. El % igual se sigue mostrando en cada parte — la barra
/// no lo reemplaza, lo acompaña.
class _BarraComposicion extends StatelessWidget {
  const _BarraComposicion({required this.segmentos});

  final List<SegmentoResumen> segmentos;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Los `flex` van en enteros por MIL: `Expanded` toma un int, y con
    // porcentajes enteros un 36/64 quedaría redondeado dos veces.
    final tramos = <Widget>[];
    var usado = 0;
    for (final s in segmentos) {
      final f = (s.fraccion.clamp(0.0, 1.0) * 1000).round();
      if (f <= 0) continue;
      usado += f;
      tramos.add(Expanded(flex: f, child: ColoredBox(color: s.color)));
    }
    final resto = 1000 - usado;
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: 9,
        child: Row(
          // `stretch` NO es decorativo: un `ColoredBox` SIN HIJO toma
          // `constraints.smallest`, y un `Row` da la altura FLOJA (min 0). Sin
          // esto la barra existe, ocupa su ancho... y se dibuja con altura
          // CERO: invisible. No lo caza `analyze` ni un test que solo cuente
          // widgets — solo mirar el render (2026-09-03).
          //
          // Es seguro pese a la regla 11 del checklist (un `Row` con `stretch`
          // reclama altura infinita): aca la altura viene ACOTADA por el
          // `SizedBox` de arriba, que es justo la condicion que la regla pide.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...tramos,
            // La canaleta. Con el total en cero la barra queda entera gris, y
            // eso es correcto: no hay nada que componer.
            if (resto > 0)
              Expanded(
                flex: resto,
                child: ColoredBox(
                    color: scheme.outlineVariant.withValues(alpha: 0.45)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Una PARTE del total, o una línea de su desglose.
///
/// [nivel] 0 es una parte (Recuperado / Por recuperar / un cobrador); 1 y 2 son
/// el desglose, que se dibuja con la barra-guía del color de su madre — el
/// mismo criterio que las tablas usan en PC.
class ParteResumen extends StatelessWidget {
  const ParteResumen({
    super.key,
    required this.label,
    required this.color,
    required this.monto,
    required this.cuotas,
    this.pct,
    this.usuarios,
    this.nivel = 0,
    this.soloTexto = false,
    this.sinConteo = false,
    this.nota,
    this.prefijoMonto,
    this.guionEnCero = false,
    this.unidadConteo = ('cuota', 'cuotas'),
    this.abierto,
    this.onTap,
  });

  final String label;

  /// El color de la parte: punto en nivel 0, barra-guía en el desglose.
  final Color color;

  final num monto;
  final int cuotas;

  /// Qué parte del total es. Null en el desglose, que no compone el 100%.
  final int? pct;

  final int? usuarios;

  /// 0 = parte · 1 = desglose · 2 = desglose del desglose.
  final int nivel;

  /// Fila de puro texto: sin monto y sin conteos.
  final bool soloTexto;

  /// Con monto pero sin conteos.
  final bool sinConteo;

  /// Aclaración al pie del renglón. Reemplaza al paréntesis de la tabla, que
  /// había que saber interpretar: acá se dice con palabras
  /// ("ya contadas arriba").
  final String? nota;

  final String? prefijoMonto;
  final bool guionEnCero;
  final (String, String) unidadConteo;

  /// No-null dibuja el chevron; null lo omite.
  final bool? abierto;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sub = nivel > 0;
    final meta = _meta(
      usuarios: usuarios,
      cuotas: cuotas,
      unidad: unidadConteo,
      guionEnCero: guionEnCero,
      omitir: soloTexto || sinConteo,
    );

    final fila = Container(
      padding: EdgeInsets.only(
          left: nivel * 14.0, top: sub ? 6 : 9, bottom: sub ? 6 : 9),
      decoration: BoxDecoration(
        color:
            sub ? scheme.onSurface.withValues(alpha: 0.028) : Colors.transparent,
        border: Border(
            top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: sub ? 0.3 : 0.5))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // El marcador. En una parte es el punto; en el desglose, la
          // barra-guía del color de su madre, que dice a cuál pertenece.
          Padding(
            padding: EdgeInsets.only(top: sub ? 2 : 4),
            child: sub
                ? Container(
                    width: 2, height: 13, color: color.withValues(alpha: 0.55))
                : Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
          ),
          SizedBox(width: sub ? 8 : 6),
          // UN SOLO `Expanded`, el de la izquierda (regla 15). El rótulo se
          // lleva todo el sobrante, así el % y el chevron caen siempre en el
          // mismo lugar.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                      fontSize: sub ? TxtResumen.cifraSub : TxtResumen.cifra,
                      fontWeight: sub ? FontWeight.w400 : FontWeight.w600,
                      color: sub ? scheme.outline : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (!soloTexto) ...[
                  const SizedBox(height: 2),
                  // El monto de la parte. Un escalón abajo del total y uno
                  // arriba del desglose: la jerarquía se lee sin depender del
                  // color.
                  Text('${prefijoMonto ?? ''}${Fmt.cordobas(monto)}',
                      style: TextStyle(
                        fontSize: sub ? TxtResumen.cifra : TxtResumen.grande,
                        fontWeight: FontWeight.w600,
                        color: sub ? scheme.outline : null,
                      )),
                ],
                if (meta != null) ...[
                  const SizedBox(height: 1),
                  Text(meta,
                      style: TextStyle(
                          fontSize: TxtResumen.apoyo, color: scheme.outline)),
                ],
                if (nota != null) ...[
                  const SizedBox(height: 1),
                  Text(nota!,
                      style: TextStyle(
                          fontSize: TxtResumen.apoyo,
                          color: scheme.outline,
                          fontStyle: FontStyle.italic)),
                ],
              ],
            ),
          ),
          if (pct != null) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text('$pct%',
                  style: TextStyle(
                      fontSize: TxtResumen.apoyo,
                      fontWeight: FontWeight.w600,
                      color: color)),
            ),
          ],
          // El hueco del chevron se reserva SIEMPRE (2026-09-02): si no, el
          // bloque de la derecha se corre en las filas que no se abren.
          SizedBox(
            width: 18,
            child: abierto == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                        abierto! ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: scheme.outline),
                  ),
          ),
        ],
      ),
    );

    if (onTap == null) return fila;
    return InkWell(onTap: onTap, child: fila);
  }
}

/// "4.434 usuarios · 4.445 cuotas".
///
/// En la tabla esto eran dos columnas con su encabezado. Acá cada número lleva
/// su palabra al lado, y por eso el bloque no necesita cabecera de columnas.
String? _meta({
  required int? usuarios,
  required int cuotas,
  required (String, String) unidad,
  required bool guionEnCero,
  bool omitir = false,
}) {
  if (omitir) return null;
  String entero(int n) => (guionEnCero && n == 0) ? '—' : Fmt.entero(n);
  String plural(int n, String uno, String varios) =>
      '${entero(n)} ${n == 1 ? uno : varios}';
  final partes = <String>[
    if (usuarios != null) plural(usuarios, 'usuario', 'usuarios'),
    plural(cuotas, unidad.$1, unidad.$2),
  ];
  return partes.isEmpty ? null : partes.join(' · ');
}
