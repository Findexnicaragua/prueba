import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Etiqueta con el nombre + versión de la app, leída del pubspec vía
/// `package_info_plus` (la misma fuente que el AppBar del super_admin y el
/// `UpdateService`). Se muestra al pie del sidebar del admin, en el login y en
/// el perfil del cobrador para que el usuario sepa en qué versión está parado.
///
/// Incluye el BUILD NUMBER, no sólo el semver: entre dos compilaciones de la
/// misma versión —que es lo normal mientras se prueba un cambio— el semver es
/// idéntico y la etiqueta no distingue nada. El 2026-08-11 se instaló un build
/// nuevo, se pidió validarlo y el dueño no tenía forma de saber si estaba
/// mirando ése o el anterior; los dos decían "v0.32.0". El build number sí
/// cambia en cada compilación, así que ahora la etiqueta cumple lo que promete:
/// confirmar que el update se aplicó.
///
/// En web `buildNumber` puede venir vacío; en ese caso se muestra sólo el
/// semver.
class AppVersionLabel extends StatelessWidget {
  const AppVersionLabel({super.key, this.padding});

  /// Padding alrededor del texto. Default: vertical 8, horizontal 16.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (_, snap) {
        final version = snap.data?.version;
        final build = snap.data?.buildNumber ?? '';
        final texto = version == null
            ? ''
            : (build.isEmpty ? 'v$version' : 'v$version ($build)');
        return Padding(
          padding: padding ??
              const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Text(
            texto,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
        );
      },
    );
  }
}
