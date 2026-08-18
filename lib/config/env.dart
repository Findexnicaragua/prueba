// Lee las variables de entorno pasadas con --dart-define o --dart-define-from-file.
// ConfiguraciÃ³n base para Findex con defaults directos para build nativo.
class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://vowjhcekftogpuucoorl.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvd2poY2VrZnRvZ3B1dWNvb3JsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY4MjYwMTEsImV4cCI6MjEwMjQwMjAxMX0.5sLl9wybIVXRIlMzF2pWXb5aLc0m76PSo4T9TSf8cG0',
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