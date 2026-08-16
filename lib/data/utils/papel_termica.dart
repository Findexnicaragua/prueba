/// Geometría del papel térmico para el camino de impresión de ESCRITORIO.
///
/// Tres hallazgos de producción encadenados. El tercero corrige al segundo:
///
/// **1. El cabezal no imprime todo el rollo.** En uno de 80mm alcanza 576 dots
/// = 72,07mm. Los ~7,9mm restantes son zona MUERTA — física, del mecanismo, no
/// hay ajuste de driver que la recupere.
///
/// **2. La página tiene que caer en dots ENTEROS.** El plugin de Windows escala
/// por `LOGPIXELSX / 72`. Una página de 80mm da 639,37 dots: fraccionario, así
/// que cada glifo se reescala y sale gris en vez de negro.
///
/// **3. La página tiene que medir lo que mide el PAPEL.** *(2026-07-29, la
/// lección cara.)* El intento anterior hizo la página del ancho IMPRIMIBLE
/// (72,07mm, dots exactos): arregló la calidad, pero el driver la apoyó en el
/// borde del papel en vez de donde arranca el cabezal, y los primeros 3,96mm
/// cayeron en zona muerta → **empezó a cortar por la IZQUIERDA** lo que antes
/// cortaba por la derecha. Se corrigió un lado y se rompió el otro.
///
/// La salida es no depender de dónde apoya el driver: **la página mide lo mismo
/// que el papel** (80,08mm = 640 dots exactos), y el contenido se mete 32 dots
/// de cada lado para caer justo en los 576 que el cabezal imprime. Una página
/// del tamaño del papel no se puede correr — la apoye a la izquierda o la
/// centre, cae en el mismo lugar. Y 640 sigue siendo entero, así que la nitidez
/// del punto 2 se conserva.
///
/// Las constantes de dots imprimibles son las MISMAS que usa el camino térmico
/// (`impresora_service_io.dart`: `anchoMm >= 80 ? 576 : 384`). Ese archivo NO se
/// toca: es el path de raster/transporte que ya rompió a la flota una vez
/// (v0.22.10-13). Se replican acá para que el camino PDF deje de contradecirlo.
library;

const double _dpiTermica = 203;
const double _puntosPorPulgada = 72;

/// Dots que el cabezal IMPRIME, según el rollo, a 203 dpi.
const int _dotsImprimible80 = 576;
const int _dotsImprimible58 = 384;

/// Dots del ANCHO FÍSICO del papel, redondeados al entero más cercano.
/// 640 dots = 80,08mm (rollo de 80) · 464 dots = 58,06mm (rollo de 58).
/// Enteros a propósito: es lo que evita el reescalado que agrisa el texto.
const int _dotsPapel80 = 640;
const int _dotsPapel58 = 464;

bool _esRollo80(int anchoMm) => anchoMm >= 80;

int _dotsPapel(int anchoMm) => _esRollo80(anchoMm) ? _dotsPapel80 : _dotsPapel58;
int _dotsImprimible(int anchoMm) =>
    _esRollo80(anchoMm) ? _dotsImprimible80 : _dotsImprimible58;

double _aPuntos(int dots) => dots / _dpiTermica * _puntosPorPulgada;

/// Ancho de la PÁGINA del PDF, en puntos: el ancho FÍSICO del papel, en dots
/// enteros. 227,00pt (80,08mm) para el rollo de 80; 164,57pt (58,06mm) para
/// el de 58. Ver el punto 3 de la cabecera: que la página mida lo que el papel
/// es lo que hace que no importe dónde la apoye el driver.
double anchoPaginaPuntos(int anchoMm) => _aPuntos(_dotsPapel(anchoMm));

/// Margen horizontal del contenido dentro de la página, en puntos.
///
/// NO es estético: es exactamente la mitad de la zona muerta del cabezal, así
/// que el contenido cae dentro de los dots que el cabezal imprime. Da 11,35pt
/// (32 dots) en el rollo de 80 y 14,19pt (40 dots) en el de 58.
///
/// Asume que el cabezal está CENTRADO en el rollo, que es como vienen las
/// térmicas de 80/58. Si alguna impresora imprimiera descentrada, el síntoma
/// sería corte de un solo lado otra vez — y el arreglo es este número, no la
/// página.
double margenHorizontalPuntos(int anchoMm) =>
    _aPuntos((_dotsPapel(anchoMm) - _dotsImprimible(anchoMm)) ~/ 2);

/// Alto de página con el que se define el papel cuando no se pudo medir el
/// recibo real. NO puede ser infinito: el plugin lo mete en `dmPaperLength`
/// (décimas de mm, en un `short`) y convertir infinito a entero es
/// comportamiento indefinido — el `DEVMODE` sale corrupto y Windows lo descarta
/// entero, así que la app nunca llegaba a controlar el papel. Era la razón de
/// fondo por la que NINGÚN ajuste del driver cambiaba nada.
const double altoFallbackPuntos = 297 * 72 / 25.4;
