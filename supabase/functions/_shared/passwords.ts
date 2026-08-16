/// Genera una password aleatoria de 16 chars usando crypto.getRandomValues.
/// Sincronizar el alphabet con _ForzarPasswordDialog del cliente Flutter.
export function generarPasswordSegura(): string {
  const chars =
    "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%*-+";
  const n = chars.length; // 63
  // Rejection sampling para eliminar el sesgo de módulo: 256 % 63 = 4, así que
  // un `bytes[i] % 63` crudo hacía salir los primeros 4 chars algo más seguido.
  // Descartamos los bytes del tramo final que no es múltiplo de `n` (>= 252) y
  // pedimos más bytes hasta completar 16 chars con distribución uniforme.
  const limit = Math.floor(256 / n) * n; // 252
  let out = "";
  while (out.length < 16) {
    const buf = new Uint8Array(16);
    crypto.getRandomValues(buf);
    for (let i = 0; i < buf.length && out.length < 16; i++) {
      if (buf[i] < limit) {
        out += chars[buf[i] % n];
      }
    }
  }
  return out;
}
