import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Etiqueta con el nombre + versión de la app, leída del pubspec vía
/// `package_info_plus` (la misma fuente que el AppBar del super_admin y el
/// `UpdateService`). Se muestra al pie del sidebar del admin, en el login y en
/// el perfil del cobrador para que el usuario sepa en qué versión está parado
/// (sirve para confirmar que un update se aplicó). En web `buildNumber` puede
/// venir vacío, así que sólo mostramos el semver.
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
        final texto = version == null ? '' : 'v$version';
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
