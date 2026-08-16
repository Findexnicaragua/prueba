import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../data/services/impresora/recibo_escpos.dart';
import '../../data/services/impresora/windows_raw_printer.dart';
import '../../data/providers/impresora_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/impresora/sistema_impresora_service.dart';
import '../../data/utils/errores.dart';

/// Versión cacheada para estampar en los diagnósticos impresos (prueba y regla
/// de ancho). Se cachea porque `PackageInfo.fromPlatform()` cruza el canal de
/// plataforma y estos botones se tocan varias veces por sesión de soporte.
String? _versionCache;

/// Versión de la app (semver, sin build) para el papel. MISMA fuente que
/// `AppVersionLabel` y el `UpdateService` — `package_info_plus`, o sea el
/// `pubspec.yaml` — para que lo que sale impreso sea exactamente lo que Rubén
/// ve en el login/sidebar al verificar un build.
///
/// Devuelve null (= no se imprime la línea) si falla: un diagnóstico de
/// impresora NUNCA se cae por no poder leer su propia versión.
Future<String?> _versionApp() async {
  try {
    return _versionCache ??= (await PackageInfo.fromPlatform()).version;
  } catch (e) {
    if (kDebugMode) debugPrint('_versionApp: $e');
    return null;
  }
}

/// Configuración de impresora en DESKTOP (Windows): lista las impresoras del
/// SISTEMA operativo (USB, red, "Imprimir a PDF"...) y permite elegir una como
/// predeterminada + imprimir prueba. Es el equivalente desktop de
/// `ImpresoraSetupScreen` (Bluetooth), que queda intacta para mobile.
class ImpresoraSistemaSetup extends ConsumerStatefulWidget {
  const ImpresoraSistemaSetup({super.key});

  @override
  ConsumerState<ImpresoraSistemaSetup> createState() =>
      _ImpresoraSistemaSetupState();
}

class _ImpresoraSistemaSetupState extends ConsumerState<ImpresoraSistemaSetup> {
  bool _cargando = true;
  List<ImpresoraSistema> _impresoras = const [];
  String? _error;
  // Lock contra doble-tap por impresora (url) mientras imprime prueba.
  final Set<String> _probandoUrls = {};

  @override
  void initState() {
    super.initState();
    _refrescar();
  }

  Future<void> _refrescar() async {
    setState(() {
      _cargando = true;
      _error = null;
      _impresoras = const [];
    });
    try {
      _impresoras = await ref.read(sistemaImpresoraServiceProvider).listar();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _seleccionar(ImpresoraSistema p) async {
    await ref
        .read(impresoraSistemaFavoritaProvider.notifier)
        .guardar(p.url, p.nombre);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impresora "${p.nombre}" guardada')),
      );
    }
  }

  Future<void> _imprimirPrueba(ImpresoraSistema p) async {
    if (_probandoUrls.contains(p.url)) return;
    setState(() {
      _probandoUrls.add(p.url);
      _error = null;
    });
    final ancho = ref.read(appSettingsProvider).formatoReciboMm;
    final ajustarADriver =
        ref.read(impresoraAjustarADriverProvider).valueOrNull ?? false;
    // La prueba tiene que usar el MISMO camino que después imprime de verdad.
    // Si probara por driver y luego imprimiera en directo (o al revés), un
    // resultado bueno en la prueba no diría nada del recibo real.
    final aj = ref.read(ajustesImpresionWinProvider).valueOrNull ??
        AjustesImpresionWin.inicial;
    final directo = aj.modo != 'driver';
    try {
      // La versión va IMPRESA en la prueba: la foto que manda el usuario tiene
      // que decir sola de qué build salió, sin eso se discute si el papel es
      // del build viejo o del nuevo. No puede fallar ni frenar la impresión.
      final version = await _versionApp();
      final ok = directo
          ? await const WindowsRawPrinter().enviarBytes(
              nombreImpresora: p.nombre,
              bytes: [
                ...comandosDensidad(aj.tiempoCalor),
                ...comandosMargenIzquierdo(aj.margenDots),
                ...comandosPruebaEscPos(ancho, version: version),
              ],
              nombreTrabajo: 'Prueba',
            )
          : await ref.read(sistemaImpresoraServiceProvider).imprimirPrueba(
                url: p.url,
                nombre: p.nombre,
                anchoMm: ancho,
                ajustarADriver: ajustarADriver,
              );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(ok
                  ? 'Prueba enviada${directo ? ' (modo directo)' : ''}'
                  : directo
                      ? 'No imprimió: esta impresora no acepta el modo directo. '
                          'Apagalo y probá de nuevo.'
                      : 'No se pudo imprimir')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _probandoUrls.remove(p.url));
    }
  }

  @override
  Widget build(BuildContext context) {
    final favoritaAsync = ref.watch(impresoraSistemaFavoritaProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Impresora'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Buscar impresoras',
            onPressed: _refrescar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                favoritaAsync.when(
                  data: (f) => f == null
                      ? _FavoritaEmpty()
                      : _FavoritaCard(
                          nombre: f.nombre,
                          onLimpiar: () => ref
                              .read(impresoraSistemaFavoritaProvider.notifier)
                              .limpiar(),
                          onProbar: () => _imprimirPrueba(ImpresoraSistema(
                              url: f.url, nombre: f.nombre)),
                        ),
                  loading: () => const SizedBox.shrink(),
                  error: (e, _) => Text(mensajeErrorHumano(e)),
                ),
                const SizedBox(height: 16),
                const _AjustesWindows(),
                const _AjustarADriverToggle(),
                const SizedBox(height: 16),
                Text('Impresoras del sistema',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Son las impresoras que Windows tiene instaladas (USB, de red, '
                  'PDF). Si no ves la tuya, instalala/encendela y tocá refrescar.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                if (_impresoras.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'No se encontraron impresoras instaladas en este equipo.'),
                    ),
                  )
                else
                  ..._impresoras.map((p) => Card(
                        child: ListTile(
                          leading: Icon(
                            Icons.print,
                            color: p.disponible ? null : Theme.of(context)
                                .colorScheme
                                .outline,
                          ),
                          title: Text(p.nombre),
                          subtitle: Text(
                            [
                              if (p.esDefault) 'Predeterminada del sistema',
                              if (!p.disponible) 'No disponible',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (a) {
                              if (a == 'fav') _seleccionar(p);
                              if (a == 'test') _imprimirPrueba(p);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'fav',
                                child: Text('Usar como predeterminada'),
                              ),
                              PopupMenuItem(
                                value: 'test',
                                child: Text('Imprimir prueba'),
                              ),
                            ],
                          ),
                        ),
                      )),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// Toggle "Ajustar al driver" por-dispositivo (opt-in, default OFF, v0.24.8).
///
/// Solo aparece en desktop (Windows/Linux/macOS), donde la impresión pasa por
/// el paquete `printing`. Mobile con Bluetooth no muestra ni usa este flag.
///
/// - OFF (default): el PDF se manda con SU formato exacto (80/58mm, margen 0).
///   Arregla el bug de v0.24.1-v0.24.7 donde térmicas USB con driver mal
///   configurado (papel = Letter/A4) estiraban el PDF y CORTABAN la derecha.
/// - ON: el driver decide el ancho (`usePrinterSettings: true`, comportamiento
///   viejo). Escape hatch por si algún modelo raro lo necesita.
class _AjustarADriverToggle extends ConsumerWidget {
  const _AjustarADriverToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activo =
        ref.watch(impresoraAjustarADriverProvider).valueOrNull ?? false;
    return Card(
      child: SwitchListTile(
        title: const Text('Ajustar al driver',
            style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          activo
              ? 'El driver de la impresora decide el ancho del papel. Puede '
                  'cortar el recibo si el driver está mal configurado.'
              : 'El recibo se manda con el ancho exacto del rollo (80/58mm). '
                  'Recomendado. Solo activalo si tu impresora imprime en '
                  'blanco o el papel no avanza.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        value: activo,
        onChanged: (v) =>
            ref.read(impresoraAjustarADriverProvider.notifier).guardar(v),
      ),
    );
  }
}

/// Ajustes de impresión de ESTA PC. Solo Windows — en el resto no se dibuja.
///
/// Espeja el selector de modo que Android ya tiene por dispositivo, y suma los
/// tres controles que el camino por driver no dejaba tocar. Cada uno se calibra
/// mirando el papel con el botón de prueba, en vez de esperar una versión nueva.
class _AjustesWindows extends ConsumerWidget {
  const _AjustesWindows();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!WindowsRawPrinter.disponible) return const SizedBox.shrink();
    final aj =
        ref.watch(ajustesImpresionWinProvider).valueOrNull ??
            AjustesImpresionWin.inicial;
    final notifier = ref.read(ajustesImpresionWinProvider.notifier);
    final chico = Theme.of(context).textTheme.bodySmall;
    final ancho = ref.watch(appSettingsProvider).formatoReciboMm;
    final envioLento =
        ref.watch(impresoraEnvioLentoProvider).valueOrNull ?? false;
    final avanceCorte = ref.watch(impresoraAvanceCorteProvider).valueOrNull ?? 6;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Modo de impresión',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: aj.modo,
              onChanged: (v) =>
                  notifier.guardar(_conModo(aj, v ?? aj.modo)),
              child: Column(
                children: [
                  _radio('imagen', 'Imagen (recomendado)',
                      'Fiel a la vista previa: conserva el diseño, los tamaños '
                          'y el logo. En recibos MUY largos puede perder el pie: '
                          'para eso está "Impresión lenta" más abajo.'),
                  _radio('texto', 'Texto nativo',
                      'Letra uniforme de la impresora, liviano y SIEMPRE completo '
                          '(nunca pierde el pie, ni en recibos largos con mora). '
                          'Con logo, pero sin los tamaños del diseñador.'),
                  _radio('driver', 'Por driver de Windows',
                      'El camino anterior. Solo si la impresora no entiende los '
                          'otros dos.'),
                ],
              ),
            ),
            if (aj.modo != 'driver') ...[
              const Divider(height: 24),
              Text('Ajustes finos', style: chico?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              _slider(
                context,
                titulo: 'Margen izquierdo',
                valor: aj.margenMm,
                min: 0,
                max: 10,
                divisiones: 20,
                etiqueta: '${aj.margenMm.toStringAsFixed(1)} mm',
                ayuda: 'Cuánto se corre el texto del borde del papel.',
                onChanged: (v) => notifier.guardar(_conMargen(aj, v)),
              ),
              // Avance antes del corte: empuja el pie/slogan más allá de la
              // cuchilla (que está ~1cm sobre el cabezal) antes de cortar. Sin
              // esto el último bloque se pierde (se corta por arriba). Aplica a
              // imagen y texto.
              _slider(
                context,
                titulo: 'Avance antes del corte',
                valor: avanceCorte.toDouble(),
                min: 3,
                max: 15,
                divisiones: 12,
                etiqueta: '$avanceCorte líneas',
                ayuda: 'Si el slogan del pie sale cortado o aparece arriba del '
                    'recibo siguiente, subilo.',
                onChanged: (v) => ref
                    .read(impresoraAvanceCorteProvider.notifier)
                    .guardar(v.round()),
              ),
              // Estrategia de tildes: SOLO en texto nativo (el modo imagen
              // rasteriza con Skia y no depende del codepage de la impresora).
              //
              // Existía desde v0.22.22 pero solo se podía tocar desde la
              // pantalla de Bluetooth: en Windows quedaba clavada en la default
              // y una térmica sin esa tabla no tenía salida (campo 2026-07-31).
              if (aj.modo == 'texto') ...[
                _slider(
                  context,
                  titulo: 'Ancho de línea',
                  // Default VISIBLE = el que realmente usa el recibo (42), no el
                  // máximo del cabezal: si mostrara 48, "sin configurar" y "48
                  // elegido" se verían igual y el usuario no sabría cuál tiene.
                  valor: (aj.charsPorLinea ?? _kAnchoTextoDefault).toDouble(),
                  min: 28,
                  max: _charsAuto(ancho).toDouble(),
                  divisiones: _charsAuto(ancho) - 28,
                  etiqueta:
                      '${aj.charsPorLinea ?? _kAnchoTextoDefault} caracteres',
                  ayuda: 'Es el ancho REAL de tu impresora: medilo con "Imprimir '
                      'regla de ancho" (abajo) y cargá acá el número más alto que '
                      'salga completo.',
                  onChanged: (v) =>
                      notifier.guardar(_conChars(aj, v.round())),
                ),
                // MEDIR el ancho real de ESTA impresora en vez de estimarlo: la
                // regla imprime líneas de largo exacto conocido; el número más
                // alto que salga completo es el ancho real del cabezal, y se
                // carga en el slider de arriba. Sin esto, cada ajuste de ancho
                // es a ciegas (3 rondas perdidas con la 3nStar RPT004).
                const _ReglaAnchoBoton(),
                const SizedBox(height: 2),
                const Text('Tildes (acentos)',
                    style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                const _TildesSelector(),
                const SizedBox(height: 12),
              ],
              if (aj.modo == 'imagen')
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: aj.imagenCompatible,
                  title: const Text('Compatibilidad de imagen'),
                  subtitle: Text(
                    aj.imagenCompatible
                        ? 'Se manda el recibo con el comando de imagen viejo.'
                        : 'Encendelo si en vez del recibo sale una tira de '
                            'caracteres sueltos: esa impresora no entiende el '
                            'comando de imagen moderno.',
                    style: chico,
                  ),
                  onChanged: (v) => notifier.guardar(_conImgCompat(aj, v)),
                ),
              if (aj.modo == 'imagen')
                _slider(
                  context,
                  titulo: 'Grosor del texto',
                  valor: aj.umbral,
                  min: 0.45,
                  max: 0.85,
                  divisiones: 8,
                  etiqueta: aj.umbral <= 0.5
                      ? 'fino'
                      : (aj.umbral >= 0.75 ? 'muy grueso' : 'grueso'),
                  ayuda: 'Si la letra se ve apagada, subilo. De más, los '
                      'trazos se pegan.',
                  onChanged: (v) => notifier.guardar(_conUmbral(aj, v)),
                ),
              // Envío lento: SOLO imagen. Dosifica el raster por bandas con
              // pausas para que las térmicas USB con buffer chico (3nStar RPT004)
              // no pierdan el final del recibo en tiradas largas. Reusa el MISMO
              // provider por-dispositivo que el envío lento de Bluetooth.
              if (aj.modo == 'imagen')
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: envioLento,
                  title: const Text('Impresión lenta'),
                  subtitle: Text(
                    envioLento
                        ? 'El recibo se manda en partes con pausas. Un poco más '
                            'lento, pero evita que se corte el final en recibos '
                            'largos.'
                        : 'Encendelo si en recibos largos (con lista de mora) el '
                            'final —el pie o el slogan— sale en blanco o cortado.',
                    style: chico,
                  ),
                  onChanged: (v) => ref
                      .read(impresoraEnvioLentoProvider.notifier)
                      .guardar(v),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: aj.tiempoCalor != null,
                title: const Text('Forzar densidad del cabezal'),
                subtitle: Text(
                  aj.tiempoCalor == null
                      ? 'Apagado: se usa la densidad de fábrica. Encendelo solo '
                          'si el papel sale gris con el grosor al máximo.'
                      : 'Calor ${aj.tiempoCalor} — más alto, más negro. Si salen '
                          'garabatos, apagalo: esa impresora no lo soporta.',
                  style: chico,
                ),
                onChanged: (v) =>
                    notifier.guardar(_conCalor(aj, v ? 80 : null)),
              ),
              if (aj.tiempoCalor != null)
                _slider(
                  context,
                  titulo: 'Calor',
                  valor: aj.tiempoCalor!.toDouble(),
                  min: 20,
                  max: 200,
                  divisiones: 18,
                  etiqueta: '${aj.tiempoCalor}',
                  ayuda: '',
                  onChanged: (v) =>
                      notifier.guardar(_conCalor(aj, v.round())),
                ),
            ],
            const SizedBox(height: 4),
            Text(
              'Estos ajustes son de ESTA computadora. No afectan a los celulares '
              'ni a las otras PCs.',
              style: chico,
            ),
          ],
        ),
      ),
    );
  }

  Widget _radio(String valor, String titulo, String detalle) => RadioListTile<String>(
        value: valor,
        contentPadding: EdgeInsets.zero,
        title: Text(titulo),
        subtitle: Text(detalle, style: const TextStyle(fontSize: 12)),
      );

  Widget _slider(
    BuildContext context, {
    required String titulo,
    required double valor,
    required double min,
    required double max,
    required int divisiones,
    required String etiqueta,
    required String ayuda,
    required ValueChanged<double> onChanged,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(titulo, style: const TextStyle(fontSize: 13)),
              Text(etiqueta,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
          Slider(
            value: valor.clamp(min, max),
            min: min,
            max: max,
            divisions: divisiones,
            onChanged: onChanged,
          ),
          if (ayuda.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(ayuda, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      );

  AjustesImpresionWin _conModo(AjustesImpresionWin a, String m) =>
      AjustesImpresionWin(
          modo: m,
          margenMm: a.margenMm,
          umbral: a.umbral,
          tiempoCalor: a.tiempoCalor,
          charsPorLinea: a.charsPorLinea,
          imagenCompatible: a.imagenCompatible);
  AjustesImpresionWin _conMargen(AjustesImpresionWin a, double v) =>
      AjustesImpresionWin(
          modo: a.modo,
          margenMm: v,
          umbral: a.umbral,
          tiempoCalor: a.tiempoCalor,
          charsPorLinea: a.charsPorLinea,
          imagenCompatible: a.imagenCompatible);
  AjustesImpresionWin _conUmbral(AjustesImpresionWin a, double v) =>
      AjustesImpresionWin(
          modo: a.modo,
          margenMm: a.margenMm,
          umbral: v,
          tiempoCalor: a.tiempoCalor,
          charsPorLinea: a.charsPorLinea,
          imagenCompatible: a.imagenCompatible);
  AjustesImpresionWin _conCalor(AjustesImpresionWin a, int? v) =>
      AjustesImpresionWin(
          modo: a.modo,
          margenMm: a.margenMm,
          umbral: a.umbral,
          tiempoCalor: v,
          charsPorLinea: a.charsPorLinea,
          imagenCompatible: a.imagenCompatible);
  AjustesImpresionWin _conChars(AjustesImpresionWin a, int v) =>
      AjustesImpresionWin(
          modo: a.modo,
          margenMm: a.margenMm,
          umbral: a.umbral,
          tiempoCalor: a.tiempoCalor,
          charsPorLinea: v,
          imagenCompatible: a.imagenCompatible);
  AjustesImpresionWin _conImgCompat(AjustesImpresionWin a, bool v) =>
      AjustesImpresionWin(
          modo: a.modo,
          margenMm: a.margenMm,
          umbral: a.umbral,
          tiempoCalor: a.tiempoCalor,
          charsPorLinea: a.charsPorLinea,
          imagenCompatible: v);

  /// Máximo de caracteres que entran a lo ancho: es el default de la librería
  /// ESC/POS para ese rollo (48 en 80mm, 32 en 58mm) y equivale al cabezal
  /// ENTERO, sin margen.
  static int _charsAuto(int anchoMm) => anchoMm >= 80 ? 48 : 32;
}

/// Ancho de línea por defecto del modo texto en Windows — DEBE coincidir con
/// `kColsTextoWin` de `recibo_screen.dart` (lo que realmente se imprime), para
/// que el slider muestre el ancho REAL y no el máximo del cabezal.
const int _kAnchoTextoDefault = 42;

/// Botón "Imprimir regla de ancho": manda a la impresora predeterminada una
/// tira con líneas de largo EXACTO conocido (`comandosReglaAnchoEscPos`), cada
/// una terminada en su número. El número más alto que salga COMPLETO es el ancho
/// real del cabezal de ESA impresora → se carga en "Ancho de línea" y el recibo
/// deja de recortarse. Mide el hardware en vez de suponerlo.
class _ReglaAnchoBoton extends ConsumerStatefulWidget {
  const _ReglaAnchoBoton();
  @override
  ConsumerState<_ReglaAnchoBoton> createState() => _ReglaAnchoBotonState();
}

class _ReglaAnchoBotonState extends ConsumerState<_ReglaAnchoBoton> {
  bool _enviando = false;

  Future<void> _imprimir() async {
    final fav = ref.read(impresoraSistemaFavoritaProvider).valueOrNull;
    if (fav == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Elegí primero una impresora predeterminada.')));
      return;
    }
    setState(() => _enviando = true);
    try {
      final ancho = ref.read(appSettingsProvider).formatoReciboMm;
      // Igual que la prueba: la regla se lee por FOTO, así que el papel tiene
      // que declarar de qué build salió.
      final version = await _versionApp();
      final ok = await const WindowsRawPrinter().enviarBytes(
        nombreImpresora: fav.nombre,
        bytes: comandosReglaAnchoEscPos(ancho, version: version),
        nombreTrabajo: 'Regla de ancho',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok
                ? 'Regla enviada: mirá el número más alto que salió completo.'
                : 'No se pudo imprimir la regla.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mensajeErrorHumano(e))));
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            icon: _enviando
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.straighten, size: 18),
            label: const Text('Imprimir regla de ancho'),
            onPressed: _enviando ? null : _imprimir,
          ),
          const SizedBox(height: 4),
          Text(
            'Imprime líneas numeradas. El número más alto que salga COMPLETO es '
            'el ancho real de esta impresora: cargalo arriba en "Ancho de línea" '
            'y el recibo deja de cortarse.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Selector de estrategia de acentos del modo texto nativo. Es el MISMO
/// provider por-dispositivo que usa el modo compatible de Bluetooth
/// (`impresoraTildesModoProvider`): no se duplica el estado ni la semántica,
/// solo faltaba el control en esta pantalla.
class _TildesSelector extends ConsumerWidget {
  const _TildesSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modo = ref.watch(impresoraTildesModoProvider).valueOrNull ?? 'cp850';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Scroll horizontal: 4 segmentos pueden no entrar en una ventana
        // angosta → sin esto sería un RenderFlex overflow. En pantalla ancha se
        // ven los 4 sin scroll.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: 'ascii', label: Text('Sin tildes')),
              // "Alternativo" (no "Acentos"): mismo rótulo que la pantalla de
              // Bluetooth — es el MISMO provider. Además "Acentos" confundía:
              // Estándar y Occidental TAMBIÉN dan acentos; lo distinto de este
              // modo es CÓMO los consigue (alfabeto nativo de la impresora).
              ButtonSegment(value: 'gbk', label: Text('Alternativo')),
              ButtonSegment(value: 'cp850', label: Text('Estándar')),
              ButtonSegment(value: 'latin1', label: Text('Occidental')),
            ],
            selected: {modo},
            onSelectionChanged: (sel) => ref
                .read(impresoraTildesModoProvider.notifier)
                .guardar(sel.first),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          switch (modo) {
            'gbk' => 'Acentos y ñ reales, en el alfabeto nativo de la impresora '
                '(para las que ignoran las tablas occidentales, como la 3nStar). '
                'Las vocales con tilde salen un poco más anchas.',
            'latin1' => 'Tabla occidental de Windows. Probá esta si con '
                'Estándar las tildes salen como símbolos raros.',
            'cp850' => 'Tabla internacional. Solo si tu impresora respeta las '
                'tablas occidentales (muchas térmicas USB no).',
            _ => 'Imprime sin acentos (a, e, i, o, u, n). Infalible en cualquier '
                'impresora y alinea perfecto. Recomendado en esta PC.',
          },
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _FavoritaEmpty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.info_outline),
            SizedBox(width: 12),
            Expanded(
                child: Text(
                    'Sin impresora predeterminada. Elegí una de la lista de abajo.')),
          ],
        ),
      ),
    );
  }
}

class _FavoritaCard extends StatelessWidget {
  const _FavoritaCard({
    required this.nombre,
    required this.onLimpiar,
    required this.onProbar,
  });
  final String nombre;
  final VoidCallback onLimpiar;
  final VoidCallback onProbar;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Impresora predeterminada',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.check_circle),
                const SizedBox(width: 8),
                Expanded(child: Text(nombre)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.print),
                    label: const Text('Prueba'),
                    onPressed: onProbar,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.link_off),
                    label: const Text('Quitar'),
                    onPressed: onLimpiar,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
