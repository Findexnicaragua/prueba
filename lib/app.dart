import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/router.dart';
import 'config/theme.dart';
import 'data/providers/foto_comprobante_provider.dart';
import 'data/services/foto_comprobante_service.dart';

/// Key global del ScaffoldMessenger raíz. Permite mostrar SnackBars
/// desde lugares que no tienen un Scaffold ascendente (R8: listener
/// global de errores de upload de fotos).
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();


/// Si esta build es la de PRUEBA (`branding/test`).
///
/// Se resuelve en tiempo de COMPILACIÓN: `--dart-define=TENANT=test` lo pone el
/// script de release a partir del slug de la marca, así que no hay forma de
/// encenderlo por error en un build de un ISP real.
const kEsBuildDePrueba = String.fromEnvironment('TENANT') == 'test';

class IspBillingApp extends ConsumerWidget {
  const IspBillingApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // R8: surface errores de upload de fotos al usuario via SnackBar
    // global. El service emite un UploadResult al final de cada corrida
    // con `failed > 0` si alguna falló — mostramos un único banner
    // resumido en vez de N por foto. Las corridas sin intento de upload
    // no emiten, así que esto es silencioso en happy path.
    //
    // El throttle interno del service evita spam en reconexiones
    // intermitentes (mismo error repetido cada N minutos pasa una vez).
    ref.listen<AsyncValue<UploadResult>>(uploadResultsProvider, (_, next) {
      final result = next.valueOrNull;
      if (result == null || result.failed == 0) return;

      // No mostrar si no hay sesión activa — el user anterior se
      // deslogueó pero el worker pudo haber emitido en transición.
      // El cobrador en /login no debería ver errores ajenos.
      if (Supabase.instance.client.auth.currentSession == null) return;

      final scheme = Theme.of(context).colorScheme;
      final mensaje = result.failed == 1
          ? 'No se pudo subir 1 foto. Se reintenta automáticamente.'
          : 'No se pudieron subir ${result.failed} fotos. '
              'Se reintentan automáticamente.';

      // No usamos hideCurrentSnackBar — confiamos en la queue de
      // Material. Sino arrancamos el snack de "Cobro registrado" del
      // flow de cobro o el de éxito del botón manual de /perfil.
      rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
        content: Text(mensaje),
        backgroundColor: scheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Ver detalles',
          textColor: scheme.onErrorContainer,
          onPressed: () {
            final ctx = rootScaffoldMessengerKey.currentContext;
            if (ctx != null) GoRouter.of(ctx).push('/perfil');
          },
        ),
      ));
    });

    return MaterialApp.router(
      title: 'CRM',
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      theme: AppTheme.light(),
      routerConfig: ref.watch(routerProvider),
      debugShowCheckedModeBanner: false,
      // Cinta de esquina en la build de PRUEBA (`--dart-define=TENANT=test`,
      // marca `branding/test`). Va en el `builder` para que se vea en TODA la
      // app, incluidos los diálogos a pantalla completa.
      //
      // Por qué existe: la build de prueba apunta al MISMO Supabase que
      // producción. Teniéndola instalada al lado de la oficial —cosa que el
      // `applicationId` propio permite—, un cobro registrado desde la app
      // equivocada con un usuario real es un cobro real. La cinta es lo único
      // que avisa desde adentro cuál se abrió.
      builder: kEsBuildDePrueba
          ? (context, child) => Banner(
                message: 'PRUEBA',
                location: BannerLocation.topEnd,
                color: const Color(0xFFB7791F),
                child: child ?? const SizedBox.shrink(),
              )
          : null,
      locale: const Locale('es', 'NI'),
      supportedLocales: const [
        Locale('es', 'NI'),
        Locale('es'),
        Locale('en'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
