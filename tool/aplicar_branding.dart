// Aplica el branding de un tenant antes de buildear (white-label, Opción B).
//
// - Genera el ícono cuadrado de la app (forma A: el logo completo centrado
//   sobre fondo blanco) en `assets/icon/app_icon.png` → de ahí salen los
//   mipmaps de Android y el .ico de Windows (flutter_launcher_icons) y el
//   logo del MSIX.
// - Copia el logo ancho tal cual a `assets/branding/login_logo.png` → es la
//   banda que se muestra en la pantalla de login.
//
// Uso:
//   dart run tool/aplicar_branding.dart <slug>            (aplica al build)
//   dart run tool/aplicar_branding.dart <slug> --preview  (solo genera un
//       branding/<slug>/icon_preview.png para revisar, sin tocar assets/)
//
// Lo invoca `Install Steps/build-release.ps1 -Tenant <slug>`; restaura los
// assets con `git checkout` al terminar para no commitear un branding.
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final preview = args.contains('--preview');
  if (positional.isEmpty) {
    stderr.writeln('uso: dart run tool/aplicar_branding.dart <slug> [--preview]');
    exit(64);
  }
  final slug = positional.first;

  final logoFile = File('branding/$slug/logo.png');
  if (!logoFile.existsSync()) {
    stderr.writeln('ERROR: no existe ${logoFile.path}');
    exit(1);
  }

  final logoBytes = logoFile.readAsBytesSync();
  final decoded = img.decodePng(logoBytes);
  if (decoded == null) {
    stderr.writeln('ERROR: no se pudo decodificar ${logoFile.path} como PNG');
    exit(1);
  }
  // Recorta el margen transparente para que el logo quede centrado y bien
  // grande en el cuadrado, sin importar cuánto padding traiga el PNG fuente.
  final logo = img.trim(decoded, mode: img.TrimMode.transparent);

  // Lienzo cuadrado opaco blanco (los íconos transparentes salen negros en
  // varios launchers de Android → fondo blanco siempre).
  const size = 1024;
  const inset = 0.86; // el logo ocupa 86% del lado, centrado (forma A)
  final canvas = img.Image(width: size, height: size, numChannels: 4);
  img.fill(canvas, color: img.ColorRgba8(255, 255, 255, 255));

  final maxBox = (size * inset).round();
  final aspect = logo.width / logo.height;
  final int w;
  final int h;
  if (aspect >= 1) {
    w = maxBox;
    h = (maxBox / aspect).round();
  } else {
    h = maxBox;
    w = (maxBox * aspect).round();
  }
  final resized = img.copyResize(logo,
      width: w, height: h, interpolation: img.Interpolation.cubic);
  img.compositeImage(canvas, resized,
      dstX: ((size - w) / 2).round(), dstY: ((size - h) / 2).round());

  final iconBytes = img.encodePng(canvas);

  if (preview) {
    File('branding/$slug/icon_preview.png').writeAsBytesSync(iconBytes);
    stdout.writeln('PREVIEW -> branding/$slug/icon_preview.png  (${size}x$size)');
    return;
  }

  File('assets/icon/app_icon.png').writeAsBytesSync(iconBytes);
  Directory('assets/branding').createSync(recursive: true);
  File('assets/branding/login_logo.png').writeAsBytesSync(logoBytes);
  stdout.writeln('Branding aplicado para "$slug":');
  stdout.writeln('  assets/icon/app_icon.png       (ícono ${size}x$size)');
  stdout.writeln('  assets/branding/login_logo.png (logo del login)');
}
