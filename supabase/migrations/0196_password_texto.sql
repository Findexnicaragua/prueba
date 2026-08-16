-- Columna para almacenar la contraseña en texto recuperable.
-- NO se incluye en sync rules — nunca llega al dispositivo.
-- Solo accesible via Edge Function (ver-password-cobrador) con
-- re-autenticación del admin.
ALTER TABLE cobradores ADD COLUMN IF NOT EXISTS password_texto text;
