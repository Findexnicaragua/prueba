// Lee las variables de entorno pasadas con --dart-define o --dart-define-from-file.
// Configuración base para Findex con defaults directos para build nativo.
class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://vowjhcekftogpuucoorl.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_l8o4VaOAZoEF0fwkamxwvw_YhqUZw2_',
  );
  static const powersyncUrl = String.fromEnvironment(
    'POWERSYNC_URL',
    defaultValue: 'https://6a80ff94f16f9067844280a4.powersync.journeyapps.com',
  );
  static const powersyncTokenEndpoint = String.fromEnvironment(
    'POWERSYNC_TOKEN_ENDPOINT',
    defaultValue: 'https://vowjhcekftogpuucoorl.supabase.co/functions/v1/powersync-auth',
  );

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      powersyncUrl.isNotEmpty &&
      powersyncTokenEndpoint.isNotEmpty;
}