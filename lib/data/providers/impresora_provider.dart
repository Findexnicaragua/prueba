import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/impresora/impresora_service.dart';
import '../services/impresora/sistema_impresora_service.dart';
import '../services/impresora/windows_raw_printer.dart';

final impresoraServiceProvider = Provider((_) => ImpresoraService());

/// True en desktop NATIVO (Windows/Linux/macOS): la impresión pasa por las
/// impresoras del SISTEMA operativo (paquete `printing`), no por Bluetooth. En
/// mobile es false → sigue con `print_bluetooth_thermal` (path del cobrador
/// intacto). En web es false. Se usa `defaultTargetPlatform` (web-safe, sin
/// `dart:io`) gateado por `kIsWeb`.
bool get impresionPorSistema =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

final sistemaImpresoraServiceProvider =
    Provider((_) => SistemaImpresoraService());

/// Impresora del SISTEMA elegida (desktop), persistida por dispositivo. Es
/// PARALELA a `impresoraFavoritaProvider` (Bluetooth) — claves distintas, así el
/// móvil no se ve afectado.
class ImpresoraSistemaFavorita {
  const ImpresoraSistemaFavorita({required this.url, required this.nombre});
  final String url;
  final String nombre;
}

final impresoraSistemaFavoritaProvider = AsyncNotifierProvider<
    ImpresoraSistemaFavoritaNotifier, ImpresoraSistemaFavorita?>(
  ImpresoraSistemaFavoritaNotifier.new,
);

class ImpresoraSistemaFavoritaNotifier
    extends AsyncNotifier<ImpresoraSistemaFavorita?> {
  static const _keyUrl = 'impresora_sistema_url';
  static const _keyNombre = 'impresora_sistema_nombre';

  @override
  Future<ImpresoraSistemaFavorita?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_keyUrl);
    final nombre = prefs.getString(_keyNombre);
    if (url == null || nombre == null) return null;
    return ImpresoraSistemaFavorita(url: url, nombre: nombre);
  }

  Future<void> guardar(String url, String nombre) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUrl, url);
    await prefs.setString(_keyNombre, nombre);
    state = AsyncData(ImpresoraSistemaFavorita(url: url, nombre: nombre));
  }

  Future<void> limpiar() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUrl);
    await prefs.remove(_keyNombre);
    state = const AsyncData(null);
  }
}

/// Ajustes de impresión de ESTA PC. **Solo Windows** — en Android ni siquiera
/// se construyen (todos los getters cortan por `WindowsRawPrinter.disponible`)
/// y la sección no se dibuja.
///
/// Espeja el modelo de Android (`impresoraModoProvider`, por dispositivo) y le
/// agrega los ajustes finos que el camino por driver no permitía tocar:
///   · `driver`  — PDF al driver de Windows (el camino viejo; queda de respaldo)
///   · `imagen`  — raster ESC/POS del recibo. Fidelidad exacta a la vista previa
///   · `texto`   — texto nativo ESC/POS: usa la fuente INTERNA de la impresora,
///                 negro pleno sin suavizado ni umbral. Reusa
///                 `construirReciboTextoEscPos` SIN modificarlo (es el mismo
///                 constructor que usa Android).
class AjustesImpresionWin {
  const AjustesImpresionWin({
    required this.modo,
    required this.margenMm,
    required this.umbral,
    required this.tiempoCalor,
    this.charsPorLinea,
    this.imagenCompatible = false,
  });

  final String modo; // driver | imagen | texto
  final double margenMm; // margen izquierdo
  final double umbral; // 0.5 = como Android; más alto = trazo más grueso
  final int? tiempoCalor; // null = no tocar la densidad de fábrica

  /// Caracteres por línea del modo TEXTO. null = el default de la librería
  /// (48 en 80mm), que son 576 puntos = el ancho EXACTO del cabezal, sin un
  /// solo punto de margen. Si la impresora reserva un margen propio, los
  /// últimos caracteres caen fuera del papel y la línea sale cortada a la
  /// derecha ("Recibo Nº: OF-117…" — fotos del campo 2026-07-31). Bajarlo es
  /// lo que devuelve el borde derecho.
  final int? charsPorLinea;

  /// Modo IMAGEN: emitir el bitmap con `ESC *` (comando viejo, línea por línea)
  /// en vez de `GS v 0`. Para las térmicas que reciben el raster moderno y lo
  /// imprimen como caracteres sueltos en vez de dibujarlo.
  final bool imagenCompatible;

  /// Margen en dots del cabezal (203 dpi).
  int get margenDots => (margenMm / 25.4 * 203).round();

  static const inicial = AjustesImpresionWin(
    // 'imagen' de default: conserva el diseño del recibo. Con el umbral algo
    // más alto que Android, para que el texto no salga fino en PC.
    modo: 'imagen',
    margenMm: 3,
    umbral: 0.62,
    tiempoCalor: null,
  );
}

final ajustesImpresionWinProvider =
    AsyncNotifierProvider<AjustesImpresionWinNotifier, AjustesImpresionWin>(
  AjustesImpresionWinNotifier.new,
);

class AjustesImpresionWinNotifier extends AsyncNotifier<AjustesImpresionWin> {
  // Claves con prefijo `win_`: no las comparte con nada de Android.
  static const _kModo = 'impresora_win_modo';
  static const _kMargen = 'impresora_win_margen_mm';
  static const _kUmbral = 'impresora_win_umbral';
  static const _kCalor = 'impresora_win_tiempo_calor';
  static const _kChars = 'impresora_win_chars_linea';
  static const _kImgCompat = 'impresora_win_imagen_compatible';
  // Migración del toggle booleano anterior (v0.29.6).
  static const _kLegacyDirecto = 'impresora_sistema_modo_directo';
  // Migración única texto→imagen (v0.31.15).
  static const _kMigradoImagen = 'impresora_win_migrado_imagen_v1';
  // Migración única del ancho de línea heredado (ver `_sinAnchoALaCiega`).
  static const _kMigradoAncho = 'impresora_win_migrado_ancho_v1';

  @override
  Future<AjustesImpresionWin> build() async {
    if (!WindowsRawPrinter.disponible) return AjustesImpresionWin.inicial;
    final p = await SharedPreferences.getInstance();
    final legacy = p.getBool(_kLegacyDirecto);
    // Si nunca se configuró el modo pero existía el toggle viejo, se respeta:
    // true → imagen (lo que hacía), false → driver.
    var modo = p.getString(_kModo) ??
        (legacy == null
            ? AjustesImpresionWin.inicial.modo
            : (legacy ? 'imagen' : 'driver'));
    // Migración única (v0.31.15): el modo TEXTO nativo corta a la derecha en las
    // térmicas USB (asume el ancho nominal completo del cabezal, que la impresora
    // no imprime) y NO puede llevar margen izquierdo (ignora GS L). El modo IMAGEN
    // sí. A los que quedaron en texto se los pasa a imagen UNA sola vez (si lo
    // re-eligen a mano después, se respeta).
    if (!(p.getBool(_kMigradoImagen) ?? false)) {
      if (modo == 'texto') {
        modo = 'imagen';
        await p.setString(_kModo, 'imagen');
      }
      await p.setBool(_kMigradoImagen, true);
    }
    return AjustesImpresionWin(
      modo: modo,
      margenMm: p.getDouble(_kMargen) ?? AjustesImpresionWin.inicial.margenMm,
      umbral: p.getDouble(_kUmbral) ?? AjustesImpresionWin.inicial.umbral,
      tiempoCalor: p.getInt(_kCalor),
      // El ancho guardado ahora MANDA (antes solo se aplicaba si era menor al
      // default). Un 46-48 viejo solo pudo setearse a ciegas —el slider mostraba
      // 48 aunque nunca se hubiera tocado y el valor no tenía efecto—; aplicarlo
      // ahora cortaría el recibo. Se descarta una vez: el usuario vuelve a medir
      // con la "regla de ancho" y carga el número real.
      charsPorLinea: _sinAnchoALaCiega(p.getInt(_kChars), p),
      imagenCompatible: p.getBool(_kImgCompat) ?? false,
    );
  }

  /// Descarta (una sola vez) un ancho de línea >= 46 heredado: con el
  /// comportamiento viejo ese valor no se aplicaba, así que no es una elección
  /// informada del usuario y hoy le cortaría el recibo.
  static int? _sinAnchoALaCiega(int? chars, SharedPreferences p) {
    if (chars == null || chars < 46) return chars;
    if (p.getBool(_kMigradoAncho) ?? false) return chars;
    p.setBool(_kMigradoAncho, true);
    p.remove(_kChars);
    return null;
  }

  Future<void> guardar(AjustesImpresionWin a) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kModo, a.modo);
    await p.setDouble(_kMargen, a.margenMm);
    await p.setDouble(_kUmbral, a.umbral);
    if (a.tiempoCalor == null) {
      await p.remove(_kCalor);
    } else {
      await p.setInt(_kCalor, a.tiempoCalor!);
    }
    if (a.charsPorLinea == null) {
      await p.remove(_kChars);
    } else {
      await p.setInt(_kChars, a.charsPorLinea!);
    }
    await p.setBool(_kImgCompat, a.imagenCompatible);
    state = AsyncData(a);
  }
}

/// ¿Esta PC imprime el recibo en MODO DIRECTO (ESC/POS crudo a la cola de
/// Windows) en vez de mandarle un PDF al driver?
///
/// Vive por DISPOSITIVO, no por tenant: el problema es del driver instalado en
/// esa máquina, y en el mismo local puede haber una PC con una térmica que
/// entiende ESC/POS y otra con una impresora común que no.
///
/// Default OFF a propósito. El transporte de impresión ya rompió a la flota una
/// vez por cambiar el camino compartido para arreglar un modelo (v0.22.10-13):
/// acá cada impresora se pasa al modo nuevo recién cuando la prueba sale bien
/// en esa impresora.
final modoDirectoImpresoraProvider =
    AsyncNotifierProvider<ModoDirectoImpresoraNotifier, bool>(
  ModoDirectoImpresoraNotifier.new,
);

class ModoDirectoImpresoraNotifier extends AsyncNotifier<bool> {
  static const _key = 'impresora_sistema_modo_directo';

  @override
  Future<bool> build() async {
    if (!WindowsRawPrinter.disponible) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> set(bool valor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, valor);
    state = AsyncData(valor);
  }
}

/// Impresora favorita persistida en SharedPreferences (por dispositivo).
class ImpresoraFavorita {
  const ImpresoraFavorita({required this.mac, required this.nombre});
  final String mac;
  final String nombre;
}

final impresoraFavoritaProvider =
    AsyncNotifierProvider<ImpresoraFavoritaNotifier, ImpresoraFavorita?>(
  ImpresoraFavoritaNotifier.new,
);

class ImpresoraFavoritaNotifier extends AsyncNotifier<ImpresoraFavorita?> {
  static const _keyMac = 'impresora_mac';
  static const _keyNombre = 'impresora_nombre';

  @override
  Future<ImpresoraFavorita?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final mac = prefs.getString(_keyMac);
    final nombre = prefs.getString(_keyNombre);
    if (mac == null || nombre == null) return null;
    return ImpresoraFavorita(mac: mac, nombre: nombre);
  }

  Future<void> guardar(String mac, String nombre) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMac, mac);
    await prefs.setString(_keyNombre, nombre);
    state = AsyncData(ImpresoraFavorita(mac: mac, nombre: nombre));
  }

  Future<void> limpiar() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyMac);
    await prefs.remove(_keyNombre);
    state = const AsyncData(null);
  }
}

/// Modo de impresión elegido en ESTE dispositivo (por-dispositivo, SharedPrefs).
/// Solo tiene efecto si el super_admin habilitó AMBOS modos en el tenant. Valores:
/// `imagen` (default) | `compatible`. La resolución final (qué modo usar) la hace
/// el call-site combinando esto con los flags del tenant.
final impresoraModoProvider =
    AsyncNotifierProvider<ImpresoraModoNotifier, String>(
  ImpresoraModoNotifier.new,
);

class ImpresoraModoNotifier extends AsyncNotifier<String> {
  static const _key = 'impresora_modo';

  @override
  Future<String> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) ?? 'imagen';
  }

  Future<void> guardar(String modo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, modo);
    state = AsyncData(modo);
  }
}

/// ENVÍO LENTO en ESTE dispositivo (por-device, opt-in, default OFF).
/// Para impresoras lentas/baratas (3nStar) que pierden el FINAL del recibo
/// (el pie sale en blanco): manda los bytes en chunks con pausas + espera
/// antes de desconectar. Con OFF el transporte es byte-idéntico al de siempre
/// (lección v0.22.10-13: nunca tocar el path global por un modelo).
final impresoraEnvioLentoProvider =
    AsyncNotifierProvider<ImpresoraEnvioLentoNotifier, bool>(
  ImpresoraEnvioLentoNotifier.new,
);

class ImpresoraEnvioLentoNotifier extends AsyncNotifier<bool> {
  static const _key = 'impresora_envio_lento';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> guardar(bool valor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, valor);
    state = AsyncData(valor);
  }
}

/// AJUSTAR AL DRIVER (PC/desktop, por-device, opt-in, default OFF).
///
/// Solo aplica a la impresión por SISTEMA (Windows/Linux/macOS — el paquete
/// `printing`). Mobile con Bluetooth NO se ve afectado.
///
/// - OFF (default, v0.24.8): el PDF se manda con SU formato exacto (80/58mm,
///   margen 0) y el driver de la impresora debe respetarlo. Arregla el bug
///   donde algunas térmicas USB con driver mal configurado (papel = Letter/A4)
///   estiraban el PDF y CORTABAN la mitad derecha del recibo.
/// - ON: el paquete `printing` ignora el `PdfPageFormat` y usa la config del
///   driver (`usePrinterSettings: true`). Escape hatch por si algún modelo
///   raro sí necesita que el driver decida (v0.24.1-v0.24.7 andaba con ON,
///   funcionaba en la mayoría — algunas se rompían).
final impresoraAjustarADriverProvider =
    AsyncNotifierProvider<ImpresoraAjustarADriverNotifier, bool>(
  ImpresoraAjustarADriverNotifier.new,
);

class ImpresoraAjustarADriverNotifier extends AsyncNotifier<bool> {
  static const _key = 'impresora_ajustar_a_driver';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> guardar(bool valor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, valor);
    state = AsyncData(valor);
  }
}

/// Estrategia de TILDES del modo COMPATIBLE en ESTE dispositivo (por-device):
///  - `'cp850'` (default): acentos vía codepage occidental (requiere que la
///    impresora respete la cancelación del modo chino).
///  - `'gbk'`: acentos codificados en el alfabeto NATIVO de las impresoras
///    chinas (zona pinyin de GB2312) — para firmware cableado a GBK que ignora
///    el FS . (caso 3nStar). El acento sale REAL, un poco más ancho.
///  - `'ascii'`: sin acentos (á→a). Infalible en cualquier firmware.
final impresoraTildesModoProvider =
    AsyncNotifierProvider<ImpresoraTildesModoNotifier, String>(
  ImpresoraTildesModoNotifier.new,
);

/// AVANCE ANTES DEL CORTE en líneas (Windows/USB, por-device). La cuchilla de
/// las térmicas está ~1-1.5 cm ARRIBA del cabezal: si no se avanza el papel esa
/// distancia antes de cortar, el ÚLTIMO bloque (pie/slogan) queda ATRAPADO entre
/// el cabezal y la cuchilla → la cuchilla corta por ARRIBA de él y se pierde
/// (aparece "cortado", reaparece en el tope del recibo siguiente). Más líneas =
/// el pie supera la cuchilla antes del corte. Default 6 (~22 mm) cubre el gap
/// típico. Android/BT usa su default de 2 (no se toca — byte-idéntico).
final impresoraAvanceCorteProvider =
    AsyncNotifierProvider<ImpresoraAvanceCorteNotifier, int>(
  ImpresoraAvanceCorteNotifier.new,
);

class ImpresoraAvanceCorteNotifier extends AsyncNotifier<int> {
  static const _key = 'impresora_win_avance_corte';
  static const _default = 6;

  @override
  Future<int> build() async {
    if (!WindowsRawPrinter.disponible) return 2;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key) ?? _default;
  }

  Future<void> guardar(int lineas) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, lineas);
    state = AsyncData(lineas);
  }
}

class ImpresoraTildesModoNotifier extends AsyncNotifier<String> {
  static const _key = 'impresora_tildes_modo';
  static const _keyLegacy = 'impresora_tildes'; // bool de v0.22.22

  @override
  Future<String> build() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    if (v != null) return v;
    // Migración del toggle bool de v0.22.22: apagado == sin tildes.
    if (prefs.getBool(_keyLegacy) == false) return 'ascii';
    // Windows/USB: las térmicas de la flota (3nStar RPT004) IGNORAN el FS .
    // (cancelar modo chino) → cp850 corrompe cada acento ("Período"→garabato
    // que se traga la letra siguiente). ascii (transliterado, 0 bytes altos) es
    // infalible y además alinea perfecto (cada glifo = 12 dots exactos). Android
    // (Bluetooth) mantiene cp850, que sí funciona en sus térmicas. Quien quiera
    // acentos REALES en PC elige 'gbk' a mano en el selector.
    if (WindowsRawPrinter.disponible) return 'ascii';
    return 'cp850';
  }

  Future<void> guardar(String modo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, modo);
    state = AsyncData(modo);
  }
}
