-- 0130 — Email opcional del cliente
-- Campo de contacto adicional (opcional) en información personal del cliente.
-- Aditivo: las apps nuevas lo esperan; las viejas lo ignoran. Sync rules usan
-- SELECT * en los buckets de clientes → la columna se sincroniza sola (no hay
-- que tocar sync-rules.yaml). NO se bumpea _dbWipeVersion (columna aditiva,
-- PowerSync la aplica in-place — política R4).

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS email text;

COMMENT ON COLUMN public.clientes.email IS
  'Correo electrónico del cliente (opcional). Sin validación server; el cliente valida formato.';
