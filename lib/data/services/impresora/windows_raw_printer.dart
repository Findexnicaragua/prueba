import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// Envía bytes CRUDOS a una cola de impresión de Windows, sin pasar por el
/// driver gráfico.
///
/// ## Qué problema resuelve
///
/// El camino normal de escritorio genera un PDF y se lo entrega al driver, que
/// decide la escala y la posición según su configuración de papel — una
/// configuración que la app NO puede leer. En las térmicas de 80mm eso salía
/// como recibos cortados de un lado o del otro y texto opaco (el opaco es la
/// firma del reescalado). Tres intentos de calibrar la geometría a ciegas
/// movieron el corte de lado sin resolverlo, porque el problema no era la
/// geometría sino depender de un número invisible.
///
/// Acá se manda el raster ESC/POS ya resuelto a los dots exactos del cabezal,
/// que es lo que hace Android por Bluetooth desde siempre y sale perfecto.
/// Windows actúa de cañería: `RAW` significa "no interpretes, pasá los bytes".
///
/// ## Cuándo NO sirve
///
/// La impresora tiene que entender ESC/POS. Las térmicas de 58/80mm lo hacen
/// (es su lenguaje nativo), pero una impresora que SOLO habla el lenguaje de su
/// driver (algunas "GDI/host-based") recibiría los bytes y no imprimiría nada.
/// Por eso el modo es OPT-IN y con botón de prueba: se verifica en la impresora
/// real en vez de asumirlo.
///
/// ## Por qué no se toca el camino viejo
///
/// El transporte de impresión ya rompió a la flota una vez por "arreglar" un
/// modelo puntual tocando el path compartido (v0.22.10-13). Este servicio se
/// AGREGA; el PDF por driver sigue siendo el default hasta que cada impresora
/// se pruebe.
class WindowsRawPrinter {
  const WindowsRawPrinter();

  /// True solo en Windows: el resto de las plataformas no tiene esta API.
  static bool get disponible =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Manda [bytes] tal cual a la cola [nombreImpresora] (el nombre que muestra
  /// Windows en la lista de impresoras). Devuelve false ante cualquier fallo,
  /// nunca lanza: imprimir no puede tumbar la pantalla del recibo.
  ///
  /// [nombreTrabajo] es lo que aparece en la cola de impresión de Windows.
  Future<bool> enviarBytes({
    required String nombreImpresora,
    required List<int> bytes,
    String nombreTrabajo = 'Recibo',
  }) async {
    if (!disponible) return false;
    if (nombreImpresora.isEmpty || bytes.isEmpty) return false;

    // Todo el bloque corre con punteros nativos: cada `allocate` necesita su
    // `free`, y el handle su `ClosePrinter`, pase lo que pase. De ahí el
    // finally anidado — una fuga acá se acumula en cada impresión.
    final nombrePtr = nombreImpresora.toNativeUtf16();
    final trabajoPtr = nombreTrabajo.toNativeUtf16();
    final tipoPtr = 'RAW'.toNativeUtf16();
    final handlePtr = calloc<HANDLE>();
    final escritosPtr = calloc<DWORD>();
    final docInfo = calloc<DOC_INFO_1>();
    Pointer<Uint8>? datos;

    try {
      if (OpenPrinter(nombrePtr, handlePtr, nullptr) == 0) {
        if (kDebugMode) {
          debugPrint('WindowsRawPrinter: no se pudo abrir "$nombreImpresora"');
        }
        return false;
      }
      final handle = handlePtr.value;
      try {
        docInfo.ref
          ..pDocName = trabajoPtr
          ..pOutputFile = nullptr
          ..pDatatype = tipoPtr;

        // StartDocPrinter devuelve el id del trabajo; 0 = error.
        if (StartDocPrinter(handle, 1, docInfo) == 0) {
          if (kDebugMode) debugPrint('WindowsRawPrinter: StartDocPrinter falló');
          return false;
        }
        try {
          if (StartPagePrinter(handle) == 0) {
            if (kDebugMode) {
              debugPrint('WindowsRawPrinter: StartPagePrinter falló');
            }
            return false;
          }
          try {
            datos = calloc<Uint8>(bytes.length);
            datos.asTypedList(bytes.length).setAll(0, bytes);
            final ok = WritePrinter(handle, datos, bytes.length, escritosPtr);
            final escritos = escritosPtr.value;
            if (ok == 0 || escritos != bytes.length) {
              if (kDebugMode) {
                debugPrint('WindowsRawPrinter: escribió $escritos de '
                    '${bytes.length} bytes');
              }
              return false;
            }
            return true;
          } finally {
            EndPagePrinter(handle);
          }
        } finally {
          EndDocPrinter(handle);
        }
      } finally {
        ClosePrinter(handle);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('WindowsRawPrinter: $e');
      return false;
    } finally {
      if (datos != null) calloc.free(datos);
      calloc
        ..free(docInfo)
        ..free(escritosPtr)
        ..free(handlePtr);
      malloc
        ..free(tipoPtr)
        ..free(trabajoPtr)
        ..free(nombrePtr);
    }
  }

  /// Como [enviarBytes] pero manda el trabajo DOSIFICADO: un solo job (un
  /// `StartDocPrinter`/`EndDocPrinter`), con **un `WritePrinter` por segmento** y
  /// una pausa de [pausaMs] entre segmentos. La impresora ve un stream continuo,
  /// solo entregado a ritmo controlado.
  ///
  /// ## Qué problema resuelve
  ///
  /// Las térmicas USB baratas (3nStar RPT004, 128 KB de buffer) pierden el final
  /// del recibo en tiradas largas: el raster entra de un saque, desborda el
  /// buffer y el firmware descarta la cola (el pie/slogan sale en blanco).
  /// Entregando el raster en ráfagas chicas ([segmentos] = bandas `GS v 0`
  /// completas, armadas por `comandosReciboEscPosSegmentado`) con pausas,
  /// la tasa de entrada queda acotada a la del cabezal y el buffer no se llena.
  ///
  /// Es la versión USB del "envío lento" de Bluetooth. **Opt-in, Windows-only**:
  /// el camino normal ([enviarBytes], una sola escritura) queda byte-idéntico y
  /// es el default. Cada segmento es un comando ESC/POS COMPLETO → cortar entre
  /// segmentos nunca parte un raster a la mitad (lección v0.22.10-13).
  ///
  /// Devuelve false ante cualquier fallo, nunca lanza.
  Future<bool> enviarSegmentos({
    required String nombreImpresora,
    required List<List<int>> segmentos,
    String nombreTrabajo = 'Recibo',
    int pausaMs = 35,
  }) async {
    if (!disponible) return false;
    if (nombreImpresora.isEmpty || segmentos.isEmpty) return false;

    final nombrePtr = nombreImpresora.toNativeUtf16();
    final trabajoPtr = nombreTrabajo.toNativeUtf16();
    final tipoPtr = 'RAW'.toNativeUtf16();
    final handlePtr = calloc<HANDLE>();
    final escritosPtr = calloc<DWORD>();
    final docInfo = calloc<DOC_INFO_1>();

    try {
      if (OpenPrinter(nombrePtr, handlePtr, nullptr) == 0) {
        if (kDebugMode) {
          debugPrint('WindowsRawPrinter: no se pudo abrir "$nombreImpresora"');
        }
        return false;
      }
      final handle = handlePtr.value;
      try {
        docInfo.ref
          ..pDocName = trabajoPtr
          ..pOutputFile = nullptr
          ..pDatatype = tipoPtr;
        if (StartDocPrinter(handle, 1, docInfo) == 0) {
          if (kDebugMode) debugPrint('WindowsRawPrinter: StartDocPrinter falló');
          return false;
        }
        try {
          if (StartPagePrinter(handle) == 0) {
            if (kDebugMode) {
              debugPrint('WindowsRawPrinter: StartPagePrinter falló');
            }
            return false;
          }
          try {
            for (var i = 0; i < segmentos.length; i++) {
              final seg = segmentos[i];
              if (seg.isEmpty) continue;
              // Buffer nativo POR segmento: se asigna y libera en el loop para no
              // arrastrar una fuga entre bandas (un recibo largo = ~40 bandas).
              final datos = calloc<Uint8>(seg.length);
              try {
                datos.asTypedList(seg.length).setAll(0, seg);
                final ok = WritePrinter(handle, datos, seg.length, escritosPtr);
                if (ok == 0 || escritosPtr.value != seg.length) {
                  if (kDebugMode) {
                    debugPrint('WindowsRawPrinter: banda $i escribió '
                        '${escritosPtr.value} de ${seg.length} bytes');
                  }
                  return false;
                }
              } finally {
                calloc.free(datos);
              }
              // Pausa ENTRE segmentos (no después del último) → dosifica la
              // entrada al buffer de la térmica.
              if (i < segmentos.length - 1 && pausaMs > 0) {
                await Future<void>.delayed(Duration(milliseconds: pausaMs));
              }
            }
            return true;
          } finally {
            EndPagePrinter(handle);
          }
        } finally {
          EndDocPrinter(handle);
        }
      } finally {
        ClosePrinter(handle);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('WindowsRawPrinter.enviarSegmentos: $e');
      return false;
    } finally {
      calloc
        ..free(docInfo)
        ..free(escritosPtr)
        ..free(handlePtr);
      malloc
        ..free(tipoPtr)
        ..free(trabajoPtr)
        ..free(nombrePtr);
    }
  }
}
