/// # La escala tipográfica del Resumen
///
/// Un solo lugar donde viven los tamaños de letra de las siete tarjetas.
///
/// ## Por qué existe
///
/// Hasta el 2026-09-01 cada tarjeta tenía los suyos escritos a mano y ya habían
/// divergido: **nueve valores distintos** repartidos en diez archivos —9, 9,5,
/// 10, 10,5, 11, 11,5, 12, 12,5, 13— sin ninguna regla que dijera cuál va
/// dónde. El resultado se ve al scrollear: la misma clase de dato aparece en
/// tres tamaños según la tarjeta que lo muestre.
///
/// Y algunos eran directamente ilegibles. Reporte del dueño con capturas:
/// *"quiero que los números y letras en general sean un poco más grandes para
/// que sean más legibles tanto en PC como en Android"*.
///
/// ## La regla
///
/// **Nada por debajo de [minimo].** Los 9px y 9,5px que había son de la época
/// en que la tarjeta entraba a los apretones; hoy el layout se adapta y no hay
/// motivo para pedirle a nadie que entrecierre los ojos.
///
/// Al agregar una tarjeta o un renglón, usar un rol de acá. Si ninguno encaja,
/// **agregar el rol con su porqué** en vez de escribir un número suelto — que
/// es exactamente como se llegó a los nueve.
abstract final class TxtResumen {
  /// El número protagonista de una tarjeta: los montos de "Caja del ciclo",
  /// que son lo primero que el dueño mira al abrir el Resumen.
  static const gigante = 24.0;

  /// Cifra destacada dentro de una tarjeta — un total, un titular.
  static const grande = 17.0;

  /// **La cifra de una fila madre en una tabla.** Es el tamaño que el pedido
  /// del 2026-09-01 vino a subir: era 12 y a esa altura, con montos de siete
  /// dígitos, el `FittedBox` los achicaba todavía más.
  static const cifra = 14.0;

  /// Fila secundaria o sub-fila de desglose. Un escalón abajo de [cifra] para
  /// que la jerarquía se lea sin depender del color.
  static const cifraSub = 13.0;

  /// Texto de apoyo: encabezado de columna, subtítulo de tarjeta, hint,
  /// leyenda del gráfico. Acompaña a la cifra, no compite con ella.
  static const apoyo = 12.5;

  /// El piso. Rótulos de los ejes del gráfico y poco más — lo único donde el
  /// espacio es de verdad escaso porque hay una etiqueta cada pocos píxeles.
  ///
  /// **No usar para nada que el usuario tenga que leer con atención.**
  static const minimo = 11.0;
}

/// Debajo de este ancho, una tabla de cuatro columnas no entra y hay que
/// cambiar de forma en vez de encoger la letra.
///
/// Sale de una cuenta, no del gusto: en un teléfono de 360px la tarjeta tiene
/// ~272px útiles; con el rótulo ocupando 170, quedan **34px por columna**, y
/// "3.984.934,53 C\$" mide ~100px a [TxtResumen.cifra]. El `FittedBox` lo
/// escalaba al 34% — fuente efectiva de 5px, que es lo que el dueño fotografió.
///
/// Por encima de este ancho la tabla entra entera; por debajo, la fila se parte
/// en dos líneas y el monto va solo, en grande. Ninguna de las dos formas
/// abrevia ni esconde un dato.
const double kAnchoTablaCompleta = 420.0;

/// Alto FIJO de la fila de encabezados de las tablas del Resumen.
///
/// Existe porque desde el 2026-09-02 "Cobertura del ciclo" muestra DOS tablas
/// lado a lado, cada una a la mitad de ancho. Ahí un encabezado largo —"% de
/// las 56 cuotas"— envuelve a dos líneas en una tabla y no en la otra según el
/// largo del número, y eso hace más alta una cabecera que la otra: TODAS las
/// filas de esa tabla se corren respecto de la otra. Fue exactamente el bug de
/// 18px que el dueño reportó.
///
/// Con altura fija + `maxLines: 1` en los textos, las dos cabeceras miden lo
/// mismo pase lo que pase con el contenido, a cualquier ancho de pantalla.
const double kAltoCabeceraTabla = 18.0;
