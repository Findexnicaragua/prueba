import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/validators.dart';

/// Acciones del sistema operativo (llamar, abrir mapa de navegación, etc.).
/// Web-safe: en mobile abre la app nativa; en web hace fallback a clipboard
/// + snackbar cuando no aplica.
class ExternalActions {
  /// Abre el dialer con el teléfono. En web copia al clipboard.
  static Future<void> llamar(BuildContext context, String telefono) async {
    final normalizado = sanitizePhone(telefono);
    if (kIsWeb) {
      await Clipboard.setData(ClipboardData(text: normalizado));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Teléfono $normalizado copiado')),
        );
      }
      return;
    }
    final uri = Uri.parse('tel:$normalizado');
    // NO usar canLaunchUrl — en Android 11+ retorna false sin <queries> en el
    // AndroidManifest aunque haya un dialer (package visibility). launchUrl
    // directo + try/catch es el patrón correcto (ver update_banner.dart).
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir el marcador')),
        );
      }
    }
  }

  /// Abre WhatsApp con el teléfono y, opcional, un texto prellenado. Usa
  /// `https://wa.me/<n>?text=...` en TODAS las plataformas: el esquema `https`
  /// está declarado en el `<queries>` del AndroidManifest, así que `launchUrl`
  /// directo + try/catch funciona (NO usar `canLaunchUrl` con `whatsapp://`:
  /// retorna false en Android 11+ sin declarar ese esquema → no abría). El
  /// teléfono se normaliza a internacional con código país (Nicaragua 505).
  static Future<void> whatsapp(BuildContext context, String telefono,
      {String? texto}) async {
    final n = phoneWhatsappIntl(telefono);
    if (n.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('El cliente no tiene teléfono')),
        );
      }
      return;
    }
    final q = (texto != null && texto.isNotEmpty)
        ? '?text=${Uri.encodeComponent(texto)}'
        : '';
    final uri = Uri.parse('https://wa.me/$n$q');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir WhatsApp')),
        );
      }
    }
  }

  /// Abre la app de mapas/navegación con coordenadas.
  /// Android/iOS: usa esquema geo:; web: Google Maps.
  static Future<void> navegarA(
    BuildContext context, {
    required double lat,
    required double lng,
    String? label,
  }) async {
    final uri = kIsWeb
        ? Uri.parse(
            'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng')
        : Uri.parse('geo:$lat,$lng?q=$lat,$lng${label != null ? "(${Uri.encodeComponent(label)})" : ""}');
    // NO usar canLaunchUrl — en Android 11+ retorna false sin <queries> en el
    // AndroidManifest aunque haya app de mapas (package visibility). launchUrl
    // directo + try/catch es el patrón correcto (ver update_banner.dart).
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay app de mapas instalada')),
        );
      }
    }
  }
}
