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
