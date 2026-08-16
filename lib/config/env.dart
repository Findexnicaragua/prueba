// Lee las variables de entorno pasadas con --dart-define o --dart-define-from-file.
// Ejemplo de .env.json:
// {
//   "SUPABASE_URL": "https://xxx.supabase.co",
//   "SUPABASE_ANON_KEY": "eyJ...",
//   "POWERSYNC_URL": "https://YOUR-VPS-IP.sslip.io",
//   "POWERSYNC_TOKEN_ENDPOINT": "https://xxx.supabase.co/functions/v1/powersync-auth"
// }
class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const powersyncUrl = String.fromEnvironment('POWERSYNC_URL');
  static const powersyncTokenEndpoint =
      String.fromEnvironment('POWERSYNC_TOKEN_ENDPOINT');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      powersyncUrl.isNotEmpty &&
      powersyncTokenEndpoint.isNotEmpty;
}
