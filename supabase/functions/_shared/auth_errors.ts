/// Superset de traducciones de errores de Supabase Auth a español.
/// Consolida los patrones de las 5 funciones que lo usaban inline.
export function humanizeAuthError(raw: string): string {
  const lower = raw.toLowerCase();
  if (
    /already.*(registered|exists)/.test(lower) ||
    lower.includes("user already") ||
    lower.includes("email_exists") ||
    lower.includes("duplicate")
  ) {
    return "Ya existe un usuario con ese email — usá otro o contactá soporte.";
  }
  if (lower.includes("sending invite") || lower.includes("sending email")) {
    return "El proveedor de email rechazó el envío. Si estás usando " +
      "Resend en sandbox, solo podés invitar al email dueño de tu " +
      "cuenta Resend — para invitar a otros, verificá tu dominio.";
  }
  if (
    lower.includes("password should be at least") ||
    lower.includes("weak password")
  ) {
    return "La contraseña no cumple los requisitos mínimos del servidor " +
      "(longitud o complejidad).";
  }
  if (lower.includes("user not found")) {
    return "Usuario no encontrado en auth.users — pudo haber sido " +
      "eliminado entre el guard y el update.";
  }
  if (lower.includes("invalid email") || lower.includes("invalid_format")) {
    return "Email inválido según el proveedor.";
  }
  if (lower.includes("rate limit")) {
    return "Rate limit del proveedor alcanzado — esperá un rato y reintentá.";
  }
  // No devolver el error raw al cliente — puede leakear nombres internos
  // de enums del SDK. Log server-side y mensaje genérico afuera.
  console.error("humanizeAuthError: unmatched error:", raw);
  return "Error de autenticación — contactá soporte.";
}
