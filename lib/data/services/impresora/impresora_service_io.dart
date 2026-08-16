import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'recibo_escpos.dart';

/// Información de una impresora Bluetooth pareada.
class ImpresoraBT {
  const ImpresoraBT({required this.nombre, required this.mac});
  final String nombre;
  final String mac;
}

/// Servicio para imprimir recibos en impresoras térmicas Bluetooth.
///
/// El recibo se imprime como IMAGEN: el call-site CAPTURA el widget Flutter
/// `ReciboTicket` a PNG (con `screenshot`) y nos lo pasa. Lo decodificamos,
/// lo pasamos a monocromo por UMBRAL (no dithering — es line-art, no foto) y lo
/// enviamos como raster ESC/POS.
/// Como lo renderiza Skia (el mismo motor que dibuja la pantalla), las tildes
/// salen perfectas en CUALQUIER impresora — no depende del codepage del modelo
/// ni de una fuente embebida. Es 100% OFFLINE y la preview = lo que se imprime.
///
/// Mobile only — web tiene un stub paralelo.
class ImpresoraService {
  bool get soportado => true;

  Future<bool> isBluetoothEnabled() async {
    try {
      return await PrintBluetoothThermal.bluetoothEnabled;
    } catch (_) {
      return false;
    }
  }

  /// Lista impresoras BT pareadas en el sistema operativo. NO escanea.
  Future<List<ImpresoraBT>> listarPareadas() async {
    final raw = await PrintBluetoothThermal.pairedBluetooths;
    return raw
        // ignore: deprecated_member_use — typo del paquete (macAdress).
        .map((b) => ImpresoraBT(nombre: b.name, mac: b.macAdress))
        .toList();
  }

  /// Imprime una IMAGEN (PNG) ya renderizada por el call-site (captura del
  /// widget `ReciboTicket` vía `screenshot`). Devuelve true al éxito.
  ///
  /// [pngBytes] = PNG del recibo. Idealmente ya viene al ancho exacto del papel
  /// (capturado con `targetSize` = dots), pero igual reescalamos por seguridad.
  /// [anchoMm] = 58 u 80 (ancho del papel).
  ///
  /// Flujo OFFLINE: decodifica el PNG en memoria (sin red), monocromo por
  /// UMBRAL (sin dither), y lo emite como raster **GS v 0 armado a mano** (polaridad
  /// 1=negro y ancho explícitos). Se eligió GS v 0 manual sobre `gen.imageRaster`
  /// porque este último codificaba mal en algunas térmicas (salía negativo/
  /// angosto) — confirmado en campo (GOOJPRT PT-210). Si algo falla, false.
  Future<bool> imprimirImagen({
    required String macImpresora,
    required Uint8List pngBytes,
    required int anchoMm,
    bool envioLento = false,
  }) async {
    try {
      // El armado del raster vive en `recibo_escpos.dart` — compartido con la
      // impresion directa de Windows. Este transporte NO cambio: los bytes que
      // salen de ahi son los mismos que armaba este metodo.
      final bytes = comandosReciboEscPos(pngBytes, anchoMm);
      if (bytes == null) return false;
      return _enviarBytes(macImpresora, bytes, envioLento: envioLento);
    } catch (e) {
      if (kDebugMode) debugPrint('Impresora imagen: $e');
      return false;
    }
  }




  /// Imprime bytes ESC/POS ya armados (modo COMPATIBLE — texto nativo).
  /// El call-site los construye con `construirReciboTextoEscPos` (texto + codepage
  /// español + logo chico). MISMO transporte que `imprimirImagen`
  /// (connect → write → disconnect), pero los datos son LIVIANOS (texto, no un
  /// raster gigante) → no desborda el buffer de impresoras baratas.
  Future<bool> imprimirTexto({
    required String macImpresora,
    required List<int> bytes,
    bool envioLento = false,
  }) async {
    try {
      return await _enviarBytes(macImpresora, bytes, envioLento: envioLento);
    } catch (e) {
      if (kDebugMode) debugPrint('Impresora texto: $e');
      return false;
    }
  }

  /// Imprime un recibo de prueba para validar conexión + papel.
  ///
  /// ASCII-only (sin tildes) a propósito: es solo un test de conexión, no debe
  /// depender del codepage del modelo. El reset ESC @ saca la térmica de
  /// cualquier modo raro antes del texto.
  Future<bool> imprimirPrueba({
    required String macImpresora,
    required int anchoMm,
    bool envioLento = false,
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(_size(anchoMm), profile);
    final bytes = <int>[
      // Reset/init ANTES del primer texto.
      0x1B, 0x40,
      ...gen.text('PRUEBA DE IMPRESION',
          styles: const PosStyles(align: PosAlign.center, bold: true)),
      ...gen.feed(1),
      ...gen.text('Si lees esto la impresora esta OK',
          styles: const PosStyles(align: PosAlign.center)),
      ...gen.feed(3),
      ...gen.cut(),
    ];
    return _enviarBytes(macImpresora, bytes, envioLento: envioLento);
  }

  /// Conecta → escribe → desconecta. Maneja errores silenciosos.
  ///
  /// [envioLento] (opt-in POR DISPOSITIVO — toggle en Perfil → Impresora):
  /// para impresoras lentas/baratas (3nStar roja) que pierden el FINAL del
  /// recibo (el pie sale en blanco). Fix: el `writeBytes` puede retornar con
  /// datos aún encolados en el stack BT; un disconnect inmediato corta la
  /// transmisión y la cola del trabajo (siempre el pie) se pierde en el aire
  /// → se espera ~2s tras el write ANTES de desconectar (settle).
  ///
  /// El WRITE es ÚNICO e idéntico al de siempre A PROPÓSITO — la v1 de este
  /// modo (v0.24.3) partía en chunks de 512B con pausas de 20ms y eso ROMPIÓ
  /// el raster en la 3nStar (campo, 2026-07-14): las pausas caen EN MEDIO del
  /// bloque binario del logo/imagen (GS v 0 + bitmap), el firmware se
  /// desincroniza y imprime el resto del bitmap como TEXTO (basura de
  /// símbolos). Antes del chunking esa impresora tragaba el raster completo
  /// bien → nunca hubo overflow; el único problema era el disconnect. NO
  /// reintroducir chunking; si algún día hace falta, cortar SOLO en límites
  /// de comando, jamás dentro de un raster.
  /// Con el toggle APAGADO (default) el envío es BYTE-IDÉNTICO al de siempre —
  /// lección v0.22.10-13: NUNCA tocar el transporte global por un modelo.
  Future<bool> _enviarBytes(String mac, List<int> bytes,
      {bool envioLento = false}) async {
    try {
      final ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      if (!ok) return false;
      final result = await PrintBluetoothThermal.writeBytes(bytes);
      if (envioLento) {
        // Settle: dejar que la impresora termine de RECIBIR e imprimir la
        // cola del trabajo antes de cortar el enlace.
        await Future.delayed(const Duration(milliseconds: 2000));
      }
      await PrintBluetoothThermal.disconnect;
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('Impresora: $e');
      try {
        await PrintBluetoothThermal.disconnect;
      } catch (_) {}
      return false;
    }
  }

  PaperSize _size(int mm) => mm >= 80 ? PaperSize.mm80 : PaperSize.mm58;
}
